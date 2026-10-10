import AVFoundation
import AppKit
import ScreenCaptureKit

enum RecorderError: LocalizedError {
  case noDisplay
  case emptyRegion
  case noScreen
  case writerFailed(String)

  var errorDescription: String? {
    switch self {
    case .noDisplay: return "Could not find a display for that region."
    case .emptyRegion: return "Selected region is outside every display."
    case .noScreen: return "No screens available."
    case .writerFailed(let s): return "Recorder failed: \(s)"
    }
  }
}

/// Captures a screen sub-rect via ScreenCaptureKit and writes it to an .mp4 file.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  nonisolated(unsafe) var onStreamError: ((Error) -> Void)?
  /// Fired for every captured frame (independent of file writing) so a live
  /// consumer such as WebRTC can tap the same stream.
  nonisolated(unsafe) var onVideoFrame: ((CVPixelBuffer, Int64) -> Void)?

  private let outputQueue = DispatchQueue(label: "glance.sck-output")
  private let lock = NSLock()
  nonisolated(unsafe) private var _recording = false
  nonisolated(unsafe) private var _sessionStarted = false
  nonisolated(unsafe) private var _frameCount = 0
  nonisolated(unsafe) private var _expectedW = 0
  nonisolated(unsafe) private var _expectedH = 0
  nonisolated(unsafe) private(set) var lastWriterError: Error?

  nonisolated(unsafe) private var stream: SCStream?
  nonisolated(unsafe) private var writer: AVAssetWriter?
  nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
  nonisolated(unsafe) private var outputURL: URL?

  private nonisolated var isRecording: Bool {
    get { lock.withLock { _recording } }
    set { lock.withLock { _recording = newValue } }
  }

  /// Start capturing `region` (Cocoa global screen coords, bottom-left origin).
  /// Returns the file URL being written to.
  func start(region: CGRect) async throws -> URL {
    let standardized = region.standardized
    guard standardized.width >= 2, standardized.height >= 2 else {
      throw RecorderError.emptyRegion
    }

    // Drop any stale state from a previous failed attempt.
    stream = nil
    writer = nil
    videoInput = nil
    outputURL = nil
    lastWriterError = nil
    lock.withLock {
      _sessionStarted = false
      _recording = false
      _frameCount = 0
      _expectedW = 0
      _expectedH = 0
    }

    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)

    // Pick the screen with the largest overlap.
    guard let screen = bestScreen(for: standardized) else {
      throw RecorderError.noScreen
    }
    let screenFrame = screen.frame
    let displayID = screen.screenNumber

    guard
      let display = content.displays.first(where: { $0.displayID == displayID })
        ?? displayContaining(standardized, in: content.displays)
    else {
      throw RecorderError.noDisplay
    }

    var scale = screen.backingScaleFactor
    if scale <= 0 {
      let ratio = display.frame.width > 0 ? CGFloat(display.width) / display.frame.width : 2
      scale = ratio > 0 ? ratio : 2
    }

    // Region relative to the chosen screen, clamped to its bounds.
    var relative = CGRect(
      x: standardized.minX - screenFrame.minX,
      y: standardized.minY - screenFrame.minY,
      width: standardized.width,
      height: standardized.height
    )
    let screenBounds = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
    relative = relative.intersection(screenBounds)
    guard !relative.isNull, !relative.isEmpty else {
      throw RecorderError.emptyRegion
    }

    // Pixel-align in point space.
    var aligned = CGRect(
      x: floor(relative.minX),
      y: floor(relative.minY),
      width: ceil(relative.width),
      height: ceil(relative.height)
    )
    aligned = aligned.intersection(screenBounds)
    guard !aligned.isNull, aligned.width >= 2, aligned.height >= 2 else {
      throw RecorderError.emptyRegion
    }

    // sourceRect uses a top-left origin, display-local.
    let flippedY = screenFrame.height - aligned.minY - aligned.height
    let sourceRect = CGRect(
      x: aligned.minX, y: flippedY, width: aligned.width, height: aligned.height)

    // H.264 needs even dimensions.
    var outW = Int((aligned.width * scale).rounded())
    var outH = Int((aligned.height * scale).rounded())
    outW = max(2, (outW / 2) * 2)
    outH = max(2, (outH / 2) * 2)

    // Exclude our own windows so the overlay / main window never appears in the capture.
    let bundleID = Bundle.main.bundleIdentifier
    let excluded = content.windows.filter {
      if let bid = $0.owningApplication?.bundleIdentifier, let mine = bundleID {
        return bid == mine
      }
      return $0.owningApplication?.processID == getpid()
    }

    let filter = SCContentFilter(display: display, excludingWindows: excluded)

    let config = SCStreamConfiguration()
    config.sourceRect = sourceRect
    config.width = outW
    config.height = outH
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 5
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = true
    config.capturesAudio = false
    config.captureResolution = .best

    let url = Self.nextOutputURL()
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    // Default H.264 bitrate mushes screen text: budget ~0.15 bits/px/frame.
    let bitRate = max(8_000_000, min(80_000_000, Int(Double(outW * outH) * 30 * 0.15)))
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: outW,
      AVVideoHeightKey: outH,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate,
        AVVideoExpectedSourceFrameRateKey: 30,
        AVVideoMaxKeyFrameIntervalKey: 60,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
    NSLog("[Glance] encoder bitrate=%d", bitRate)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else {
      throw RecorderError.writerFailed("cannot add video input")
    }
    writer.add(input)

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)

    self.stream = stream
    self.writer = writer
    self.videoInput = input
    self.outputURL = url
    lock.withLock {
      _sessionStarted = false
      _recording = true
      _expectedW = outW
      _expectedH = outH
    }
    NSLog(
      "[Glance] start region=%@ screen=%@ scale=%.3f sourceRect=%@ out=%dx%d",
      NSStringFromRect(standardized), NSStringFromRect(screenFrame), scale,
      NSStringFromRect(sourceRect), outW, outH)

    try await stream.startCapture()
    NSLog("[Glance] recording to %@", url.path(percentEncoded: false) as NSString)
    return url
  }

  func stop() async -> URL? {
    NSLog("[Glance] recorder.stop begin")
    let url = lock.withLock { () -> URL? in
      _recording = false
      return outputURL
    }
    guard let stream else { return url }

    do {
      try await stream.stopCapture()
    } catch {
      // Stopping can throw if the stream already ended; still finalize the file.
    }
    let started = lock.withLock { _sessionStarted }
    if started {
      videoInput?.markAsFinished()
      if let writer {
        await writer.finishWriting()
        let frames = lock.withLock { _frameCount }
        NSLog(
          "[Glance] recorder.stop finished writing to %@, status=%d frames=%d error=%@",
          (url?.path(percentEncoded: false) ?? "(unknown)") as NSString, writer.status.rawValue,
          frames, String(describing: writer.error))
        if writer.status == .failed {
          lastWriterError = writer.error
          self.stream = nil
          self.writer = nil
          self.videoInput = nil
          return nil
        }
      }
    } else {
      // No frames ever arrived: finishing would hang/fail, so cancel instead.
      NSLog("[Glance] recorder.stop: no frames arrived, cancelling")
      writer?.cancelWriting()
      if let url {
        try? FileManager.default.removeItem(at: url)
      }
      self.stream = nil
      self.writer = nil
      self.videoInput = nil
      return nil
    }
    self.stream = nil
    self.writer = nil
    self.videoInput = nil
    return url
  }

  func cancel() async {
    _ = await stop()
    if let url = outputURL {
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - SCStreamOutput

  nonisolated func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen else { return }
    guard isRecording else { return }
    guard CMSampleBufferDataIsReady(sampleBuffer),
      let writer = self.writer,
      let input = self.videoInput,
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }
    if writer.status == .failed || writer.status == .cancelled {
      if writer.status == .failed, lastWriterError == nil {
        lastWriterError = writer.error
        NSLog("[Glance] writer failed: %@", String(describing: writer.error))
      }
      return
    }

    let count = lock.withLock { () -> Int in
      _frameCount += 1
      return _frameCount
    }
    if count == 1 {
      let w = CVPixelBufferGetWidth(pixelBuffer)
      let h = CVPixelBufferGetHeight(pixelBuffer)
      let exp = lock.withLock { (_expectedW, _expectedH) }
      NSLog("[Glance] first frame %dx%d (expected %dx%d)", w, h, exp.0, exp.1)
    } else if count % 90 == 0 {
      NSLog("[Glance] captured %d frames", count)
    }

    lock.withLock {
      if !_sessionStarted {
        // First frame: this transitions the writer from .unknown to .writing.
        writer.startWriting()
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        _sessionStarted = true
        NSLog("[Glance] capture session started")
      }
    }
    // Stream out regardless of file-writer state.
    let timestampNs = Int64(
      CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
    onVideoFrame?(pixelBuffer, timestampNs)
    if input.isReadyForMoreMediaData, writer.status == .writing {
      input.append(sampleBuffer)
    }
  }

  // MARK: - SCStreamDelegate

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    let callback = onStreamError
    if let cb = callback {
      DispatchQueue.main.async { cb(error) }
    }
  }

  // MARK: - Helpers

  private func bestScreen(for rect: CGRect) -> NSScreen? {
    var best: NSScreen?
    var bestArea: CGFloat = 0
    for screen in NSScreen.screens {
      let area = screen.frame.intersection(rect)
      guard !area.isNull else { continue }
      let a = area.width * area.height
      if a > bestArea {
        bestArea = a
        best = screen
      }
    }
    return best ?? NSScreen.main
  }

  private func displayContaining(_ rect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    // SCDisplay.frame is in the same global space on current macOS; match generously.
    return displays.first { $0.frame.contains(center) } ?? displays.first
  }

  private static func nextOutputURL() -> URL {
    let movies =
      FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss"
    let name = "Glance-\(fmt.string(from: Date())).mp4"
    return movies.appendingPathComponent(name)
  }
}

extension NSScreen {
  fileprivate var screenNumber: CGDirectDisplayID {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
  }
}
