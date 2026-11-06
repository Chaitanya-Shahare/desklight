import LampKit
import SwiftUI

struct PomodoroPanel: View {
    @Bindable var pomodoro: PomodoroController

    var body: some View {
        let timer = pomodoro.timer
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.phase.title).font(.headline)
                    Text(timer.phase == .focus ? "Session \(timer.focusInSet) of \(pomodoro.config.longBreakEvery)"
                                               : "\(timer.completedFocus) focus sessions done")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(pomodoro.remainingLabel)
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
            }
            ProgressBar(progress: pomodoro.progress) { pomodoro.color(at: $0) }
                .frame(height: 10)
            HStack {
                Button {
                    pomodoro.toggle()
                } label: {
                    Label(timer.isRunning ? "Pause" : timer.isPaused ? "Resume" : "Start \(timer.phase.title.lowercased())",
                          systemImage: timer.isRunning ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("Skip") { pomodoro.skip() }.disabled(!pomodoro.inSession)
                Spacer()
                Button("Stop") { pomodoro.stop() }.disabled(!pomodoro.inSession)
            }
            Toggle("Show progress on lamp (green → red, blue on breaks)", isOn: $pomodoro.showOnLamp)
                .font(.caption)
            DisclosureGroup("Durations") {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper("Focus \(pomodoro.config.focusMinutes) min",
                            value: $pomodoro.config.focusMinutes, in: 1...120, step: 5)
                    Stepper("Short break \(pomodoro.config.shortBreakMinutes) min",
                            value: $pomodoro.config.shortBreakMinutes, in: 1...30)
                    Stepper("Long break \(pomodoro.config.longBreakMinutes) min",
                            value: $pomodoro.config.longBreakMinutes, in: 5...60, step: 5)
                    Stepper("Long break every \(pomodoro.config.longBreakEvery)",
                            value: $pomodoro.config.longBreakEvery, in: 2...8)
                    Toggle("Start breaks automatically", isOn: $pomodoro.config.autoStartBreaks)
                    Toggle("Start focus automatically", isOn: $pomodoro.config.autoStartFocus)
                }
                .padding(.top, 4)
            }
        }
    }
}

/// Filled with the same colour gradient the lamp walks through.
private struct ProgressBar: View {
    let progress: Double
    let color: (Double) -> RGB

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: max(progress, 0.01), by: max(progress, 0.01) / 6)
                        .map { swiftUI(color($0)) }, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.height, geo.size.width * progress))
                    .animation(.linear(duration: 1), value: progress)
            }
        }
    }

    private func swiftUI(_ c: RGB) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}
