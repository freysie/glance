import AppKit

private final class SelectionWindow: NSWindow {
  // This is needed for NSView cursor rects to work.
  override var canBecomeKey: Bool { true }
}

/// Transparent full-screen overlay (one window per display) for drag-selecting
/// a region. The rect is reported in Cocoa global screen coordinates
/// (bottom-left origin).
@MainActor
final class SelectionController {
  var onSelect: ((CGRect) -> Void)?
  var onCancel: (() -> Void)?

  private var windows: [NSWindow] = []
  private var didPushCursor = false
  private var finished = false

  func show() {
    hide()
    finished = false

    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }

    for screen in screens {
      let view = SelectionView()
      view.controller = self

      // One window sized to exactly this display's frame — never a union rect.
      let window = SelectionWindow(
        contentRect: screen.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
      )
      window.contentView = view
      window.backgroundColor = .clear
      window.isOpaque = false
      window.hasShadow = false
      window.level = .screenSaver
      window.ignoresMouseEvents = false
      window.acceptsMouseMovedEvents = true
      window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
      window.isReleasedWhenClosed = false
      window.animationBehavior = .none
      windows.append(window)
      window.orderFrontRegardless()
      NSLog(
        "[Glance] overlay window for screen %@ frame %@",
        String(describing: screen.localizedName), NSStringFromRect(screen.frame))
    }

    windows.first?.makeKey()
    NSApp.activate(ignoringOtherApps: true)
  }

  func hide() {
    for window in windows {
      window.orderOut(nil)
    }
    windows = []
  }

  fileprivate func finish(with rect: CGRect) {
    guard !finished else { return }
    finished = true
    let standardized = rect.standardized
    hide()
    if standardized.width < 5 || standardized.height < 5 {
      onCancel?()
    } else {
      onSelect?(standardized)
    }
  }

  fileprivate func cancel() {
    guard !finished else { return }
    finished = true
    hide()
    onCancel?()
  }
}

private final class SelectionView: NSView {
  weak var controller: SelectionController?
  private var startScreenPoint: NSPoint?
  private var currentScreenPoint: NSPoint?

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
    startScreenPoint = screenPoint(for: event)
    currentScreenPoint = startScreenPoint
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    currentScreenPoint = screenPoint(for: event)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let start = startScreenPoint else { return }
    let end = screenPoint(for: event)
    startScreenPoint = nil
    currentScreenPoint = nil
    needsDisplay = true
    controller?.finish(
      with: CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(start.x - end.x),
        height: abs(start.y - end.y)
      ))
  }

  override func rightMouseDown(with event: NSEvent) {
    startScreenPoint = nil
    currentScreenPoint = nil
    controller?.cancel()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {  // Esc
      controller?.cancel()
    } else {
      super.keyDown(with: event)
    }
  }

  private func screenPoint(for event: NSEvent) -> NSPoint {
    guard let window else { return .zero }
    // locationInWindow may lie outside our bounds when the drag crosses
    // displays; adding our origin still yields correct global coordinates.
    let loc = event.locationInWindow
    return NSPoint(x: window.frame.origin.x + loc.x, y: window.frame.origin.y + loc.y)
  }
  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    // No dimming on purpose: the screen stays untouched, only the rubber band shows.

    guard
      let start = startScreenPoint,
      let current = currentScreenPoint,
      let window
    else {
      return
    }

    let selectionScreen = CGRect(
      x: min(start.x, current.x),
      y: min(start.y, current.y),
      width: abs(start.x - current.x),
      height: abs(start.y - current.y)
    )
    // Convert global screen coords to view coords.
    let selectionView = CGRect(
      x: selectionScreen.minX - window.frame.origin.x,
      y: selectionScreen.minY - window.frame.origin.y,
      width: selectionScreen.width,
      height: selectionScreen.height
    )

    // Dark under-stroke so the rect reads on light backgrounds, white on top.
    NSColor.black.withAlphaComponent(0.5).setStroke()
    let under = NSBezierPath(rect: selectionView)
    under.lineWidth = 3
    under.stroke()

    NSColor.white.setStroke()
    let border = NSBezierPath(rect: selectionView)
    border.lineWidth = 1.5
    border.stroke()

    // Size label.
    let label = "\(Int(selectionScreen.width)) × \(Int(selectionScreen.height))"
    drawLabel(label, near: selectionView)
  }

  private func drawLabel(_ text: String, near rect: NSRect) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
      .backgroundColor: NSColor.black.withAlphaComponent(0.7),
    ]
    let size = (text as NSString).size(withAttributes: attrs)
    var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
    if origin.y + size.height > bounds.maxY - 8 {
      origin.y = rect.minY - size.height - 6
    }
    (text as NSString).draw(at: origin, withAttributes: attrs)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .crosshair)
  }
}
