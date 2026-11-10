import Foundation

/// A directory entry as shown in the UI.
public struct Entry: Sendable {
    public enum Kind: UInt8, Sendable { case file, directory, symlink, other }
    public var name: String
    public var kind: Kind
    /// Allocated bytes for files; for directories the UI fills this from the scan tree.
    public var size: Int64
    public var mtime: Double
    public var flags: UInt32
    public var isHidden: Bool
    public var isPackage: Bool

    public var isDirectory: Bool { kind == .directory }
}

public enum DirListing {
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "xcodeproj", "xcworkspace",
        "pkg", "appex", "prefPane", "saver", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
    ]

    /// Lists one directory with all the attributes the UI needs.
    public static func list(_ path: String) throws -> [Entry] {
        let buffer = DirEnumerator.makeBuffer()
        defer { buffer.deallocate() }
        var out: [Entry] = []
        out.reserveCapacity(256)
        try DirEnumerator.enumerate(path: path, buffer: buffer, mode: .full) { e in
            let name = String(decoding: e.name, as: UTF8.self)
            let kind: Entry.Kind
            switch e.objType {
            case DirEnumerator.vreg: kind = .file
            case DirEnumerator.vdir: kind = .directory
            case DirEnumerator.vlnk: kind = .symlink
            default: kind = .other
            }
            var package = false
            if kind == .directory, let dot = name.lastIndex(of: "."), dot != name.startIndex {
                package = packageExtensions.contains(name[name.index(after: dot)...].lowercased())
            }
            out.append(Entry(name: name, kind: kind, size: e.alloc, mtime: Double(e.mtime), flags: e.flags,
                             isHidden: e.name.first == UInt8(ascii: ".") || e.flags & FSFlags.hidden != 0,
                             isPackage: package))
        }
        return out
    }
}
