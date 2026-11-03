import AppKit
import CoreAudio
import CoreMediaIO
import LampKit
import Observation

/// Reacts to Mac state: lock/sleep → lamp off, unlock/wake → back on;
/// camera or microphone in use → red "On Air" light, restored afterwards.
@MainActor
@Observable
final class Automations {
    var followLock: Bool { didSet { UserDefaults.standard.set(followLock, forKey: "followLock") } }
    var onAirCamera: Bool { didSet { UserDefaults.standard.set(onAirCamera, forKey: "onAirCamera"); check() } }
    var onAirMic: Bool { didSet { UserDefaults.standard.set(onAirMic, forKey: "onAirMic"); check() } }
    private(set) var onAir = false

    private let lamp: LampController
    private var timer: Timer?
    private var wasOnBeforeLock = true
    private var saved: (on: Bool, look: LampAction?)?

    init(lamp: LampController) {
        self.lamp = lamp
        let d = UserDefaults.standard
        followLock = d.bool(forKey: "followLock")
        onAirCamera = d.bool(forKey: "onAirCamera")
        onAirMic = d.bool(forKey: "onAirMic")

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.away() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.back() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.away() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    // MARK: Lock / sleep

    private var isAway = false

    private func away() {
        guard followLock, !isAway else { return }
        isAway = true
        wasOnBeforeLock = lamp.isOn
        if lamp.isOn { lamp.setPower(false) }
    }

    private func back() {
        guard followLock, isAway else { return }
        isAway = false
        if wasOnBeforeLock { lamp.setPower(true) }
    }

    // MARK: On Air

    private func check() {
        let busy = (onAirCamera && Self.cameraInUse()) || (onAirMic && Self.microphoneInUse())
        guard busy != onAir else { return }
        onAir = busy
        if busy {
            saved = (lamp.isOn, lamp.look)
            lamp.lookIsHeld = true
            lamp.perform([.on, .color(r: 255, g: 0, b: 0)])
        } else {
            lamp.lookIsHeld = false
            guard let saved else { return }
            var restore: [LampAction] = saved.look.map { [$0] } ?? [.colorTemperature(warm: 50)]
            restore.append(saved.on ? .on : .off)
            lamp.perform(restore)
            self.saved = nil
        }
    }

    /// True if any camera is streaming to any process. Needs no camera permission.
    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == noErr else { return false }
        return ids.contains { id in
            var a = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var got: UInt32 = 0
            return CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr
                && running != 0
        }
    }

    /// True if the default input device is open in any process. Needs no microphone permission.
    static func microphoneInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return false }
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr && running != 0
    }
}
