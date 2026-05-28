import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private var cancellable: AnyCancellable?

  override init() {
    super.init()
    popover.behavior = .transient
    popover.animates = true

    if let button = statusItem.button {
      button.imageScaling = .scaleProportionallyDown
      button.imagePosition = .imageOnly

      let isRecording = AppState.shared.isRecording
      button.image = menuBarIcon(isRecording: isRecording)
      button.target = self
      button.action = #selector(togglePopover(_:))
    }

    // Observe recording state changes and update icon
    cancellable = AppState.shared.$isRecording
      .removeDuplicates()
      .sink { [weak self] isRecording in
        self?.updateIcon(isRecording: isRecording)
      }
  }

  private func updateIcon(isRecording: Bool) {
    statusItem.button?.image = menuBarIcon(isRecording: isRecording)
  }

  private func menuBarIcon(isRecording: Bool) -> NSImage? {
    let name = isRecording ? "MenuBarOnIcon" : "MenuBarOffIcon"
    guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
    image.size = NSSize(width: 22, height: 18)
    return image
  }

  @objc private func togglePopover(_ sender: Any?) {
    if popover.isShown {
      popover.performClose(sender)
    } else {
      showPopover()
    }
  }

  private func showPopover() {
    guard let button = statusItem.button else { return }
    popover.contentSize = NSSize(width: 220, height: 200)
    popover.contentViewController = NSHostingController(
      rootView: StatusMenuView(dismissMenu: { [weak self] in
        self?.popover.performClose(nil)
      })
    )
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }
}
