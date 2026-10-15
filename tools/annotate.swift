// Turns a raw dock snapshot (from `NeXTDock --snapshot`) into the annotated README image:
// the dock on a desktop-style backdrop with callouts pointing at each feature.
// Usage: swift tools/annotate.swift <dock.png> <out.png>   (reads <dock.png>.json for tile positions)

import AppKit

let args = CommandLine.arguments
let dockURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let dock = NSImage(contentsOf: dockURL)!
let meta = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1] + ".json"))) as! [String: Any]
let tiles = meta["tiles"] as! [[String: Any]]
let ptW = (meta["width"] as! NSNumber).doubleValue
let ptH = (meta["height"] as! NSNumber).doubleValue
let pixelsWide = (meta["pixelsWide"] as! NSNumber).doubleValue

// Layout in points (AppKit coordinates: origin bottom-left). Rendered at the snapshot's pixel density.
let scale = pixelsWide / ptW
let pad = 40.0, labelArea = 430.0
let W = labelArea + ptW + pad * 2, H = ptH + pad * 2
let dockX = W - pad - ptW
func yUp(_ fromTop: Double) -> Double { H - pad - fromTop }   // dock-space y (top-down) -> canvas y (bottom-up)

func num(_ t: [String: Any], _ k: String) -> Double { (t[k] as! NSNumber).doubleValue }
func center(_ t: [String: Any]) -> Double { yUp(num(t, "y") + num(t, "h") / 2) }
func kind(_ t: [String: Any]) -> String { t["kind"] as! String }
func running(_ t: [String: Any]) -> Bool { (t["running"] as! NSNumber).boolValue }
func first(_ match: ([String: Any]) -> Bool) -> [String: Any]? { tiles.first(where: match) }

var callouts: [(String, String, Double)] = []
if let t = first({ kind($0) == "clock" }) { callouts.append(("Clock + calendar", "NeXT-style; click opens Calendar", center(t))) }
if let t = first({ kind($0) == "spaces" }) { callouts.append(("Desktop switcher", "Solaris CDE-style; click a number to jump", center(t))) }
if let t = first({ kind($0) == "app" && !running($0) && ($0["name"] as! String) != "Finder" }) {
    callouts.append(("Pinned apps", "Stay exactly where you put them", center(t)))
}
if let t = first({ kind($0) == "folder" }) { callouts.append(("Folders", "Click for a pop-up of the contents", center(t))) }
if let t = first({ kind($0) == "script" }) { callouts.append(("Scripts", "Run in the background; border shows result", center(t))) }
if let t = first({ kind($0) == "shortcut" }) { callouts.append(("Shortcuts", "Run any macOS Shortcut", center(t))) }
if let t = first({ running($0) }) { callouts.append(("Running apps", "Kept separate, below the divider", center(t))) }
if let t = first({ kind($0) == "plus" }) { callouts.append(("Options", "Click for settings; drop files here to pin", center(t))) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Backdrop: dark slate gradient, lighter at the top.
NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
           ending: NSColor(calibratedRed: 0.19, green: 0.22, blue: 0.28, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

// Dock with a soft shadow.
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = NSColor(white: 0, alpha: 0.6); sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: -6)
sh.set()
dock.draw(in: NSRect(x: dockX, y: pad, width: ptW, height: ptH))
NSGraphicsContext.restoreGraphicsState()

// Callouts: title + detail, right-aligned, with a leader line to the tile.
let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                                 .foregroundColor: NSColor.white]
let detailAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular),
                                                  .foregroundColor: NSColor(white: 0.75, alpha: 1)]
let accent = NSColor(calibratedRed: 1, green: 0.72, blue: 0.25, alpha: 1)
let textRight = dockX - 64
for (title, detail, y) in callouts {
    let ts = (title as NSString).size(withAttributes: titleAttrs)
    let ds = (detail as NSString).size(withAttributes: detailAttrs)
    let blockH = ts.height + ds.height
    (title as NSString).draw(at: NSPoint(x: textRight - ts.width, y: y + blockH / 2 - ts.height), withAttributes: titleAttrs)
    (detail as NSString).draw(at: NSPoint(x: textRight - ds.width, y: y - blockH / 2), withAttributes: detailAttrs)
    accent.setStroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: textRight + 10, y: y)); line.line(to: NSPoint(x: dockX - 8, y: y))
    line.lineWidth = 1.5; line.stroke()
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: dockX - 12, y: y - 4, width: 8, height: 8)).fill()
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("Wrote \(outURL.path)")
