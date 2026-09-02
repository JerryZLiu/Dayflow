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
  /// What the panel was showing before it hid, so we can pick the matching
  /// exit clip (wave goodbye, climb out of the tub, fly off on the plane).
  private var lastPresentation: FlowOverlayPresentation = .hidden

  private init() {}

  /// Call once at app launch; keeps the panel in sync with the mirror.
  func start() {
    cancellable = FlowSessionMirror.shared.$overlay
      .receive(on: DispatchQueue.main)
      .sink { [weak self] presentation in
        if presentation == .hidden {
          self?.hidePanel()
        } else {
          self?.lastPresentation = presentation
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

    // Let the creature leave in character before the panel fades.
    let exit = exitClip(for: lastPresentation)
    lastPresentation = .hidden
    guard let exit else {
      fadeOut(panel)
      return
    }
    FlowCreaturePlayer.shared.playOnce(exit) { [weak self] in
      // The overlay may have come back mid-exit (a new nudge); leave it up.
      guard FlowSessionMirror.shared.overlay == .hidden else { return }
      self?.panel.map { self?.fadeOut($0) }
    }
  }

  private func exitClip(for presentation: FlowOverlayPresentation) -> FlowCreatureClip? {
    switch presentation {
    case .hidden: return nil
    case .onBreak: return .bathEnd
    case .sessionEnded: return .exitPlane
    case .nudge(_, true): return .fireEnd
    case .toast, .nudge: return .randomExit
    }
  }

  private func fadeOut(_ panel: NSPanel) {
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
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
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
