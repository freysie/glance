import AppKit
import SwiftUI
import WebRTC

@main
struct GlanceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(AppState.shared)
        .environment(delegate)
    }
    .windowResizability(.contentSize)
  }
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let state = AppState.shared
  private let selection = SelectionController()
  private let recorder = ScreenRecorder()
  private let statusBar = StatusBarController()
  private let streamer = WebRTCStreamer()
  private let signaling = SignalingServer()
  @ObservationIgnored private var isStopping = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    signaling.statusProvider = { [weak self] requestedId in
      guard let self else { return StatusSnapshot(live: false, viewers: 0) }
      let live = self.state.phase == .recording && self.state.streamId == requestedId
      return StatusSnapshot(live: live, viewers: self.streamer.viewerCount)
    }
    signaling.onListenError = { [weak self] message in
      self?.state.signalingError =
        message
        + " Quit other Glance instances (or whatever holds :\(StreamPorts.api)) and relaunch."
    }
    signaling.onListening = { [weak self] in
      self?.state.signalingError = nil
    }
    signaling.onOffer = { [weak self] offer in
      guard let self else { return .noStream }
      guard
        self.state.phase == .recording, let current = self.state.streamId,
        current == offer.stream
      else { return .noStream }
      do {
        let answer = try await self.streamer.answerOffer(sdp: offer.sdp)
        NSLog(
          "[Glance] viewer joined stream %@ (%d total)", offer.stream,
          self.streamer.viewerCount)
        return .answer(sdp: answer)
      } catch {
        return .failure(error.localizedDescription)
      }
    }
    signaling.start()

    statusBar.setup()
    statusBar.onPrimaryAction = { [weak self] in
      guard let self else { return }
      if self.state.phase == .recording {
        Task { @MainActor in await self.stopRecording() }
      } else if self.state.phase != .selecting {
        // While selecting, the overlay covers the menu bar anyway.
        self.startSelection()
      }
    }
    statusBar.onStop = { [weak self] in Task { @MainActor in await self?.stopRecording() } }
    statusBar.onRecordAgain = { [weak self] in self?.startSelection() }
    statusBar.onReveal = { [weak self] in self?.revealLastRecording() }
    statusBar.onQuit = { NSApp.terminate(nil) }

    selection.onSelect = { [weak self] rect in
      Task { @MainActor in await self?.beginRecording(rect: rect) }
    }
    selection.onCancel = { [weak self] in
      self?.state.setIdle("Selection cancelled. Click Select Region to try again.")
      self?.refreshStatusItem()
    }

    recorder.onStreamError = { [weak self] error in
      Task { @MainActor in
        self?.streamer.stopStream()
        self?.recorder.onVideoFrame = nil
        self?.state.streamId = nil
        self?.state.setFailed(error.localizedDescription)
        self?.refreshStatusItem()
        self?.showWindow()
      }
    }

    // Give the app a moment to activate, then go straight to crosshair selection.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.startSelection()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  // MARK: - Flow

  func startSelection() {
    NSLog("[Glance] startSelection called, phase=%@", String(describing: state.phase))
    state.setSelecting()
    refreshStatusItem()
    showWindow()
    selection.show()
  }

  private func beginRecording(rect: CGRect) async {
    state.setRecording(rect: rect)
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    state.streamId = id
    // Fresh stream link on the pasteboard the moment the rect lands.
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      StreamPorts.pageURL(streamId: id).absoluteString, forType: .string)
    streamer.startStream()
    recorder.onVideoFrame = { [weak streamer] pixelBuffer, timestampNs in
      streamer?.push(pixelBuffer: pixelBuffer, timestampNs: timestampNs)
    }
    refreshStatusItem()
    // Get our window out of the way so it neither covers content nor steals focus.
    hideMainWindow()
    do {
      _ = try await recorder.start(region: rect)
      refreshStatusItem()
      NSLog("[Glance] live at %@", StreamPorts.pageURL(streamId: id).absoluteString)
    } catch {
      streamer.stopStream()
      recorder.onVideoFrame = nil
      state.streamId = nil
      handleStartFailure(error)
    }
  }

  func stopRecording() async {
    NSLog("[Glance] stopRecording called, phase=%@", String(describing: state.phase))
    guard !isStopping else { return }
    // Only stop when actually recording; menu is hidden otherwise anyway.
    guard state.phase == .recording else { return }
    isStopping = true
    defer { isStopping = false }
    if let url = await recorder.stop() {
      state.setFinished(url: url)
    } else if let err = recorder.lastWriterError {
      state.setFailed("Recording failed: \(err.localizedDescription)")
    } else {
      state.setIdle("Stopped — no video was captured (no frames arrived). Try again.")
    }
    streamer.stopStream()
    recorder.onVideoFrame = nil
    state.streamId = nil
    refreshStatusItem()
    showWindow()
    NSSound(named: "Glass")?.play()
  }

  private func handleStartFailure(_ error: Error) {
    let message: String
    if let scError = error as? RecorderError {
      message = scError.localizedDescription
    } else {
      message = error.localizedDescription
    }
    // Screen Recording permission denied surfaces as an SC error; point at Settings.
    if message.lowercased().contains("denied")
      || message.lowercased().contains("not authorized")
      || message.lowercased().contains("permission")
    {
      state.setFailed(
        "Screen Recording permission denied. Enable it in System Settings → Privacy & Security → Screen Recording, then Record Again."
      )
    } else {
      state.setFailed(message)
    }
    refreshStatusItem()
    showWindow()
  }

  private func revealLastRecording() {
    guard let url = state.recordingURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func showWindow() {
    NSApp.activate(ignoringOtherApps: true)
    for window in NSApp.windows where window.canBecomeKey && window.isVisible {
      window.makeKeyAndOrderFront(nil)
      return
    }
    // If the main window was closed, reopen it.
    for window in NSApp.windows where window.canBecomeKey {
      window.makeKeyAndOrderFront(nil)
      return
    }
  }

  private func hideMainWindow() {
    for window in NSApp.windows where window.isVisible && window.level < .screenSaver {
      window.orderOut(nil)
    }
  }

  private func refreshStatusItem() {
    switch state.phase {
    case .recording:
      statusBar.update(recording: true, canReveal: false)
    case .finished:
      statusBar.update(recording: false, canReveal: state.recordingURL != nil)
    default:
      statusBar.update(recording: false, canReveal: state.recordingURL != nil)
    }
  }
}
