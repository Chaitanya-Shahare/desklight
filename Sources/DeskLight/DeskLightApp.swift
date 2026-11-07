import LampKit
import SwiftUI

@main
struct DeskLightApp: App {
    @State private var lamp: LampController
    @State private var scheduler: Scheduler
    @State private var wallpaper: WallpaperSync
    @State private var live: LiveSync
    @State private var automations: Automations
    @State private var pomodoro: PomodoroController
    private let commands: Commands

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--diagnose") {
            let diag = Diagnostics(nameFilter: args.indices.contains(i + 1) ? args[i + 1] : nil)
            withExtendedLifetime(diag) { RunLoop.main.run(until: .now + 60) }
            exit(2)
        }
        if args.contains("--selftest") {
            SelfTest.run() // headless: exercises the lamp, timer and audio tap, then exits
        }
        let lamp = LampController()
        let wallpaper = WallpaperSync(lamp: lamp)
        let live = LiveSync(lamp: lamp, wallpaper: wallpaper)
        _lamp = State(initialValue: lamp)
        _scheduler = State(initialValue: Scheduler(lamp: lamp))
        _wallpaper = State(initialValue: wallpaper)
        _live = State(initialValue: live)
        _automations = State(initialValue: Automations(lamp: lamp))
        let pomodoro = PomodoroController(lamp: lamp, live: live)
        _pomodoro = State(initialValue: pomodoro)
        commands = Commands(lamp: lamp, wallpaper: wallpaper, live: live, pomodoro: pomodoro)
    }

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(lamp: lamp, wallpaper: wallpaper, live: live, automations: automations, pomodoro: pomodoro)
        } label: {
            if pomodoro.inSession {
                // Countdown in the menu bar while a Pomodoro session runs.
                // Minutes only (one redraw a minute); seconds appear in the final minute.
                Image(systemName: pomodoro.timer.phase == .focus ? "timer" : "cup.and.saucer.fill")
                Text(pomodoro.menuLabel).monospacedDigit()
            } else {
                Image(systemName: menuIcon)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Schedules", id: "schedules") {
            ScheduleList(scheduler: scheduler)
        }
        .defaultSize(width: 520, height: 420)

        Window("DeskLight Settings", id: "settings") {
            SettingsView(lamp: lamp, pomodoro: pomodoro, automations: automations)
        }
        .windowResizability(.contentSize)
    }

    private var menuIcon: String {
        if automations.onAir { return "video.fill" }
        if !lamp.isConnected { return "lightbulb" }
        if live.mode == .music { return "music.note" }
        if live.mode == .screen { return "tv.fill" }
        return lamp.isFading ? "sunset.fill" : "lightbulb.fill"
    }
}

struct ControlPanel: View {
    enum Tab: String, CaseIterable { case color = "Color", white = "White", live = "Live", focus = "Focus" }

    let lamp: LampController
    let wallpaper: WallpaperSync
    @Bindable var live: LiveSync
    @Bindable var automations: Automations
    @Bindable var pomodoro: PomodoroController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("tab") private var tab = Tab.color
    @AppStorage("brightness") private var brightness = 80.0
    @AppStorage("warmth") private var warmth = 50.0
    @AppStorage("customColor") private var customHex = "FF653E"
    /// Colours the user saved with "+", comma-separated hex.
    @AppStorage("savedColors") private var savedHex = ""
    @State private var hexField = ""

    private static let swatches: [RGB] = [
        RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 110, b: 0), RGB(r: 255, g: 220, b: 0), RGB(r: 0, g: 255, b: 0),
        RGB(r: 0, g: 255, b: 255), RGB(r: 0, g: 0, b: 255), RGB(r: 150, g: 0, b: 255), RGB(r: 255, g: 0, b: 150),
        RGB(r: 255, g: 255, b: 255),
    ]

    private var custom: RGB { RGB(hex: customHex) ?? RGB(r: 255, g: 101, b: 62) }

    private static let maxSaved = 9
    private var saved: [RGB] { savedHex.split(separator: ",").compactMap { RGB(hex: String($0)) } }
    private func setSaved(_ colors: [RGB]) { savedHex = colors.map(\.hex).joined(separator: ",") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if lamp.isConnected {
                LabeledContent("Brightness") {
                    Slider(value: $brightness, in: 0...100)
                        .onChange(of: brightness) { lamp.setBrightness(Int($1)) }
                }
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden()
                switch tab {
                case .color: colorTab
                case .white: whiteTab
                case .live: liveTab
                case .focus: PomodoroPanel(pomodoro: pomodoro)
                }
                fadeRow
            } else {
                scanList
            }
            Divider()
            HStack {
                Button("Schedules…") { open("schedules") }
                Button("Settings…") { open("settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear { hexField = custom.hex }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text(lamp.status.label).font(.headline).lineLimit(1)
            Spacer()
            if lamp.isConnected {
                Toggle("", isOn: Binding(get: { lamp.isOn }, set: { lamp.setPower($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var colorTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ColorWheel(color: custom) { pick($0) }
                    .frame(width: 130, height: 130)
                VStack(alignment: .leading, spacing: 6) {
                    channel("R", \.r, .red)
                    channel("G", \.g, .green)
                    channel("B", \.b, .blue)
                    HStack {
                        Text("#").foregroundStyle(.secondary)
                        TextField("RRGGBB", text: $hexField)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { if let c = RGB(hex: hexField) { pick(c) } }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.swatches, id: \.self) { c in
                    Button { pick(c) } label: { dot(c, size: 22) }.buttonStyle(.plain)
                }
            }
            Text("My colors").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(saved, id: \.self) { c in
                    Button { pick(c) } label: { dot(c, size: 22) }
                        .buttonStyle(.plain)
                        .help("#\(c.hex) · right-click to remove")
                        .contextMenu { Button("Remove") { setSaved(saved.filter { $0 != c }) } }
                }
                if saved.count < Self.maxSaved && !saved.contains(custom) {
                    Button { setSaved(saved + [custom]) } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(custom.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help("Save #\(custom.hex) to My colors")
                }
                if saved.isEmpty {
                    Text("Save the current color").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var whiteTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Cool ↔ Warm") {
                Slider(value: $warmth, in: 0...100)
                    .onChange(of: warmth) { _, w in
                        live.stopForManualChange()
                        pomodoro.userTookOverLamp()
                        lamp.setWarmth(Int(w))
                    }
            }
            HStack {
                ForEach([("Cool", 0.0), ("Neutral", 45.0), ("Warm", 80.0), ("Candle", 100.0)], id: \.0) { name, w in
                    Button(name) { warmth = w }
                }
            }
        }
    }

    private var liveTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $live.mode) { ForEach(LiveSync.Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            switch live.mode {
            case .off:
                Text("Your wallpaper, the music you're playing, or what's on screen can drive the lamp color.")
                    .font(.caption).foregroundStyle(.secondary)
            case .wallpaper:
                HStack {
                    Text("Follows your desktop picture.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let c = wallpaper.color { dot(c, size: 16) }
                    Button("Apply now") { wallpaper.apply(force: true) }
                }
                if let e = wallpaper.error { Text(e).font(.caption).foregroundStyle(.secondary) }
            case .music:
                Text("Pulses with whatever your Mac is playing.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Sensitivity") { Slider(value: $live.sensitivity, in: 0.3...3) }
            case .screen:
                screenOptions
            }
            if let e = live.error { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var screenOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("Records your screen to read its colors. Uses more battery, and macOS shows a recording indicator. Turn it off when you're done.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let c = live.screenColor { dot(c, size: 16) }
            }
            if DisplayChoice.all.count > 1 {
                Picker("Display", selection: $live.screenDisplay) {
                    Text("Main display").tag(CGDirectDisplayID?.none)
                    ForEach(DisplayChoice.all) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Picker("Style", selection: $live.screenProfile) {
                ForEach(ScreenProfile.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(profileHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var profileHint: String {
        switch live.screenProfile {
        case .solid: "Slow, steady color from the lower middle of the screen. Lowest battery use."
        case .movie: "Follows the action in the lower middle of the picture, without flicker."
        case .game: "Follows the screen edges like a TV backlight; reacts instantly. Highest battery use."
        }
    }

    private var fadeRow: some View {
        HStack {
            if let end = lamp.fadeEndsAt {
                Image(systemName: "sunset")
                Text("Fading until \(end.formatted(date: .omitted, time: .shortened))").font(.caption)
                Spacer()
                Button("Cancel") { lamp.cancelFade() }
            } else {
                Menu("Fade out") {
                    ForEach([5, 15, 30, 60], id: \.self) { m in
                        Button("\(m) minutes") { startFade([.off], minutes: m) }
                    }
                }
                Menu("Sunrise") {
                    ForEach([5, 15, 30], id: \.self) { m in
                        Button("\(m) minutes") { startFade([.on, .colorTemperature(warm: 60), .brightness(100)], minutes: m) }
                    }
                }
            }
        }
    }

    private var scanList: some View {
        VStack(alignment: .leading) {
            Button(lamp.status == .scanning ? "Scanning…" : "Scan for lamps") { lamp.startScan() }
                .disabled(lamp.status == .scanning)
            ForEach(lamp.discovered.sorted { $0.rssi > $1.rssi }) { d in
                Button { lamp.connect(d) } label: {
                    HStack { Text(d.name); Spacer(); Text("\(d.rssi) dBm").foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
            }
            if lamp.status == .unauthorized {
                Text("Allow DeskLight in System Settings → Privacy & Security → Bluetooth.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func channel(_ label: String, _ key: WritableKeyPath<RGB, Int>, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.monospaced()).frame(width: 12)
            Slider(value: Binding(get: { Double(custom[keyPath: key]) },
                                  set: { var c = custom; c[keyPath: key] = Int($0); pick(c) }),
                   in: 0...255)
                .tint(tint)
            Text("\(custom[keyPath: key])").font(.caption.monospacedDigit()).frame(width: 26, alignment: .trailing)
        }
    }

    private func open(_ window: String) {
        openWindow(id: window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dot(_ c: RGB, size: CGFloat) -> some View {
        Circle()
            .fill(c.swiftUI)
            .overlay(Circle().stroke(.secondary.opacity(0.5)))
            .frame(width: size, height: size)
    }

    private func pick(_ c: RGB) {
        customHex = c.hex
        hexField = c.hex
        live.stopForManualChange()
        pomodoro.userTookOverLamp()
        lamp.setColor(r: c.r, g: c.g, b: c.b)
    }

    private func startFade(_ target: [LampAction], minutes: Int) {
        live.stopForManualChange()
        lamp.fade(to: target, over: Double(minutes) * 60)
    }
}
