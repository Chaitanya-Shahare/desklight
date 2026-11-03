import AppKit
import Foundation
import LampKit
import Observation

/// Persists schedules and fires them while the Mac is awake.
@MainActor
@Observable
final class Scheduler {
    var entries: [ScheduleEntry] = [] {
        didSet { save() }
    }

    private let lamp: LampController
    private var clock = ScheduleClock()
    private var timer: Timer?
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskLight", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedules.json")
    }()

    init(lamp: LampController) {
        self.lamp = lamp
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lamp.reconnect()
                self?.tick()
            }
        }
    }

    func tick(now: Date = Date()) {
        for entry in clock.due(entries, at: now) {
            lamp.perform(entry.actions)
        }
    }

    func run(_ entry: ScheduleEntry) { lamp.perform(entry.actions) }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([ScheduleEntry].self, from: data) else {
            entries = [
                ScheduleEntry(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6],
                              actions: [.on, .colorTemperature(warm: 30), .brightness(80)]),
                ScheduleEntry(hour: 19, minute: 0, actions: [.colorTemperature(warm: 90), .brightness(40)]),
                ScheduleEntry(hour: 23, minute: 30, actions: [.off]),
            ].map { var e = $0; e.enabled = false; return e }
            return
        }
        entries = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
