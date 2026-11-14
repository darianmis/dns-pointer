// Renders the DMG window background (neon grid + glow + hint text) at 1x and 2x.
// Usage: swift make-dmg-background.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = CGSize(width: 640, height: 400)

func render(scale: CGFloat) -> Data {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Base
    ctx.setFillColor(CGColor(srgbRed: 0.031, green: 0.035, blue: 0.047, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    // Glows
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func glow(_ center: CGPoint, _ radius: CGFloat, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) {
        let grad = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: r, green: g, blue: b, alpha: a), CGColor(srgbRed: r, green: g, blue: b, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    glow(CGPoint(x: 560, y: 380), 420, 0.2, 0.5, 1.0, 0.28)
    glow(CGPoint(x: 60, y: 20), 360, 0.0, 0.9, 1.0, 0.12)
    glow(CGPoint(x: 320, y: 215), 120, 0.0, 0.9, 1.0, 0.16)
    // Grid
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0.9, blue: 1, alpha: 0.06))
    ctx.setLineWidth(0.5)
    stride(from: 0.0, through: size.width, by: 24).forEach { x in ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height)) }
    stride(from: 0.0, through: size.height, by: 24).forEach { y in ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)) }
    ctx.strokePath()
    // Ring around the installer icon (icon centre is at 320,190 in Finder's top-left coordinates)
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0.9, blue: 1, alpha: 0.55))
    ctx.setLineWidth(1.5)
    ctx.setShadow(offset: .zero, blur: 12, color: CGColor(srgbRed: 0, green: 0.9, blue: 1, alpha: 0.9))
    ctx.strokeEllipse(in: CGRect(x: 320 - 78, y: size.height - 190 - 78, width: 156, height: 156))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Text
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = gc
    func draw(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, tracking: CGFloat = 0, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
        let s = NSAttributedString(string: text, attributes: attrs)
        let b = s.size()
        s.draw(at: CGPoint(x: (640 - b.width) / 2, y: 400 - y - b.height / 2))
    }
    draw("DNS REDIRECT", y: 44, size: 20, weight: .heavy, color: NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1), tracking: 4, mono: true)
    draw("INSTALLER", y: 68, size: 10, weight: .bold, color: NSColor(srgbRed: 0, green: 0.9, blue: 1, alpha: 1), tracking: 5, mono: true)
    draw("Double-click to install", y: 318, size: 15, weight: .semibold, color: NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1))
    draw("Apple Silicon & Intel · macOS 14 Sonoma or later · uninstall from the same app", y: 344, size: 11, weight: .regular,
         color: NSColor(srgbRed: 0.62, green: 0.66, blue: 0.74, alpha: 1))
    NSGraphicsContext.current = nil
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = size
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
print("wrote background.png and background@2x.png to \(out.path)")
