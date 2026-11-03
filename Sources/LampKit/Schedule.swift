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
    /// 0 = instant; otherwise colour/brightness glide to the target over this many minutes.
    public var fadeMinutes: Int

    public init(hour: Int, minute: Int, weekdays: Set<Int> = [], actions: [LampAction], fadeMinutes: Int = 0) {
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.actions = actions
        self.fadeMinutes = fadeMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        hour = try c.decode(Int.self, forKey: .hour)
        minute = try c.decode(Int.self, forKey: .minute)
        weekdays = try c.decode(Set<Int>.self, forKey: .weekdays)
        // Schedules saved by older builds may contain removed actions (effects); skip those.
        actions = try c.decode([FailableAction].self, forKey: .actions).compactMap(\.action)
        fadeMinutes = try c.decodeIfPresent(Int.self, forKey: .fadeMinutes) ?? 0
    }

    private struct FailableAction: Decodable {
        let action: LampAction?
        init(from decoder: Decoder) throws { action = try? LampAction(from: decoder) }
    }

    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard c.hour == hour, c.minute == minute else { return false }
        return weekdays.isEmpty || weekdays.contains(c.weekday ?? 0)
    }

    public var timeLabel: String { String(format: "%02d:%02d", hour, minute) }

    public var fadeLabel: String? { fadeMinutes > 0 ? "fade \(fadeMinutes) min" : nil }

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
