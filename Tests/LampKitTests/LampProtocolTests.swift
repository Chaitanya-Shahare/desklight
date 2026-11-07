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

struct NewFeatureTests {
    private func image(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                (px[i], px[i + 1], px[i + 2]) = pixel(x, y)
            }
        }
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(ctx.makeImage())
    }

    /// Dusk wallpaper shape: 80% dark navy sky, 20% bright coral horizon → coral wins.
    @Test func brightHorizonBeatsDarkSky() throws {
        let img = try image(50, 50) { _, y in y < 40 ? (15, 40, 90) : (240, 110, 90) }
        let c = try #require(DominantColor.of(img))
        #expect(c.r == 255 && c.b < 120)
    }

    @Test func hexRoundTrip() {
        #expect(RGB(hex: "#FF653E") == RGB(r: 255, g: 101, b: 62))
        #expect(RGB(r: 1, g: 2, b: 255).hex == "0102FF")
        #expect(RGB(hex: "nope") == nil)
    }

    @Test func musicBeatJumpsHueAndBrightens() {
        var m = MusicReactor(hue: 0)
        for _ in 0..<100 { _ = m.update(bass: 0.02, rms: 0.03, dt: 0.02) }   // quiet bed
        let quiet = m.level
        let (_, beat) = m.update(bass: 0.3, rms: 0.3, dt: 0.02)              // kick
        #expect(beat)
        #expect(m.level == 1 && quiet < 0.5)
        #expect(m.hue > 0.08)
    }

    @Test func oldSchedulesWithEffectsStillLoad() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","enabled":true,"hour":7,"minute":30,"weekdays":[],
          "actions":[{"on":{}},{"effect":{"_0":3}},{"brightness":{"_0":50}}]}]
        """
        let entries = try JSONDecoder().decode([ScheduleEntry].self, from: Data(json.utf8))
        #expect(entries.first?.actions == [.on, .brightness(50)])
        #expect(entries.first?.fadeMinutes == 0)
    }
}

struct PomodoroTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func countsDownAndPauses() {
        var p = Pomodoro()
        p.start(at: t0)
        #expect(p.remaining(at: t0.addingTimeInterval(60)) == 24 * 60)
        #expect(abs(p.progress(at: t0.addingTimeInterval(750)) - 0.5) < 0.001)
        p.pause(at: t0.addingTimeInterval(600))
        // Paused time doesn't count.
        #expect(p.remaining(at: t0.addingTimeInterval(5000)) == 15 * 60)
        p.start(at: t0.addingTimeInterval(5000))
        #expect(p.remaining(at: t0.addingTimeInterval(5060)) == 14 * 60)
    }

    @Test func cyclesToLongBreak() {
        var p = Pomodoro()
        var phases: [PomodoroPhase] = []
        for _ in 0..<8 { phases.append(p.advance(at: t0)) }
        #expect(phases == [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus])
        // Breaks auto-start, focus waits for the user by default.
        #expect(!p.isRunning)
    }

    @Test func focusColorRunsGreenThroughYellowToRed() {
        let p = Pomodoro()
        #expect(p.color(.focus, progress: 0) == RGB(r: 0, g: 255, b: 0))
        #expect(p.color(.focus, progress: 1) == RGB(r: 255, g: 0, b: 0))
        #expect(p.color(.focus, progress: 0.5) == RGB(r: 255, g: 255, b: 0)) // yellow, not brown
    }

    @Test func customColorsAndOldConfigs() throws {
        var c = PomodoroConfig()
        c.focusStart = RGB(r: 0, g: 0, b: 255)
        c.focusEnd = RGB(r: 255, g: 0, b: 255)
        #expect(Pomodoro(config: c).color(.focus, progress: 1) == RGB(r: 255, g: 0, b: 255))
        // Configs saved before colours existed still decode, with default colours.
        let old = try JSONDecoder().decode(PomodoroConfig.self, from: Data(#"{"focusMinutes":50}"#.utf8))
        #expect(old.focusMinutes == 50 && old.focusStart == PomodoroConfig().focusStart)
    }

    @Test func timeScaleForSelfTest() {
        var p = Pomodoro()
        p.secondsPerMinute = 1
        p.start(at: t0)
        #expect(p.remaining(at: t0) == 25)
    }
}

struct ScreenSyncTests {
    private func image(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                (px[i], px[i + 1], px[i + 2]) = pixel(x, y)
            }
        }
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(ctx.makeImage())
    }

    /// Thin red border around a big blue picture: the whole frame reads blue, the edges read red.
    @Test func edgesRegionIgnoresTheMiddle() throws {
        let img = try image(64, 64) { x, y in
            min(x, y, 63 - x, 63 - y) < 5 ? (230, 20, 20) : (20, 40, 230)
        }
        let full = try #require(DominantColor.analyze(img, sample: 64))
        #expect(full.color.b == 255 && full.color.r < 80)
        let edges = try #require(DominantColor.analyze(img, sample: 64, include: ScreenRegion.edges.sampleRects))
        #expect(edges.color.r == 255 && edges.color.b < 80)
    }

    /// `include` uses a top-left origin: top half green, bottom half red.
    @Test func includeUsesTopLeftOrigin() throws {
        let img = try image(40, 40) { _, y in y < 20 ? (20, 220, 20) : (220, 20, 20) }
        let top = try #require(DominantColor.analyze(img, include: [CGRect(x: 0, y: 0, width: 1, height: 0.5)]))
        #expect(top.color.g == 255 && top.color.r < 80)
        let bottom = try #require(DominantColor.analyze(img, include: [CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]))
        #expect(bottom.color.r == 255 && bottom.color.g < 80)
    }

    /// Dark-mode UI: mostly dark grey with a small blue accent. Screen sync should show the
    /// accent as a saturated blue, not a washed-out grey.
    @Test func ambientIgnoresGreyUI() throws {
        let img = try image(60, 60) { x, y in x < 12 && y < 12 ? (20, 90, 240) : (40, 40, 44) }
        let p = ScreenProfile.movie
        let c = try #require(DominantColor.ambient(img, satWeight: p.satWeight, saturation: p.saturation, gain: p.gain))
        let (h, s, _) = c.hsv
        #expect(s > 0.8 && abs(h - 0.6) < 0.05)
    }

    @Test func regionsStayOnScreen() {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for r in ScreenRegion.allCases {
            #expect(unit.contains(r.captureRect))
            for s in r.sampleRects ?? [] { #expect(unit.contains(s)) }
        }
        // Each style uses the area it was tuned with.
        #expect(ScreenProfile.solid.region == .bottomCenter)
        #expect(ScreenProfile.movie.region == .bottomCenter)
        #expect(ScreenProfile.game.region == .edges)
    }

    @Test func fasterProfilesReactFaster() {
        let (solid, movie, game) = (ScreenProfile.solid, ScreenProfile.movie, ScreenProfile.game)
        #expect(solid.framesPerSecond < movie.framesPerSecond && movie.framesPerSecond < game.framesPerSecond)
        #expect(solid.smoothing < movie.smoothing && movie.smoothing < game.smoothing)
        #expect(solid.glide > movie.glide && movie.glide > game.glide)
    }
}
