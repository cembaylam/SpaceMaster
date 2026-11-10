import AppKit
import QuickLookThumbnailing
import SMCore
import UniformTypeIdentifiers

/// Thin title strip above each column: folder name on the left, total size on the right.
@MainActor
final class ColumnHeaderView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var detail = "" { didSet { needsDisplay = true } }
    var emphasized = true { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let text = TextCache.shared
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        // Use the context fill color (CoreText would otherwise draw black).
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, fromContext: true]
        let base = ((bounds.height + font.capHeight) / 2).rounded()
        var right = bounds.width - 14
        if !detail.isEmpty {
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: detail, attributes: [.font: text.smallFont, fromContext: true]))
            let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
            ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
            ctx.textPosition = CGPoint(x: right - w, y: base)
            CTLineDraw(l, ctx)
            right -= w + 10
        }
        var l = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attrs))
        if CTLineGetTypographicBounds(l, nil, nil, nil) > Double(right - 14) {
            let tok = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            l = CTLineCreateTruncatedLine(l, Double(max(10, right - 14)), .middle, tok) ?? l
        }
        ctx.setFillColor((emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor)
        ctx.textPosition = CGPoint(x: 14, y: base)
        CTLineDraw(l, ctx)
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }
}

/// Bottom bar: folder/selection summary, scan progress, volume capacity.
@MainActor
final class StatusBarView: NSView {
    var summary = "" { didSet { needsDisplay = true } }
    var scanText: String? { didSet { needsDisplay = true } }
    var flash: String? { didSet { needsDisplay = true } }
    var volume: VolumeInfo? { didSet { needsDisplay = true } }
    /// Quiet, clickable note (e.g. unreadable folders → open Full Disk Access settings).
    var accessNote: String? { didSet { needsDisplay = true } }
    var onAccessClick: (() -> Void)?
    fileprivate var accessRect: NSRect = .zero
    var scanPhase: Double = 0
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let text = TextCache.shared
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
        let base = text.baseline(for: text.smallFont, rowHeight: bounds.height)

        var right = bounds.width - 14
        if let v = volume, v.total > 0 {
            let used = Double(v.used) / Double(v.total)
            let s = "\(ByteFormat.string(v.available)) free of \(ByteFormat.string(v.total))"
            let (l, w) = text.line(s, .small, maxWidth: nil)
            ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
            ctx.textPosition = CGPoint(x: right - w, y: base)
            CTLineDraw(l, ctx)
            right -= w + 10
            let barW: CGFloat = 90, barH: CGFloat = 6
            let bar = NSRect(x: right - barW, y: (bounds.height - barH) / 2, width: barW, height: barH)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            let color: NSColor = used > 0.9 ? .systemRed : used > 0.75 ? .systemOrange : .controlAccentColor
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(6, bar.width * CGFloat(used)), height: barH), xRadius: 3, yRadius: 3).fill()
            right -= barW + 14
        }

        var left: CGFloat = 14
        if let scanText {
            // Indeterminate shimmer dot + text
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineWidth(1.6); ctx.setLineCap(.round)
            let a = CGFloat(scanPhase * 2 * .pi)
            ctx.addArc(center: CGPoint(x: left + 5, y: bounds.height / 2), radius: 4.5, startAngle: a, endAngle: a + 4.2, clockwise: false)
            ctx.strokePath()
            left += 16
            let (l, w) = text.line(scanText, .small, maxWidth: nil)
            ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
            ctx.textPosition = CGPoint(x: left, y: base)
            CTLineDraw(l, ctx)
            left += w + 18
        }
        accessRect = .zero
        if let note = accessNote {
            let (l, w) = text.line(note, .small, maxWidth: nil)
            if let img = IconCache.shared.symbol("exclamationmark.triangle.fill", size: 10, color: .systemOrange) {
                let rect = NSRect(x: left, y: (bounds.height - 6) / 2 - 2, width: 0, height: 0)
                _ = rect
                img.draw(in: NSRect(x: left, y: (bounds.height - img.size.height) / 2, width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                left += img.size.width + 5
            }
            ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
            ctx.textPosition = CGPoint(x: left, y: base)
            CTLineDraw(l, ctx)
            accessRect = NSRect(x: left - 18, y: 0, width: w + 22, height: bounds.height)
            left += w + 18
        }
        let msg = flash ?? summary
        let (l, w) = text.line(msg, .small, maxWidth: max(40, right - left))
        ctx.setFillColor((flash != nil ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor)
        // Centered like Finder's status line (but never over the scan indicator or the volume bar).
        let cx = min(max(left, (bounds.width - w) / 2), max(left, right - w))
        ctx.textPosition = CGPoint(x: cx, y: base)
        CTLineDraw(l, ctx)
    }
}

extension StatusBarView {
    override func mouseDown(with event: NSEvent) {
        if accessNote != nil, accessRect.contains(convert(event.locationInWindow, from: nil)) { onAccessClick?() }
    }
    override func resetCursorRects() { if accessNote != nil { addCursorRect(accessRect, cursor: .pointingHand) } }
}

/// Finder-style breadcrumb: Macintosh HD › Users › cem › Projects. Click a segment to go there.
@MainActor
final class PathBarView: NSView {
    var path = "/" { didSet { needsDisplay = true } }
    var volumeName = "Macintosh HD"
    var onSelect: ((String) -> Void)?
    private var hits: [(NSRect, String)] = []
    override var isFlipped: Bool { true }

    private func segments() -> [(title: String, path: String)] {
        var out: [(String, String)] = [(volumeName, "/")]
        var p = ""
        for c in path.split(separator: "/") { p += "/" + c; out.append((String(c), p)) }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let text = TextCache.shared
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
        let segs = segments()
        let icon: CGFloat = 14, pad: CGFloat = 8, chev: CGFloat = 14
        func width(_ t: String) -> CGFloat { icon + 4 + text.line(t, .small, maxWidth: nil).width + chev }
        var start = 0
        var total = segs.reduce(CGFloat(0)) { $0 + width($1.title) } + 14
        while total > bounds.width - 20, start < segs.count - 1 { total -= width(segs[start].title); start += 1 }
        hits = []
        var x: CGFloat = 12
        let base = text.baseline(for: text.smallFont, rowHeight: bounds.height)
        if start > 0 { ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor); ctx.textPosition = CGPoint(x: x, y: base); CTLineDraw(text.line("… ›", .small, maxWidth: nil).line, ctx); x += 24 }
        _ = pad
        for (i, seg) in segs.enumerated() where i >= start {
            let (l, w) = text.line(seg.title, .small, maxWidth: nil)
            let img = NSWorkspace.shared.icon(forFile: seg.path)
            img.draw(in: NSRect(x: x, y: (bounds.height - icon) / 2, width: icon, height: icon), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
            let last = i == segs.count - 1
            ctx.setFillColor((last ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor)
            ctx.textPosition = CGPoint(x: x + icon + 4, y: base)
            CTLineDraw(l, ctx)
            hits.append((NSRect(x: x, y: 0, width: icon + 4 + w, height: bounds.height), seg.path))
            x += icon + 4 + w
            if !last {
                ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor)
                ctx.textPosition = CGPoint(x: x + 4, y: base)
                CTLineDraw(text.line("›", .small, maxWidth: nil).line, ctx)
                x += chev
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hits.first(where: { $0.0.contains(p) }) { onSelect?(hit.1) }
    }
}

/// Banner explaining Full Disk Access.
@MainActor
final class AccessBanner: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let openButton = NSButton(title: "Open Settings…", target: nil, action: nil)
    let dismissButton = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.16).cgColor
        label.stringValue = "Some folders can't be read. Grant Full Disk Access to include them and scan faster."
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        dismissButton.bezelStyle = .inline
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.isBordered = false
        for v in [label, openButton, dismissButton] as [NSView] { addSubview(v) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        dismissButton.frame = NSRect(x: b.width - 30, y: (b.height - 18) / 2, width: 18, height: 18)
        openButton.sizeToFit()
        openButton.frame.origin = NSPoint(x: b.width - 38 - openButton.frame.width, y: (b.height - openButton.frame.height) / 2)
        label.frame = NSRect(x: 14, y: (b.height - 16) / 2, width: max(0, openButton.frame.minX - 24), height: 16)
    }
}

/// Right column when a file (not a folder) is under the cursor.
@MainActor
final class FileInfoView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private var grid = NSGridView()
    private var thumbToken = 0
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byTruncatingMiddle
        reasonLabel.font = .systemFont(ofSize: 11)
        reasonLabel.textColor = .secondaryLabelColor
        reasonLabel.alignment = .center
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        for v in [iconView, nameLabel, grid, badge, reasonLabel] as [NSView] { addSubview(v) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func show(path: String, row: Row) {
        nameLabel.stringValue = row.name
        let ws = NSWorkspace.shared
        iconView.image = ws.icon(forFile: path)
        let url = URL(fileURLWithPath: path)
        let type = UTType(filenameExtension: url.pathExtension)
        let kind = row.kind == .symlink ? "Alias / symbolic link" : (type?.localizedDescription ?? "Document")
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let modified = row.mtime > 0 ? f.string(from: Date(timeIntervalSince1970: row.mtime)) : "—"
        let rowsData: [(String, String)] = [
            ("Size", ByteFormat.string(row.size) + (row.size >= 1000 ? "  (\(ByteFormat.count(Int(row.size))) bytes)" : "")),
            ("Kind", kind), ("Modified", modified),
            ("Where", (path as NSString).deletingLastPathComponent.abbreviatingWithTildeInPath),
        ]
        grid.removeFromSuperview()
        grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        addSubview(grid)
        for (k, v) in rowsData {
            let kl = NSTextField(labelWithString: k)
            kl.font = .systemFont(ofSize: 11); kl.textColor = .secondaryLabelColor; kl.alignment = .right
            let vl = NSTextField(wrappingLabelWithString: v)
            vl.font = .systemFont(ofSize: 11); vl.maximumNumberOfLines = 3; vl.lineBreakMode = .byTruncatingMiddle
            vl.isSelectable = true
            grid.addRow(with: [kl, vl])
        }
        grid.column(at: 0).xPlacement = .trailing
        switch row.safety.level {
        case .safe: badge.stringValue = "Safe to delete"; badge.textColor = .systemGreen
        case .protected: badge.stringValue = "Protected — can't be deleted"; badge.textColor = .systemRed
        case .mixed: badge.stringValue = "Protected, but has safe items inside"; badge.textColor = .systemOrange
        }
        reasonLabel.stringValue = row.safety.reason
        needsLayout = true

        thumbToken += 1
        let token = thumbToken
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 160),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            nonisolated(unsafe) let image = img
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.thumbToken == token else { return }
                    self.iconView.image = image
                }
            }
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 18
        iconView.frame = NSRect(x: (w - 112) / 2, y: 28, width: 112, height: 112)
        let nh = nameLabel.sizeThatFits(NSSize(width: w - 2 * pad, height: 200)).height
        nameLabel.frame = NSRect(x: pad, y: 150, width: w - 2 * pad, height: nh)
        var y = nameLabel.frame.maxY + 8
        badge.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: 16); y += 18
        let rh = reasonLabel.sizeThatFits(NSSize(width: w - 2 * pad, height: 200)).height
        reasonLabel.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: rh); y += rh + 14
        let gs = grid.fittingSize
        grid.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: min(gs.height, max(0, bounds.height - y - 8)))
    }
}

/// Root view: banner + three columns (parent | current | preview) + status bar.
@MainActor
final class BrowserView: NSView {
    weak var controller: BrowserViewController?

    let parentList = FileListView()
    let currentList = FileListView()
    let previewList = FileListView()
    let info = FileInfoView()
    let headers = [ColumnHeaderView(), ColumnHeaderView(), ColumnHeaderView()]
    let status = StatusBarView()
    let pathBar = PathBarView()
    let banner = AccessBanner()

    static let defaultRatio: [CGFloat] = [2, 4, 3]
    private static let ratioKey = "sm.columnRatio"
    var ratio: [CGFloat] = BrowserView.defaultRatio { didSet { needsLayout = true } }
    static let statusHeight: CGFloat = 26
    static let pathBarHeight: CGFloat = 24
    private var listBottom: CGFloat { Self.statusHeight + Self.pathBarHeight }
    static let headerHeight: CGFloat = 24
    static let bannerHeight: CGFloat = 34
    private static let dividerHit: CGFloat = 4
    private var draggedDivider: Int?
    var bannerVisible = false { didSet { banner.isHidden = !bannerVisible; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        if let saved = UserDefaults.standard.array(forKey: Self.ratioKey) as? [Double], saved.count == 3, saved.allSatisfy({ $0 > 0 }) {
            ratio = saved.map { CGFloat($0) }
        }
        for v in ([parentList, currentList, previewList, info, status, pathBar, banner] as [NSView]) + headers { addSubview(v) }
        for l in [parentList, currentList, previewList] as [NSView] { l.clipsToBounds = true }
        info.clipsToBounds = true
        parentList.isActive = false
        previewList.isActive = false
        previewList.showsCursor = false
        info.isHidden = true
        banner.isHidden = true
        headers[0].emphasized = false
        headers[2].emphasized = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        // Column dividers
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        let colTop = headers[0].frame.maxY
        for x in dividerXs { NSRect(x: x - 0.5, y: listBottom, width: 1, height: max(0, colTop - listBottom)).fill() }
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let sh = Self.statusHeight
        status.frame = NSRect(x: 0, y: 0, width: b.width, height: sh)
        pathBar.frame = NSRect(x: 0, y: sh, width: b.width, height: Self.pathBarHeight)
        let lb = listBottom
        var top = b.height - max(0, safeAreaInsets.top)
        if bannerVisible {
            banner.frame = NSRect(x: 0, y: top - Self.bannerHeight, width: b.width, height: Self.bannerHeight)
            top -= Self.bannerHeight
        }
        let hh = Self.headerHeight
        let listH = max(0, top - lb - hh)
        let total = ratio.reduce(0, +)
        var x: CGFloat = 0
        let lists: [NSView] = [parentList, currentList, previewList]
        for i in 0..<3 {
            let w = i == 2 ? b.width - x : (b.width * ratio[i] / total).rounded()
            lists[i].frame = NSRect(x: x, y: lb, width: w, height: listH)
            headers[i].frame = NSRect(x: x, y: lb + listH, width: w, height: hh)
            if i == 2 { info.frame = lists[i].frame }
            x += w
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Resizable columns

    private var dividerXs: [CGFloat] { [currentList.frame.minX, previewList.frame.minX] }

    private func divider(at p: NSPoint) -> Int? {
        guard p.y > listBottom else { return nil }
        return dividerXs.firstIndex { abs(p.x - $0) <= Self.dividerHit }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if divider(at: convert(point, from: superview)) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        for x in dividerXs {
            addCursorRect(NSRect(x: x - Self.dividerHit, y: listBottom, width: Self.dividerHit * 2, height: bounds.height - listBottom), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let d = divider(at: convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount == 2 { ratio = Self.defaultRatio; saveRatio() } else { draggedDivider = d }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = draggedDivider else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let total = bounds.width
        let min: CGFloat = 140
        var a = ratio[0] / ratio.reduce(0, +) * total
        var b = (ratio[0] + ratio[1]) / ratio.reduce(0, +) * total
        if d == 0 { a = Swift.min(Swift.max(min, x), b - min) } else { b = Swift.min(Swift.max(a + min, x), total - min) }
        ratio = [a, b - a, total - b]
    }

    override func mouseUp(with event: NSEvent) {
        if draggedDivider != nil { draggedDivider = nil; saveRatio() }
    }

    private func saveRatio() { UserDefaults.standard.set(ratio.map { Double($0) }, forKey: Self.ratioKey) }
}
