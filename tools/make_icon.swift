// Draws the NeXTDock app icon at every size macOS needs and writes an .iconset folder.
// Usage:  swift tools/make_icon.swift <output.iconset>
//         iconutil -c icns <output.iconset> -o Resources/AppIcon.icns
//
// Design: a column of NeXTSTEP-style beveled gray tiles (clock, desktop switcher, script)
// on a dark charcoal base. Everything is drawn as vectors on a 1024-point canvas.

import AppKit

let canvas: CGFloat = 1024

func gray(_ w: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(calibratedWhite: w, alpha: a) }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }

/// Rectangle measured from the top of the canvas (easier to lay out), converted to AppKit's bottom-up coordinates.
func fromTop(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: canvas - top - h, width: w, height: h)
}

func bevel(_ r: NSRect, _ e: CGFloat, raised: Bool) {
    let hi = gray(0.82), lo = gray(0.05)
    (raised ? hi : lo).setFill()
    NSRect(x: r.minX, y: r.maxY - e, width: r.width, height: e).fill()      // top
    NSRect(x: r.minX, y: r.minY, width: e, height: r.height).fill()          // left
    (raised ? lo : hi).setFill()
    NSRect(x: r.minX, y: r.minY, width: r.width, height: e).fill()           // bottom
    NSRect(x: r.maxX - e, y: r.minY, width: e, height: r.height).fill()      // right
}

func text(_ s: String, _ font: NSFont, _ color: NSColor, centerIn r: NSRect, dy: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let sz = (s as NSString).size(withAttributes: attrs)
    (s as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2 + dy), withAttributes: attrs)
}

func tileBase(_ r: NSRect) {
    NSGradient(starting: gray(0.24), ending: gray(0.44))!.draw(in: r, angle: 90)
    bevel(r, 6, raised: true)
}

func clockTile(_ r: NSRect) {
    tileBase(r)
    let m: CGFloat = 24
    let strip = NSRect(x: r.minX + m, y: r.maxY - m - 54, width: r.width - 2 * m, height: 54)
    gray(0.06).setFill(); strip.fill()
    gray(0.6).setFill(); NSRect(x: strip.minX, y: strip.minY, width: strip.width, height: 2).fill()
    text("9:41", .monospacedDigitSystemFont(ofSize: 40, weight: .semibold), rgb(1, 0.72, 0.25), centerIn: strip)

    let page = NSRect(x: r.minX + m, y: r.minY + m, width: r.width - 2 * m, height: strip.minY - 10 - (r.minY + m))
    gray(0.95).setFill(); page.fill()
    gray(0.1).setStroke()
    let p = NSBezierPath(rect: page.insetBy(dx: 1.5, dy: 1.5)); p.lineWidth = 3; p.stroke()
    // Stack weekday / date / month top to bottom with equal gaps (same layout as the live clock tile).
    let lines: [(String, NSFont, NSColor)] = [
        ("THU", .systemFont(ofSize: 20, weight: .heavy), rgb(0.75, 0.1, 0.1)),
        ("15", .systemFont(ofSize: 44, weight: .bold), .black),
        ("OCT", .systemFont(ofSize: 18, weight: .semibold), gray(0.25)),
    ]
    let sizes = lines.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]) }
    let gap = max(0, (page.height - sizes.reduce(0) { $0 + $1.height }) / 4)
    var y = page.maxY - gap
    for (i, l) in lines.enumerated() {
        y -= sizes[i].height
        (l.0 as NSString).draw(at: NSPoint(x: page.midX - sizes[i].width / 2, y: y),
                               withAttributes: [.font: l.1, .foregroundColor: l.2])
        y -= gap
    }
}

func desktopsTile(_ r: NSRect) {
    tileBase(r)
    let m: CGFloat = 24, gap: CGFloat = 10
    let area = r.insetBy(dx: m, dy: m)
    let cw = (area.width - gap) / 2, ch = (area.height - gap) / 2
    for i in 0..<4 {
        let row = i / 2, col = i % 2
        let cell = NSRect(x: area.minX + CGFloat(col) * (cw + gap),
                          y: area.maxY - CGFloat(row + 1) * ch - CGFloat(row) * gap, width: cw, height: ch)
        let cur = i == 0
        (cur ? rgb(0.20, 0.40, 0.58) : gray(0.66)).setFill(); cell.fill()
        bevel(cell, 4, raised: !cur)
        text("\(i + 1)", .systemFont(ofSize: 40, weight: .bold), cur ? .white : .black, centerIn: cell)
    }
}

func scriptTile(_ r: NSRect) {
    tileBase(r)
    let screen = r.insetBy(dx: 26, dy: 26)
    rgb(0.04, 0.06, 0.04).setFill(); screen.fill()
    bevel(screen, 4, raised: false)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 66, weight: .bold),
                                                .foregroundColor: rgb(0.30, 1.0, 0.45)]
    let s = ">_" as NSString
    let sz = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: screen.minX + 22, y: screen.midY - sz.height / 2), withAttributes: attrs)
}

func plusBar(_ r: NSRect) {
    gray(0.17).setFill(); r.fill()
    gray(0.45).setFill(); NSRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 3).fill()
    text("+", .systemFont(ofSize: 56, weight: .light), gray(0.75), centerIn: r)
}

func drawIcon() {
    // Base: rounded square on the standard macOS icon grid (824 pt body, 100 pt margin).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = gray(0, 0.45); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    gray(0.1).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: gray(0.07), ending: gray(0.24))!.draw(in: shape, angle: 90)
    gray(1, 0.10).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182); rim.lineWidth = 4; rim.stroke()

    // The dock column.
    let tile: CGFloat = 216, plusH: CGFloat = 70
    let total = tile * 3 + plusH
    let x = (canvas - tile) / 2, top = (canvas - total) / 2
    let column = fromTop(x, top, tile, total)
    NSGraphicsContext.saveGraphicsState()
    let cs = NSShadow()
    cs.shadowColor = gray(0, 0.7); cs.shadowBlurRadius = 34; cs.shadowOffset = NSSize(width: 0, height: -16)
    cs.set()
    gray(0.15).setFill(); column.fill()
    NSGraphicsContext.restoreGraphicsState()

    clockTile(fromTop(x, top, tile, tile))
    desktopsTile(fromTop(x, top + tile, tile, tile))
    scriptTile(fromTop(x, top + tile * 2, tile, tile))
    plusBar(fromTop(x, top + tile * 3, tile, plusH))
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let t = NSAffineTransform(); t.scale(by: CGFloat(px) / canvas); t.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("Wrote \(out.path)")
