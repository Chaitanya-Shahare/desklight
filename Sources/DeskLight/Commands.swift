import AppKit
import Carbon.HIToolbox
import LampKit

/// Text commands shared by `desklight://` URLs and global hotkeys.
///
///     desklight://on | off | toggle | wallpaper
///     desklight://brightness/40      desklight://brightness/+10
///     desklight://color/FF8800       desklight://white/70   (70% warm)
///     desklight://live/screen|music|wallpaper|off
///     desklight://fadeout/30         desklight://sunrise/15  (minutes)
@MainActor
final class Commands: NSObject {
    private let lamp: LampController
    private let wallpaper: WallpaperSync
    private let live: LiveSync
    private var hotKeys: [EventHotKeyRef?] = []
    private static var shared: Commands?

    init(lamp: LampController, wallpaper: WallpaperSync, live: LiveSync) {
        self.lamp = lamp
        self.wallpaper = wallpaper
        self.live = live
        super.init()
        Self.shared = self
        installURLHandler()
        // SwiftUI installs its own GetURL handler during launch, replacing ours; take it back.
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Commands.shared?.installURLHandler() }
        }
        registerHotKeys()
    }

    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s) else { return }
        run(([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).joined(separator: "/"))
    }

    func run(_ command: String) {
        let parts = command.lowercased().split(separator: "/").map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "on": lamp.setPower(true)
        case "off": lamp.setPower(false)
        case "toggle": lamp.toggle()
        case "wallpaper": wallpaper.apply(force: true)
        case "brightness": setBrightness(arg)
        case "white":
            guard let w = Int(arg) else { return }
            live.stopForManualChange()
            lamp.setWarmth(w)
        case "color":
            guard let c = RGB(hex: arg) else { return }
            live.stopForManualChange()
            lamp.setColor(r: c.r, g: c.g, b: c.b)
        case "live":
            if let m = LiveSync.Mode.allCases.first(where: { $0.rawValue.lowercased() == arg }) { live.mode = m }
        case "fadeout":
            live.stopForManualChange()
            lamp.fade(to: [.off], over: (Double(arg) ?? 30) * 60)
        case "sunrise":
            live.stopForManualChange()
            lamp.fade(to: [.on, .colorTemperature(warm: 60), .brightness(100)], over: (Double(arg) ?? 15) * 60)
        default: break
        }
    }

    /// Absolute ("40") or relative ("+10" / "-10"); shares the menu slider's stored value.
    private func setBrightness(_ arg: String) {
        let d = UserDefaults.standard
        let current = d.object(forKey: "brightness") as? Double ?? 80
        var value: Double
        if arg.hasPrefix("+") || arg.hasPrefix("-") {
            value = current + (Double(arg) ?? 0)
        } else {
            guard let v = Double(arg) else { return }
            value = v
        }
        value = max(0, min(100, value))
        d.set(value, forKey: "brightness")
        lamp.setBrightness(Int(value))
    }

    // MARK: Hotkeys (⌃⌥⌘ + L / ↑ / ↓ / W). Carbon hotkeys need no Accessibility permission.

    private static let bindings: [(key: Int, command: String)] = [
        (kVK_ANSI_L, "toggle"),
        (kVK_UpArrow, "brightness/+10"),
        (kVK_DownArrow, "brightness/-10"),
        (kVK_ANSI_W, "wallpaper"),
    ]

    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard Commands.bindings.indices.contains(index) else { return }
                    Commands.shared?.run(Commands.bindings[index].command)
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for (i, b) in Self.bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x444C_4954), id: UInt32(i)) // 'DLIT'
            RegisterEventHotKey(UInt32(b.key), modifiers, id, GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }
}
