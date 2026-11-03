import AppKit
import ImageIO
import LampKit
import Observation

/// Reads the current desktop picture and, when following, re-applies its colour
/// whenever the wallpaper or active Space changes.
@MainActor
@Observable
final class WallpaperSync {
    private(set) var color: RGB?
    private(set) var error: String?

    var following: Bool {
        didSet {
            UserDefaults.standard.set(following, forKey: "followWallpaper")
            if following { apply(force: true) }
        }
    }

    private let lamp: LampController
    private var lastSignature: String?
    private var timer: Timer?

    init(lamp: LampController) {
        self.lamp = lamp
        following = UserDefaults.standard.bool(forKey: "followWallpaper")
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        // There is no public "wallpaper changed" notification; a cheap URL/date check covers it.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if following { apply(force: true) }
    }

    /// One-shot: send the wallpaper colour now.
    func apply(force: Bool = false) {
        guard let url = currentURL() else {
            error = "Couldn't find the current wallpaper."
            return
        }
        lastSignature = signature(url)
        guard let image = loadImage(url) else {
            error = "This wallpaper type can't be read (dynamic/aerial wallpapers aren't supported)."
            return
        }
        guard let c = DominantColor.of(image) else { return }
        error = nil
        if force || c != color {
            color = c
            lamp.perform([.color(r: c.r, g: c.g, b: c.b)])
        }
    }

    private func poll() {
        guard following, !lamp.lookIsHeld, let url = currentURL(), signature(url) != lastSignature else { return }
        apply()
    }

    private func currentURL() -> URL? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // macOS can report a stale extension (e.g. Safari "Use as Desktop Picture" saves
        // `.webp` but the wallpaper store says `.jpg`). Look for a sibling with the same name.
        let dir = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return siblings.first { $0.deletingPathExtension().lastPathComponent == stem } ?? url
    }

    private func signature(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)"
    }

    private func loadImage(_ url: URL) -> CGImage? {
        var isDir: ObjCBool = false
        var file = url
        // Some wallpaper URLs point at a folder (shuffle); use its first image.
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let first = items.first(where: { ["jpg", "jpeg", "png", "heic", "tiff"].contains($0.pathExtension.lowercased()) })
            else { return nil }
            file = first
        }
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        // A thumbnail is plenty for colour analysis and avoids decoding 6K images.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
