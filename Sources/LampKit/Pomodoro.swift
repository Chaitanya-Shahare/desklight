import Foundation

public struct PomodoroConfig: Codable, Equatable, Sendable {
    public var focusMinutes = 25
    public var shortBreakMinutes = 5
    public var longBreakMinutes = 15
    public var longBreakEvery = 4
    public var autoStartBreaks = true
    public var autoStartFocus = false
    public init() {}
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

    public init(config: PomodoroConfig = .init()) { self.config = config }

    public var isRunning: Bool { endsAt != nil }
    public var isPaused: Bool { pausedRemaining != nil }

    public func duration(of p: PomodoroPhase) -> TimeInterval {
        switch p {
        case .focus: Double(config.focusMinutes) * 60
        case .shortBreak: Double(config.shortBreakMinutes) * 60
        case .longBreak: Double(config.longBreakMinutes) * 60
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
        self = Pomodoro(config: config)
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

    /// Lamp colour for a phase at a given progress.
    /// Focus runs green → yellow → orange → red as time runs out; breaks are calm, dimmer blues.
    public static func color(_ phase: PomodoroPhase, progress p: Double) -> RGB {
        let p = min(1, max(0, p))
        switch phase {
        case .focus: return RGB(hue: (1.0 / 3) * (1 - p), saturation: 1, value: 1)
        case .shortBreak: return RGB(hue: 0.55 - 0.1 * p, saturation: 0.75, value: 0.55)
        case .longBreak: return RGB(hue: 0.75 - 0.15 * p, saturation: 0.7, value: 0.55)
        }
    }
}
