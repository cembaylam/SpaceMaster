import Foundation

public struct VolumeInfo: Sendable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var total: Int64
    public var available: Int64
    public var isInternal: Bool
    public var isRoot: Bool
    public var used: Int64 { max(0, total - available) }
}

public enum Volumes {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
    ]

    public static func list() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                          options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { continue }
            let path = url.path
            out.append(VolumeInfo(
                name: v.volumeName ?? url.lastPathComponent, path: path,
                total: Int64(v.volumeTotalCapacity ?? 0),
                available: Int64(v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)),
                isInternal: v.volumeIsInternal ?? false, isRoot: path == "/"))
        }
        return out.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }

    /// Info for the volume containing `path`.
    public static func info(containing path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeURLKey]), let root = v.volume else { return nil }
        let rootPath = root.path == "/System/Volumes/Data" ? "/" : root.path
        return list().first { $0.path == rootPath }
    }
}
