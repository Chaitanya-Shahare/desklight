import AppKit
import LampKit
import Observation

/// Runs the Pomodoro timer and paints its progress on the lamp.
///
/// Power use: there is no animation loop. The lamp only gets a write when the gradient
/// moves by at least one colour step, and the timer wakes every 5 s while the popup is
/// closed (1 s while it's open or in the final minute).
@MainActor
@Observable
final class PomodoroController {
    private(set) var timer: Pomodoro
    /// Current time as of the last tick. Not observed: views read the published labels
    /// below, which only change when their text does (menu bar: once a minute).
    @ObservationIgnored private var now = Date()
    private(set) var menuLabel = ""
    /// Per-second countdown and progress for the Focus panel; only refreshed while it's open.
    private(set) var remainingLabel = ""
    private(set) var progress = 0.0
    /// Set by the Focus panel so it can show a per-second countdown only while visible.
    var panelVisible = false { didSet { if panelVisible { tick() } } }
    /// The user picked a colour by hand mid-phase; leave the lamp alone until the next phase.
    private(set) var lampPausedByUser = false

    var config: PomodoroConfig {
        get { timer.config }
        set {
            timer.config = newValue
            remainingLabel = ""
            refreshLabels()
            if persists, let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "pomodoroConfig") }
            paint(force: true)
        }
    }

    var showOnLamp: Bool {
        didSet {
            UserDefaults.standard.set(showOnLamp, forKey: "pomodoroLamp")
            showOnLamp ? paint(force: true) : restoreLamp()
        }
    }

    /// A session exists from the first Start until Stop (including paused/waiting states).
    var inSession: Bool { saved != nil }

    private let lamp: LampController
    private let live: LiveSync
    private var ticker: Timer?
    private var saved: (on: Bool, look: LampAction?)?
    private var flashing = false
    private var lastPainted: RGB?
    /// The colour the timer last asked the lamp to show (self-test hook).
    var paintedColor: RGB? { lastPainted }

    /// False in the self-test so its throwaway config never overwrites the user's.
    private let persists: Bool

    init(lamp: LampController, live: LiveSync, secondsPerMinute: Double = 60, persists: Bool = true) {
        self.lamp = lamp
        self.live = live
        self.persists = persists
        let d = UserDefaults.standard
        let config = d.data(forKey: "pomodoroConfig").flatMap { try? JSONDecoder().decode(PomodoroConfig.self, from: $0) }
        var timer = Pomodoro(config: config ?? .init())
        timer.secondsPerMinute = secondsPerMinute
        self.timer = timer
        showOnLamp = d.object(forKey: "pomodoroLamp") as? Bool ?? true
        refreshLabels()
    }

    var remaining: TimeInterval { timer.remaining(at: now) }

    private func refreshLabels() {
        let s = Int(remaining.rounded(.up))
        let full = String(format: "%d:%02d", s / 60, s % 60)
        // Menu bar: minutes only, seconds in the final minute.
        let menu = remaining > 60 ? "\(Int((remaining / 60).rounded(.up)))m" : full
        if menu != menuLabel { menuLabel = menu }
        if panelVisible || remainingLabel.isEmpty {
            if full != remainingLabel { remainingLabel = full }
            progress = timer.progress(at: now)
        }
    }

    func color(at progress: Double) -> RGB { timer.color(timer.phase, progress: progress) }

    // MARK: Controls

    func toggle() { timer.isRunning ? pause() : start() }

    func start() {
        if saved == nil {
            saved = (lamp.isOn, lamp.look)
            live.stopForManualChange()
            if showOnLamp && !lamp.isOn { lamp.setPower(true) }
        }
        timer.start(at: Date())
        lastPainted = nil
        tick(glide: 0.4)
    }

    func pause() {
        timer.pause(at: Date())
        tick()
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
        remainingLabel = ""
        refreshLabels()
        restoreLamp()
        saved = nil
        lampPausedByUser = false
    }

    /// Called when the user picks a colour by hand during a session.
    func userTookOverLamp() {
        guard inSession, showOnLamp else { return }
        lampPausedByUser = true
    }

    func resumeLamp() {
        lampPausedByUser = false
        paint(force: true, glide: 0.4)
    }

    // MARK: Internals

    private func tick(glide: Double = 0) {
        now = Date()
        refreshLabels()
        if timer.isRunning && timer.remaining(at: now) <= 0 {
            finishPhase(playSound: true)
            return
        }
        paint(glide: glide)
        scheduleTick()
    }

    private func scheduleTick() {
        ticker?.invalidate()
        ticker = nil
        guard inSession else { return }
        var interval = panelVisible || remaining <= 61 ? 1.0 : 5.0
        if timer.isRunning { interval = min(interval, max(0.05, remaining)) }
        else if !panelVisible { return } // paused or waiting: nothing changes until the user acts
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func finishPhase(playSound: Bool) {
        let ended = timer.phase
        timer.advance(at: Date())
        now = Date()
        remainingLabel = ""
        refreshLabels()
        lampPausedByUser = false
        if playSound { NSSound(named: ended == .focus ? "Glass" : "Hero")?.play() }
        flash()
        scheduleTick()
    }

    private func paint(force: Bool = false, glide: Double = 0) {
        guard showOnLamp, inSession, !flashing, !lampPausedByUser else { return }
        let c = color(at: timer.progress(at: now))
        guard force || c != lastPainted else { return }
        lastPainted = c
        lamp.stream(c, tau: glide)
    }

    /// Three quick white pulses mark the end of a phase, then the next phase's colour.
    private func flash() {
        guard showOnLamp, inSession else { return }
        flashing = true
        Task { @MainActor in
            for _ in 0..<3 {
                lamp.stream(RGB(r: 255, g: 255, b: 255), tau: 0)
                try? await Task.sleep(for: .milliseconds(250))
                lamp.stream(color(at: 0), tau: 0)
                try? await Task.sleep(for: .milliseconds(300))
            }
            flashing = false
            paint(force: true, glide: 0.4)
        }
    }

    private func restoreLamp() {
        guard let saved else { return }
        var actions: [LampAction] = saved.look.map { [$0] } ?? []
        actions.append(saved.on ? .on : .off)
        lamp.perform(actions)
    }
}
