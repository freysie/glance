import CoreGraphics
import Foundation
import Observation

/// Shared UI state between SwiftUI, the selection overlay, the recorder and the status item.
@MainActor
@Observable
final class AppState {
  enum Phase: Equatable {
    case idle
    case selecting
    case recording
    case finished
    case failed
  }

  static let shared = AppState()

  var phase: Phase = .idle
  var statusMessage: String? = "Starting…"
  var recordingURL: URL?
  var errorMessage: String?
  var recordingStart: Date?
  var selectionRect: CGRect = .zero
  var streamId: String?
  var signalingError: String?

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
    statusMessage = nil
    errorMessage = nil
  }

  func setFinished(url: URL) {
    phase = .finished
    recordingURL = url
    recordingStart = nil
    statusMessage = nil
    errorMessage = nil
  }

  func setIdle(_ message: String? = nil) {
    phase = .idle
    statusMessage = message
    recordingStart = nil
    errorMessage = nil
  }

  func setFailed(_ message: String) {
    phase = .failed
    errorMessage = message
    statusMessage = nil
    recordingStart = nil
  }
}
