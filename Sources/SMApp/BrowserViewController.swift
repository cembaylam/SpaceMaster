import AppKit
import SMCore

@MainActor
final class BrowserViewController: NSViewController, NSMenuItemValidation, NSSearchFieldDelegate {
    let model = AppModel.shared
    var browserView: BrowserView { view as! BrowserView }

    private(set) var cwd = "/"
    private(set) var current: DirState!
    private var parentState: DirState?
    private var previewState: DirState?
    private var cursorMemory: [String: String] = [:]
    private var cursorName: String?
    /// Cursor follows the top row while sizes are still arriving and the user hasn't moved it.
    private var pinnedToTop = false
    private(set) var selection: Set<String> = []
    private var history: [String] = []
    private var historyIndex = -1
    private var states: [String: DirState] = [:]
    private var stateOrder: [String] = []

    private(set) var sortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sm.sort") ?? "") ?? .size
    private(set) var sortReversed = UserDefaults.standard.bool(forKey: "sm.sortReversed")
    private(set) var showHidden = UserDefaults.standard.object(forKey: "sm.showHidden") as? Bool ?? true
    private var filter = ""
    private var pendingPrefix: String?
    private var timer: Timer?
    private var lastVersion = -1
    private var flashTimer: Timer?
    private var undoStack: [[TrashRecord]] = []
    private var deleting = 0

    struct TrashRecord { var original: String; var trashed: String; var isDirectory: Bool; var size: Int64 }

    /// Called whenever the location or its summary changes (window title, sidebar selection, toolbar state).
    var onLocationChange: ((String) -> Void)?
    weak var searchField: NSSearchField?

    // MARK: Setup

    override func loadView() {
        let v = BrowserView()
        v.controller = self
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let v = browserView
        v.currentList.onClick = { [weak self] i, mods in self?.click(i, mods) }
        v.currentList.onDoubleClick = { [weak self] i in self?.moveCursor(to: i); self?.openCursor() }
        v.currentList.onScrollRows = { [weak self] d in self?.browserView.currentList.scroll(by: d) }
        v.currentList.menuProvider = { [weak self] _ in self?.contextMenu() }
        v.parentList.onClick = { [weak self] i, _ in self?.clickParent(i) }
        v.parentList.onScrollRows = { [weak self] d in self?.browserView.parentList.scroll(by: d) }
        v.previewList.onClick = { [weak self] i, _ in self?.clickPreview(i) }
        v.previewList.onScrollRows = { [weak self] d in self?.browserView.previewList.scroll(by: d) }
        v.pathBar.onSelect = { [weak self] p in self?.cd(p); self?.focus() }
        v.banner.openButton.target = self
        v.banner.openButton.action = #selector(openFullDiskAccessSettings)
        v.banner.dismissButton.target = self
        v.banner.dismissButton.action = #selector(dismissBanner)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        }
        NotificationCenter.default.addObserver(forName: AppModel.volumesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        let last = UserDefaults.standard.string(forKey: "sm.lastPath")
        let start = last.flatMap { model.resolve($0) } ?? model.home
        model.startScanning(prioritizing: start)
        cd(start, history: true)
    }

    override func viewDidAppear() { super.viewDidAppear(); view.needsLayout = true }

    func focus() { view.window?.makeFirstResponder(view) }

    // MARK: State loading

    private func loadState(_ path: String, force: Bool) -> DirState {
        if !force, let s = states[path], Date().timeIntervalSince(s.loadedAt) < 15 { return s }
        let node = model.node(for: path)
        let s = DirState(path: path, node: node, ctx: model.classifier.context(forDirectory: path))
        do { s.entries = try DirListing.list(path) } catch let e as DirEnumerator.Failure {
            s.error = e.code == EPERM || e.code == EACCES ? "No permission to read this folder.\nGrant Full Disk Access in System Settings." : e.description
        } catch { s.error = error.localizedDescription }
        s.rebuild(model: model, sort: sortKey, reversed: sortReversed, showHidden: showHidden, filter: path == cwd ? filter : "")
        states[path] = s
        stateOrder.removeAll { $0 == path }
        stateOrder.append(path)
        if stateOrder.count > 40 { states[stateOrder.removeFirst()] = nil }
        return s
    }

    private func invalidateCache() { states.removeAll(); stateOrder.removeAll() }

    // MARK: Navigation

    func cd(_ rawPath: String, focus name: String? = nil, history addHistory: Bool = true) {
        guard let path = model.resolve(rawPath) else { flash("Can't open “\(rawPath)”"); return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            flash("“\(path)” is not a folder"); return
        }
        if current != nil, let n = cursorName { cursorMemory[cwd] = n }
        if addHistory && path != cwd {
            if historyIndex < history.count - 1 { history.removeLast(history.count - historyIndex - 1) }
            history.append(path); historyIndex = history.count - 1
        }
        cwd = path
        selection = []
        filter = ""
        searchField?.stringValue = ""
        pendingPrefix = nil
        UserDefaults.standard.set(path, forKey: "sm.lastPath")

        // Scan the parent first and the folder itself on top: the folder being viewed always gets scanned first.
        if path != "/" { model.scan((path as NSString).deletingLastPathComponent) }
        model.scan(path)

        current = loadState(path, force: true)
        parentState = path == "/" ? nil : loadState((path as NSString).deletingLastPathComponent, force: true)
        cursorName = name ?? cursorMemory[path] ?? current.rows.first?.name
        pinnedToTop = name == nil && cursorMemory[path] == nil
        if current.index(of: cursorName) == nil { cursorName = current.rows.first?.name }
        renderAll(ensureVisible: true)
        startTimer()
        onLocationChange?(path)
    }

    func goBack() { if historyIndex > 0 { historyIndex -= 1; cd(history[historyIndex], history: false) } }
    func goForward() { if historyIndex < history.count - 1 { historyIndex += 1; cd(history[historyIndex], history: false) } }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func leave() {
        guard cwd != "/" else { return }
        cd((cwd as NSString).deletingLastPathComponent, focus: (cwd as NSString).lastPathComponent)
    }

    var cursorRow: Row? {
        guard let i = current?.index(of: cursorName) else { return nil }
        return current.rows[i]
    }
    private var cursorIndex: Int { current?.index(of: cursorName) ?? 0 }

    func path(of row: Row) -> String { cwd == "/" ? "/" + row.name : cwd + "/" + row.name }

    func enter() {
        guard let r = cursorRow, r.isDirectory else { return }
        cd(path(of: r))
    }

    func openCursor() {
        guard let r = cursorRow else { return }
        if r.isDirectory && !r.isPackage { enter() } else { NSWorkspace.shared.open(URL(fileURLWithPath: path(of: r))) }
    }

    func moveCursor(to index: Int) {
        guard let rows = current?.rows, !rows.isEmpty else { return }
        let i = min(max(0, index), rows.count - 1)
        cursorName = rows[i].name
        pinnedToTop = false
        browserView.currentList.moveCursor(to: i)
        updatePreview()
        updateStatus()
    }

    private func click(_ i: Int, _ mods: NSEvent.ModifierFlags) {
        guard i < current.rows.count else { return }
        focus()
        if mods.contains(.command) {
            let n = current.rows[i].name
            if selection.contains(n) { selection.remove(n) } else { selection.insert(n) }
            browserView.currentList.setSelected(selection)
        } else if mods.contains(.shift), let a = current.index(of: cursorName) {
            for j in min(a, i)...max(a, i) { selection.insert(current.rows[j].name) }
            browserView.currentList.setSelected(selection)
        } else if !selection.isEmpty && !mods.contains(.control) {
            selection = []
            browserView.currentList.setSelected(selection)
        }
        moveCursor(to: i)
    }

    private func clickParent(_ i: Int) {
        guard let p = parentState, i < p.rows.count else { return }
        focus()
        let r = p.rows[i]
        let dir = (cwd as NSString).deletingLastPathComponent
        if r.isDirectory { cd(dir == "/" ? "/" + r.name : dir + "/" + r.name) }
    }

    private func clickPreview(_ i: Int) {
        guard let p = previewState, i < p.rows.count else { return }
        focus()
        let r = p.rows[i]
        if r.isDirectory { cd(p.path == "/" ? "/" + r.name : p.path + "/" + r.name) }
    }

    // MARK: Rendering

    private func message(for s: DirState?) -> String? {
        guard let s else { return nil }
        if let e = s.error { return e }
        if s.rows.isEmpty { return s.entries.isEmpty ? "Empty folder" : "No matching items" }
        return nil
    }

    func renderAll(ensureVisible: Bool) {
        let v = browserView
        let ci = current.index(of: cursorName) ?? 0
        v.currentList.update(state: current, cursor: ci, selected: selection, message: message(for: current), ensureVisible: ensureVisible)
        let parentCursor = parentState?.index(of: (cwd as NSString).lastPathComponent) ?? 0
        v.parentList.update(state: parentState, cursor: parentCursor, selected: [], message: nil, ensureVisible: ensureVisible)
        updatePreview(ensureVisible: ensureVisible)
        updateHeaders()
        updateStatus()
    }

    private func updateHeaders() {
        let v = browserView
        let parentPath = (cwd as NSString).deletingLastPathComponent
        v.headers[0].title = cwd == "/" ? "" : (parentPath == "/" ? "Macintosh HD" : (parentPath as NSString).lastPathComponent)
        v.headers[0].detail = parentState.map { ByteFormat.string($0.total) } ?? ""
        v.headers[1].title = cwd == "/" ? "Macintosh HD" : (cwd as NSString).lastPathComponent
        v.headers[1].detail = ByteFormat.string(current.total) + (current.anyCalculating ? "+" : "")
        if let s = previewState {
            v.headers[2].title = (s.path as NSString).lastPathComponent
            v.headers[2].detail = ByteFormat.string(s.total) + (s.anyCalculating ? "+" : "")
        } else if let r = cursorRow {
            v.headers[2].title = r.name
            v.headers[2].detail = ByteFormat.string(r.size)
        } else { v.headers[2].title = ""; v.headers[2].detail = "" }
    }

    func updatePreview(ensureVisible: Bool = true) {
        let v = browserView
        guard let r = cursorRow else {
            previewState = nil
            v.info.isHidden = true; v.previewList.isHidden = false
            v.previewList.update(state: nil, cursor: 0, selected: [], message: nil, ensureVisible: true)
            updateHeaders()
            return
        }
        let p = path(of: r)
        if r.isDirectory {
            model.scan(p)
            let s = loadState(p, force: false)
            if s !== previewState || ensureVisible {
                previewState = s
                v.info.isHidden = true; v.previewList.isHidden = false
                v.previewList.update(state: s, cursor: 0, selected: [], message: message(for: s), ensureVisible: true)
            }
        } else {
            previewState = nil
            v.previewList.isHidden = true; v.info.isHidden = false
            v.info.show(path: p, row: r)
        }
        updateHeaders()
    }

    func updateStatus() {
        let s = browserView.status
        s.volume = model.volume(containing: cwd)
        browserView.pathBar.path = cwd
        browserView.pathBar.volumeName = model.volumes.first(where: { $0.isRoot })?.name ?? "Macintosh HD"
        if !selection.isEmpty {
            let rows = current.rows.filter { selection.contains($0.name) }
            let bytes = rows.reduce(Int64(0)) { $0 + $1.size }
            s.summary = "\(rows.count) selected · \(ByteFormat.string(bytes))"
        } else {
            let n = current.rows.count
            let hidden = current.entries.count - current.rows.count
            s.summary = "\(ByteFormat.count(n)) item\(n == 1 ? "" : "s"), \(ByteFormat.string(current.total))"
                + (filter.isEmpty && hidden > 0 ? " · \(hidden) hidden" : "")
        }
        let sc = model.scanner
        if sc.isScanning {
            s.scanText = "Scanning… \(ByteFormat.count(sc.itemsScanned.load(ordering: .relaxed))) items"
        } else {
            s.scanText = nil
        }
        let denied = sc.denied.load(ordering: .relaxed)
        let needsAccess = denied > 0 && !sc.isScanning && !model.hasFullDiskAccess()
        s.accessNote = needsAccess ? "\(denied) folders unreadable — Grant Access" : nil
        s.onAccessClick = { [weak self] in self?.openFullDiskAccessSettings() }
        s.window?.invalidateCursorRects(for: s)
    }

    // MARK: Live refresh while scanning

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let sc = model.scanner
        let v = sc.version.load(ordering: .relaxed)
        let phase = (Date.timeIntervalSinceReferenceDate * 1.1).truncatingRemainder(dividingBy: 1)
        let busy = sc.isScanning
        var spinning = false
        if v != lastVersion {
            lastVersion = v
            refreshVisibleStates()
        }
        for s in [current, parentState, previewState] where s?.anyCalculating == true { spinning = true }
        if spinning || busy {
            for l in [browserView.currentList, browserView.parentList, browserView.previewList] {
                l.spinnerPhase = phase
                l.needsDisplay = true
            }
            browserView.status.scanPhase = phase
            updateStatus()
        }
        if !busy && !spinning {
            timer?.invalidate(); timer = nil
            updateStatus()
            model.refreshVolumes()
        }
    }

    /// Re-sorts the visible columns with the latest sizes, keeping the cursor on the same item.
    private func refreshVisibleStates() {
        for s in [current, parentState, previewState] {
            s?.rebuild(model: model, sort: sortKey, reversed: sortReversed, showHidden: showHidden, filter: s === current ? filter : "")
        }
        let v = browserView
        if pinnedToTop, let first = current.rows.first, first.name != cursorName {
            cursorName = first.name
            v.currentList.update(state: current, cursor: 0, selected: selection, message: message(for: current), ensureVisible: true)
            updatePreview()
        }
        v.currentList.update(state: current, cursor: current.index(of: cursorName) ?? 0, selected: selection, message: message(for: current), ensureVisible: pinnedToTop)
        v.parentList.update(state: parentState, cursor: parentState?.index(of: (cwd as NSString).lastPathComponent) ?? 0, selected: [], message: nil, ensureVisible: false)
        if let p = previewState {
            v.previewList.update(state: p, cursor: 0, selected: [], message: message(for: p), ensureVisible: false)
        }
        updateHeaders()
    }

    private func appDidBecomeActive() {
        guard current != nil else { return }
        invalidateCache()
        model.refreshVolumes()
        let name = cursorName
        current = loadState(cwd, force: true)
        parentState = cwd == "/" ? nil : loadState((cwd as NSString).deletingLastPathComponent, force: true)
        cursorName = current.index(of: name) != nil ? name : current.rows.first?.name
        renderAll(ensureVisible: false)
        startTimer()
    }

    // MARK: Keyboard (yazi-style, like FileMaster)

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.contains(.command), !mods.contains(.option) else { return false }
        let ctrl = mods.contains(.control)
        let chars = event.charactersIgnoringModifiers ?? ""
        let shifted = event.characters ?? chars
        let page = max(1, browserView.currentList.visibleRows - 1)

        // Two-key sequences: g… (go) and ,… (sort)
        if let prefix = pendingPrefix {
            pendingPrefix = nil
            return handleSequence(prefix, shifted)
        }
        if ctrl {
            switch chars {
            case "d": moveCursor(to: cursorIndex + page / 2); return true
            case "u": moveCursor(to: cursorIndex - page / 2); return true
            case "f": moveCursor(to: cursorIndex + page); return true
            case "b": moveCursor(to: cursorIndex - page); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 126: moveCursor(to: cursorIndex - 1); return true            // up
        case 125: moveCursor(to: cursorIndex + 1); return true            // down
        case 123: leave(); return true                                    // left
        case 124: enter(); return true                                    // right
        case 36, 76: openCursor(); return true                            // return / enter
        case 116: moveCursor(to: cursorIndex - page); return true         // page up
        case 121: moveCursor(to: cursorIndex + page); return true         // page down
        case 115: moveCursor(to: 0); return true                          // home
        case 119: moveCursor(to: Int.max); return true                    // end
        case 53: escape(); return true                                    // esc
        case 51: trashSelection(nil); return true                         // delete key
        case 48: toggleSelectAndAdvance(); return true                    // tab
        default: break
        }
        switch shifted {
        case "j": moveCursor(to: cursorIndex + 1)
        case "k": moveCursor(to: cursorIndex - 1)
        case "h": leave()
        case "l": enter()
        case "o": openCursor()
        case "G": moveCursor(to: Int.max)
        case "H": goBack()
        case "L": goForward()
        case " ": toggleSelectAndAdvance()
        case "v": selectAll(nil)
        case "d": trashSelection(nil)
        case "D": deleteSelection(nil)
        case ".": toggleHidden(nil)
        case "r": rescan(nil)
        case "y": copyPath(nil)
        case "R": revealInFinder(nil)
        case "/", "f": focusSearch(nil)
        case "g", ",": pendingPrefix = shifted
        case "?": showKeyboardHelp(nil)
        default: return false
        }
        return true
    }

    private func handleSequence(_ prefix: String, _ key: String) -> Bool {
        let h = model.home
        if prefix == "g" {
            switch key {
            case "g": moveCursor(to: 0)
            case "h": cd(h)
            case "d": cd(h + "/Downloads")
            case "D": cd(h + "/Desktop")
            case "c": cd(h + "/Documents")
            case "a": cd("/Applications")
            case "l": cd(h + "/Library")
            case "r": cd("/")
            case "t": cd(h + "/.Trash")
            case " ": goTo(nil)
            default: return false
            }
            return true
        }
        let rev = key.first?.isUppercase == true
        switch key.lowercased() {
        case "s": setSort(.size, reversed: rev)
        case "n": setSort(.name, reversed: rev)
        case "m": setSort(.modified, reversed: rev)
        default: return false
        }
        return true
    }

    private func escape() {
        if !selection.isEmpty { selection = []; browserView.currentList.setSelected(selection); updateStatus() }
        else if !filter.isEmpty { applyFilter("") ; searchField?.stringValue = "" }
    }

    // MARK: Selection

    func toggleSelectAndAdvance() {
        guard let r = cursorRow else { return }
        if selection.contains(r.name) { selection.remove(r.name) } else { selection.insert(r.name) }
        browserView.currentList.setSelected(selection)
        moveCursor(to: cursorIndex + 1)
    }

    @objc override func selectAll(_ sender: Any?) {
        selection = Set(current.rows.map(\.name))
        browserView.currentList.setSelected(selection)
        updateStatus()
    }

    @objc func selectNone(_ sender: Any?) { escape() }

    /// Rows an action applies to: the multi-selection, or the row under the cursor.
    private func targets() -> [Row] {
        if !selection.isEmpty { return current.rows.filter { selection.contains($0.name) } }
        return cursorRow.map { [$0] } ?? []
    }

    // MARK: Sorting, filtering, hidden files

    func setSort(_ key: SortKey, reversed: Bool) {
        sortKey = key; sortReversed = reversed
        UserDefaults.standard.set(key.rawValue, forKey: "sm.sort")
        UserDefaults.standard.set(reversed, forKey: "sm.sortReversed")
        refreshVisibleStates()
        updateStatus()
        flash("Sorted by \(key.title)\(reversed ? " (reversed)" : "")")
    }

    @objc func sortBySize(_ sender: Any?) { setSort(.size, reversed: sortKey == .size && !sortReversed) }
    @objc func sortByName(_ sender: Any?) { setSort(.name, reversed: sortKey == .name && !sortReversed) }
    @objc func sortByDate(_ sender: Any?) { setSort(.modified, reversed: sortKey == .modified && !sortReversed) }

    @objc func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        UserDefaults.standard.set(showHidden, forKey: "sm.showHidden")
        refreshVisibleStates()
        if current.index(of: cursorName) == nil { cursorName = current.rows.first?.name }
        renderAll(ensureVisible: true)
    }

    @objc func focusSearch(_ sender: Any?) {
        guard let f = searchField else { return }
        view.window?.makeFirstResponder(f)
    }

    func controlTextDidChange(_ obj: Notification) {
        if let f = obj.object as? NSSearchField { applyFilter(f.stringValue) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSResponder.insertNewline(_:)) {
            if sel == #selector(NSResponder.cancelOperation(_:)) { applyFilter(""); (control as? NSSearchField)?.stringValue = "" }
            focus()
            return true
        }
        return false
    }

    private func applyFilter(_ s: String) {
        filter = s
        current.rebuild(model: model, sort: sortKey, reversed: sortReversed, showHidden: showHidden, filter: filter)
        if current.index(of: cursorName) == nil { cursorName = current.rows.first?.name }
        renderAll(ensureVisible: true)
    }

    // MARK: Go to

    @objc func goBackAction(_ sender: Any?) { goBack() }
    @objc func goForwardAction(_ sender: Any?) { goForward() }
    @objc func goEnclosing(_ sender: Any?) { leave() }
    @objc func goInto(_ sender: Any?) { enter() }

    @objc func goTo(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.informativeText = "Enter a path (~ is your home folder)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = cwd.abbreviatingWithTildeInPath + "/"
        field.placeholderString = "~/Projects"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { self?.focus(); return }
            self?.cd(field.stringValue)
            self?.focus()
        }
        alert.window.makeFirstResponder(field)
    }

    // MARK: Actions on files

    @objc func revealInFinder(_ sender: Any?) {
        let rows = targets()
        if rows.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)); return }
        NSWorkspace.shared.activateFileViewerSelecting(rows.map { URL(fileURLWithPath: path(of: $0)) })
    }

    @objc func openSelection(_ sender: Any?) { openCursor() }

    @objc func copyPath(_ sender: Any?) {
        let paths = targets().map { path(of: $0) }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        flash(paths.count == 1 ? "Copied path" : "Copied \(paths.count) paths")
    }

    @objc func copyFiles(_ sender: Any?) {
        let urls = targets().map { URL(fileURLWithPath: path(of: $0)) as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    /// Re-scans the folder under the cursor (or the current folder) from scratch.
    @objc func rescan(_ sender: Any?) {
        invalidateCache()
        if let r = cursorRow, r.isDirectory, let n = r.node, n.isDone || n.state == .unlisted {
            model.scanner.rescan(n)
        } else {
            model.scanner.rescan(model.node(for: cwd))
        }
        current = loadState(cwd, force: true)
        parentState = cwd == "/" ? nil : loadState((cwd as NSString).deletingLastPathComponent, force: true)
        renderAll(ensureVisible: false)
        startTimer()
    }

    @objc func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    @objc func dismissBanner() {
        model.accessBannerDismissed = true
        browserView.bannerVisible = false
    }

    @objc func showKeyboardHelp(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        j k / ↑ ↓      move          h l / ← →      parent / enter
        gg G           top / bottom  ⌃d ⌃u          half page
        H L            history       Return / o     open
        Space / Tab    select + next v / ⌘A         select all
        d / ⌫          move to Trash D / ⌘⌥⌫        delete permanently
        .              show hidden   r              rescan folder
        ,s ,n ,m       sort size/name/date (capital reverses)
        gh gd gD gc    home, Downloads, Desktop, Documents
        ga gl gr gt    Applications, Library, /, Trash
        g␣ / ⌘⇧G       go to path    / or f         filter
        y              copy path     R              reveal in Finder
        """
        alert.informativeText = alert.informativeText
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: Delete

    @objc func trashSelection(_ sender: Any?) { performDelete(permanently: false) }
    @objc func deleteSelection(_ sender: Any?) { performDelete(permanently: true) }

    private func performDelete(permanently: Bool) {
        let rows = targets()
        guard !rows.isEmpty, let window = view.window, deleting == 0 else { return }
        if let bad = rows.first(where: { !$0.safety.isDeletable }) {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = rows.count == 1 ? "“\(bad.name)” can't be deleted" : "Selection includes protected items"
            a.informativeText = rows.count == 1 ? bad.safety.reason : "“\(bad.name)”: \(bad.safety.reason)\nDeselect protected items and try again."
            a.addButton(withTitle: "OK")
            a.beginSheetModal(for: window)
            return
        }
        let bytes = rows.reduce(Int64(0)) { $0 + $1.size }
        let what = rows.count == 1 ? "“\(rows[0].name)”" : "\(rows.count) items"
        if permanently {
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = "Delete \(what) permanently?"
            a.informativeText = "This frees \(ByteFormat.string(bytes)) immediately and can't be undone."
            let b = a.addButton(withTitle: "Delete")
            b.hasDestructiveAction = true
            a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: window) { [weak self] r in
                if r == .alertFirstButtonReturn { self?.runDelete(rows, permanently: true) }
                self?.focus()
            }
        } else {
            runDelete(rows, permanently: false)
        }
    }

    private func runDelete(_ rows: [Row], permanently: Bool) {
        let dirPath = cwd
        let dirNode = current.node
        let items = rows.map { (name: $0.name, path: path(of: $0), isDir: $0.isDirectory, size: $0.size, node: $0.node) }
        let paths = items.map(\.path)
        deleting += 1
        flash(permanently ? "Deleting…" : "Moving to Trash…", duration: 60)
        Task { [weak self] in
            struct Outcome: Sendable { var done: [String: String?]; var failed: [(String, String)] }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                let fm = FileManager.default
                var done: [String: String?] = [:]
                var failed: [(String, String)] = []
                for p in paths {
                    do {
                        if permanently {
                            try fm.removeItem(atPath: p); done[p] = .some(nil)
                        } else {
                            var out: NSURL?
                            try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &out)
                            done[p] = .some(out?.path)
                        }
                    } catch { failed.append((p, error.localizedDescription)) }
                }
                return Outcome(done: done, failed: failed)
            }.value
            guard let self else { return }
            self.deleting -= 1
            var freed: Int64 = 0
            var records: [TrashRecord] = []
            for it in items where outcome.done[it.path] != nil {
                freed += it.size
                if it.isDir, let n = it.node { self.model.scanner.didRemoveDirectory(n) }
                else { self.model.scanner.didRemoveFiles(bytes: it.size, items: 1, from: dirNode) }
                if let t = outcome.done[it.path] ?? nil { records.append(TrashRecord(original: it.path, trashed: t, isDirectory: it.isDir, size: it.size)) }
            }
            if !records.isEmpty { self.undoStack.append(records) }
            self.afterMutation(dirPath: dirPath)
            let n = outcome.done.count
            if n > 0 {
                self.flash(permanently
                           ? "Deleted \(n) item\(n == 1 ? "" : "s") — freed \(ByteFormat.string(freed))"
                           : "Moved \(n) item\(n == 1 ? "" : "s") to Trash (\(ByteFormat.string(freed))) — empty the Trash to free the space. ⌘Z to undo")
            }
            if !outcome.failed.isEmpty, let w = self.view.window {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "\(outcome.failed.count) item\(outcome.failed.count == 1 ? "" : "s") couldn't be deleted"
                a.informativeText = outcome.failed.prefix(4).map { "\(($0.0 as NSString).lastPathComponent): \($0.1)" }.joined(separator: "\n")
                a.beginSheetModal(for: w, completionHandler: nil)
            }
        }
    }

    private func afterMutation(dirPath: String) {
        selection = []
        invalidateCache()
        guard cwd == dirPath else { return }
        let idx = cursorIndex
        current = loadState(cwd, force: true)
        parentState = cwd == "/" ? nil : loadState((cwd as NSString).deletingLastPathComponent, force: true)
        let rows = current.rows
        cursorName = rows.isEmpty ? nil : rows[min(idx, rows.count - 1)].name
        renderAll(ensureVisible: true)
        startTimer()
        model.refreshVolumes()
    }

    @objc func undoTrash(_ sender: Any?) {
        guard let records = undoStack.popLast() else { return }
        var restored = 0
        for r in records {
            do {
                try FileManager.default.moveItem(atPath: r.trashed, toPath: r.original)
                restored += 1
                let parent = (r.original as NSString).deletingLastPathComponent
                if r.isDirectory { model.scan(r.original) }
                else { model.scanner.didRemoveFiles(bytes: -r.size, items: -1, from: model.node(for: parent)) }
            } catch { flash("Couldn't restore “\((r.original as NSString).lastPathComponent)”: \(error.localizedDescription)") }
        }
        afterMutation(dirPath: cwd)
        if restored > 0 { flash("Restored \(restored) item\(restored == 1 ? "" : "s")") }
    }

    // MARK: Flash message

    func flash(_ text: String, duration: TimeInterval = 5) {
        browserView.status.flash = text
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.browserView.status.flash = nil }
        }
    }

    // MARK: Context menu & validation

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            m.addItem(i)
        }
        add("Open", #selector(openSelection(_:)))
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        add("Copy Path", #selector(copyPath(_:)))
        m.addItem(.separator())
        add("Rescan", #selector(rescan(_:)))
        m.addItem(.separator())
        add("Move to Trash", #selector(trashSelection(_:)))
        add("Delete Immediately…", #selector(deleteSelection(_:)))
        return m
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(trashSelection(_:)), #selector(deleteSelection(_:)):
            return !targets().isEmpty && deleting == 0
        case #selector(undoTrash(_:)): return !undoStack.isEmpty
        case #selector(goBackAction(_:)): return canGoBack
        case #selector(goForwardAction(_:)): return canGoForward
        case #selector(goEnclosing(_:)): return cwd != "/"
        case #selector(goInto(_:)): return cursorRow?.isDirectory == true
        case #selector(toggleHidden(_:)): item.state = showHidden ? .on : .off; return true
        case #selector(sortBySize(_:)): item.state = sortKey == .size ? .on : .off; return true
        case #selector(sortByName(_:)): item.state = sortKey == .name ? .on : .off; return true
        case #selector(sortByDate(_:)): item.state = sortKey == .modified ? .on : .off; return true
        default: return true
        }
    }
}

extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}

extension BrowserViewController {
    @objc func goToPath(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String { cd(p) }
    }
}
