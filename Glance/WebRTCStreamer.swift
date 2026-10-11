import CoreVideo
import Foundation
import WebRTC

enum StreamError: LocalizedError {
  case notStreaming
  case badOffer
  case gatheringTimeout
  case negotiationFailed(String)

  var errorDescription: String? {
    switch self {
    case .notStreaming: return "Not streaming."
    case .badOffer: return "Bad offer."
    case .gatheringTimeout: return "ICE gathering timed out."
    case .negotiationFailed(let s): return "Negotiation failed: \(s)"
    }
  }
}

/// Owns the shared screen-share video source and one RTCPeerConnection per viewer.
/// Fed with CVPixelBuffers from the ScreenCaptureKit callback; file recording
/// keeps working alongside untouched.
final class WebRTCStreamer: NSObject, @unchecked Sendable {
  private let lock = NSLock()
  nonisolated(unsafe) private var factory: RTCPeerConnectionFactory?
  nonisolated(unsafe) private var videoSource: RTCVideoSource?
  nonisolated(unsafe) private var capturer: RTCVideoCapturer?
  nonisolated(unsafe) private var videoTrack: RTCVideoTrack?
  nonisolated(unsafe) private var peers: [RTCPeerConnection] = []
  nonisolated(unsafe) private var gatheringWaits:
    [ObjectIdentifier: CheckedContinuation<String, Error>] = [:]
  nonisolated(unsafe) private var statsTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]

  var viewerCount: Int {
    lock.withLock { peers.count }
  }

  // MARK: - Lifecycle

  func startStream() {
    stopStream()
    if factory == nil {
      RTCInitializeSSL()
      let encoder = RTCDefaultVideoEncoderFactory()
      let decoder = RTCDefaultVideoDecoderFactory()
      factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }
    guard let factory else { return }
    // ScreenCast source: tuned for screen content rather than camera video.
    let source = factory.videoSource(forScreenCast: true)
    let cap = RTCVideoCapturer(delegate: source)
    let track = factory.videoTrack(with: source, trackId: "screen0")
    lock.withLock {
      videoSource = source
      capturer = cap
      videoTrack = track
    }
    NSLog("[Glance] webrtc source ready")
  }

  func stopStream() {
    let (old, timers): ([RTCPeerConnection], [DispatchSourceTimer]) = lock.withLock {
      let p = peers
      peers = []
      gatheringWaits = [:] // FIXME
      let t = Array(statsTimers.values)
      statsTimers = [:]
      return (p, t)
    }
    for timer in timers { timer.cancel() }
    for pc in old { pc.close() }
    lock.withLock {
      videoSource = nil
      capturer = nil
      videoTrack = nil
    }
    NSLog("[Glance] webrtc stopped, closed %d peer(s)", old.count)
  }

  // MARK: - Frames in

  func push(pixelBuffer: CVPixelBuffer, timestampNs: Int64) {
    let source: RTCVideoSource? = lock.withLock { self.videoSource }
    let cap: RTCVideoCapturer? = lock.withLock { self.capturer }
    let hasViewers: Bool = lock.withLock { !self.peers.isEmpty }
    guard let source, let cap, hasViewers else { return }
    let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
    let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timestampNs)
    source.capturer(cap, didCapture: frame)
  }

  // MARK: - Viewers in (non-trickle: browser posts a full offer, gets a full answer)

  func answerOffer(sdp offerSdp: String) async throws -> String {
    let rtcFactory: RTCPeerConnectionFactory? = lock.withLock { self.factory }
    let track: RTCVideoTrack? = lock.withLock { self.videoTrack }
    guard let rtcFactory, let track else { throw StreamError.notStreaming }

    let config = RTCConfiguration()
    config.iceServers = []
    config.sdpSemantics = .unifiedPlan
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: nil as [String: String]?, optionalConstraints: nil as [String: String]?)
    guard
      let pc = rtcFactory.peerConnection(with: config, constraints: constraints, delegate: self)
    else { throw StreamError.negotiationFailed("peerConnection() returned nil") }
    if let sender = pc.add(track, streamIds: ["glance0"]) {
      // Best effort pre-negotiation; re-applied on connect when encodings exist.
      Self.applySenderParams(to: sender)
    }
    lock.withLock { peers.append(pc) }
    NSLog("[Glance] viewer connecting (%d total)", lock.withLock { peers.count })

    let offer = RTCSessionDescription(type: .offer, sdp: offerSdp)
    try await setRemote(pc, sdp: offer)
    let answer = try await makeAnswer(pc)
    try await setLocal(pc, sdp: answer)

    // Wait for our ICE gathering so the answer carries candidates.
    let rawSdp: String = try await withCheckedThrowingContinuation { cont in
      let id = ObjectIdentifier(pc)
      var resumeNow = false
      lock.withLock {
        if pc.iceGatheringState == .complete {
          resumeNow = true
        } else {
          gatheringWaits[id] = cont
        }
      }
      if resumeNow {
        cont.resume(returning: pc.localDescription?.sdp ?? "")
        return
      }
      // Timeout: exactly-once via removal.
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
        guard let self else { return }
        let pending: CheckedContinuation<String, Error>? = self.lock.withLock {
          self.gatheringWaits.removeValue(forKey: id)
        }
        if pending != nil {
          NSLog("[Glance] gathering timeout for a viewer")
          pending?.resume(throwing: StreamError.gatheringTimeout)
        }
      }
    }
    if let h264 = Self.preferH264(rawSdp) {
      NSLog("[Glance] negotiated H264 for viewer")
      return h264
    }
    NSLog("[Glance] WARNING: no H264 in answer, sending as-is")
    return rawSdp
  }

  /// Screen text needs bits and stable resolution: generous bitrate ceiling
  /// and degrade framerate — never resolution — under pressure. Must run once
  /// encodings exist (i.e. after negotiation), so it's applied on connect.
  nonisolated static func applySenderParams(to sender: RTCRtpSender) {
    if let encoding = sender.parameters.encodings.first {
      encoding.maxBitrateBps = 12_000_000 as NSNumber
      // A real floor, not a suggestion: loopback has infinite bandwidth, and
      // without this the allocator idles near zero and text turns to soup.
      encoding.minBitrateBps = 4_000_000 as NSNumber
      NSLog("[Glance] sender bitrate range applied (4-12 Mbps)")
    } else {
      NSLog("[Glance] WARNING: sender has no encodings yet, bitrate not applied")
    }
    sender.parameters.degradationPreference = NSNumber(
      value: RTCDegradationPreference.maintainResolution.rawValue)
  }

  nonisolated static func preferH264(_ sdp: String) -> String? {
    let lines = sdp.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: CharacterSet.newlines)
    }
    guard let mIndex = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return nil }

    func payload(of line: String, prefix: String) -> String? {
      guard line.hasPrefix(prefix) else { return nil }
      let rest = line.dropFirst(prefix.count)
      return rest.split(separator: " ").first.map(String.init)
    }

    var h264: Set<String> = []
    var apt: [String: String] = [:]  // fmtp PT -> apt target PT
    var fmtp: [String: String] = [:]  // fmtp PT -> params string
    for line in lines {
      if line.hasPrefix("a=rtpmap:"),
        let pt = payload(of: line, prefix: "a=rtpmap:"),
        line.uppercased().contains("H264/")
      {
        h264.insert(pt)
      } else if line.hasPrefix("a=fmtp:"),
        let pt = payload(of: line, prefix: "a=fmtp:")
      {
        fmtp[pt] = line
        // a=fmtp:97 apt=96;…
        for part in line.split(separator: ";") {
          let kv = part.split(separator: "=").map {
            String($0).trimmingCharacters(in: .whitespaces)
          }
          if kv.count == 2, kv[0].hasSuffix("apt") { apt[pt] = kv[1] }
        }
      }
    }
    guard !h264.isEmpty else { return nil }
    var keep = h264
    for (pt, target) in apt where h264.contains(target) { keep.insert(pt) }

    // Order H264 by profile so High wins: 64xx, then 4dxx, then 42exx, then rtx.
    func profileRank(_ pt: String) -> Int {
      guard let f = fmtp[pt], let r = f.range(of: "profile-level-id=") else { return 9 }
      let id = f[r.upperBound...].prefix(6).lowercased()
      if id.hasPrefix("64") { return 0 }
      if id.hasPrefix("4d") { return 1 }
      if id.hasPrefix("42") { return 2 }
      return 3
    }

    var out: [String] = []
    for (i, line) in lines.enumerated() {
      if i == mIndex {
        // m=video <port> <proto> <pts…>
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 3 else { return nil }
        let video = parts[3...].filter { h264.contains($0) }.sorted {
          profileRank($0) < profileRank($1)
        }
        let rtx = parts[3...].filter { keep.contains($0) && !h264.contains($0) }
        let pts = video + rtx
        guard !pts.isEmpty else { return nil }
        out.append(([parts[0], parts[1], parts[2]] + pts).joined(separator: " "))
        continue
      }
      if line.hasPrefix("a=rtpmap:") || line.hasPrefix("a=fmtp:")
        || line.hasPrefix("a=rtcp-fb:")
      {
        let pt =
          payload(of: line, prefix: "a=rtpmap:")
          ?? payload(of: line, prefix: "a=fmtp:")
          ?? payload(of: line, prefix: "a=rtcp-fb:")
        if let pt, !keep.contains(pt) { continue }
      }
      out.append(line)
    }
    return out.joined(separator: "\r\n")
  }

  private nonisolated func removePeer(_ pc: RTCPeerConnection) {
    let timer: DispatchSourceTimer? = lock.withLock {
      peers.removeAll { $0 === pc }
      if let cont = gatheringWaits.removeValue(forKey: ObjectIdentifier(pc)) {
        cont.resume(throwing: StreamError.negotiationFailed("connection lost"))
      }
      return statsTimers.removeValue(forKey: ObjectIdentifier(pc))
    }
    timer?.cancel()
  }

  /// Log encoder reality (codec, fps, bitrate, limit reason) every 5s per viewer.
  nonisolated private func startStats(for pc: RTCPeerConnection) {
    let id = ObjectIdentifier(pc)
    let old: DispatchSourceTimer? = lock.withLock {
      let previous = statsTimers[id]
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
      timer.schedule(deadline: .now() + 5, repeating: 5)
      var lastBytes: Int64 = -1
      var lastTime: TimeInterval = -1
      timer.setEventHandler { [weak pc] in
        guard let pc else { return }
        pc.statistics { report in
          let byId = report.statistics
          for (_, stats) in byId {
            guard stats.type == "outbound-rtp",
              (stats.values["kind"] as? String) == "video"
            else { continue }
            // mimeType lives on the codec report referenced by codecId.
            var mime = stats.values["mimeType"] as? String
            if mime == nil, let codecId = stats.values["codecId"] as? String {
              mime = byId[codecId]?.values["mimeType"] as? String
            }
            let fps = stats.values["framesPerSecond"] as? Double ?? -1
            let bytes = (stats.values["bytesSent"] as? NSNumber)?.int64Value ?? -1
            let now = Date().timeIntervalSince1970
            var mbps = -1.0
            if lastBytes >= 0, lastTime > 0, now > lastTime {
              mbps = Double(bytes - lastBytes) * 8 / (now - lastTime) / 1_000_000
            }
            lastBytes = bytes
            lastTime = now
            NSLog(
              "[Glance] webrtc out: %@ fps=%.1f mbps=%.2f limit=%@", mime ?? "?",
              fps, mbps,
              (stats.values["qualityLimitationReason"] as? String) ?? "?")
          }
        }
      }
      statsTimers[id] = timer
      timer.resume()
      return previous
    }
    old?.cancel()
  }

  // MARK: - Callback wrappers

  private func setRemote(_ pc: RTCPeerConnection, sdp: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      pc.setRemoteDescription(sdp) { error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      }
    }
  }

  private func makeAnswer(_ pc: RTCPeerConnection) async throws -> RTCSessionDescription {
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: nil as [String: String]?, optionalConstraints: nil as [String: String]?)
    return try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<RTCSessionDescription, Error>) in
      pc.answer(for: constraints) { sdp, error in
        if let sdp {
          cont.resume(returning: sdp)
        } else {
          cont.resume(throwing: error ?? StreamError.negotiationFailed("no answer"))
        }
      }
    }
  }

  private func setLocal(_ pc: RTCPeerConnection, sdp: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      pc.setLocalDescription(sdp) { error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      }
    }
  }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCStreamer: RTCPeerConnectionDelegate {
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
  ) {}

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream
  ) {}

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream
  ) {}

  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
  ) {
    NSLog("[Glance] ICE connection state: \(newState.rawValue)")
    if newState == .connected {
      startStats(for: peerConnection)
      // Encodings only exist post-negotiation: (re-)apply here for real.
      if let sender = peerConnection.senders.first(where: { $0.track?.kind == "video" }) {
        Self.applySenderParams(to: sender)
      }
    }
    if newState == .failed || newState == .closed {
      // Just drop our reference; dealloc tears down natively. Calling close()
      // here re-triggers this callback in a loop and ends in use-after-free.
      removePeer(peerConnection)
    }
  }

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
  ) {
    if newState == .complete {
      let cont: CheckedContinuation<String, Error>? = lock.withLock {
        gatheringWaits.removeValue(forKey: ObjectIdentifier(peerConnection))
      }
      cont?.resume(returning: peerConnection.localDescription?.sdp ?? "")
    }
  }

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate
  ) {
    // Non-trickle: candidates ride along in the gathered SDP. Ignore.
  }

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
  ) {}

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel
  ) {}
}
