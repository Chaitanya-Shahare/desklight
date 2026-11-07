import Foundation
import LampKit
import Observation

/// Colour sources that change on their own: the wallpaper or system audio.
@MainActor
@Observable
final class LiveSync {
    enum Mode: String, CaseIterable, Identifiable {
        case off = "Off", wallpaper = "Wallpaper", music = "Music"
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

    private(set) var error: String?

    private let lamp: LampController
    private let wallpaper: WallpaperSync
    let tap = AudioTap()

    init(lamp: LampController, wallpaper: WallpaperSync) {
        self.lamp = lamp
        self.wallpaper = wallpaper
        let d = UserDefaults.standard
        // "Screen" was removed; anything unknown falls back to off.
        mode = Mode(rawValue: d.string(forKey: "liveMode") ?? "") ?? .off
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
        restart()
    }

    /// Any manual colour choice ends live syncing.
    func stopForManualChange() {
        if mode != .off { mode = .off }
    }

    private func restart() {
        wallpaper.following = mode == .wallpaper
        tap.stop()
        error = nil
        guard mode == .music else { return }
        do {
            try tap.start()
            lamp.note("Music tap started")
        } catch {
            self.error = error.localizedDescription
            lamp.note("Music tap failed: \(error.localizedDescription)")
        }
    }
}
