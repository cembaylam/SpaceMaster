import Darwin
import Foundation
import Synchronization
import os

/// Parallel directory-size scanner.
///
/// Workers pull directories from a LIFO stack (depth-first locality, and the folder the user just opened
/// is always on top), list them with `getattrlistbulk`, add the files' bytes to the directory and all of its
/// ancestors with atomic adds, and push sub-directories. The UI reads the atomics at any time for live sizes.
public final class SizeScanner: @unchecked Sendable {
    struct Job {
        var node: Node
        var path: String
        var dev: Int32
    }

    public let root = Node(name: "", parent: nil)

    private let treeLock = OSAllocatedUnfairLock()
    private let cond = NSCondition()
    private var stack: [Job] = []

    /// Directories queued or being listed.
    public let pending = Atomic<Int>(0)
    /// Incremented after each listed directory; the UI polls it to know whether anything changed.
    public let version = Atomic<Int>(0)
    public let dirsScanned = Atomic<Int>(0)
    public let itemsScanned = Atomic<Int>(0)
    public let denied = Atomic<Int>(0)

    public var isScanning: Bool { pending.load(ordering: .relaxed) > 0 }

    public init(threads: Int = max(4, ProcessInfo.processInfo.activeProcessorCount)) {
        root.stateRaw.store(Node.State.unlisted.rawValue, ordering: .relaxed)
        for i in 0..<threads {
            let t = Thread { [weak self] in self?.workerLoop() }
            t.name = "SpaceMaster.scan.\(i)"
            t.qualityOfService = .userInitiated
            t.stackSize = 1 << 20
            t.start()
        }
    }

    // MARK: Public API

    /// Finds or creates the node for an absolute, normalized path (placeholders for unscanned ancestors).
    public func node(forPath path: String) -> Node {
        var node = root
        guard path != "/" else { return node }
        treeLock.withLockUnchecked {
            for comp in path.split(separator: "/") {
                let name = String(comp)
                if let c = node.children.first(where: { $0.name == name }) {
                    node = c
                } else {
                    let c = Node(name: name, parent: node)
                    node.children.append(c)
                    node = c
                }
            }
        }
        return node
    }

    /// Existing children of a node (snapshot).
    public func children(of node: Node) -> [Node] { treeLock.withLockUnchecked { node.children } }

    public func isUnreadable(_ node: Node) -> Bool { treeLock.withLockUnchecked { node.unreadable } }

    /// Scans `node` (and its subtree) if it was never scanned. Runs before everything already queued.
    public func scan(_ node: Node) {
        let path = node.path
        var dev: Int32 = 0
        var st = stat()
        if lstat(path, &st) == 0 { dev = st.st_dev }
        let accept: Bool = treeLock.withLockUnchecked {
            guard node.state == .unlisted else { return false }
            node.stateRaw.store(Node.State.queued.rawValue, ordering: .releasing)
            return true
        }
        guard accept else { return }
        push([Job(node: node, path: path, dev: dev)])
    }

    /// Marks a node as an independent scan root (mounted volume): its bytes stay out of the ancestors.
    public func markMountRoot(_ node: Node) {
        treeLock.withLockUnchecked { node.isMountRoot = true; node.silent = true }
    }

    /// Throws away a finished subtree and scans it again.
    public func rescan(_ node: Node) {
        let accept: Bool = treeLock.withLockUnchecked {
            guard node.state == .done || node.state == .unlisted else { return false }
            if node.state == .done {
                Self.propagate(from: node, bytes: -node.totalBytes, items: -node.itemCount)
            }
            node.children = []
            node.remaining = 0
            node.unreadable = false
            node.silent = true
            node.stateRaw.store(Node.State.unlisted.rawValue, ordering: .releasing)
            return true
        }
        if accept { scan(node) }
    }

    /// Bookkeeping after files in `dir` were deleted.
    public func didRemoveFiles(bytes: Int64, items: Int64, from dir: Node) {
        treeLock.withLockUnchecked { Self.propagate(from: dir, bytes: -bytes, items: -items) }
        version.wrappingAdd(1, ordering: .relaxed)
    }

    /// Bookkeeping after a whole sub-directory was deleted.
    public func didRemoveDirectory(_ child: Node) {
        treeLock.withLockUnchecked {
            guard let parent = child.parent else { return }
            parent.children.removeAll { $0 === child }
            if !child.isMountRoot { Self.propagate(from: parent, bytes: -child.totalBytes, items: -child.itemCount) }
        }
        version.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: Workers

    private func push(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        pending.wrappingAdd(jobs.count, ordering: .relaxed)
        cond.lock()
        stack.append(contentsOf: jobs)
        cond.unlock()
        if jobs.count == 1 { cond.signal() } else { cond.broadcast() }
    }

    private func workerLoop() {
        let buffer = DirEnumerator.makeBuffer()
        while true {
            cond.lock()
            while stack.isEmpty { cond.wait() }
            let job = stack.removeLast()
            cond.unlock()
            process(job, buffer: buffer)
            pending.wrappingSubtract(1, ordering: .relaxed)
        }
    }

    private struct Sub {
        var name: String
        var dev: Int32
        var skip: SkipKind
    }
    private static func isMountName(_ n: UnsafeBufferPointer<UInt8>, root: Bool) -> Bool {
        let name = String(decoding: n, as: UTF8.self)
        return root ? (name == "Volumes" || name == "dev" || name == "home" || name == "net" || name == ".vol") : name == "Volumes"
    }
    private enum SkipKind { case none, mount, dataless }

    private func process(_ job: Job, buffer: UnsafeMutableRawPointer) {
        var subs: [Sub] = []
        var fileBytes: Int64 = 0
        var fileCount = 0
        var failed = false
        let isRoot = job.path == "/"
        // getattrlistbulk reports a mount point's *covered* directory device, so the device check below can't see
        // these; skip them by path (the Data volume would otherwise be counted twice via /System/Volumes/Data).
        let isSystem = job.path == "/System"
        do {
            try DirEnumerator.enumerate(path: job.path, buffer: buffer, mode: .scan) { e in
                if e.objType == DirEnumerator.vdir {
                    var skip = SkipKind.none
                    if isRoot || isSystem, Self.isMountName(e.name, root: isRoot) { skip = .mount }
                    else if e.flags & FSFlags.dataless != 0 { skip = .dataless }
                    else if e.dev != job.dev && !isRoot { skip = .mount }
                    subs.append(Sub(name: String(decoding: e.name, as: UTF8.self), dev: e.dev, skip: skip))
                } else {
                    fileBytes &+= e.alloc
                    fileCount += 1
                }
            }
        } catch {
            failed = true
        }
        if failed { denied.wrappingAdd(1, ordering: .relaxed) }

        let node = job.node
        var spawn: [Job] = []
        treeLock.withLockUnchecked {
            var existing: [String: Node] = [:]
            if !node.children.isEmpty { existing.reserveCapacity(node.children.count); for c in node.children { existing[c.name] = c } }
            var remaining = 1 // our own token, released after spawning
            node.children.reserveCapacity(node.children.count + subs.count)
            var childPath: String?
            for s in subs {
                let c: Node
                if let ex = existing[s.name] { c = ex } else {
                    c = Node(name: s.name, parent: node)
                    node.children.append(c)
                }
                switch s.skip {
                case .mount:
                    c.isMountRoot = true; c.silent = true
                case .dataless:
                    c.stateRaw.store(Node.State.done.rawValue, ordering: .relaxed)
                case .none:
                    switch c.state {
                    case .unlisted:
                        c.stateRaw.store(Node.State.queued.rawValue, ordering: .relaxed)
                        if childPath == nil { childPath = job.path == "/" ? "" : job.path }
                        spawn.append(Job(node: c, path: childPath! + "/" + s.name, dev: s.dev))
                        remaining += 1
                    case .queued, .listed:
                        remaining += 1
                    case .done:
                        break
                    }
                }
            }
            node.unreadable = failed
            node.remaining = remaining
            node.stateRaw.store(Node.State.listed.rawValue, ordering: .releasing)
        }

        let items = Int64(fileCount + subs.count)
        if fileBytes != 0 || items != 0 {
            // Lock-free: atomic adds up the ancestor chain (stops at mount roots).
            Self.propagate(from: node, bytes: fileBytes, items: items)
        }
        dirsScanned.wrappingAdd(1, ordering: .relaxed)
        itemsScanned.wrappingAdd(Int(items), ordering: .relaxed)
        version.wrappingAdd(1, ordering: .relaxed)

        push(spawn)

        treeLock.withLockUnchecked {
            node.remaining -= 1
            if node.remaining == 0 { Self.completeLocked(node) }
        }
    }

    /// Adds to the node and every ancestor, stopping after a mount root. Atomics only; safe with or without the lock.
    private static func propagate(from node: Node, bytes: Int64, items: Int64) {
        var n: Node? = node
        while let x = n {
            if bytes != 0 { x.total.wrappingAdd(bytes, ordering: .relaxed) }
            if items != 0 { x.items.wrappingAdd(items, ordering: .relaxed) }
            if x.isMountRoot { break }
            n = x.parent
        }
    }

    /// Marks `start` done and cascades up while parents have no outstanding children. Caller holds the lock.
    private static func completeLocked(_ start: Node) {
        var n = start
        while true {
            n.stateRaw.store(Node.State.done.rawValue, ordering: .releasing)
            let wasSilent = n.silent
            n.silent = n.isMountRoot
            guard !wasSilent, let p = n.parent, p.state == .listed else { return }
            p.remaining -= 1
            if p.remaining == 0 { n = p } else { return }
        }
    }
}
