// Renders the PocketCode app icon and launch logo with CoreGraphics.
// Usage: swift scripts/render_icon.swift <output-dir>
// Original artwork: a stitched pocket holding a terminal prompt. Deliberately unlike
// VS Code's branding (no ribbon/infinity shape, no VS Code blue).
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Pocket outline in a 1024 design space, scaled/offset by `s`/`o`.
func pocketPath(scale s: CGFloat, origin o: CGPoint, inset: CGFloat = 0) -> NSBezierPath {
    let l = 252 + inset, r = 772 - inset, top = 278 + inset, side = 640 - inset * 0.4, tip = 800 - inset * 1.25
    // AppKit's origin is bottom-left; design coordinates are top-down.
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: o.x + x * s, y: o.y + (1024 - y) * s) }
    let path = NSBezierPath()
    path.move(to: p(l, top))
    path.line(to: p(r, top))
    path.line(to: p(r, side))
    path.line(to: p(512, tip))
    path.line(to: p(l, side))
    path.close()
    path.lineJoinStyle = .round
    path.lineCapStyle = .round
    return path
}

func drawGlyph(in size: CGFloat, origin: CGPoint = .zero) {
    let s = size / 1024
    let mint = color(0x4BE3A4)
    let pocket = pocketPath(scale: s, origin: origin)
    color(0x4BE3A4, 0.10).setFill()
    pocket.fill()
    mint.setStroke()
    pocket.lineWidth = 44 * s
    pocket.stroke()
    // Stitching
    let stitch = pocketPath(scale: s, origin: origin, inset: 46)
    stitch.lineWidth = 9 * s
    stitch.setLineDash([26 * s, 20 * s], count: 2, phase: 0)
    color(0x4BE3A4, 0.55).setStroke()
    stitch.stroke()
    // Prompt
    let font = NSFont.monospacedSystemFont(ofSize: 230 * s, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: -6 * s]
    let text = NSAttributedString(string: ">_", attributes: attrs)
    let b = text.size()
    text.draw(at: NSPoint(x: origin.x + 512 * s - b.width / 2, y: origin.y + (1024 - 530) * s - b.height / 2))
}

func render(_ name: String, size: CGFloat, background: Bool) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if background {
        // App icons must be opaque and square; iOS applies the corner mask.
        NSGradient(colors: [color(0x26304A), color(0x0D4A47)])!
            .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -50)
    }
    drawGlyph(in: size)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    print("wrote \(name)")
}

render("AppIcon.png", size: 1024, background: true)
render("LaunchLogo.png", size: 600, background: false)
