import LampKit
import ServiceManagement
import SwiftUI

@main
struct DeskLightApp: App {
    @State private var lamp: LampController
    @State private var scheduler: Scheduler
    @State private var wallpaper: WallpaperSync
    @State private var automations: Automations
    private let commands: Commands

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--diagnose") {
            let diag = Diagnostics(nameFilter: args.indices.contains(i + 1) ? args[i + 1] : nil)
            withExtendedLifetime(diag) { RunLoop.main.run(until: .now + 60) }
            exit(2)
        }
        let lamp = LampController()
        _lamp = State(initialValue: lamp)
        _scheduler = State(initialValue: Scheduler(lamp: lamp))
        let wallpaper = WallpaperSync(lamp: lamp)
        _wallpaper = State(initialValue: wallpaper)
        _automations = State(initialValue: Automations(lamp: lamp))
        commands = Commands(lamp: lamp, wallpaper: wallpaper)
    }

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(lamp: lamp, wallpaper: wallpaper, automations: automations)
        } label: {
            Image(systemName: automations.onAir ? "video.fill" : lamp.isConnected ? "lightbulb.fill" : "lightbulb")
        }
        .menuBarExtraStyle(.window)

        Window("Schedules", id: "schedules") {
            ScheduleList(scheduler: scheduler)
        }
        .defaultSize(width: 520, height: 420)
    }
}

struct ControlPanel: View {
    let lamp: LampController
    @Bindable var wallpaper: WallpaperSync
    @Bindable var automations: Automations
    @AppStorage("effect") private var effect = 255
    @AppStorage("speed") private var speed = 50.0
    @Environment(\.openWindow) private var openWindow
    @AppStorage("brightness") private var brightness = 80.0
    @AppStorage("warmth") private var warmth = 50.0
    @AppStorage("hue") private var hue = 0.08
    @AppStorage("saturation") private var saturation = 1.0

    private static let swatches: [(Int, Int, Int)] = [
        (255, 0, 0), (255, 110, 0), (255, 220, 0), (0, 255, 0), (0, 255, 255),
        (0, 0, 255), (150, 0, 255), (255, 0, 150), (255, 255, 255),
    ]
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(lamp.status.label).font(.headline)
                Spacer()
                if lamp.isConnected {
                    Button("Disconnect") { lamp.disconnect() }
                }
            }

            if lamp.isConnected {
                HStack {
                    Button { lamp.setPower(true) } label: { Label("On", systemImage: "power") }
                    Button { lamp.setPower(false) } label: { Label("Off", systemImage: "poweroff") }
                }
                LabeledContent("Brightness") {
                    Slider(value: $brightness, in: 0...100)
                        .onChange(of: brightness) { lamp.setBrightness(Int($1)) }
                }
                LabeledContent("Cool ↔ Warm") {
                    Slider(value: $warmth, in: 0...100)
                        .onChange(of: warmth) { lamp.setWarmth(Int($1)) }
                }
                // Inline controls: the system colour panel would close this menu bar popover.
                HStack(spacing: 6) {
                    ForEach(Self.swatches.indices, id: \.self) { i in
                        let (r, g, b) = Self.swatches[i]
                        Button { lamp.setColor(r: r, g: g, b: b) } label: {
                            Circle()
                                .fill(Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255))
                                .overlay(Circle().stroke(.secondary.opacity(0.5)))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
                LabeledContent("Hue") {
                    Slider(value: $hue, in: 0...1)
                        .tint(Color(hue: hue, saturation: 1, brightness: 1))
                        .onChange(of: hue) { sendHue() }
                }
                LabeledContent("Saturation") {
                    Slider(value: $saturation, in: 0...1)
                        .onChange(of: saturation) { sendHue() }
                }
                HStack {
                    Button { wallpaper.apply(force: true) } label: { Label("Wallpaper color", systemImage: "photo") }
                    if let c = wallpaper.color {
                        Circle()
                            .fill(Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255))
                            .frame(width: 16, height: 16)
                    }
                    Spacer()
                    Toggle("Follow", isOn: $wallpaper.following)
                        .help("Update the lamp whenever the wallpaper or Space changes")
                }
                if let error = wallpaper.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    EffectPicker(selection: $effect)
                        .onChange(of: effect) { lamp.setEffect($1) }
                    Button("Play") { lamp.setEffect(effect) }
                }
                LabeledContent("Speed") {
                    Slider(value: $speed, in: 0...100)
                        .onChange(of: speed) { lamp.setSpeed(Int($1)) }
                }
            } else {
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

            Divider()
            Toggle("Off when Mac locks or sleeps", isOn: $automations.followLock)
            HStack {
                Text("On-Air red light:")
                Toggle("Camera", isOn: $automations.onAirCamera)
                Toggle("Mic", isOn: $automations.onAirMic)
            }
            Text("Shortcuts: ⌃⌥⌘L toggle · ⌃⌥⌘↑/↓ brightness · ⌃⌥⌘W wallpaper")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Log") {
                ScrollView {
                    Text(lamp.log.suffix(30).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 100)
            }
            HStack {
                Button("Schedules…") {
                    openWindow(id: "schedules")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func sendHue() {
        let c = NSColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1)
        lamp.setColor(r: Int(c.redComponent * 255), g: Int(c.greenComponent * 255), b: Int(c.blueComponent * 255))
    }
}
