// Draws the DeskLight app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit
import CoreGraphics

let size = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func point(_ p: CGPoint, _ d: CGVector, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x + d.dx * k, y: p.y + d.dy * k) }

func draw(_ ctx: CGContext) {
    // Work in top-left coordinates.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icon grid: 824 pt rounded square inside a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x161B26))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Background: deep blue-black with a faint lift at the top.
    ctx.drawLinearGradient(gradient([color(0x232A3B), color(0x0D1017)], [0, 1]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Lamp geometry.
    let base = CGPoint(x: 265, y: 805)
    let elbow = CGPoint(x: 305, y: 525)
    let neck = CGPoint(x: 480, y: 290)
    let axis = CGVector(dx: 0.34, dy: 0.94)               // shade tilts down toward the desk
    let perp = CGVector(dx: -axis.dy, dy: axis.dx)
    let narrow = point(neck, axis, 18)
    let mouth = point(narrow, axis, 185)
    let (nw, ww) = (40.0, 118.0)
    let mouthL = point(mouth, perp, ww), mouthR = point(mouth, perp, -ww)

    // Light beam: spreads from the shade mouth to the desk, hue sweeps across it,
    // alpha fades with distance.
    let reach = 470.0, spread = 0.27
    let farL = point(mouthL, CGVector(dx: axis.dx + perp.dx * spread, dy: axis.dy + perp.dy * spread), reach)
    let farR = point(mouthR, CGVector(dx: axis.dx - perp.dx * spread, dy: axis.dy - perp.dy * spread), reach)
    let beam = CGMutablePath()
    beam.addLines(between: [mouthL, farL, farR, mouthR])
    beam.closeSubpath()
    ctx.saveGState()
    ctx.addPath(beam)
    ctx.clip()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.drawLinearGradient(
        gradient([color(0xFF5FB4), color(0xFFA35C), color(0xFFF1B0), color(0x7CF5D8), color(0x6FA2FF)],
                 [0, 0.3, 0.5, 0.7, 1]),
        start: point(farL, perp, 40), end: point(farR, perp, -40), options: [])
    ctx.setBlendMode(.destinationIn)
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 1), color(0xFFFFFF, 0.7), color(0xFFFFFF, 0.3)], [0, 0.5, 1]),
                           start: mouth, end: point(mouth, axis, reach), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Desk glow where the beam lands.
    ctx.drawRadialGradient(gradient([color(0xFFC46B, 0.45), color(0xFF7AB8, 0.12), color(0xFF7AB8, 0)], [0, 0.6, 1]),
                           startCenter: CGPoint(x: 680, y: 940), startRadius: 0,
                           endCenter: CGPoint(x: 680, y: 940), endRadius: 330, options: [])

    let metal = gradient([color(0xF4F6FA), color(0xB9C1CE), color(0x8C95A5)], [0, 0.55, 1])

    // Arms.
    ctx.setLineCap(.round)
    for (a, b) in [(CGPoint(x: base.x, y: base.y - 20), elbow), (elbow, neck)] {
        ctx.saveGState()
        ctx.setLineWidth(38)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(metal, start: CGPoint(x: min(a.x, b.x) - 20, y: 0),
                               end: CGPoint(x: max(a.x, b.x) + 20, y: 0), options: [])
        ctx.restoreGState()
    }

    // Base.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: base.x - 125, y: base.y - 30, width: 250, height: 64))
    ctx.clip()
    ctx.drawLinearGradient(metal, start: CGPoint(x: 0, y: base.y - 30), end: CGPoint(x: 0, y: base.y + 34), options: [])
    ctx.restoreGState()

    // Joints.
    for (p, r) in [(elbow, 27.0), (neck, 30.0)] {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.clip()
        ctx.drawLinearGradient(metal, start: CGPoint(x: p.x - r, y: p.y - r), end: CGPoint(x: p.x + r, y: p.y + r), options: [])
        ctx.restoreGState()
    }

    // Shade.
    let shade = CGMutablePath()
    shade.addLines(between: [point(narrow, perp, nw), mouthL, mouthR, point(narrow, perp, -nw)])
    shade.closeSubpath()
    ctx.saveGState()
    ctx.addPath(shade)
    ctx.clip()
    ctx.drawLinearGradient(metal, start: point(mouth, perp, ww), end: point(mouth, perp, -ww), options: [])
    ctx.restoreGState()

    // Bulb glow at the mouth.
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 1), color(0xFFF2C4, 0.9), color(0xFFE0A0, 0)], [0, 0.35, 1]),
                           startCenter: point(mouth, axis, 6), startRadius: 0,
                           endCenter: point(mouth, axis, 6), endRadius: 150, options: [])
    // Rim highlight.
    ctx.setStrokeColor(color(0xFFFFFF, 0.9))
    ctx.setLineWidth(7)
    ctx.move(to: mouthL)
    ctx.addLine(to: mouthR)
    ctx.strokePath()

    ctx.restoreGState()

    // Hairline edge so the tile reads on light backgrounds.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

func png(_ pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
