import AppKit
import SMCore

@MainActor
final class CapacityBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let color: NSColor = fraction > 0.9 ? .systemRed : fraction > 0.75 ? .systemOrange : .controlAccentColor
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height),
                     xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

@MainActor
final class VolumeCellView: NSTableCellView {
    let bar = CapacityBar()
    let detail = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(); imageView = icon
        let name = NSTextField(labelWithString: ""); textField = name
        name.font = .systemFont(ofSize: 13); name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 10.5); detail.textColor = .secondaryLabelColor
        for v in [icon, name, bar, detail] as [NSView] { addSubview(v) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let b = bounds
        imageView?.frame = NSRect(x: 4, y: b.height - 26, width: 22, height: 22)
        textField?.frame = NSRect(x: 32, y: b.height - 22, width: b.width - 36, height: 16)
        bar.frame = NSRect(x: 32, y: b.height - 34, width: b.width - 40, height: 5)
        detail.frame = NSRect(x: 32, y: b.height - 50, width: b.width - 36, height: 14)
    }
}

@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Item {
        case header(String)
        case place(title: String, path: String, symbol: String)
        case volume(VolumeInfo)
        var path: String? {
            switch self { case .header: nil; case .place(_, let p, _): p; case .volume(let v): v.path }
        }
    }

    private let table = NSTableView()
    private var items: [Item] = []
    var onSelect: ((String) -> Void)?
    private var suppress = false
    private let model = AppModel.shared

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        table.style = .sourceList
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowSizeStyle = .default
        table.floatsGroupRows = false
        table.allowsEmptySelection = true
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        view = scroll
        NotificationCenter.default.addObserver(forName: AppModel.volumesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() {
        let h = model.home
        let fm = FileManager.default
        var places: [Item] = [
            .place(title: NSUserName(), path: h, symbol: "house"),
            .place(title: "Desktop", path: h + "/Desktop", symbol: "menubar.dock.rectangle"),
            .place(title: "Documents", path: h + "/Documents", symbol: "doc"),
            .place(title: "Downloads", path: h + "/Downloads", symbol: "arrow.down.circle"),
            .place(title: "Applications", path: "/Applications", symbol: "square.grid.2x2"),
        ]
        var hogs: [Item] = []
        for (t, p, s) in [("Library", h + "/Library", "books.vertical"), ("Caches", h + "/Library/Caches", "memorychip"),
                          ("Developer", h + "/Library/Developer", "hammer"), ("Trash", h + "/.Trash", "trash")]
        where fm.fileExists(atPath: p) { hogs.append(.place(title: t, path: p, symbol: s)) }
        items = [.header("Favorites")] + places + hogs + [.header("Locations")] + model.volumes.map { .volume($0) }
        places.removeAll()
        let sel = selectedPath
        suppress = true
        table.reloadData()
        if let sel { select(path: sel) }
        suppress = false
    }

    private var selectedPath: String? {
        table.selectedRow >= 0 ? items[table.selectedRow].path : nil
    }

    /// Highlights the sidebar row matching `path` exactly (no highlight inside deeper folders).
    func select(path: String) {
        suppress = true
        defer { suppress = false }
        if let i = items.firstIndex(where: { $0.path == path }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = items[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .volume = items[row] { return 54 }
        return 28
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let t):
            let c = NSTableCellView()
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(l); c.textField = l
            NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                                         l.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            return c
        case .place(let title, let path, let symbol):
            let c = NSTableCellView()
            let iv = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            iv.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            let l = NSTextField(labelWithString: title)
            l.lineBreakMode = .byTruncatingTail
            for v in [iv, l] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            c.imageView = iv; c.textField = l
            c.toolTip = path.abbreviatingWithTildeInPath
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6), iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 20),
                l.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6), l.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                l.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        case .volume(let v):
            let c = VolumeCellView()
            c.imageView?.image = NSWorkspace.shared.icon(forFile: v.path)
            c.textField?.stringValue = v.name
            c.bar.fraction = v.total > 0 ? Double(v.used) / Double(v.total) : 0
            c.detail.stringValue = "\(ByteFormat.string(v.available)) free of \(ByteFormat.string(v.total))"
            return c
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, table.selectedRow >= 0, let p = items[table.selectedRow].path else { return }
        onSelect?(p)
    }
}
