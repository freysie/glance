import AppKit

// TODO: make right-click menu function like system menu extras (right mouse down, not up), or remove it

/// Menu-bar item visible while the app runs.
/// Left-click performs the primary action (stop while recording, otherwise
/// start selecting). Right-click (or Ctrl-click) shows a small menu.
@MainActor
final class StatusBarController {
  var onPrimaryAction: (() -> Void)?
  var onStop: (() -> Void)?
  var onRecordAgain: (() -> Void)?
  var onReveal: (() -> Void)?
  var onQuit: (() -> Void)?

  private var item: NSStatusItem?
  private let menu = NSMenu()
  private var stopItem: NSMenuItem!
  private var revealItem: NSMenuItem!

  func setup() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.item = item

    if let button = item.button {
      button.target = self
      button.action = #selector(clicked)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    let stop = NSMenuItem(
      title: "Stop Recording", action: #selector(stopPressed), keyEquivalent: "")
    stop.target = self
    stopItem = stop

    let reveal = NSMenuItem(
      title: "Show in Finder", action: #selector(revealPressed), keyEquivalent: "")
    reveal.target = self
    revealItem = reveal

    let again = NSMenuItem(
      title: "Record Again", action: #selector(againPressed), keyEquivalent: "")
    again.target = self

    let quit = NSMenuItem(title: "Quit Glance", action: #selector(quitPressed), keyEquivalent: "q")
    quit.target = self

    menu.addItem(stop)
    menu.addItem(reveal)
    menu.addItem(again)
    menu.addItem(.separator())
    menu.addItem(quit)

    update(recording: false, canReveal: false)
  }

  /// - recording: red recording dot.
  /// - canReveal: enables "Show in Finder".
  func update(recording: Bool, canReveal: Bool) {
    stopItem?.isHidden = !recording
    revealItem?.isEnabled = canReveal
    guard let button = item?.button else { return }
    // Hand-drawn icons: the idle ring is a template image (auto-adapts to
    // light/dark menu bars), the recording dot is solid red (visible on both).
    if recording {
      button.image = statusImage(filled: true, color: .systemRed, template: false)
    } else {
      button.image = statusImage(filled: false, color: .black, template: true)
    }
    button.title = ""
    button.contentTintColor = nil
  }

  private func statusImage(filled: Bool, color: NSColor, template: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
      let diameter: CGFloat = 11
      let dot = NSRect(
        x: rect.midX - diameter / 2,
        y: rect.midY - diameter / 2,
        width: diameter,
        height: diameter)
      color.set()
      let path = NSBezierPath(ovalIn: dot)
      if filled {
        path.fill()
      } else {
        path.lineWidth = 2
        path.stroke()
      }
      return true
    }
    image.isTemplate = template
    return image
  }

  @objc private func clicked() {
    guard let event = NSApp.currentEvent else {
      onPrimaryAction?()
      return
    }
    if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
      showMenu()
    } else {
      onPrimaryAction?()
    }
  }

  private func showMenu() {
    guard let button = item?.button else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
  }

  @objc private func stopPressed() {
    NSLog("[Glance] Stop pressed in menu")
    onStop?()
  }
  @objc private func revealPressed() { onReveal?() }
  @objc private func againPressed() { onRecordAgain?() }
  @objc private func quitPressed() { onQuit?() }
}
