import AudioToolbox
import CoreAudio
import Foundation
import LampKit

/// Listens to everything the Mac is playing through a Core Audio process tap (macOS 14.2+).
/// Only needs "System Audio Recording" permission — no screen capture involved.
///
/// Analysis runs on the audio thread's queue; colours are handed to `onColor` at most
/// `maxRate` times a second so the main thread stays idle between updates.
final class AudioTap: @unchecked Sendable {
    var onColor: (@Sendable (RGB, _ beat: Bool) -> Void)?
    var sensitivity: Double {
        get { lock.withLock { reactor.sensitivity } }
        set { lock.withLock { reactor.sensitivity = newValue } }
    }
    /// Audio buffers analysed so far; used by the headless self-test.
    private(set) var buffersSeen = 0
    private(set) var beatsSeen = 0

    private let queue = DispatchQueue(label: "DeskLight.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var reactor = MusicReactor(hue: .random(in: 0...1))
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var lowPass: Float = 0
    private var sampleRate: Double = 48_000
    private var channels = 2
    private var lastPost = 0.0
    private var lastColor: RGB?
    private let maxRate = 30.0

    enum TapError: LocalizedError {
        case status(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let step, let s): "\(step) failed (\(s)). Allow DeskLight under System Settings → Privacy & Security → System Audio Recording Only."
            }
        }
    }

    var isRunning: Bool { procID != nil }

    func start() throws {
        guard procID == nil else { return }
        // Global stereo tap of all output, excluding nothing (we produce no audio).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check("Create audio tap", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format) == noErr {
            sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
            channels = max(1, Int(format.mChannelsPerFrame))
        }

        // A private aggregate device clocked by the default output hosts the tap.
        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DeskLight Music Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("Create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // ~43 ms buffers: plenty for beat detection and ~4× fewer wake-ups than the default 512 frames.
        var frames: UInt32 = 2048
        var bufferAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(aggregateID, &bufferAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        try check("Create IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, input, _, _, _ in
            self?.process(input)
        })
        try check("Start audio", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = list.first, let data = buffer.mData else { return }
        let stride = max(1, Int(buffer.mNumberChannels))
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / stride
        guard count > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)

        // One-pole low-pass at ~150 Hz isolates kick drum / bass. First channel only.
        let a = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        var sum: Float = 0, bassSum: Float = 0
        for i in 0..<count {
            let x = samples[i * stride]
            lowPass += a * (x - lowPass)
            sum += x * x
            bassSum += lowPass * lowPass
        }
        let dt = Double(count) / sampleRate
        let (color, beat) = lock.withLock {
            reactor.update(bass: Double(sqrt(bassSum / Float(count))), rms: Double(sqrt(sum / Float(count))), dt: dt)
        }
        buffersSeen += 1
        if beat { beatsSeen += 1 }

        let now = ProcessInfo.processInfo.systemUptime
        guard beat || now - lastPost >= 1 / maxRate, color != lastColor else { return }
        lastPost = now
        lastColor = color
        onColor?(color, beat)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw TapError.status(step, status)
        }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr else { throw TapError.status("Find output device", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw TapError.status("Read output device", status) }
        return uid.takeRetainedValue() as String
    }
}
