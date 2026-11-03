import LampKit
import SwiftUI

struct ScheduleList: View {
    @Bindable var scheduler: Scheduler
    @State private var editing: ScheduleEntry?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach($scheduler.entries) { $entry in
                    HStack {
                        Toggle("", isOn: $entry.enabled).labelsHidden()
                        VStack(alignment: .leading) {
                            Text(entry.timeLabel).font(.title3.monospacedDigit())
                            Text(entry.daysLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 110, alignment: .leading)
                        Text(entry.actions.map(\.label).joined(separator: " → "))
                            .lineLimit(2)
                        Spacer()
                        Button("Run") { scheduler.run(entry) }
                        Button("Edit") { editing = entry }
                    }
                }
                .onDelete { scheduler.entries.remove(atOffsets: $0) }
            }
            Divider()
            HStack {
                Text("Schedules run while this Mac is awake.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add schedule") {
                    editing = ScheduleEntry(hour: 9, minute: 0, actions: [.on])
                }
            }
            .padding(10)
        }
        .sheet(item: $editing) { entry in
            ScheduleEditor(entry: entry) { saved in
                if let i = scheduler.entries.firstIndex(where: { $0.id == saved.id }) {
                    scheduler.entries[i] = saved
                } else {
                    scheduler.entries.append(saved)
                }
                scheduler.entries.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
            }
        }
    }
}

struct ScheduleEditor: View {
    enum Power: String, CaseIterable { case unchanged = "Unchanged", on = "On", off = "Off" }
    enum Light: String, CaseIterable { case unchanged = "Unchanged", white = "White", color = "Color", effect = "Effect" }

    let original: ScheduleEntry
    let onSave: (ScheduleEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var power: Power = .unchanged
    @State private var light: Light = .unchanged
    @State private var warmth = 50.0
    @State private var color = Color.orange
    @State private var effect = 255
    @State private var speed = 50.0
    @State private var setBrightness = false
    @State private var brightness = 80.0

    init(entry: ScheduleEntry, onSave: @escaping (ScheduleEntry) -> Void) {
        original = entry
        self.onSave = onSave
        _time = State(initialValue: Calendar.current.date(from: DateComponents(hour: entry.hour, minute: entry.minute)) ?? Date())
        _weekdays = State(initialValue: entry.weekdays)
        for action in entry.actions {
            switch action {
            case .on: _power = State(initialValue: .on)
            case .off: _power = State(initialValue: .off)
            case .brightness(let b):
                _setBrightness = State(initialValue: true)
                _brightness = State(initialValue: Double(b))
            case .colorTemperature(let w):
                _light = State(initialValue: .white)
                _warmth = State(initialValue: Double(w))
            case .color(let r, let g, let b):
                _light = State(initialValue: .color)
                _color = State(initialValue: Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255))
            case .effect(let n):
                _light = State(initialValue: .effect)
                _effect = State(initialValue: n)
            case .speed(let v):
                _speed = State(initialValue: Double(v))
            }
        }
    }

    var body: some View {
        Form {
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            LabeledContent("Days") {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                            get: { weekdays.contains(day) },
                            set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }
                        ))
                        .toggleStyle(.button)
                    }
                }
            }
            Text("No days selected = every day.").font(.caption).foregroundStyle(.secondary)
            Picker("Power", selection: $power) { ForEach(Power.allCases, id: \.self) { Text($0.rawValue) } }
            if power != .off {
                Picker("Light", selection: $light) { ForEach(Light.allCases, id: \.self) { Text($0.rawValue) } }
                if light == .white {
                    LabeledContent("Cool ↔ Warm") { Slider(value: $warmth, in: 0...100) }
                }
                if light == .color {
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                }
                if light == .effect {
                    EffectPicker(selection: $effect)
                    LabeledContent("Speed \(Int(speed))%") { Slider(value: $speed, in: 0...100) }
                }
                Toggle("Set brightness", isOn: $setBrightness)
                if setBrightness {
                    LabeledContent("Brightness \(Int(brightness))%") { Slider(value: $brightness, in: 0...100) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(build())
                    dismiss()
                }
                .disabled(build().actions.isEmpty)
            }
        }
    }

    private func build() -> ScheduleEntry {
        var actions: [LampAction] = []
        switch power {
        case .on: actions.append(.on)
        case .off: actions.append(.off)
        case .unchanged: break
        }
        if power != .off {
            switch light {
            case .white: actions.append(.colorTemperature(warm: Int(warmth)))
            case .color:
                let n = NSColor(color).usingColorSpace(.sRGB) ?? .white
                actions.append(.color(r: Int(n.redComponent * 255), g: Int(n.greenComponent * 255),
                                      b: Int(n.blueComponent * 255)))
            case .effect:
                actions += [.effect(effect), .speed(Int(speed))]
            case .unchanged: break
            }
            if setBrightness { actions.append(.brightness(Int(brightness))) }
        }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        var entry = original
        entry.hour = c.hour ?? 0
        entry.minute = c.minute ?? 0
        entry.weekdays = weekdays
        entry.actions = actions
        return entry
    }
}

struct EffectPicker: View {
    @Binding var selection: Int

    var body: some View {
        Picker("Effect", selection: $selection) {
            ForEach(DMX03Effects.all, id: \.number) { e in
                Text(e.number == 255 ? e.name : "\(e.number). \(e.name)").tag(e.number)
            }
        }
    }
}
