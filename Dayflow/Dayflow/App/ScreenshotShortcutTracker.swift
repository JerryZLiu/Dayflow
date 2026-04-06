import AppKit

@MainActor
final class ScreenshotShortcutTracker {
  struct Match: Equatable {
    let shortcut: String
    let copiesToClipboard: Bool
  }

  static let shared = ScreenshotShortcutTracker()

  private var eventMonitor: Any?

  private init() {}

  func start() {
    guard eventMonitor == nil else { return }

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard NSApp.isActive else { return event }
      guard let match = Self.match(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
      else { return event }

      AnalyticsService.shared.capture(
        "screenshot_taken",
        [
          "source": "keyboard_shortcut_heuristic",
          "shortcut": match.shortcut,
          "copies_to_clipboard": match.copiesToClipboard,
        ])
      return event
    }
  }

  func stop() {
    guard let eventMonitor else { return }
    NSEvent.removeMonitor(eventMonitor)
    self.eventMonitor = nil
  }

  nonisolated static func match(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Match? {
    let relevantModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
    let requiredModifiers: NSEvent.ModifierFlags = [.command, .shift]

    guard relevantModifiers.contains(requiredModifiers) else { return nil }

    let allowedModifiers: NSEvent.ModifierFlags = [.command, .shift, .control]
    guard relevantModifiers.subtracting(allowedModifiers).isEmpty else { return nil }

    let shortcutSuffix: String
    switch keyCode {
    case 20:
      shortcutSuffix = "3"
    case 21:
      shortcutSuffix = "4"
    case 23:
      shortcutSuffix = "5"
    default:
      return nil
    }

    let copiesToClipboard = relevantModifiers.contains(.control)
    let shortcut =
      copiesToClipboard
      ? "cmd_shift_ctrl_\(shortcutSuffix)"
      : "cmd_shift_\(shortcutSuffix)"

    return Match(shortcut: shortcut, copiesToClipboard: copiesToClipboard)
  }
}
