import AppKit
import SwiftUI
import Combine

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
            // Set initial icon based on current recording state
            let isRecording = AppState.shared.isRecording
            button.image = NSImage(named: isRecording ? "MenuBarOnIcon" : "MenuBarOffIcon")
            button.imagePosition = .imageOnly
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
        statusItem.button?.image = NSImage(named: isRecording ? "MenuBarOnIcon" : "MenuBarOffIcon")
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
