import AppKit

@main
@MainActor
enum SMMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = MainWindowController()
        NSApp.mainMenu = MainMenu.build(browser: windowController.browser)
        windowController.showWindow(nil)
        NSApp.activate()
        // Debug aid: SM_SNAPSHOT=/path.png renders the window to a PNG after a delay and quits.
        if let out = ProcessInfo.processInfo.environment["SM_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["SM_SNAPSHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                if let nav = ProcessInfo.processInfo.environment["SM_NAV"] { windowController.browser.cd(nav) }
                if let keys = ProcessInfo.processInfo.environment["SM_KEYS"] {
                    for ch in keys {
                        let s = String(ch)
                        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 255) {
                            _ = windowController.browser.handleKey(e)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    let contentOnly = ProcessInfo.processInfo.environment["SM_SNAPSHOT_VIEW"] == "content"
                    if let v = contentOnly ? windowController.browser.view : windowController.window?.contentView?.superview,
                       let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
