import AppKit
import Darwin
import SMCore

@MainActor
final class AppModel {
    static let shared = AppModel()

    let scanner = SizeScanner()
    let classifier = SafetyClassifier()
    let home = NSHomeDirectory()
    private(set) var volumes: [VolumeInfo] = Volumes.list()
    var accessBannerDismissed = false

    static let volumesChanged = Notification.Name("SpaceMasterVolumesChanged")

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.refreshVolumes() }
            }
        }
    }

    func refreshVolumes() {
        volumes = Volumes.list()
        NotificationCenter.default.post(name: Self.volumesChanged, object: nil)
    }

    func volume(containing path: String) -> VolumeInfo? {
        volumes.filter { path == $0.path || $0.path == "/" || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// Node for a path; mounted volumes under /Volumes become independent scan roots.
    func node(for path: String) -> Node {
        let n = scanner.node(forPath: path)
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/")
            if parts.count >= 2 {
                scanner.markMountRoot(scanner.node(forPath: "/Volumes/" + parts[1]))
            }
        }
        return n
    }

    func scan(_ path: String) { scanner.scan(node(for: path)) }

    /// Starts everything: the startup volume in the background, the given path on top.
    func startScanning(prioritizing path: String) {
        scanner.scan(scanner.root)
        scan(path)
    }

    /// True when the app can read TCC-protected locations (Full Disk Access granted).
    func hasFullDiskAccess() -> Bool {
        let fd = open(home + "/Library/Safari", O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM
    }

    func resolve(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath((path as NSString).expandingTildeInPath, &buf) != nil else { return nil }
        let p = String(cString: buf)
        return p.hasPrefix("/System/Volumes/Data/") ? String(p.dropFirst("/System/Volumes/Data".count)) : p
    }
}
