import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            // Set initial icon based on current recording state
            let isRecording = AppState.shared.isRecording
            button.image = NSImage(named: isRecording ? "MenuBarOnIcon" : "MenuBarOffIcon")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        // Observe recording state changes and update icon
        AppState.shared.$isRecording
            .removeDuplicates()
            .sink { [weak self] isRecording in
                self?.updateDisplay(isRecording: isRecording)
            }
            .store(in: &cancellables)

        // Observe productivity score changes
        AppState.shared.$productivityScore
            .combineLatest(AppState.shared.$hasProductivityData)
            .sink { [weak self] score, hasData in
                self?.updateDisplay(score: score, hasData: hasData)
            }
            .store(in: &cancellables)
    }

    private func updateDisplay(isRecording: Bool? = nil, score: Int? = nil, hasData: Bool? = nil) {
        guard let button = statusItem.button else { return }

        // Update icon if recording state changed
        if let isRecording = isRecording {
            button.image = NSImage(named: isRecording ? "MenuBarOnIcon" : "MenuBarOffIcon")
        }

        // Update productivity score if provided
        let currentScore = score ?? AppState.shared.productivityScore
        let currentHasData = hasData ?? AppState.shared.hasProductivityData

        if currentHasData {
            let color: NSColor
            if currentScore >= 70 {
                color = NSColor(red: 0.30, green: 0.69, blue: 0.31, alpha: 1.0) // Green
            } else if currentScore >= 60 {
                color = NSColor(red: 0.95, green: 0.52, blue: 0.29, alpha: 1.0) // Orange
            } else {
                color = NSColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1.0) // Red
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: color
            ]
            button.attributedTitle = NSAttributedString(string: " \(currentScore)", attributes: attributes)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
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
