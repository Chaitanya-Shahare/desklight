import LampKit
import ServiceManagement
import SwiftUI

/// A regular window, so the system colour panel works (it would close the menu bar popover).
struct SettingsView: View {
    let lamp: LampController
    @Bindable var pomodoro: PomodoroController
    @Bindable var automations: Automations
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Focus timer") {
                Stepper("Focus \(pomodoro.config.focusMinutes) min",
                        value: $pomodoro.config.focusMinutes, in: 5...120, step: 5)
                Stepper("Short break \(pomodoro.config.shortBreakMinutes) min",
                        value: $pomodoro.config.shortBreakMinutes, in: 1...30)
                Stepper("Long break \(pomodoro.config.longBreakMinutes) min",
                        value: $pomodoro.config.longBreakMinutes, in: 5...60, step: 5)
                Stepper("Long break every \(pomodoro.config.longBreakEvery) sessions",
                        value: $pomodoro.config.longBreakEvery, in: 2...8)
                Toggle("Start breaks automatically", isOn: $pomodoro.config.autoStartBreaks)
                Toggle("Start focus automatically", isOn: $pomodoro.config.autoStartFocus)
            }

            Section {
                gradientRow("Focus", \.focusStart, \.focusEnd, phase: .focus)
                gradientRow("Short break", \.shortBreakStart, \.shortBreakEnd, phase: .shortBreak)
                gradientRow("Long break", \.longBreakStart, \.longBreakEnd, phase: .longBreak)
                Button("Reset to defaults") { pomodoro.config.resetColors() }
            } header: {
                Text("Focus timer colors")
            } footer: {
                Text("The lamp glides from the first color to the second as each phase runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Automations") {
                Toggle("Turn off when the Mac locks or sleeps", isOn: $automations.followLock)
                Toggle("Red On-Air light while the camera is in use", isOn: $automations.onAirCamera)
                Toggle("…or while the microphone is in use", isOn: $automations.onAirMic)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                LabeledContent("Shortcuts") {
                    Text("⌃⌥⌘L toggle · ⌃⌥⌘↑/↓ brightness · ⌃⌥⌘W wallpaper · ⌃⌥⌘P focus timer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if lamp.isConnected {
                    Button("Disconnect lamp") { lamp.disconnect() }
                }
            }

            Section("Log") {
                ScrollView {
                    Text(lamp.log.suffix(40).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 520)
    }

    private func gradientRow(_ title: String, _ start: WritableKeyPath<PomodoroConfig, RGB>,
                             _ end: WritableKeyPath<PomodoroConfig, RGB>, phase: PomodoroPhase) -> some View {
        HStack {
            Text(title)
            Spacer()
            ColorPicker("", selection: colorBinding(start), supportsOpacity: false).labelsHidden()
            ProgressBar(progress: 1) { pomodoro.timer.color(phase, progress: $0) }
                .frame(width: 90, height: 8)
            ColorPicker("", selection: colorBinding(end), supportsOpacity: false).labelsHidden()
        }
    }

    private func colorBinding(_ key: WritableKeyPath<PomodoroConfig, RGB>) -> Binding<Color> {
        Binding(get: { pomodoro.config[keyPath: key].swiftUI },
                set: { pomodoro.config[keyPath: key] = RGB($0) })
    }
}
