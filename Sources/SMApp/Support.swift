import AppKit
import SMCore
import UniformTypeIdentifiers

// MARK: Model

enum SortKey: String, CaseIterable {
    case size, name, modified
    var title: String { switch self { case .size: "Size"; case .name: "Name"; case .modified: "Date Modified" } }
}

struct Row {
    var name: String
    var kind: Entry.Kind
    var size: Int64
    var mtime: Double
    var isPackage: Bool
    var isHidden: Bool
    var safety: Safety
    var flags: UInt32
    var node: Node?
    /// Subtree still being scanned (size is a lower bound).
    var calculating: Bool
    /// Directory that was never scanned (mount point, cloud placeholder) — size unknown.
    var unknownSize: Bool
    var isDirectory: Bool { kind == .directory }
}

/// One directory as displayed in a column: raw listing + sorted/filtered rows.
@MainActor
final class DirState {
    let path: String
    let node: Node
    var entries: [Entry] = []
    var error: String?
    var ctx: SafetyClassifier.Context
    var rows: [Row] = []
    /// Sum of every entry (hidden or filtered included): the denominator for percentages.
    var total: Int64 = 0
    var maxSize: Int64 = 1
    var anyCalculating = false
    var loadedAt = Date()

    init(path: String, node: Node, ctx: SafetyClassifier.Context) {
        self.path = path; self.node = node; self.ctx = ctx
    }

    func rebuild(model: AppModel, sort: SortKey, reversed: Bool, showHidden: Bool, filter: String) {
        let scanner = model.scanner
        var byName: [String: Node] = [:]
        if entries.contains(where: { $0.kind == .directory }) {
            let kids = scanner.children(of: node)
            byName.reserveCapacity(kids.count)
            for k in kids { byName[k.name] = k }
        }
        var rows: [Row] = []
        rows.reserveCapacity(entries.count)
        var total: Int64 = 0
        var calculating = false
        let needle = filter.lowercased()
        for e in entries {
            var size = e.size
            var calc = false
            var unknown = false
            var n: Node?
            if e.kind == .directory {
                n = byName[e.name]
                if let n {
                    size = n.totalBytes
                    switch n.state {
                    case .done: break
                    case .unlisted: unknown = true; size = 0
                    default: calc = true
                    }
                } else { unknown = true; size = 0 }
            }
            total += size
            if calc { calculating = true }
            if !showHidden && e.isHidden { continue }
            if !needle.isEmpty && !e.name.lowercased().contains(needle) { continue }
            rows.append(Row(name: e.name, kind: e.kind, size: size, mtime: e.mtime, isPackage: e.isPackage,
                            isHidden: e.isHidden, safety: model.classifier.classify(name: e.name, flags: e.flags, isDirectory: e.kind == .directory, in: ctx),
                            flags: e.flags, node: n, calculating: calc, unknownSize: unknown))
        }
        switch sort {
        case .size:
            rows.sort { $0.size != $1.size ? $0.size > $1.size : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .name:
            rows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .modified:
            rows.sort { $0.mtime != $1.mtime ? $0.mtime > $1.mtime : $0.name < $1.name }
        }
        // Size and date default to descending; name to ascending. `reversed` flips whichever applies.
        if reversed { rows.reverse() }
        self.rows = rows
        self.total = total
        self.maxSize = max(1, rows.map(\.size).max() ?? 1)
        self.anyCalculating = calculating
    }

    func index(of name: String?) -> Int? {
        guard let name else { return nil }
        return rows.firstIndex { $0.name == name }
    }
}

// MARK: Share colors

@MainActor enum ShareColor {
    private static var cache: [Int: NSColor] = [:]
    private static var cacheDark: [Int: NSColor] = [:]

    /// Heat color by share of the folder: large → red, mid → green, tiny → blue.
    static func color(share: Double, dark: Bool) -> NSColor {
        let s = max(share, 1e-4)
        let t = min(1, max(0, (log10(s) + 3) / 3))
        let bucket = Int(t * 48)
        if let c = (dark ? cacheDark : cache)[bucket] { return c }
        let tt = Double(bucket) / 48
        let hue = (1 - tt) * 0.64
        let c = NSColor(hue: hue, saturation: dark ? 0.88 : 0.72, brightness: dark ? 0.60 : 0.98, alpha: 1)
        if dark { cacheDark[bucket] = c } else { cache[bucket] = c }
        return c
    }
}

// MARK: Text

@MainActor
final class TextCache {
    static let shared = TextCache()
    enum Face: Int { case name, meta, small, badge }

    let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    let metaFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    private struct Key: Hashable { var s: String; var face: Int; var w: Int }
    private var cache: [Key: (CTLine, CGFloat)] = [:]

    func font(_ f: Face) -> NSFont {
        switch f { case .name: nameFont; case .meta: metaFont; case .small: smallFont; case .badge: badgeFont }
    }

    func baseline(for font: NSFont, rowHeight: CGFloat) -> CGFloat {
        ((rowHeight + font.capHeight) / 2).rounded()
    }

    func line(_ s: String, _ face: Face, maxWidth: CGFloat?) -> (line: CTLine, width: CGFloat) {
        let key = Key(s: s, face: face.rawValue, w: maxWidth.map { Int($0) } ?? -1)
        if let hit = cache[key] { return hit }
        if cache.count > 6000 { cache.removeAll(keepingCapacity: true) }
        // Draw with the context's fill color (set per row) instead of CoreText's default black.
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let attrs: [NSAttributedString.Key: Any] = [.font: font(face), fromContext: true]
        let attr = NSAttributedString(string: s, attributes: attrs)
        var line = CTLineCreateWithAttributedString(attr)
        if let maxWidth, maxWidth > 0, CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            // Middle-ish truncation keeps extensions visible: use end truncation for names under 40pt, middle otherwise.
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), .middle, token) ?? line
        }
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        cache[key] = (line, w)
        return (line, w)
    }
}

// MARK: Icons

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var byPath: [String: NSImage] = [:]
    private var byType: [String: NSImage] = [:]
    private lazy var folder: NSImage = NSWorkspace.shared.icon(for: .folder)
    private lazy var generic: NSImage = NSWorkspace.shared.icon(for: .data)
    private var symbols: [String: NSImage] = [:]

    func icon(for row: Row, dir: String) -> NSImage {
        switch row.kind {
        case .directory:
            if row.isPackage || dir.count < 40 {
                let p = dir == "/" ? "/" + row.name : dir + "/" + row.name
                if let i = byPath[p] { return i }
                if byPath.count > 3000 { byPath.removeAll() }
                let i = NSWorkspace.shared.icon(forFile: p)
                byPath[p] = i
                return i
            }
            return folder
        case .symlink, .other:
            return generic
        case .file:
            let ext = (row.name as NSString).pathExtension.lowercased()
            if ext.isEmpty { return generic }
            if let i = byType[ext] { return i }
            let i = UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? generic
            byType[ext] = i
            return i
        }
    }

    func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold) -> NSImage? {
        let key = "\(name)|\(size)|\(color.hashValue)"
        if let s = symbols[key] { return s }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        symbols[key] = img
        return img
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
