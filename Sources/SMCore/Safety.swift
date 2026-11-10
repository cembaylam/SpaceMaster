import Darwin
import Foundation

/// Whether removing an item is reasonable. "Safe" means only that deleting it won't damage macOS or the
/// user's account; whether the *content* matters is the user's call.
public struct Safety: Sendable, Equatable {
    /// `mixed`: the item itself can't be deleted, but it contains items that can.
    public enum Level: UInt8, Sendable { case safe, protected, mixed }
    public var level: Level
    public var reason: String

    public static let safe = Safety(level: .safe, reason: "Safe to delete. Deleting frees this space; check that you don't need the contents.")
    public var isDeletable: Bool { level == .safe }
}

/// Classifies entries per directory: one context per listing, O(1) per entry.
public struct SafetyClassifier: Sendable {
    public struct Context: Sendable {
        var blanket: String?
        var names: [String: String]
        /// Directories that are protected themselves but hold deletable items.
        var mixedAll = false
        var mixedNames: Set<String> = []
        var neverMixed: Set<String> = []
    }

    public static let mixedReason = "Can't be deleted itself, but it contains items you can delete. Open it to find them."

    private let home: String

    public init(home: String = NSHomeDirectory()) { self.home = home }

    private static let systemTrees = [
        "/System", "/bin", "/sbin", "/usr", "/dev", "/private/etc", "/private/var/db", "/private/var/root",
        "/private/var/protected", "/Library/Apple", "/Library/Extensions", "/Library/LaunchDaemons",
        "/Library/LaunchAgents", "/Library/Frameworks", "/Library/SystemExtensions", "/Library/Filesystems",
        "/Library/Security", "/cores", "/etc", "/.Spotlight-V100", "/.fseventsd", "/.vol",
    ]
    private static let systemBlanket: [String: String] = [
        "/": "Top-level system folder.",
        "/Users": "User accounts folder.",
        "/Volumes": "Mounted volumes. Eject a drive instead of deleting it.",
        "/private": "System folder.",
        "/private/var": "System folder.",
        "/Library": "System-wide support files.",
        "/opt": "System folder.",
        "/var": "System folder.",
        "/tmp": "System folder.",
    ]
    private static let homeNames: [String: String] = [
        "Desktop": "Standard macOS folder. Delete its contents instead.",
        "Documents": "Standard macOS folder. Delete its contents instead.",
        "Downloads": "Standard macOS folder. Delete its contents instead.",
        "Movies": "Standard macOS folder. Delete its contents instead.",
        "Music": "Standard macOS folder. Delete its contents instead.",
        "Pictures": "Standard macOS folder. Delete its contents instead.",
        "Public": "Standard macOS folder. Delete its contents instead.",
        "Library": "Your user Library holds app data and settings. Delete items inside it instead.",
        "Applications": "Standard macOS folder. Delete its contents instead.",
        ".Trash": "The Trash folder itself can't be deleted; delete what's inside.",
        ".ssh": "Holds your SSH keys. Deleting it can lock you out of servers.",
        ".gnupg": "Holds your GPG keys.",
    ]
    private static let libraryNames: [String: String] = [
        "Keychains": "Holds your saved passwords and certificates.",
        "Preferences": "Holds all app settings.",
        "Accounts": "Holds your account configuration.",
        "Mobile Documents": "Your iCloud Drive. Deleting here deletes from iCloud.",
        "CloudStorage": "Cloud provider storage. Deleting here deletes from the cloud.",
        "Application Support": "Data for every app. Delete individual app folders instead.",
        "Containers": "Data for sandboxed apps. Delete individual app folders instead.",
        "Group Containers": "Shared app data. Delete individual folders instead.",
        "Mail": "Your local mail.",
        "Messages": "Your Messages history.",
        "Calendars": "Your local calendars.",
        "Safari": "Your Safari data.",
        "Cookies": "Browser cookies shared by apps.",
        "Fonts": "Your installed fonts.",
        "LaunchAgents": "Background items that keep apps working.",
    ]

    public func context(forDirectory path: String) -> Context {
        for t in Self.systemTrees where path == t || path.hasPrefix(t + "/") {
            if t == "/usr", path == "/usr/local" || path.hasPrefix("/usr/local/") { break }
            return Context(blanket: "System file protected by macOS.", names: [:])
        }
        if path == "/" {
            return Context(blanket: Self.systemBlanket["/"], names: [:],
                           mixedNames: ["Applications", "Library", "Users", "Volumes", "opt", "private", "var", "tmp"])
        }
        if let b = Self.systemBlanket[path] {
            switch path {
            case "/Users", "/Volumes": return Context(blanket: b, names: [:], mixedAll: true)
            case "/private": return Context(blanket: b, names: [:], mixedNames: ["var", "tmp"])
            case "/private/var": return Context(blanket: b, names: [:], mixedNames: ["folders", "tmp"])
            case "/Library":
                return Context(blanket: b, names: [:], mixedAll: true,
                               neverMixed: ["Apple", "Extensions", "LaunchDaemons", "LaunchAgents", "Frameworks", "SystemExtensions",
                                            "Filesystems", "Security", "Preferences", "Keychains"])
            default: return Context(blanket: b, names: [:])
            }
        }
        if path == home {
            return Context(blanket: nil, names: Self.homeNames, mixedAll: true, neverMixed: [".ssh", ".gnupg"])
        }
        if path == home + "/Library" {
            return Context(blanket: nil, names: Self.libraryNames, mixedAll: true,
                           neverMixed: ["Keychains", "Preferences", "Accounts", "Cookies", "LaunchAgents"])
        }
        if path.hasPrefix("/Volumes/"), path.split(separator: "/").count == 2 { return Context(blanket: nil, names: [:]) }
        // Directories we can't write to: entries can't be removed without administrator rights.
        if access(path, W_OK) != 0 {
            return Context(blanket: "You don't have permission to delete items here.", names: [:])
        }
        return Context(blanket: nil, names: [:])
    }

    public func classify(name: String, flags: UInt32, isDirectory: Bool = false, in ctx: Context) -> Safety {
        if flags & (FSFlags.restricted | FSFlags.sImmutable | FSFlags.uImmutable) != 0 {
            return Safety(level: .protected, reason: "Locked or protected by macOS.")
        }
        let mixed = isDirectory && !ctx.neverMixed.contains(name) && (ctx.mixedAll || ctx.mixedNames.contains(name))
        if let b = ctx.blanket {
            return mixed ? Safety(level: .mixed, reason: Self.mixedReason) : Safety(level: .protected, reason: b)
        }
        if let r = ctx.names[name] {
            return mixed ? Safety(level: .mixed, reason: r + " It contains items you can delete; open it to find them.")
                         : Safety(level: .protected, reason: r)
        }
        return .safe
    }

    /// Classification of an arbitrary path (used by the info panel and as a final check before deleting).
    public func classify(path: String, flags: UInt32, isDirectory: Bool = false) -> Safety {
        if path == "/" { return Safety(level: .protected, reason: "The startup volume.") }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if path == home { return Safety(level: .protected, reason: "Your home folder.") }
        if path.hasPrefix("/Volumes/"), path.split(separator: "/").count == 2 {
            return Safety(level: .protected, reason: "A mounted volume. Eject it instead of deleting.")
        }
        return classify(name: name, flags: flags, isDirectory: isDirectory, in: context(forDirectory: parent))
    }
}
