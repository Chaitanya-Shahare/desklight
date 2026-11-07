import AppKit
import LampKit
import ScreenCaptureKit
import VideoToolbox

/// A display Screen sync can follow.
struct DisplayChoice: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String

    static var all: [DisplayChoice] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayChoice(id: CGDirectDisplayID(n.uint32Value), name: screen.localizedName)
        }
    }
}

/// Captures a small, low-rate image of one display region and reports its dominant colour.
/// Runs only while Screen mode is selected.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "DeskLight.screen", qos: .userInitiated)
    private var stream: SCStream?
    private var sampleRects: [CGRect]?
    private var profile = ScreenProfile.movie

    /// Called on a background queue for every analysed frame.
    var onFrame: ((RGB) -> Void)?
    /// Called if macOS stops the capture (permission revoked, display unplugged, …).
    var onStop: ((String) -> Void)?

    func start(display displayID: CGDirectDisplayID?, profile: ScreenProfile) async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let wanted = displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
        // Ignore our own popup so opening the menu doesn't tint the lamp.
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        // Capture only the style's region, scaled down to a thumbnail: colour needs few pixels.
        let region = profile.region
        let r = region.captureRect
        let source = CGRect(x: r.minX * Double(display.width), y: r.minY * Double(display.height),
                            width: r.width * Double(display.width), height: r.height * Double(display.height))
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = 96
        config.height = max(2, Int(96 * source.height / max(1, source.width)))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(profile.framesPerSecond))
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        sampleRects = region.sampleRects
        self.profile = profile

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?("Screen capture stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = buffer.imageBuffer else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image,
              let c = DominantColor.ambient(image, include: sampleRects, satWeight: profile.satWeight,
                                            saturation: profile.saturation, gain: profile.gain) else { return }
        onFrame?(c)
    }
}
