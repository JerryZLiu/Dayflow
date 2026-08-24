//
//  FlowOverlayController.swift
//  Dayflow
//
//  Owns the transparent, non-activating panel that shows the Flow creature at
//  the bottom-right of the screen (toasts, distraction nudges, break state).
//  Presentation decisions live in FlowSessionMirror; this just shows/hides.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class FlowOverlayController {
  static let shared = FlowOverlayController()

  private var panel: NSPanel?
  private var cancellable: AnyCancellable?

  private init() {}

  /// Call once at app launch; keeps the panel in sync with the mirror.
  func start() {
    cancellable = FlowSessionMirror.shared.$overlay
      .receive(on: DispatchQueue.main)
      .sink { [weak self] presentation in
        if presentation == .hidden {
          self?.hidePanel()
        } else {
          self?.showPanel()
        }
      }
  }

  private func showPanel() {
    if panel == nil {
      panel = makePanel()
    }
    guard let panel else { return }
    position(panel)
    if !panel.isVisible {
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        panel.animator().alphaValue = 1
      }
    }
  }

  private func hidePanel() {
    guard let panel, panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.2
        panel.animator().alphaValue = 0
      },
      completionHandler: {
        panel.orderOut(nil)
      })
  }

  private func makePanel() -> NSPanel {
    let panel = FlowOverlayPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false

    let hostingView = NSHostingView(rootView: FlowOverlayView())
    hostingView.frame = panel.contentRect(forFrameRect: panel.frame)
    hostingView.autoresizingMask = [.width, .height]
    // Never let SwiftUI's ideal size drive the window frame — without this the
    // panel collapses to the text's intrinsic width (a tall sliver).
    hostingView.sizingOptions = []
    panel.contentView = hostingView
    return panel
  }

  private func position(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    // Bottom-right, flush with the screen edge so the creature art clips at
    // the edge exactly like the Figma mock (it "peeks in" from offscreen).
    let origin = NSPoint(
      x: visible.maxX - size.width,
      y: visible.minY + 8
    )
    panel.setFrameOrigin(origin)
  }
}

/// Borderless panels refuse key status by default; keep it that way so
/// clicking a pill never steals focus from the app the user is working in.
private final class FlowOverlayPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
