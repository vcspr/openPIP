import AppKit
import ScreenCaptureKit
import OpenPiPCore

/// Streams one window with ScreenCaptureKit and hands each new frame to `onFrame` on the main thread.
///
/// ScreenCaptureKit keeps sending "complete" copies of a still window, so each frame is fingerprinted
/// and copies are dropped. The stream runs at 15 fps while the window changes and 5 fps when it is still.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State { case idle, starting, running }

    var onFrame: ((IOSurfaceRef) -> Void)?
    /// Called when the system stops the stream (window closed, permission removed, and so on).
    var onStop: ((String) -> Void)?

    private(set) var state: State = .idle
    private(set) var windowID: CGWindowID?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.hemii.openpip.capture", qos: .userInteractive)
    // Touched only on `queue`.
    private var detector = FrameChangeDetector()
    private var config = SCStreamConfiguration()

    @MainActor
    func start(_ window: SCWindow) async throws {
        await stop()
        state = .starting
        windowID = window.windowID

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var w = window.frame.width * scale, h = window.frame.height * scale
        let longest = max(w, h), cap: CGFloat = 1600
        if longest > cap { w *= cap / longest; h *= cap / longest }
        config.width = max(2, Int(w))
        config.height = max(2, Int(h))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(FrameChangeDetector().fastFPS))
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.preservesAspectRatio = true

        queue.sync {
            detector = FrameChangeDetector()
            self.config = config
        }
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
        } catch {
            state = .idle
            windowID = nil
            throw error
        }
        // A newer start() or a stop() may have run while we awaited.
        guard state == .starting, windowID == window.windowID else {
            try? await s.stopCapture()
            return
        }
        stream = s
        state = .running
    }

    @MainActor
    func stop() async {
        let s = stream
        stream = nil
        state = .idle
        windowID = nil
        if let s { try? await s.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        IOSurfaceLock(surface, .readOnly, nil)
        let bytes = UnsafeRawBufferPointer(start: IOSurfaceGetBaseAddress(surface), count: IOSurfaceGetAllocSize(surface))
        let fingerprint = FrameFingerprint.of(bytes)
        IOSurfaceUnlock(surface, .readOnly, nil)

        let (changed, newFPS) = detector.feed(fingerprint, at: Date())
        if let newFPS {
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(newFPS))
            stream.updateConfiguration(config) { _ in }
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.onFrame?(surface)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.state = .idle
            self.windowID = nil
            self.onStop?("Window not visible")
        }
    }
}
