//
//  MiniTimerWindowController.swift
//  Dayflow
//
//  Manages the floating, always‑on‑top focus timer panel. Non‑activating so it
//  never steals focus, joins all Spaces (incl. fullscreen), and is draggable.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class MiniTimerWindowController: NSObject, ObservableObject {
  static let shared = MiniTimerWindowController()

  /// Source of truth for whether the timer is on screen (drives menu/settings UI).
  @Published private(set) var isVisible = false

  private var panel: NSPanel?
  private var moveObserver: NSObjectProtocol?

  private override init() {
    super.init()
  }

  /// Show the panel if the user previously enabled it.
  func restoreIfEnabled() {
    if ProductivityPreferences.miniTimerEnabled {
      show(persist: false)
    }
  }

  func toggle() {
    isVisible ? hide() : show()
  }

  func setVisible(_ visible: Bool) {
    visible ? show() : hide()
  }

  func show(persist: Bool = true) {
    if persist { ProductivityPreferences.miniTimerEnabled = true }

    if let panel {
      panel.orderFrontRegardless()
      isVisible = true
      return
    }

    // Fixed-size hosting view. Do NOT use NSHostingController.sizingOptions /
    // auto-sizing here: combined with a borderless movable panel it drove
    // AppKit's constraint engine into infinite recursion (stack overflow).
    let size = MiniTimerView.windowSize
    let hosting = NSHostingView(
      rootView: MiniTimerView(onClose: { [weak self] in self?.hide() }))
    hosting.frame = NSRect(origin: .zero, size: size)

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false  // the SwiftUI capsule draws its own shadow
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    // Dayflow runs as a menu-bar (.accessory) app when the Dock icon is off.
    // Accessory apps hide ALL their windows when not frontmost; canHide = false
    // is the lever that keeps this panel on screen regardless of app focus.
    panel.canHide = false
    panel.contentView = hosting

    positionPanel(panel, size: size)
    panel.orderFrontRegardless()

    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification,
      object: panel,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.saveOrigin() }
    }

    self.panel = panel
    isVisible = true
  }

  func hide() {
    ProductivityPreferences.miniTimerEnabled = false
    if let moveObserver {
      NotificationCenter.default.removeObserver(moveObserver)
      self.moveObserver = nil
    }
    panel?.orderOut(nil)
    panel = nil
    isVisible = false
  }

  // MARK: - Positioning

  private func positionPanel(_ panel: NSPanel, size: NSSize) {
    if let saved = ProductivityPreferences.miniTimerOrigin,
      isOriginOnScreen(saved, size: size)
    {
      panel.setFrameOrigin(saved)
      return
    }

    // Default: top‑right of the main screen, just below the menu bar.
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let origin = CGPoint(
      x: screen.maxX - size.width - 24,
      y: screen.maxY - size.height - 24)
    panel.setFrameOrigin(origin)
  }

  private func isOriginOnScreen(_ origin: CGPoint, size: NSSize) -> Bool {
    let frame = CGRect(origin: origin, size: size)
    return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
  }

  private func saveOrigin() {
    guard let panel else { return }
    ProductivityPreferences.miniTimerOrigin = panel.frame.origin
  }
}
