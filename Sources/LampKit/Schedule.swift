import Foundation

public enum LampAction: Codable, Hashable, Sendable {
    case on
    case off
    case brightness(Int)
    /// Warm white percentage (0 = coolest, 100 = warmest).
    case colorTemperature(warm: Int)
    case color(r: Int, g: Int, b: Int)

    public var label: String {
        switch self {
        case .on: "Turn on"
        case .off: "Turn off"
        case .brightness(let b): "Brightness \(b)%"
        case .colorTemperature(let w): "White \(w)% warm"
        case .color(let r, let g, let b): String(format: "Color #%02X%02X%02X", r, g, b)
        }
    }
}

public struct ScheduleEntry: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var hour: Int
    public var minute: Int
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty means every day.
    public var weekdays: Set<Int>
    /// Actions run in order (e.g. on → white 70% warm → brightness 40%).
    public var actions: [LampAction]

    public init(hour: Int, minute: Int, weekdays: Set<Int> = [], actions: [LampAction]) {
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.actions = actions
    }

    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard c.hour == hour, c.minute == minute else { return false }
        return weekdays.isEmpty || weekdays.contains(c.weekday ?? 0)
    }

    public var timeLabel: String { String(format: "%02d:%02d", hour, minute) }

    public var daysLabel: String {
        if weekdays.isEmpty || weekdays.count == 7 { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
    }
}

/// Fires each entry at most once per matching minute.
public struct ScheduleClock: Sendable {
    private var lastFired: [UUID: Date] = [:]

    public init() {}

    public mutating func due(_ entries: [ScheduleEntry], at date: Date, calendar: Calendar = .current) -> [ScheduleEntry] {
        let minute = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        return entries.filter { entry in
            guard entry.matches(date, calendar: calendar), lastFired[entry.id] != minute else { return false }
            lastFired[entry.id] = minute
            return true
        }
    }
}
