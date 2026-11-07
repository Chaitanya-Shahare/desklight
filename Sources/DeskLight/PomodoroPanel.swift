import LampKit
import SwiftUI

struct PomodoroPanel: View {
    @Bindable var pomodoro: PomodoroController
    @Environment(\.openWindow) private var openWindow

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
            if pomodoro.lampPausedByUser {
                HStack {
                    Text("Lamp shows your color until the next phase.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume on lamp") { pomodoro.resumeLamp() }.controlSize(.small)
                }
            }
            HStack {
                Toggle("Show progress on lamp", isOn: $pomodoro.showOnLamp).font(.caption)
                Spacer()
                Button("Colors & durations…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
            }
        }
        .onAppear { pomodoro.panelVisible = true }
        .onDisappear { pomodoro.panelVisible = false }
    }
}

/// Filled with the same colour gradient the lamp walks through.
struct ProgressBar: View {
    let progress: Double
    let color: (Double) -> RGB

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                // Static gradient, no implicit animation: nothing renders between ticks.
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.2)
                        .map { color($0 * max(progress, 0.01)).swiftUI }, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.height, geo.size.width * progress))
            }
        }
    }
}

extension RGB {
    var swiftUI: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    init(_ color: Color) {
        let n = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Int((n.redComponent * 255).rounded()), g: Int((n.greenComponent * 255).rounded()),
                  b: Int((n.blueComponent * 255).rounded()))
    }
}
