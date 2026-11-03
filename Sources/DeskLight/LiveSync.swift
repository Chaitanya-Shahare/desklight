import AVFoundation
import LampKit
import Observation
import ScreenCaptureKit
import VideoToolbox

/// Colour sources that change continuously: the wallpaper, what's on screen, or system audio.
@MainActor
@Observable
final class LiveSync {
    enum Mode: String, CaseIterable, Identifiable {
        case off = "Off", wallpaper = "Wallpaper", screen = "Screen", music = "Music"
        var id: String { rawValue }
    }

    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "liveMode")
            Task { await restart() }
        }
    }

    var sensitivity: Double {
        didSet {
            UserDefaults.standard.set(sensitivity, forKey: "musicSensitivity")
            reactor.sensitivity = sensitivity
        }
    }

    private(set) var error: String?
    private(set) var current: RGB?

    private let lamp: LampController
    private let wallpaper: WallpaperSync
    private var stream: SCStream?
    private let output = CaptureOutput()
    private var reactor = MusicReactor(hue: .random(in: 0...1))
    private var smoothed: RGB?
    private var lastSent = Date.distantPast

    init(lamp: LampController, wallpaper: WallpaperSync) {
        self.lamp = lamp
        self.wallpaper = wallpaper
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "liveMode") ?? "") ?? (wallpaper.following ? .wallpaper : .off)
        sensitivity = d.object(forKey: "musicSensitivity") as? Double ?? 1
        reactor.sensitivity = sensitivity

        output.onFrame = { [weak self] analysis in
            Task { @MainActor in self?.screenFrame(analysis) }
        }
        output.onAudio = { [weak self] bass, rms, dt in
            Task { @MainActor in self?.audioBuffer(bass: bass, rms: rms, dt: dt) }
        }
        output.onStop = { [weak self] message in
            Task { @MainActor in self?.error = message; self?.stream = nil }
        }
        Task { await restart() }
    }

    /// Any manual colour choice ends live syncing.
    func stopForManualChange() {
        if mode != .off { mode = .off }
    }

    private func restart() async {
        wallpaper.following = mode == .wallpaper
        if let stream { try? await stream.stopCapture() }
        stream = nil
        smoothed = nil
        current = nil
        error = nil
        guard mode == .screen || mode == .music else { return }
        do {
            stream = try await startStream(audio: mode == .music)
        } catch {
            self.error = "Allow DeskLight in System Settings → Privacy & Security → Screen & System Audio Recording, then pick the mode again."
        }
    }

    private func startStream(audio: Bool) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
        // Ignore our own popup so opening the menu doesn't tint the lamp.
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 96
        config.height = max(2, 96 * display.height / max(1, display.width))
        config.minimumFrameInterval = CMTime(value: 1, timescale: audio ? 1 : 12)
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if audio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 1
        }
        output.wantsFrames = !audio
        output.wantsAudio = audio

        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        if audio { try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue) }
        try await stream.startCapture()
        return stream
    }

    private func screenFrame(_ a: DominantColor.Analysis) {
        guard mode == .screen else { return }
        // Dark scenes dim the lamp; bright scenes run it at full colour.
        let target = a.color.scaled(0.12 + a.luminance * 1.6)
        let next = smoothed.map { $0.mixed(with: target, 0.35) } ?? target
        smoothed = next
        send(next, minChange: 6, minInterval: 0.08)
    }

    private func audioBuffer(bass: Double, rms: Double, dt: Double) {
        guard mode == .music else { return }
        let (color, beat) = reactor.update(bass: bass, rms: rms, dt: dt)
        send(color, minChange: beat ? 0 : 4, minInterval: beat ? 0 : 0.06)
    }

    private func send(_ c: RGB, minChange: Int, minInterval: TimeInterval) {
        let now = Date()
        if let current, c.distance(to: current) < minChange { return }
        guard now.timeIntervalSince(lastSent) >= minInterval else { return }
        lastSent = now
        current = c
        lamp.stream(c)
    }
}

/// ScreenCaptureKit callbacks arrive on a background queue; analysis happens there.
private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "DeskLight.capture", qos: .userInitiated)
    var wantsFrames = false
    var wantsAudio = false
    var onFrame: ((DominantColor.Analysis) -> Void)?
    var onAudio: ((Double, Double, Double) -> Void)?
    var onStop: ((String) -> Void)?
    private var lowPass: Float = 0

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?("Capture stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen where wantsFrames: frame(buffer)
        case .audio where wantsAudio: audio(buffer)
        default: break
        }
    }

    private func frame(_ buffer: CMSampleBuffer) {
        guard let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = buffer.imageBuffer else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image, let a = DominantColor.analyze(image, sample: 48, minVividShare: 0.03) else { return }
        onFrame?(a)
    }

    private func audio(_ buffer: CMSampleBuffer) {
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr,
              let first = UnsafeMutableAudioBufferListPointer(list).first, let data = first.mData else { return }

        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let sampleRate = CMSampleBufferGetFormatDescription(buffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
        // One-pole low-pass at ~150 Hz isolates kick drum / bass.
        let a = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        var sum: Float = 0, bassSum: Float = 0
        for i in 0..<count {
            let x = samples[i]
            lowPass += a * (x - lowPass)
            sum += x * x
            bassSum += lowPass * lowPass
        }
        let rms = Double(sqrt(sum / Float(count)))
        let bass = Double(sqrt(bassSum / Float(count)))
        onAudio?(bass, rms, Double(count) / sampleRate)
    }
}
