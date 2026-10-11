import AppKit
import Combine
import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var state
  @Environment(AppDelegate.self) var delegate
  @State private var now = Date()
  private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Circle()
          .fill(dotColor)
          .frame(width: 10, height: 10)
        Text(title)
          .font(.headline)
      }

      if let error = state.signalingError {
        Text(error)
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text(state.statusMessage)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if state.phase == .recording, let start = state.recordingStart {
        Text(
          "Elapsed \(elapsed(since: start)) — \(Int(state.selectionRect.width)) × \(Int(state.selectionRect.height)) pt"
        )
        .font(.callout.monospacedDigit())

        if let id = state.streamId {
          Link(destination: StreamPorts.pageURL(streamId: id)) {
            Text(verbatim: "Open stream: http://localhost:\(StreamPorts.page)/?stream=\(id)")
          }
          .font(.callout)

          HStack(spacing: 8) {
            Button("Copy Link") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(
                StreamPorts.pageURL(streamId: id).absoluteString, forType: .string)
            }
            .buttonStyle(.link)
          }

          Text(verbatim: "Serve the page first: python3 -m http.server \(StreamPorts.page) --directory Web")
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
        }

        Text("Tip: Click the red dot in the menu bar to stop.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let url = state.recordingURL, state.phase == .finished {
        Text(url.path(percentEncoded: false))
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }

      if let error = state.errorMessage, state.phase == .failed {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        switch state.phase {
        case .selecting:
          Text("Waiting for drag…")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .recording:
          Button("Stop Recording") {
            Task { await delegate.stopRecording() }
          }
          .keyboardShortcut(".", modifiers: .command)
          .buttonStyle(.borderedProminent)
        case .finished:
          Button("Show in Finder") {
            if let url = state.recordingURL {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          }
          Button("Record Again") {
            delegate.startSelection()
          }
        case .failed, .idle:
          Button("Select Region") {
            delegate.startSelection()
          }
          .buttonStyle(.borderedProminent)
          if state.phase == .failed {
            Button("Open Screen Recording Settings") {
              NSWorkspace.shared.open(
                URL(
                  string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
              )
            }
          }
        }
      }
    }
    .padding(20)
    .frame(minWidth: 380, minHeight: 180)
    .onReceive(timer) { now = $0 }
  }

  private var title: String {
    switch state.phase {
    case .idle: return "Glance"
    case .selecting: return "Select a Region"
    case .recording: return "Recording"
    case .finished: return "Saved"
    case .failed: return "Something Failed"
    }
  }

  private var dotColor: Color {
    switch state.phase {
    case .recording: return .red
    case .failed: return .orange
    case .finished: return .green
    default: return .gray
    }
  }

  private func elapsed(since start: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}
