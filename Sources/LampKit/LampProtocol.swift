import Foundation

/// Command frames for lamps controlled by the "LED LAMP" app (com.ledlamp).
///
/// Recovered from the Android APK (`com.home.net.NetConnectBle`). Every command is a
/// 9-byte write to characteristic FFE1 in service FFE0. See docs/PROTOCOL.md.
public enum LampProtocol {
    public static let serviceUUID = "FFE0"
    public static let characteristicUUID = "FFE1"

    /// Advertised-name families. The app picks command layouts from the name prefix.
    public enum Variant: String, Codable, Sendable {
        /// `LEDBLE-00/01/02-…`, `LED-…`, `LED_…`: frames start `7E FF <cmd>`.
        case classic
        /// `LEDBLE-03/04/05-…`: frames start `7E <cmd>` (one byte shorter header).
        case compact
        /// `LEDDMX-03-…` RGB controllers: frames are `7B … BF`. No white channel.
        case dmx

        public init(deviceName name: String) {
            let upper = name.uppercased()
            if upper.hasPrefix("LEDDMX") {
                self = .dmx
            } else if ["LEDBLE-03", "LEDBLE-04", "LEDBLE-05"].contains(where: upper.hasPrefix) {
                self = .compact
            } else {
                self = .classic
            }
        }
    }

    /// Which UI panel a brightness change belongs to. Only `.compact` lamps encode it.
    public enum Channel: UInt8, Sendable {
        case rgb = 0, dim = 1, colorTemperature = 2
    }

    public static func isSupported(name: String) -> Bool {
        name.uppercased().hasPrefix("LED")
    }

    private static func clamp(_ v: Int, _ lo: Int = 0, _ hi: Int = 255) -> UInt8 {
        UInt8(max(lo, min(hi, v)))
    }

    // MARK: Commands

    public static func power(_ on: Bool, variant: Variant) -> [UInt8] {
        switch variant {
        case .classic, .compact: return [0x7E, 0xFF, 0x04, on ? 0x01 : 0x00, 0x00, 0xFF, 0xFF, 0x00, 0xEF]
        case .dmx: return [0x7B, 0x04, 0x04, on ? 0x01 : 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF]
        }
    }

    /// Brightness 0–100.
    public static func brightness(_ percent: Int, variant: Variant, channel: Channel = .rgb) -> [UInt8] {
        let b = clamp(percent, 0, 100)
        switch variant {
        case .classic: return [0x7E, 0xFF, 0x01, b, 0x00, 0xFF, 0xFF, 0xFF, 0xEF]
        case .compact: return [0x7E, 0x01, b, channel.rawValue, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF]
        case .dmx: return [0x7B, 0xFF, 0x01, UInt8(Int(b) * 32 / 100), b, 0x00, 0xFF, 0xFF, 0xBF]
        }
    }

    public static func color(r: Int, g: Int, b: Int, variant: Variant) -> [UInt8] {
        switch variant {
        case .classic, .compact: return [0x7E, 0xFF, 0x05, 0x03, clamp(r), clamp(g), clamp(b), 0xFF, 0xEF]
        // RgbFragment → setDmxRgb for LEDDMX-03: byte 6 is 0x00, not 0xFF.
        case .dmx: return [0x7B, 0xFF, 0x07, clamp(r), clamp(g), clamp(b), 0x00, 0xFF, 0xBF]
        }
    }

    /// Approximate white for RGB-only lamps: blend cool (255,255,255) toward warm (255,147,41).
    static func rgbWhite(warm: Int) -> (Int, Int, Int) {
        let t = Double(max(0, min(100, warm))) / 100
        return (255, Int(255 - t * 108), Int(255 - t * 214))
    }

    /// White colour temperature. `warm` is 0–100; cool is `100 - warm`.
    public static func colorTemperature(warm: Int, variant: Variant) -> [UInt8] {
        let w = clamp(warm, 0, 100)
        let c = 100 - w
        switch variant {
        case .classic: return [0x7E, 0xFF, 0x05, 0x02, w, c, 0xFF, 0xFF, 0xEF]
        case .compact: return [0x7E, 0x06, c, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF]
        case .dmx:
            let (r, g, b) = rgbWhite(warm: warm)
            return color(r: r, g: g, b: b, variant: .dmx)
        }
    }

    /// Single-channel dimmer (the app's "DIM" tab), 0–100.
    public static func dim(_ percent: Int, variant: Variant) -> [UInt8] {
        let v = clamp(percent, 0, 100)
        switch variant {
        case .classic: return [0x7E, 0xFF, 0x05, 0x01, v, 0xFF, 0xFF, 0xFF, 0xEF]
        case .compact: return [0x7E, 0x07, v, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF]
        case .dmx: return [0x7B, 0xFF, 0x09, UInt8(Int(v) * 32 / 100), v, 0xFF, 0xFF, 0xFF, 0xBF]
        }
    }

    /// Built-in effect number (the app's "MODE" list).
    public static func effect(_ mode: Int, variant: Variant) -> [UInt8] {
        let m = clamp(mode)
        switch variant {
        case .classic: return [0x7E, 0xFF, 0x03, m, 0x03, 0xFF, 0xFF, 0xFF, 0xEF]
        case .compact: return [0x7E, 0x03, m, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF]
        case .dmx: return [0x7B, 0xFF, 0x03, m, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF]
        }
    }

    /// Effect speed 0–100.
    public static func speed(_ percent: Int, variant: Variant) -> [UInt8] {
        let s = clamp(percent, 0, 100)
        switch variant {
        case .classic: return [0x7E, 0xFF, 0x02, s, 0x00, 0xFF, 0xFF, 0xFF, 0xEF]
        case .compact: return [0x7E, 0x02, s, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF]
        case .dmx: return [0x7B, 0xFF, 0x02, s, 0xFF, 0x00, 0xFF, 0xFF, 0xBF]
        }
    }

    /// Sent by the app ~300 ms after connecting. Carries the (default) 4-byte password
    /// `A1 23 45 67` and the current weekday/hour/minute, which also syncs the lamp clock.
    /// The lamp answers with a `2A 05 <status>` notification.
    public static func handshake(date: Date = Date(), calendar: Calendar = .current,
                                 password: [UInt8] = [0xA1, 0x23, 0x45, 0x67]) -> [UInt8] {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        // Calendar weekday: 1 = Sunday. Lamp: Monday = 1 … Sunday = 7.
        let lampDay = [7, 1, 2, 3, 4, 5, 6][(c.weekday ?? 1) - 1]
        let dayHour = UInt8((lampDay << 5) | (c.hour ?? 0))
        return [0x2A, 0x02] + password.prefix(4) + [dayHour, UInt8(c.minute ?? 0), 0xAF]
    }
}
