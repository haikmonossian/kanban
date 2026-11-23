// Renders the app icon (1024px PNG): glassy dark tile with three kanban columns (blue, amber, teal).
// Usage: swift Scripts/icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

// macOS icon grid: 824pt tile centered, continuous-ish corners.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0, 0, 0, 0.35).cgColor)
rgb(0.10, 0.12, 0.17).setFill(); tilePath.fill()
ctx.restoreGState()

// Background gradient + colored glows
ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [rgb(0.16, 0.19, 0.27), rgb(0.07, 0.08, 0.12)])!.draw(in: tile, angle: -90)
let glows: [(NSColor, CGPoint, CGFloat)] = [
    (rgb(0.30, 0.56, 0.96, 0.55), CGPoint(x: 230, y: 820), 420),
    (rgb(0.25, 0.78, 0.62, 0.45), CGPoint(x: 860, y: 260), 420),
    (rgb(0.96, 0.64, 0.18, 0.30), CGPoint(x: 560, y: 120), 360),
]
for (c, p, r) in glows {
    let g = NSGradient(colors: [c, c.withAlphaComponent(0)])!
    g.draw(fromCenter: p, radius: 0, toCenter: p, radius: r, options: [])
}

// Columns
let colW: CGFloat = 176, gap: CGFloat = 42, top: CGFloat = 790
let x0 = tile.midX - (colW * 3 + gap * 2) / 2
let specs: [(NSColor, CGFloat, Int)] = [
    (rgb(0.30, 0.56, 0.96), 470, 3),
    (rgb(0.96, 0.64, 0.18), 600, 4),
    (rgb(0.25, 0.78, 0.62), 330, 2),
]
for (i, (color, h, n)) in specs.enumerated() {
    let r = CGRect(x: x0 + CGFloat(i) * (colW + gap), y: top - h, width: colW, height: h)
    let p = NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color.withAlphaComponent(0.55).cgColor)
    NSGradient(colors: [color.blended(withFraction: 0.18, of: .white)!, color.blended(withFraction: 0.12, of: .black)!])!
        .draw(in: p, angle: -90)
    ctx.restoreGState()
    // glass rim
    rgb(1, 1, 1, 0.35).setStroke(); p.lineWidth = 3; p.stroke()
    // cards
    for k in 0..<n {
        let cr = CGRect(x: r.minX + 26, y: r.maxY - 44 - CGFloat(k) * 104 - 72, width: colW - 52, height: 72)
        let cp = NSBezierPath(roundedRect: cr, xRadius: 20, yRadius: 20)
        rgb(1, 1, 1, 0.82).setFill(); cp.fill()
        let line = NSBezierPath(roundedRect: CGRect(x: cr.minX + 18, y: cr.midY - 6, width: cr.width * 0.55, height: 12), xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.55).setFill(); line.fill()
    }
}

// Top gloss
let gloss = NSBezierPath(roundedRect: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), xRadius: 186, yRadius: 186)
NSGradient(colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)])!.draw(in: gloss, angle: -90)
ctx.restoreGState()

// Rim
rgb(1, 1, 1, 0.16).setStroke(); tilePath.lineWidth = 4; tilePath.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
