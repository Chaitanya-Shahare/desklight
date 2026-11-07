import CoreGraphics
import Foundation
import LampKit
import Observation

/// Colour sources that change on their own: the wallpaper, system audio, or what's on screen.
@MainActor
@Observable
final class LiveSync {
    enum Mode: String, CaseIterable, Identifiable {
        case off = "Off", wallpaper = "Wallpaper", music = "Music", screen = "Screen"
        var id: String { rawValue }
    }

    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "liveMode")
            restart()
        }
    }

    var sensitivity: Double {
        didSet {
            UserDefaults.standard.set(sensitivity, forKey: "musicSensitivity")
            tap.sensitivity = sensitivity
        }
    }

    /// Screen sync settings. Changing any of them restarts the capture.
    var screenProfile: ScreenProfile {
        didSet { save(screenProfile.rawValue, "screenProfile", changed: screenProfile != oldValue) }
    }
    /// nil follows the main display.
    var screenDisplay: CGDirectDisplayID? {
        didSet { save(screenDisplay.map { Int($0) }, "screenDisplay", changed: screenDisplay != oldValue) }
    }

    private(set) var error: String?
    /// Last colour Screen sync sent, shown as a swatch in the Live tab.
    private(set) var screenColor: RGB?

    private let lamp: LampController
    private let wallpaper: WallpaperSync
    let tap = AudioTap()
    private let screen = ScreenCapture()
    private var smoothed: RGB?
    /// Bumped on every restart so a slow capture start can't outlive a newer mode.
    private var generation = 0
    /// The last capture stop/start. Each restart waits for it, so two starts never overlap
    /// (an older start finishing last would orphan the newer stream, leaving capture running).
    private var screenTask: Task<Void, Never>?

    init(lamp: LampController, wallpaper: WallpaperSync) {
        self.lamp = lamp
        self.wallpaper = wallpaper
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "liveMode") ?? "") ?? .off
        screenProfile = ScreenProfile(rawValue: d.string(forKey: "screenProfile") ?? "") ?? .movie
        screenDisplay = (d.object(forKey: "screenDisplay") as? Int).map { CGDirectDisplayID($0) }
        sensitivity = d.object(forKey: "musicSensitivity") as? Double ?? 1
        tap.sensitivity = sensitivity
        tap.onColor = { [weak self] color, beat in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Snappy attack on beats, softer decay between them.
                    self?.lamp.stream(color, tau: beat ? 0.04 : 0.12)
                }
            }
        }
        screen.onFrame = { [weak self] color in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.screenFrame(color) }
            }
        }
        screen.onStop = { [weak self] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.error = message
                    self?.lamp.note(message)
                }
            }
        }
        restart()
    }

    /// Any manual colour choice ends live syncing.
    func stopForManualChange() {
        if mode != .off { mode = .off }
    }

    private func save(_ value: Any?, _ key: String, changed: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        if changed && mode == .screen { restart() }
    }

    private func restart() {
        generation += 1
        wallpaper.following = mode == .wallpaper
        tap.stop()
        error = nil
        smoothed = nil
        screenColor = nil
        let generation = generation
        let wantScreen = mode == .screen
        let (display, profile) = (screenDisplay, screenProfile)
        let previous = screenTask
        screenTask = Task {
            await previous?.value
            await screen.stop()
            guard wantScreen, generation == self.generation else { return }
            do {
                try await screen.start(display: display, profile: profile)
                lamp.note("Screen sync started (\(profile.rawValue))")
                // The mode may have changed while the capture was starting.
                if generation != self.generation { await screen.stop() }
            } catch {
                guard generation == self.generation else { return }
                self.error = "Allow DeskLight in System Settings → Privacy & Security → Screen & System Audio Recording, then pick Screen again."
                lamp.note("Screen sync failed: \(error.localizedDescription)")
            }
        }
        guard mode == .music else { return }
        do {
            try tap.start()
            lamp.note("Music tap started")
        } catch {
            self.error = error.localizedDescription
            lamp.note("Music tap failed: \(error.localizedDescription)")
        }
    }

    private func screenFrame(_ target: RGB) {
        guard mode == .screen else { return }
        let p = screenProfile
        let next = smoothed.map { $0.mixed(with: target, p.smoothing) } ?? target
        smoothed = next
        if let last = screenColor, next.distance(to: last) < p.minChange { return }
        screenColor = next
        lamp.stream(next, tau: p.glide)
    }
}
