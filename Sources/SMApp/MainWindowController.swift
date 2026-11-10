import AppKit
import SMCore

extension NSToolbarItem.Identifier {
    static let nav = NSToolbarItem.Identifier("sm.nav")
    static let sort = NSToolbarItem.Identifier("sm.sort")
    static let trash = NSToolbarItem.Identifier("sm.trash")
    static let delete = NSToolbarItem.Identifier("sm.delete")
    static let reveal = NSToolbarItem.Identifier("sm.reveal")
    static let rescan = NSToolbarItem.Identifier("sm.rescan")
    static let filter = NSToolbarItem.Identifier("sm.filter")
}

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    let browser = BrowserViewController()
    let sidebar = SidebarViewController()
    private var navGroup: NSToolbarItemGroup?

    init() {
        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 200
        sideItem.maximumThickness = 320
        sideItem.canCollapse = true
        let content = NSSplitViewItem(viewController: browser)
        content.minimumThickness = 640
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(content)
        split.splitView.autosaveName = "SpaceMasterSplit"

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = split
        window.title = "SpaceMaster"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 900, height: 480)
        window.setFrameAutosaveName("SpaceMasterMain")
        window.setContentSize(NSSize(width: 1320, height: 800))
        if !window.setFrameUsingName("SpaceMasterMain") { window.center() }
        super.init(window: window)

        let tb = NSToolbar(identifier: "SpaceMasterToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        window.toolbar = tb

        browser.onLocationChange = { [weak self] path in self?.locationChanged(path) }
        sidebar.onSelect = { [weak self] path in
            guard let self else { return }
            self.browser.cd(path)
            if NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .leftMouseDown { self.browser.focus() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        _ = browser.view
        browser.focus()
    }

    private func locationChanged(_ path: String) {
        window?.title = path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent
        window?.subtitle = path.abbreviatingWithTildeInPath
        sidebar.select(path: path)
        navGroup?.subitems.first?.isEnabled = browser.canGoBack
        if (navGroup?.subitems.count ?? 0) > 1 { navGroup?.subitems[1].isEnabled = browser.canGoForward }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .nav, .flexibleSpace, .sort, .reveal, .rescan, .trash, .delete, .filter]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ sel: Selector, tip: String) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = label; i.paletteLabel = label; i.toolTip = tip
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            i.target = browser; i.action = sel
            return i
        }
        switch id {
        case .nav:
            let g = NSToolbarItemGroup(itemIdentifier: .nav, images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!,
            ], selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navAction(_:)))
            g.label = "Navigate"; g.paletteLabel = "Navigate"
            navGroup = g
            return g
        case .sort:
            let i = NSMenuToolbarItem(itemIdentifier: .sort)
            i.label = "Sort"; i.paletteLabel = "Sort"; i.toolTip = "Sort by"
            i.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
            let m = NSMenu()
            for (t, s) in [("Size", #selector(BrowserViewController.sortBySize(_:))), ("Name", #selector(BrowserViewController.sortByName(_:))),
                           ("Date Modified", #selector(BrowserViewController.sortByDate(_:)))] {
                let mi = NSMenuItem(title: t, action: s, keyEquivalent: ""); mi.target = browser; m.addItem(mi)
            }
            m.addItem(.separator())
            let h = NSMenuItem(title: "Show Hidden Files", action: #selector(BrowserViewController.toggleHidden(_:)), keyEquivalent: "")
            h.target = browser; m.addItem(h)
            i.menu = m
            i.showsIndicator = true
            return i
        case .reveal: return button(.reveal, "Reveal", "magnifyingglass.circle", #selector(BrowserViewController.revealInFinder(_:)), tip: "Reveal in Finder")
        case .rescan: return button(.rescan, "Rescan", "arrow.clockwise", #selector(BrowserViewController.rescan(_:)), tip: "Rescan this folder")
        case .trash: return button(.trash, "Trash", "trash", #selector(BrowserViewController.trashSelection(_:)), tip: "Move to Trash (⌘⌫)")
        case .delete:
            let i = button(.delete, "Delete", "xmark.bin", #selector(BrowserViewController.deleteSelection(_:)), tip: "Delete immediately (⌘⌥⌫) — frees space now")
            return i
        case .filter:
            let i = NSSearchToolbarItem(itemIdentifier: .filter)
            i.searchField.placeholderString = "Filter"
            i.searchField.delegate = browser
            i.preferredWidthForSearchField = 180
            browser.searchField = i.searchField
            return i
        default: return nil
        }
    }

    @objc private func navAction(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { browser.goBack() } else { browser.goForward() }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let sel = item.action else { return true }
        if sel == #selector(BrowserViewController.trashSelection(_:)) || sel == #selector(BrowserViewController.deleteSelection(_:)) {
            return browser.validateMenuItem(NSMenuItem(title: "", action: sel, keyEquivalent: ""))
        }
        return true
    }
}
