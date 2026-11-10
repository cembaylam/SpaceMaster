import Synchronization

/// A directory in the scan tree. Files are not nodes: their bytes are summed into the directory's totals
/// (and re-listed on demand when the UI shows the folder), which keeps memory proportional to the number
/// of directories rather than files.
public final class Node: @unchecked Sendable {
    public enum State: UInt8, Sendable {
        case unlisted = 0   // never scanned
        case queued = 1     // waiting for / being listed by a worker
        case listed = 2     // this directory listed, descendants still running
        case done = 3       // whole subtree scanned
    }

    public let name: String
    public unowned(unsafe) let parent: Node?

    /// Bytes of everything scanned so far in this subtree. Live while scanning, final once `isDone`.
    public let total = Atomic<Int64>(0)
    /// Number of files + directories scanned so far in this subtree.
    public let items = Atomic<Int64>(0)
    let stateRaw = Atomic<UInt8>(0)

    // Guarded by Scanner.treeLock.
    var children: [Node] = []
    var remaining = 0
    /// Mount points: own scan root; their bytes are not added to ancestors.
    var isMountRoot = false
    /// Does not notify its parent on completion (mount roots, nodes being rescanned).
    var silent = false
    /// Directory could not be read (permissions).
    var unreadable = false

    init(name: String, parent: Node?) {
        self.name = name
        self.parent = parent
    }

    public var state: State { State(rawValue: stateRaw.load(ordering: .acquiring)) ?? .unlisted }
    public var isDone: Bool { state == .done }
    public var totalBytes: Int64 { total.load(ordering: .relaxed) }
    public var itemCount: Int64 { items.load(ordering: .relaxed) }

    /// Absolute path of this node.
    public var path: String {
        var parts: [String] = []
        var n: Node? = self
        while let x = n, x.parent != nil { parts.append(x.name); n = x.parent }
        return "/" + parts.reversed().joined(separator: "/")
    }
}
