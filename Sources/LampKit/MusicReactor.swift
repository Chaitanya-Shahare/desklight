import Foundation

/// Turns audio loudness into lamp colours: brightness follows the bass, and each
/// detected beat steps the hue. Feed it one audio buffer at a time.
public struct MusicReactor: Sendable {
    /// Multiplies input energy; 1 is tuned for typical system playback volume.
    public var sensitivity: Double = 1
    public private(set) var hue: Double
    public private(set) var level: Double = 0
    private var average: Double = 0
    private var sinceBeat: Double = 1

    public init(hue: Double = 0) { self.hue = hue }

    /// - Parameters:
    ///   - bass: RMS of the low-passed (~150 Hz) signal, 0–1.
    ///   - rms: RMS of the full signal, 0–1.
    ///   - dt: seconds of audio this buffer covered.
    /// - Returns: colour to show, and whether this buffer was a beat.
    public mutating func update(bass: Double, rms: Double, dt: Double) -> (color: RGB, beat: Bool) {
        let energy = min(1.5, (bass * 0.7 + rms * 0.3) * sensitivity * 6)
        // Running average over ~1 s decides what counts as a beat for this song.
        let k = min(1, dt / 1.0)
        average += (energy - average) * k
        sinceBeat += dt

        let beat = energy > average * 1.45 && energy > 0.08 && sinceBeat > 0.18
        if beat {
            sinceBeat = 0
            hue = (hue + 0.09 + Double.random(in: 0...0.06)).truncatingRemainder(dividingBy: 1)
            level = 1
        } else {
            // Fall off quickly after a hit, but never below the current loudness.
            level = max(min(1, energy), level - dt * 2.2)
        }
        hue = (hue + dt * 0.015).truncatingRemainder(dividingBy: 1)
        let shown = rms < 0.002 ? 0.04 : max(0.08, level)
        return (RGB(hue: hue, saturation: 1, value: shown), beat)
    }
}
