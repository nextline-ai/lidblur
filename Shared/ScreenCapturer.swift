import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Captures one display (excluding this app's own windows) and keeps the most recent frame.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "studio.xtower.lidblur.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var sequence: UInt64 = 0
    private(set) var isRunning = false
    var onError: ((Error) -> Void)?

    /// Returns the newest frame if it is newer than `after`.
    func frame(newerThan after: UInt64) -> (CVPixelBuffer, UInt64)? {
        lock.withLock {
            guard let latest, sequence > after else { return nil }
            return (latest, sequence)
        }
    }

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int = 120) async throws {
        if isRunning { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "LidBlur", code: 1, userInfo: [NSLocalizedDescriptionKey: "내장 디스플레이를 찾지 못했습니다"])
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid || $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        guard !me.isEmpty else {
            throw NSError(domain: "LidBlur", code: 2, userInfo: [NSLocalizedDescriptionKey: "자기 창을 캡처에서 제외할 수 없습니다"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.displayP3
        config.capturesAudio = false
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        isRunning = true
    }

    func stop() async {
        lock.withLock { latest = nil }          // never reuse a frame from a stopped stream
        guard let s = stream else { isRunning = false; return }
        stream = nil
        isRunning = false
        try? await s.stopCapture()
    }

    /// Drops the cached frame (e.g. when the screen locks) without stopping the stream.
    func discardLatest() { lock.withLock { latest = nil } }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock { latest = pb; sequence &+= 1 }
    }

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        self.stream = nil
        onError?(error)
    }
}

enum Displays {
    /// The built-in (laptop) screen, if it is currently online.
    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
    var pixelSize: (Int, Int) {
        (Int((frame.width * backingScaleFactor).rounded()), Int((frame.height * backingScaleFactor).rounded()))
    }
}
