import AppKit

@MainActor
enum MainMenu {
    static func build(browser: BrowserViewController) -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(); let m = NSMenu(title: title)
            build(m); item.submenu = m; main.addItem(item)
        }
        func add(_ m: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                 target: AnyObject? = browser) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            i.target = target
            m.addItem(i)
        }
        let backspace = String(UnicodeScalar(0x08))
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

        submenu("SpaceMaster") { m in
            add(m, "About SpaceMaster", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
            m.addItem(.separator())
            add(m, "Hide SpaceMaster", #selector(NSApplication.hide(_:)), "h", target: NSApp)
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
            m.addItem(.separator())
            add(m, "Quit SpaceMaster", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        }
        submenu("File") { m in
            add(m, "Open", #selector(BrowserViewController.openSelection(_:)), "o")
            add(m, "Reveal in Finder", #selector(BrowserViewController.revealInFinder(_:)), "r", [.command, .option])
            add(m, "Copy Path", #selector(BrowserViewController.copyPath(_:)), "c", [.command, .option])
            m.addItem(.separator())
            add(m, "Rescan Folder", #selector(BrowserViewController.rescan(_:)), "r")
            m.addItem(.separator())
            add(m, "Move to Trash", #selector(BrowserViewController.trashSelection(_:)), backspace)
            add(m, "Delete Immediately…", #selector(BrowserViewController.deleteSelection(_:)), backspace, [.command, .option])
            m.addItem(.separator())
            add(m, "Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil)
        }
        submenu("Edit") { m in
            add(m, "Undo Move to Trash", #selector(BrowserViewController.undoTrash(_:)), "z")
            m.addItem(.separator())
            add(m, "Copy", #selector(BrowserViewController.copyFiles(_:)), "c", target: nil)
            add(m, "Select All", #selector(NSResponder.selectAll(_:)), "a", target: nil)
            add(m, "Filter…", #selector(BrowserViewController.focusSearch(_:)), "f")
        }
        submenu("View") { m in
            add(m, "Sort by Size", #selector(BrowserViewController.sortBySize(_:)), "1", [.command, .control])
            add(m, "Sort by Name", #selector(BrowserViewController.sortByName(_:)), "2", [.command, .control])
            add(m, "Sort by Date Modified", #selector(BrowserViewController.sortByDate(_:)), "3", [.command, .control])
            m.addItem(.separator())
            add(m, "Show Hidden Files", #selector(BrowserViewController.toggleHidden(_:)), ".", [.command, .shift])
            m.addItem(.separator())
            add(m, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control], target: nil)
            add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil)
        }
        submenu("Go") { m in
            add(m, "Back", #selector(BrowserViewController.goBackAction(_:)), "[")
            add(m, "Forward", #selector(BrowserViewController.goForwardAction(_:)), "]")
            add(m, "Enclosing Folder", #selector(BrowserViewController.goEnclosing(_:)), up)
            add(m, "Open Folder", #selector(BrowserViewController.goInto(_:)), down)
            m.addItem(.separator())
            for (t, p, k) in [("Home", "~", "h"), ("Desktop", "~/Desktop", "d"), ("Documents", "~/Documents", "o"),
                              ("Downloads", "~/Downloads", "l"), ("Applications", "/Applications", "a")] {
                add(m, t, #selector(BrowserViewController.goToPath(_:)), k, [.command, .shift])
                m.items.last?.representedObject = p
            }
            add(m, "Macintosh HD", #selector(BrowserViewController.goToPath(_:)), "")
            m.items.last?.representedObject = "/"
            m.addItem(.separator())
            add(m, "Go to Folder…", #selector(BrowserViewController.goTo(_:)), "g", [.command, .shift])
        }
        submenu("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)), target: nil)
            NSApp.windowsMenu = m
        }
        submenu("Help") { m in
            add(m, "Keyboard Shortcuts", #selector(BrowserViewController.showKeyboardHelp(_:)), "/", [.command, .shift])
            NSApp.helpMenu = m
        }
        return main
    }
}
