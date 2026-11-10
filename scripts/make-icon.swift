// Renders Resources/AppIcon.icns: a dark squircle with a heat-colored disk-usage donut.
// Usage: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor(red: 0.13, green: 0.15, blue: 0.24, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1)])!
        .draw(in: rect, angle: -90)
    // Disk-usage donut: heat-colored arcs (red = biggest share → blue = smallest) with rounded caps and a glowing core.
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width * 0.28, lw = rect.width * 0.15
    let parts: [(CGFloat, CGFloat)] = [(0.42, 0.0), (0.24, 0.075), (0.17, 0.30), (0.11, 0.52), (0.06, 0.66)]
    let gap: CGFloat = 4.5   // degrees between segments
    var start: CGFloat = 90
    for (share, hue) in parts {
        let sweep = share * 360
        let a0 = start, a1 = start - sweep + gap
        let col = NSColor(hue: hue, saturation: 0.74, brightness: 1.0, alpha: 1)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: radius, startAngle: a0 - gap / 2, endAngle: a1 - gap / 2, clockwise: true)
        arc.lineWidth = lw; arc.lineCapStyle = .butt
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow(); glow.shadowColor = col.withAlphaComponent(0.55); glow.shadowBlurRadius = s * 0.035; glow.shadowOffset = .zero
        glow.set()
        col.setStroke(); arc.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
        start -= sweep
    }
    // Core
    let core = NSBezierPath(ovalIn: NSRect(x: c.x - rect.width * 0.09, y: c.y - rect.width * 0.09, width: rect.width * 0.18, height: rect.width * 0.18))
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.95), NSColor(red: 0.55, green: 0.65, blue: 1, alpha: 0.9)])!.draw(in: core, relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
    // Gloss
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), .clear])!.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = "build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("Resources/AppIcon.icns")
