import Combine
import CoreGraphics
import Foundation

/// Shared UI state between SwiftUI, the selection overlay, the recorder and the status item.
@MainActor
final class AppState: ObservableObject {
  enum Phase: Equatable {
    case idle
    case selecting
    case recording
    case finished
    case failed
  }

  static let shared = AppState()

  @Published var phase: Phase = .idle
  @Published var statusMessage: String = "Starting…"
  @Published var recordingURL: URL?
  @Published var errorMessage: String?
  @Published var recordingStart: Date?
  @Published var selectionRect: CGRect = .zero
  @Published var streamId: String?
  @Published var signalingError: String?

  func setSelecting() {
    phase = .selecting
    statusMessage = "Drag a rectangle on screen to capture. Esc cancels."
    errorMessage = nil
    recordingURL = nil
  }

  func setRecording(rect: CGRect) {
    phase = .recording
    selectionRect = rect
    recordingStart = Date()
    statusMessage = "Recording…"
    errorMessage = nil
  }

  func setFinished(url: URL) {
    phase = .finished
    recordingURL = url
    recordingStart = nil
    statusMessage = "Saved."
    errorMessage = nil
  }

  func setIdle(_ message: String = "Ready.") {
    phase = .idle
    statusMessage = message
    recordingStart = nil
    errorMessage = nil
  }

  func setFailed(_ message: String) {
    phase = .failed
    errorMessage = message
    statusMessage = "Failed."
    recordingStart = nil
  }
}
