import CoreGraphics
import Foundation

public struct RGB: Equatable, Hashable, Codable, Sendable {
    public var r, g, b: Int
    public init(r: Int, g: Int, b: Int) { (self.r, self.g, self.b) = (r, g, b) }

    public init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(r: v >> 16 & 0xFF, g: v >> 8 & 0xFF, b: v & 0xFF)
    }

    public var hex: String { String(format: "%02X%02X%02X", r, g, b) }

    public init(hue: Double, saturation s: Double, value v: Double) {
        let h = (hue - floor(hue)) * 6
        let i = Int(h) % 6, f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
        self.init(r: Int((r * 255).rounded()), g: Int((g * 255).rounded()), b: Int((b * 255).rounded()))
    }

    /// (hue, saturation, value), each 0–1.
    public var hsv: (Double, Double, Double) {
        DominantColor.hsv(Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    public func scaled(_ k: Double) -> RGB {
        let k = max(0, min(1, k))
        return RGB(r: Int(Double(r) * k), g: Int(Double(g) * k), b: Int(Double(b) * k))
    }

    public func mixed(with o: RGB, _ t: Double) -> RGB {
        func m(_ a: Int, _ b: Int) -> Int { Int((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return RGB(r: m(r, o.r), g: m(g, o.g), b: m(b, o.b))
    }

    public func distance(to o: RGB) -> Int { abs(r - o.r) + abs(g - o.g) + abs(b - o.b) }

    /// Blends through HSV along the shorter way round the hue wheel, so green → red passes
    /// through yellow/orange instead of the muddy brown a straight RGB mix gives.
    public func blended(to o: RGB, _ t: Double) -> RGB {
        let t = min(1, max(0, t))
        var (h1, s1, v1) = hsv
        var (h2, s2, v2) = o.hsv
        // Greys have no meaningful hue: borrow the other colour's.
        if s1 < 0.05 { h1 = h2 }
        if s2 < 0.05 { h2 = h1 }
        var dh = h2 - h1
        if dh > 0.5 { dh -= 1 } else if dh < -0.5 { dh += 1 }
        return RGB(hue: h1 + dh * t, saturation: s1 + (s2 - s1) * t, value: v1 + (v2 - v1) * t)
    }
}

/// Picks an LED-friendly accent colour from an image.
///
/// Pixels are binned by hue and weighted by saturation² × brightness³, so a bright
/// sunset horizon beats a large dark-blue sky. Neighbouring bins are pooled so a colour
/// straddling a bin edge isn't split. The result is pushed to full value with a mild
/// saturation boost, since LEDs render muted colours as washed-out white.
public enum DominantColor {
    public struct Analysis: Sendable {
        public var color: RGB
        /// Mean relative luminance of the image, 0–1.
        public var luminance: Double
    }

    public static func of(_ image: CGImage, sample: Int = 64) -> RGB? {
        analyze(image, sample: sample)?.color
    }

    /// - Parameter minVividShare: fraction of the frame the winning hue must cover (by weight)
    ///   before it beats the plain average. Raise it for screens, where a small icon shouldn't win.
    /// - Parameter include: if set, only pixels inside these rectangles count. Unit coordinates,
    ///   origin at the top-left (e.g. the four edge strips for screen sync's "Edges" region).
    public static func analyze(_ image: CGImage, sample: Int = 64, minVividShare: Double = 0.002,
                               include: [CGRect]? = nil) -> Analysis? {
        let w = sample, h = max(1, sample * image.height / max(1, image.width))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var avg = (0.0, 0.0, 0.0)
        var luma = 0.0
        var counted = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            if let include {
                // Bitmap rows run top to bottom, matching the top-left origin of `include`.
                let p = i / 4
                let pt = CGPoint(x: (Double(p % w) + 0.5) / Double(w), y: (Double(p / w) + 0.5) / Double(h))
                guard include.contains(where: { $0.contains(pt) }) else { continue }
            }
            counted += 1
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            avg.0 += r; avg.1 += g; avg.2 += b
            luma += 0.2126 * r + 0.7152 * g + 0.0722 * b
            let (hue, s, v) = hsv(r, g, b)
            let wgt = s * s * v * v * v
            guard wgt > 0.005 else { continue }
            let bin = min(bins - 1, Int(hue * Double(bins)))
            weight[bin] += wgt
            sums[bin].0 += r * wgt; sums[bin].1 += g * wgt; sums[bin].2 += b * wgt
        }

        guard counted > 0 else { return nil }
        let n = Double(counted)
        luma /= n
        let pooled = (0..<bins).map { i in
            weight[i] + 0.5 * (weight[(i + bins - 1) % bins] + weight[(i + 1) % bins])
        }
        guard let best = pooled.indices.max(by: { pooled[$0] < pooled[$1] }), pooled[best] > n * minVividShare else {
            // No clear hue (greyscale, documents): average colour, gently saturated.
            return Analysis(color: vivid(avg.0 / n, avg.1 / n, avg.2 / n, boost: false), luminance: luma)
        }
        var t = 0.0, c = (0.0, 0.0, 0.0)
        for i in [(best + bins - 1) % bins, best, (best + 1) % bins] {
            let k = i == best ? 1.0 : 0.5
            t += weight[i] * k
            c.0 += sums[i].0 * k; c.1 += sums[i].1 * k; c.2 += sums[i].2 * k
        }
        return Analysis(color: vivid(c.0 / t, c.1 / t, c.2 / t, boost: true), luminance: luma)
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
        let (h, s, _) = hsv(r, g, b)
        return RGB(hue: h, saturation: boost ? min(1, s * 1.2 + 0.05) : s, value: 1)
    }
}
