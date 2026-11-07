import Foundation

public struct PomodoroConfig: Codable, Equatable, Sendable {
    public var focusMinutes = 25
    public var shortBreakMinutes = 5
    public var longBreakMinutes = 15
    public var longBreakEvery = 4
    public var autoStartBreaks = true
    public var autoStartFocus = false
    /// Each phase glides from its start colour to its end colour as time passes.
    public var focusStart = RGB(r: 0, g: 255, b: 0)
    public var focusEnd = RGB(r: 255, g: 0, b: 0)
    public var shortBreakStart = RGB(r: 35, g: 112, b: 140)
    public var shortBreakEnd = RGB(r: 35, g: 140, b: 105)
    public var longBreakStart = RGB(r: 98, g: 42, b: 140)
    public var longBreakEnd = RGB(r: 42, g: 70, b: 140)

    public init() {}

    public func colors(for phase: PomodoroPhase) -> (start: RGB, end: RGB) {
        switch phase {
        case .focus: (focusStart, focusEnd)
        case .shortBreak: (shortBreakStart, shortBreakEnd)
        case .longBreak: (longBreakStart, longBreakEnd)
        }
    }

    public mutating func resetColors() {
        let d = PomodoroConfig()
        (focusStart, focusEnd) = (d.focusStart, d.focusEnd)
        (shortBreakStart, shortBreakEnd) = (d.shortBreakStart, d.shortBreakEnd)
        (longBreakStart, longBreakEnd) = (d.longBreakStart, d.longBreakEnd)
    }

    // Older saved configs lack some keys; fall back to defaults field by field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PomodoroConfig()
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? d.focusMinutes
        shortBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .shortBreakMinutes) ?? d.shortBreakMinutes
        longBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .longBreakMinutes) ?? d.longBreakMinutes
        longBreakEvery = try c.decodeIfPresent(Int.self, forKey: .longBreakEvery) ?? d.longBreakEvery
        autoStartBreaks = try c.decodeIfPresent(Bool.self, forKey: .autoStartBreaks) ?? d.autoStartBreaks
        autoStartFocus = try c.decodeIfPresent(Bool.self, forKey: .autoStartFocus) ?? d.autoStartFocus
        focusStart = try c.decodeIfPresent(RGB.self, forKey: .focusStart) ?? d.focusStart
        focusEnd = try c.decodeIfPresent(RGB.self, forKey: .focusEnd) ?? d.focusEnd
        shortBreakStart = try c.decodeIfPresent(RGB.self, forKey: .shortBreakStart) ?? d.shortBreakStart
        shortBreakEnd = try c.decodeIfPresent(RGB.self, forKey: .shortBreakEnd) ?? d.shortBreakEnd
        longBreakStart = try c.decodeIfPresent(RGB.self, forKey: .longBreakStart) ?? d.longBreakStart
        longBreakEnd = try c.decodeIfPresent(RGB.self, forKey: .longBreakEnd) ?? d.longBreakEnd
    }
}

public enum PomodoroPhase: String, Codable, Sendable {
    case focus, shortBreak, longBreak

    public var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }
}

/// Wall-clock Pomodoro state. Uses an end date rather than counting ticks,
/// so sleep or a stalled timer never makes it drift.
public struct Pomodoro: Sendable {
    public var config: PomodoroConfig
    public private(set) var phase: PomodoroPhase = .focus
    public private(set) var completedFocus = 0
    public private(set) var endsAt: Date?
    public private(set) var pausedRemaining: TimeInterval?

    /// Real seconds per configured minute. Tests and the headless self-test shrink this.
    public var secondsPerMinute: Double = 60

    public init(config: PomodoroConfig = .init()) { self.config = config }

    public var isRunning: Bool { endsAt != nil }
    public var isPaused: Bool { pausedRemaining != nil }

    public func duration(of p: PomodoroPhase) -> TimeInterval {
        switch p {
        case .focus: Double(config.focusMinutes) * secondsPerMinute
        case .shortBreak: Double(config.shortBreakMinutes) * secondsPerMinute
        case .longBreak: Double(config.longBreakMinutes) * secondsPerMinute
        }
    }

    public func remaining(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return pausedRemaining ?? duration(of: phase)
    }

    /// 0 at the start of the phase, 1 when it ends.
    public func progress(at now: Date) -> Double {
        let d = duration(of: phase)
        return d > 0 ? min(1, max(0, 1 - remaining(at: now) / d)) : 1
    }

    /// Position within the current set, e.g. 2 of 4.
    public var focusInSet: Int { completedFocus % max(1, config.longBreakEvery) + (phase == .focus ? 1 : 0) }

    public mutating func start(at now: Date) {
        guard endsAt == nil else { return }
        endsAt = now.addingTimeInterval(pausedRemaining ?? duration(of: phase))
        pausedRemaining = nil
    }

    public mutating func pause(at now: Date) {
        guard let endsAt else { return }
        pausedRemaining = max(0, endsAt.timeIntervalSince(now))
        self.endsAt = nil
    }

    public mutating func reset() {
        let scale = secondsPerMinute
        self = Pomodoro(config: config)
        secondsPerMinute = scale
    }

    /// Ends the current phase (time up or skipped) and moves to the next one.
    @discardableResult
    public mutating func advance(at now: Date) -> PomodoroPhase {
        if phase == .focus {
            completedFocus += 1
            phase = completedFocus % max(1, config.longBreakEvery) == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        pausedRemaining = nil
        let auto = phase == .focus ? config.autoStartFocus : config.autoStartBreaks
        endsAt = auto ? now.addingTimeInterval(duration(of: phase)) : nil
        return phase
    }

    /// Lamp colour for a phase at a given progress (0–1), from the configured gradient.
    public func color(_ phase: PomodoroPhase, progress p: Double) -> RGB {
        let (start, end) = config.colors(for: phase)
        return start.blended(to: end, p)
    }
}
