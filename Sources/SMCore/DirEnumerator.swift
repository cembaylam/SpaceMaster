import Darwin

/// One raw directory entry as returned by `getattrlistbulk(2)`. `name` points into the enumeration
/// buffer and is only valid inside the callback.
public struct RawEntry {
    public var name: UnsafeBufferPointer<UInt8>
    public var objType: UInt32
    public var dev: Int32
    public var flags: UInt32
    public var mtime: Int64
    /// Bytes allocated on disk (all forks). 0 for directories.
    public var alloc: Int64

    public var isDirectory: Bool { objType == DirEnumerator.vdir }
    public var isSymlink: Bool { objType == DirEnumerator.vlnk }
}

/// Bulk directory enumeration: one syscall returns names and attributes for many entries (no per-entry stat).
public enum DirEnumerator {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let code: Int32
        public var description: String { String(cString: strerror(code)) }
    }

    public enum Mode: Sendable { case scan, full }

    public static let vreg: UInt32 = 1, vdir: UInt32 = 2, vlnk: UInt32 = 5

    // <sys/attr.h> values (written out: several are too large for the imported Int32 macros).
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturned: UInt32 = 0x8000_0000
    private static let fileAllocSize: UInt32 = 0x0000_0004

    public static let bufferSize = 128 * 1024

    public static func makeBuffer() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    /// Calls `body` for each entry of `path`. `buffer` must be `bufferSize` bytes (one per thread).
    public static func enumerate(path: String, buffer: UnsafeMutableRawPointer, mode: Mode,
                                 _ body: (RawEntry) -> Void) throws {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure(code: errno) }
        defer { Darwin.close(fd) }

        var common = cmnReturned | cmnName | cmnError | cmnDevID | cmnObjType | cmnFlags
        if mode == .full { common |= cmnModTime }
        var request = attrlist(bitmapcount: UInt16(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: common,
                               volattr: 0, dirattr: 0, fileattr: fileAllocSize, forkattr: 0)

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure(code: errno)
            }
            if count == 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let e = parse(entry) { body(e) }
                entry += length
            }
        }
    }

    /// Attributes are packed in bit order (common group, then file group), each only if its bit is set
    /// in the returned set. `ATTR_CMN_ERROR` immediately follows the returned set.
    @inline(__always)
    private static func parse(_ entry: UnsafeRawPointer) -> RawEntry? {
        var p = entry + 4
        let common = p.loadUnaligned(as: UInt32.self)
        let fileAttrs = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        p += 20
        if common & cmnError != 0 {
            let err = p.loadUnaligned(as: UInt32.self)
            p += 4
            if err != 0 && common & cmnName == 0 { return nil }
        }
        guard common & cmnName != 0 else { return nil }
        let offset = Int(p.loadUnaligned(as: Int32.self))
        let length = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let name = UnsafeBufferPointer(start: (p + offset).assumingMemoryBound(to: UInt8.self), count: max(0, length - 1))
        p += 8

        var dev: Int32 = 0
        if common & cmnDevID != 0 { dev = p.loadUnaligned(as: Int32.self); p += 4 }
        var objType: UInt32 = 0
        if common & cmnObjType != 0 { objType = p.loadUnaligned(as: UInt32.self); p += 4 }
        var mtime: Int64 = 0
        if common & cmnModTime != 0 { mtime = p.loadUnaligned(as: Int64.self); p += 16 }
        var flags: UInt32 = 0
        if common & cmnFlags != 0 { flags = p.loadUnaligned(as: UInt32.self); p += 4 }
        var alloc: Int64 = 0
        if fileAttrs & fileAllocSize != 0 { alloc = p.loadUnaligned(as: Int64.self); p += 8 }
        return RawEntry(name: name, objType: objType, dev: dev, flags: flags, mtime: mtime, alloc: alloc)
    }
}

public enum FSFlags {
    public static let hidden: UInt32 = 0x0000_8000      // UF_HIDDEN
    public static let uImmutable: UInt32 = 0x0000_0002  // UF_IMMUTABLE
    public static let sImmutable: UInt32 = 0x0002_0000  // SF_IMMUTABLE
    public static let restricted: UInt32 = 0x0008_0000  // SF_RESTRICTED (SIP)
    public static let dataless: UInt32 = 0x4000_0000    // SF_DATALESS (cloud-only placeholder)
}
