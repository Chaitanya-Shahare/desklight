import AppKit
import Darwin
import LampKit

/// `DeskLight --selftest`: headless end-to-end check against the real lamp and audio stack.
/// No windows open. Prints PASS/FAIL lines and exits non-zero on failure.
/// The user's colour, Pomodoro config and live mode are restored afterwards.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("DeskLight self-test \(Date())")
        let defaults = UserDefaults.standard
        let savedLiveMode = defaults.string(forKey: "liveMode")
        defaults.set("Off", forKey: "liveMode")

        let lamp = LampController()
        let wallpaper = WallpaperSync(lamp: lamp)
        let live = LiveSync(lamp: lamp, wallpaper: wallpaper)
        let userLook = lamp.look

        // 1. Bluetooth
        wait(45) { lamp.isConnected }
        let online = lamp.isConnected
        if online {
            check("lamp connects", true, lamp.status.label)
            lamp.setPower(true)
            lamp.setBrightness(100)
            wait(1) { false }
        } else {
            print("SKIP  lamp not advertising (off, out of range, or held by the phone app) — checking app output instead")
        }

        // 2. Pomodoro with custom colours, 1 "minute" = 4 s
        var config = PomodoroConfig()
        (config.focusMinutes, config.shortBreakMinutes, config.longBreakMinutes, config.longBreakEvery) = (1, 1, 1, 2)
        config.autoStartBreaks = true
        config.autoStartFocus = true
        config.focusStart = RGB(r: 0, g: 0, b: 255)
        config.focusEnd = RGB(r: 255, g: 0, b: 255)
        config.shortBreakStart = RGB(r: 255, g: 160, b: 0)
        config.shortBreakEnd = RGB(r: 255, g: 220, b: 0)
        let pomodoro = PomodoroController(lamp: lamp, live: live, secondsPerMinute: 4, persists: false)
        pomodoro.config = config
        pomodoro.panelVisible = true // 1 s ticks
        pomodoro.start()
        // Online: what reached the lamp. Offline: what the timer asked for.
        func shown() -> RGB? { online ? lamp.shownColor : pomodoro.paintedColor }
        wait(1.5) { false }
        let early = shown()
        check("focus starts at custom start color (blue)", early.map { $0.b > 200 && $0.g < 40 } ?? false, "\(String(describing: early))")
        wait(2) { false }
        let late = shown()
        check("focus moves toward custom end color (magenta)", late.map { $0.r > 80 && $0.b > 200 } ?? false, "\(String(describing: late))")
        wait(4) { pomodoro.timer.phase == .shortBreak }
        check("focus ends and break starts automatically", pomodoro.timer.phase == .shortBreak, pomodoro.timer.phase.title)
        wait(2.5) { false } // white flashes finish
        let breakColor = shown()
        check("break uses custom break color (orange)", breakColor.map { $0.r > 200 && $0.b < 60 } ?? false, "\(String(describing: breakColor))")
        pomodoro.stop()
        wait(1) { false }
        if online {
            check("stop restores previous color", lamp.look == userLook || userLook == nil, "\(String(describing: lamp.look))")
        }

        // 3. Idle cost while a real-speed Pomodoro runs with the popup closed
        let slow = PomodoroController(lamp: lamp, live: live, persists: false)
        slow.start()
        wait(1) { false }
        let before = Usage.now()
        idle(20)
        let after = Usage.now()
        slow.stop()
        let cpu = (after.cpu - before.cpu) / 20 * 100
        print(String(format: "  pomodoro running: CPU %.2f%%  wakeups %.1f/s  memory %.0f MB",
                     cpu, Double(after.wakeups - before.wakeups) / 20, after.footprintMB))
        check("pomodoro costs < 0.2% CPU", cpu < 0.2, String(format: "%.2f%%", cpu))

        // 4. Music via Core Audio tap while macOS plays sounds
        let frames0 = lamp.framesSent
        let tapStart = Usage.now()
        do {
            try live.tap.start()
            check("system audio tap starts", true, "")
        } catch {
            check("system audio tap starts", false, error.localizedDescription)
        }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/bin/sh")
        player.arguments = ["-c", "for s in Funk Submarine Hero Funk Submarine Hero; do afplay /System/Library/Sounds/$s.aiff; done"]
        try? player.run()
        var colorsOut = 0
        live.tap.onColor = { color, beat in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    colorsOut += 1
                    lamp.stream(color, tau: beat ? 0.04 : 0.12)
                }
            }
        }
        idle(8)
        player.terminate()
        let tapEnd = Usage.now()
        live.tap.stop()
        let musicCPU = (tapEnd.cpu - tapStart.cpu) / 8 * 100
        check("audio buffers arrive", live.tap.buffersSeen > 50, "\(live.tap.buffersSeen) buffers")
        let driven = online ? lamp.framesSent - frames0 : colorsOut
        check("music produces lamp colors", driven > 10,
              "\(driven) \(online ? "frames sent" : "colors produced"), \(live.tap.beatsSeen) beats")
        print(String(format: "  music mode: CPU %.2f%%  memory %.0f MB", musicCPU, tapEnd.footprintMB))

        finish(lamp, userLook, savedLiveMode)
    }

    private static func finish(_ lamp: LampController, _ look: LampAction?, _ liveMode: String?) -> Never {
        if let look { lamp.perform([look]) }
        wait(1) { false }
        UserDefaults.standard.set(liveMode, forKey: "liveMode")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }

    /// Spins the main run loop (Bluetooth callbacks, timers, MainActor tasks) until done or timeout.
    private static func wait(_ seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// Lets the app run untouched (no polling of our own) so measurements reflect only the app.
    private static func idle(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

private struct Usage {
    var cpu: Double
    var wakeups: UInt64
    var footprintMB: Double

    static func now() -> Usage {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        } == 0
        return Usage(cpu: cpu,
                     wakeups: ok ? info.ri_interrupt_wkups + info.ri_pkg_idle_wkups : 0,
                     footprintMB: ok ? Double(info.ri_phys_footprint) / 1_048_576 : 0)
    }
}
