import CoreGraphics
import Foundation
import LampKit
import Testing

// Expected bytes are the literal int arrays from com.home.net.NetConnectBle in the APK.
struct LampProtocolTests {
    @Test func power() {
        #expect(LampProtocol.power(true, variant: .classic) == [126, 255, 4, 1, 0, 255, 255, 0, 239])
        #expect(LampProtocol.power(false, variant: .classic) == [126, 255, 4, 0, 0, 255, 255, 0, 239])
    }

    @Test func classicFrames() {
        #expect(LampProtocol.color(r: 10, g: 20, b: 30, variant: .classic) == [126, 255, 5, 3, 10, 20, 30, 255, 239])
        #expect(LampProtocol.brightness(150, variant: .classic) == [126, 255, 1, 100, 0, 255, 255, 255, 239])
        #expect(LampProtocol.colorTemperature(warm: 70, variant: .classic) == [126, 255, 5, 2, 70, 30, 255, 255, 239])
        #expect(LampProtocol.effect(5, variant: .classic) == [126, 255, 3, 5, 3, 255, 255, 255, 239])
    }

    @Test func compactFrames() {
        #expect(LampProtocol.brightness(40, variant: .compact, channel: .colorTemperature) == [126, 1, 40, 2, 255, 255, 255, 255, 239])
        #expect(LampProtocol.colorTemperature(warm: 70, variant: .compact) == [126, 6, 30, 255, 255, 255, 255, 255, 239])
    }

    @Test func dmxFrames() {
        #expect(LampProtocol.power(true, variant: .dmx) == [123, 4, 4, 1, 255, 255, 255, 255, 191])
        #expect(LampProtocol.power(false, variant: .dmx) == [123, 4, 4, 0, 255, 255, 255, 255, 191])
        #expect(LampProtocol.color(r: 1, g: 2, b: 3, variant: .dmx) == [123, 255, 7, 1, 2, 3, 0, 255, 191])
        #expect(LampProtocol.brightness(50, variant: .dmx) == [123, 255, 1, 16, 50, 0, 255, 255, 191])
        #expect(LampProtocol.Variant(deviceName: "LEDDMX-03-0F2B") == .dmx)
    }

    @Test func variantFromName() {
        #expect(LampProtocol.Variant(deviceName: "LEDBLE-04-ABCD") == .compact)
        #expect(LampProtocol.Variant(deviceName: "LEDBLE-01-ABCD") == .classic)
        #expect(LampProtocol.Variant(deviceName: "LED-1234") == .classic)
    }

    @Test func handshake() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 2026-11-03 is a Tuesday → lamp day 2.
        let date = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 21, minute: 15)))
        #expect(LampProtocol.handshake(date: date, calendar: cal) == [0x2A, 0x02, 0xA1, 0x23, 0x45, 0x67, (2 << 5) | 21, 15, 0xAF])
    }

    @Test func scheduleFiresOncePerMinute() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let entry = ScheduleEntry(hour: 9, minute: 0, weekdays: [3], actions: [.on]) // Tuesday
        let t = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 0, second: 5)))
        var clock = ScheduleClock()
        #expect(clock.due([entry], at: t, calendar: cal).count == 1)
        #expect(clock.due([entry], at: t.addingTimeInterval(20), calendar: cal).isEmpty)
        #expect(clock.due([entry], at: t.addingTimeInterval(86_400 * 7), calendar: cal).count == 1)
        #expect(clock.due([entry], at: t.addingTimeInterval(86_400), calendar: cal).isEmpty) // Wednesday
    }
}

struct DominantColorTests {
    /// 70% grey + 30% saturated blue → blue wins despite covering less area.
    @Test func vividBeatsLargeGrey() throws {
        let w = 40, h = 40
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let blue = x >= 28
                px[i] = blue ? 20 : 128; px[i + 1] = blue ? 60 : 128; px[i + 2] = blue ? 220 : 128; px[i + 3] = 255
            }
        }
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        let c = try #require(DominantColor.of(image))
        #expect(c.b == 255 && c.r < 60 && c.g < 120)
    }
}
