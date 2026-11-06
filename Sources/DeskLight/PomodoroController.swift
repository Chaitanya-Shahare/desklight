import AppKit
import LampKit
import Observation

/// Runs the Pomodoro timer and paints its progress on the lamp.
@MainActor
@Observable
final class PomodoroController {
    private(set) var timer: Pomodoro
    /// Updated every second while a session exists; drives the menu bar countdown.
    private(set) var now = Date()

    var config: PomodoroConfig {
        get { timer.config }
        set {
            timer.config = newValue
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "pomodoroConfig") }
            paint()
        }
    }

    var showOnLamp: Bool {
        didSet {
            UserDefaults.standard.set(showOnLamp, forKey: "pomodoroLamp")
            showOnLamp ? paint() : restoreLamp()
        }
    }

    /// A session exists from the first Start until Stop (including paused/waiting states).
    var inSession: Bool { saved != nil }

    private let lamp: LampController
    private let live: LiveSync
    private var ticker: Timer?
    private var saved: (on: Bool, look: LampAction?)?
    private var flashing = false

    init(lamp: LampController, live: LiveSync) {
        self.lamp = lamp
        self.live = live
        let d = UserDefaults.standard
        let config = d.data(forKey: "pomodoroConfig").flatMap { try? JSONDecoder().decode(PomodoroConfig.self, from: $0) }
        timer = Pomodoro(config: config ?? .init())
        showOnLamp = d.object(forKey: "pomodoroLamp") as? Bool ?? true
    }

    var remainingLabel: String {
        let s = Int(timer.remaining(at: now).rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var progress: Double { timer.progress(at: now) }

    func color(at progress: Double) -> RGB { Pomodoro.color(timer.phase, progress: progress) }

    // MARK: Controls

    func toggle() { timer.isRunning ? pause() : start() }

    func start() {
        if saved == nil {
            saved = (lamp.isOn, lamp.look)
            live.stopForManualChange()
            if showOnLamp && !lamp.isOn { lamp.setPower(true) }
        }
        timer.start(at: Date())
        startTicking()
        paint(tau: 0.4)
    }

    func pause() {
        timer.pause(at: Date())
        now = Date()
    }

    func skip() {
        guard inSession else { return }
        finishPhase(playSound: false)
    }

    func stop() {
        timer.reset()
        ticker?.invalidate()
        ticker = nil
        now = Date()
        restoreLamp()
        saved = nil
    }

    // MARK: Internals

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        if timer.isRunning && timer.remaining(at: now) <= 0 {
            finishPhase(playSound: true)
        } else {
            paint()
        }
    }

    private func finishPhase(playSound: Bool) {
        let ended = timer.phase
        timer.advance(at: Date())
        now = Date()
        if playSound { NSSound(named: ended == .focus ? "Glass" : "Hero")?.play() }
        flash()
    }

    /// Lamp shows the phase colour for the current progress. A long glide makes the
    /// once-a-second updates read as one continuous shift.
    private func paint(tau: Double = 1.2) {
        guard showOnLamp, inSession, !flashing else { return }
        lamp.stream(color(at: progress), tau: tau)
    }

    /// Three quick white pulses mark the end of a phase, then the next phase's colour.
    private func flash() {
        guard showOnLamp, inSession else { return }
        flashing = true
        Task { @MainActor in
            for _ in 0..<3 {
                lamp.stream(RGB(r: 255, g: 255, b: 255), tau: 0.03)
                try? await Task.sleep(for: .milliseconds(250))
                lamp.stream(color(at: 0), tau: 0.03)
                try? await Task.sleep(for: .milliseconds(300))
            }
            flashing = false
            paint(tau: 0.4)
        }
    }

    private func restoreLamp() {
        guard let saved else { return }
        var actions: [LampAction] = saved.look.map { [$0] } ?? []
        actions.append(saved.on ? .on : .off)
        lamp.perform(actions)
    }
}
