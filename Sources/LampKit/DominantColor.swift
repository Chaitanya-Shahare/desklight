import CoreGraphics
import Foundation

public struct RGB: Equatable, Codable, Sendable {
    public var r, g, b: Int
    public init(r: Int, g: Int, b: Int) { (self.r, self.g, self.b) = (r, g, b) }
}

/// Picks an LED-friendly accent colour from an image.
///
/// Pixels are binned by hue and weighted by saturation × brightness, so a vivid sunset
/// beats a large grey sky. The winning bin's average is then pushed to full brightness
/// and higher saturation, because LEDs render muted colours as washed-out white.
public enum DominantColor {
    public static func of(_ image: CGImage, sample: Int = 64) -> RGB? {
        let w = sample, h = sample
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var fallback = (0.0, 0.0, 0.0)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            fallback.0 += r; fallback.1 += g; fallback.2 += b
            let (hue, s, v) = hsv(r, g, b)
            let wgt = s * s * v
            guard wgt > 0.02 else { continue }
            let bin = min(bins - 1, Int(hue * Double(bins)))
            weight[bin] += wgt
            sums[bin].0 += r * wgt; sums[bin].1 += g * wgt; sums[bin].2 += b * wgt
        }

        let n = Double(w * h)
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > n * 0.002 else {
            // Greyscale image: use its average, which will read as white-ish.
            return vivid(fallback.0 / n, fallback.1 / n, fallback.2 / n, boost: false)
        }
        let s = sums[best], t = weight[best]
        return vivid(s.0 / t, s.1 / t, s.2 / t, boost: true)
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    private static func vivid(_ r: Double, _ g: Double, _ b: Double, boost: Bool) -> RGB {
        var (h, s, _) = hsv(r, g, b)
        if boost { s = min(1, s * 1.4 + 0.15) }
        // HSV → RGB at full value.
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = 1 - s, q = 1 - f * s, t = 1 - (1 - f) * s
        let (rr, gg, bb): (Double, Double, Double) = [
            (1, t, p), (q, 1, p), (p, 1, t), (p, q, 1), (t, p, 1), (1, p, q),
        ][i]
        return RGB(r: Int(rr * 255), g: Int(gg * 255), b: Int(bb * 255))
    }
}
