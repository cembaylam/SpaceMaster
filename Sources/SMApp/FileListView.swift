import AppKit
import SMCore

/// Custom-drawn list (like FileMaster's): fixed row height, only visible rows are drawn, cached CTLines and icons,
/// cursor-driven scrolling. Each row has a colored bar behind it whose length is its size relative to the largest sibling.
@MainActor
final class FileListView: NSView {
    static let rowHeight: CGFloat = 24

    private(set) var state: DirState?
    private(set) var cursor = 0
    private(set) var offset = 0
    private var selected: Set<String> = []
    private var message: String?

    var isActive = true { didSet { if isActive != oldValue { needsDisplay = true } } }
    var showsCursor = true { didSet { if showsCursor != oldValue { needsDisplay = true } } }
    var spinnerPhase: Double = 0

    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var onScrollRows: ((Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    private var scrollAccumulator: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var rows: [Row] { state?.rows ?? [] }
    var visibleRows: Int { max(1, Int(bounds.height / Self.rowHeight)) }
    var scrolloff = 4

    // MARK: State

    func update(state: DirState?, cursor: Int, selected: Set<String>, message: String?, ensureVisible: Bool = true) {
        self.state = state
        let n = state?.rows.count ?? 0
        self.cursor = n == 0 ? 0 : min(max(0, cursor), n - 1)
        self.selected = selected
        self.message = message
        clampOffset()
        if ensureVisible { scrollToCursor() }
        needsDisplay = true
    }

    func setSelected(_ s: Set<String>) {
        guard s != selected else { return }
        selected = s
        needsDisplay = true
    }

    func moveCursor(to index: Int) {
        let n = rows.count
        guard n > 0 else { return }
        let old = cursor, oldOffset = offset
        cursor = min(max(0, index), n - 1)
        scrollToCursor()
        if offset != oldOffset { needsDisplay = true } else {
            setNeedsDisplay(rowRect(old)); setNeedsDisplay(rowRect(cursor))
        }
    }

    func scroll(by rows: Int) {
        let n = min(max(0, offset + rows), max(0, self.rows.count - visibleRows))
        guard n != offset else { return }
        offset = n
        needsDisplay = true
    }

    private func clampOffset() { offset = max(0, min(offset, max(0, rows.count - visibleRows))) }

    private func scrollToCursor() {
        let vis = visibleRows
        let so = min(scrolloff, (vis - 1) / 2)
        if cursor < offset + so { offset = cursor - so }
        else if cursor > offset + vis - 1 - so { offset = cursor - (vis - 1 - so) }
        clampOffset()
    }

    func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(i - offset) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampOffset()
        scrollToCursor()
    }

    // MARK: Drawing

    private static let sizeWidth: CGFloat = 66
    private static let pctWidth: CGFloat = 38

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let text = TextCache.shared
        let dark = effectiveAppearance.isDark
        ctx.clip(to: bounds)
        // Explicit text colors: high contrast on top of the colored bars in both appearances.
        let primary = dark ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.07, alpha: 1)
        let secondary = primary.withAlphaComponent(0.72)
        let tertiary = primary.withAlphaComponent(0.55)

        guard let state, !state.rows.isEmpty else {
            if let message {
                let (line, w) = text.line(message, .name, maxWidth: bounds.width - 24)
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.setFillColor(secondary.cgColor)
                ctx.textPosition = CGPoint(x: max(12, (bounds.width - w) / 2), y: 40)
                CTLineDraw(line, ctx)
            }
            return
        }

        let rh = Self.rowHeight
        let rows = state.rows
        let first = offset + max(0, Int(dirtyRect.minY / rh))
        let last = min(rows.count - 1, offset + Int(dirtyRect.maxY / rh))
        guard first <= last else { return }

        let width = bounds.width
        let showPct = width >= 300
        let badgeCompact = width < 400
        let pctReserve: CGFloat = showPct ? Self.pctWidth : 0
        let nameBase = text.baseline(for: text.nameFont, rowHeight: rh)
        let metaBase = text.baseline(for: text.metaFont, rowHeight: rh)
        let smallBase = text.baseline(for: text.smallFont, rowHeight: rh)
        let badgeBase = text.baseline(for: text.badgeFont, rowHeight: rh)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let total = Double(max(1, state.total))
        let maxSize = Double(max(1, state.maxSize))
        let icons = IconCache.shared
        let accent = NSColor.controlAccentColor
        let barLeft: CGFloat = 6
        let chevronReserve: CGFloat = 16
        let barMax = width - 12

        for i in first...last {
            let r = rows[i]
            let y = CGFloat(i - offset) * rh
            let isCursor = showsCursor && i == cursor
            let isSelected = selected.contains(r.name)

            // Bar
            if r.size > 0 {
                let share = Double(r.size) / total
                let frac = CGFloat(Double(r.size) / maxSize)
                let bw = max(6, barMax * frac)
                let rect = NSRect(x: barLeft, y: y + 2, width: bw, height: rh - 4)
                let base = ShareColor.color(share: share, dark: dark)
                let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.saveGState()
                ctx.addPath(path); ctx.clip()
                let a0: CGFloat = dark ? 0.92 : 0.60, a1: CGFloat = dark ? 0.42 : 0.28
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [base.withAlphaComponent(a0).cgColor, base.withAlphaComponent(a1).cgColor] as CFArray,
                                      locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
                }
                ctx.restoreGState()
            }

            if isSelected {
                accent.withAlphaComponent(0.20).setFill()
                NSBezierPath(roundedRect: NSRect(x: 3, y: y + 1, width: width - 6, height: rh - 2), xRadius: 7, yRadius: 7).fill()
                accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: 1, y: y + 6, width: 3, height: rh - 12), xRadius: 1.5, yRadius: 1.5).fill()
            }
            if isCursor {
                let rect = NSRect(x: 5, y: y + 1, width: width - 10, height: rh - 2)
                let p = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                if isActive {
                    accent.withAlphaComponent(0.88).setFill()
                } else {
                    NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(dark ? 0.9 : 1).setFill()
                }
                p.fill()
            }
            let onAccent = isCursor && isActive
            let rowPrimary = onAccent ? NSColor.white : primary
            let rowSecondary = onAccent ? NSColor.white.withAlphaComponent(0.8) : secondary
            let rowTertiary = onAccent ? NSColor.white.withAlphaComponent(0.65) : tertiary

            // Icon
            icons.icon(for: r, dir: state.path).draw(in: NSRect(x: 14, y: y + (rh - 16) / 2, width: 16, height: 16),
                                                     from: .zero, operation: .sourceOver, fraction: r.isHidden ? 0.6 : 1,
                                                     respectFlipped: true, hints: nil)

            // Right side, laid out from the right edge.
            var x = width - 12 - chevronReserve
            if r.isDirectory, let img = IconCache.shared.symbol("chevron.right", size: 9, color: rowTertiary, weight: .semibold) {
                img.draw(in: NSRect(x: width - 12 - img.size.width - 2, y: y + (rh - img.size.height) / 2, width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if showPct {
                if r.size > 0 && !r.unknownSize {
                    let pct = Double(r.size) / total * 100
                    let s = pct >= 10 ? "\(Int(pct.rounded()))%" : pct >= 0.1 ? String(format: "%.1f%%", pct) : "<0.1%"
                    let (l, w) = text.line(s, .small, maxWidth: nil)
                    ctx.setFillColor(rowTertiary.cgColor)
                    ctx.textPosition = CGPoint(x: x - w, y: y + smallBase)
                    CTLineDraw(l, ctx)
                }
                x -= pctReserve
            }
            let sizeText = r.unknownSize ? "—" : ByteFormat.string(r.size)
            let (sl, sw) = text.line(sizeText, .meta, maxWidth: nil)
            ctx.setFillColor((r.calculating ? rowSecondary : rowPrimary).cgColor)
            ctx.textPosition = CGPoint(x: x - sw, y: y + metaBase)
            CTLineDraw(sl, ctx)
            if r.calculating { drawSpinner(ctx, center: CGPoint(x: x - sw - 9, y: y + rh / 2)) }
            x -= Self.sizeWidth + (r.calculating ? 10 : 0)

            // Badge
            let badgeW = drawBadge(ctx, r.safety, rightEdge: x, y: y, rowHeight: rh, compact: badgeCompact,
                                   baseline: badgeBase, text: text)
            x -= badgeW + 8

            // Name
            let nameColor: NSColor = r.isHidden && !onAccent ? secondary : r.kind == .symlink && !onAccent ? .systemTeal : rowPrimary
            ctx.setFillColor(nameColor.cgColor)
            let (nl, _) = text.line(r.name, .name, maxWidth: max(30, x - 38))
            ctx.textPosition = CGPoint(x: 38, y: y + nameBase)
            CTLineDraw(nl, ctx)
        }

        drawScroller(ctx)
    }

    /// Returns the width used.
    private func drawBadge(_ ctx: CGContext, _ safety: Safety, rightEdge: CGFloat, y: CGFloat, rowHeight rh: CGFloat,
                           compact: Bool, baseline: CGFloat, text: TextCache) -> CGFloat {
        let color: NSColor, label: String, symbol: String
        switch safety.level {
        case .safe: (color, label, symbol) = (.systemGreen, "Safe", "checkmark")
        case .protected: (color, label, symbol) = (.systemRed, "Protected", "lock.fill")
        case .mixed: (color, label, symbol) = (.systemOrange, "Has safe items", "lock.open.fill")
        }
        let h: CGFloat = 17
        let (l, lw) = text.line(label, .badge, maxWidth: nil)
        let w: CGFloat = compact ? h + 2 : 8 + 11 + 4 + lw + 8
        let rect = NSRect(x: rightEdge - w, y: y + (rh - h) / 2, width: w, height: h)
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
        if let img = IconCache.shared.symbol(symbol, size: 9, color: color) {
            let s = img.size
            let ix = compact ? rect.midX - s.width / 2 : rect.minX + 8
            img.draw(in: NSRect(x: ix, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if !compact {
            ctx.setFillColor(color.blended(withFraction: 0.25, of: .labelColor)?.cgColor ?? color.cgColor)
            ctx.textPosition = CGPoint(x: rect.minX + 8 + 11 + 4, y: y + baseline)
            CTLineDraw(l, ctx)
        }
        return w
    }

    private func drawSpinner(_ ctx: CGContext, center: CGPoint) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        let a = CGFloat(spinnerPhase * 2 * .pi)
        ctx.addArc(center: center, radius: 4, startAngle: a, endAngle: a + 4.2, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawScroller(_ ctx: CGContext) {
        let n = rows.count, vis = visibleRows
        guard n > vis else { return }
        let h = bounds.height
        let thumbH = max(24, h * CGFloat(vis) / CGFloat(n))
        let maxOff = CGFloat(n - vis)
        let y = (h - thumbH) * CGFloat(offset) / maxOff
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.width - 6, y: y + 2, width: 3.5, height: thumbH - 4), xRadius: 1.75, yRadius: 1.75).fill()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(trackingArea!)
    }

    private func rowIndex(_ event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        let i = offset + Int(p.y / Self.rowHeight)
        return i >= 0 && i < rows.count ? i : nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard let i = rowIndex(event) else { toolTip = nil; return }
        let p = convert(event.locationInWindow, from: nil)
        let r = rows[i]
        // Tooltip text explains the badge when hovering the right part of the row.
        toolTip = p.x > bounds.width - 230 ? r.safety.reason : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = rowIndex(event) else { return }
        if event.clickCount == 2 { onDoubleClick?(i) } else { onClick?(i, event.modifierFlags) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = rowIndex(event) else { return nil }
        onClick?(i, [])
        return menuProvider?(i)
    }

    override func scrollWheel(with event: NSEvent) {
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dy *= Self.rowHeight }
        scrollAccumulator -= dy
        let r = Int(scrollAccumulator / Self.rowHeight)
        if r != 0 {
            scrollAccumulator -= CGFloat(r) * Self.rowHeight
            if let onScrollRows { onScrollRows(r) } else { scroll(by: r) }
        }
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = 0 }
    }
}
