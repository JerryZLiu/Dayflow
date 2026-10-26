//
//  PermissionHelperPanel.swift
//  Dayflow
//
//  A small floating panel that sits next to System Settings while the user
//  grants a permission. It shows the Dayflow icon, which the user can drag
//  straight into the Settings list, and closes itself once access is on.
//

import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// The macOS permissions onboarding walks the user through.
enum SystemPermission: String {
  case screenRecording = "screen_recording"
  case accessibility

  var title: String {
    switch self {
    case .screenRecording: return String(localized: "Screen Recording")
    case .accessibility: return String(localized: "Accessibility")
    }
  }

  var isGranted: Bool {
    switch self {
    case .screenRecording: return CGPreflightScreenCaptureAccess()
    case .accessibility: return AXIsProcessTrusted()
    }
  }

  private var settingsURL: URL? {
    switch self {
    case .screenRecording:
      return URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    case .accessibility:
      return URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
  }

  func openSystemSettings() {
    guard let settingsURL else { return }
    NSWorkspace.shared.open(settingsURL)
  }
}

@MainActor
final class PermissionHelperPanelController: ObservableObject {
  static let shared = PermissionHelperPanelController()

  /// What the panel is helping with right now; drives the panel's text.
  @Published private(set) var permission: SystemPermission = .screenRecording
  @Published private(set) var isGranted = false

  private var panel: NSPanel?
  private var timer: Timer?
  /// Set once the panel has found System Settings and moved next to it, so
  /// the first move animates and later ones just follow the window.
  private var hasSnappedToSettings = false
  /// When `show` started waiting for System Settings to open, or nil once
  /// the panel is on screen. The panel stays hidden while this is set, so it
  /// appears already docked instead of jumping across the screen.
  private var waitingForSettingsSince: Date?

  /// Where the draggable icon sits inside the panel (top-left origin), as
  /// reported by the SwiftUI view; the drag hint starts from here.
  var iconFrameInPanel: CGRect = .zero
  /// A click-through window that shows a faded icon gliding from the panel
  /// into the Settings list, so the user sees where to drag.
  private var hintWindow: NSPanel?
  /// The faded icon plus a grabbing-hand cursor on top, moved and faded as one.
  private var hintView: NSView?
  private var lastHintStart: Date?
  /// The hint stops for good once the user drags the real icon.
  private var userHasDragged = false
  /// Bumped whenever the hint is cancelled, so a running animation's
  /// completion handlers know to stop.
  private var hintGeneration = 0

  private static let systemSettingsBundleID = "com.apple.systempreferences"
  private static let gapFromSettings: CGFloat = 12
  private static let hintIconSize: CGFloat = 72
  /// Time from the start of one hint to the start of the next.
  private static let hintInterval: TimeInterval = 2.8
  /// How often to look for System Settings while waiting for it to open.
  private static let waitingPollInterval: TimeInterval = 0.1
  /// How often to check for access and follow the Settings window once the
  /// panel is up.
  private static let shownPollInterval: TimeInterval = 0.5
  /// If System Settings hasn't shown a window by then, show the panel on
  /// its own rather than keep the user waiting.
  private static let maxWaitForSettings: TimeInterval = 2

  private init() {}

  /// Opens System Settings on the permission's page and shows the panel
  /// beside it once its window is on screen.
  func show(for permission: SystemPermission) {
    self.permission = permission
    isGranted = permission.isGranted
    hasSnappedToSettings = false
    userHasDragged = false
    lastHintStart = nil
    cancelHint()

    permission.openSystemSettings()

    if panel == nil {
      panel = makePanel()
    }
    guard let panel else { return }
    resizeToFit(panel)

    if panel.isVisible {
      // Already up (possibly mid fade-out from a previous permission); bring
      // it back and let the timer keep it docked.
      panel.alphaValue = 1
      waitingForSettingsSince = nil
      startTimer(interval: Self.shownPollInterval)
    } else {
      waitingForSettingsSince = Date()
      startTimer(interval: Self.waitingPollInterval)
    }
    AnalyticsService.shared.capture(
      "permission_helper_opened", ["permission": permission.rawValue])
  }

  func hide() {
    stopTimer()
    cancelHint()
    waitingForSettingsSince = nil
    guard let panel, panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.2
        panel.animator().alphaValue = 0
      },
      completionHandler: {
        // Skip if show() brought the panel back during the fade.
        guard panel.alphaValue < 0.01 else { return }
        panel.orderOut(nil)
      })
  }

  // MARK: - Polling

  /// Each tick: check whether access was turned on, and keep the panel
  /// docked next to System Settings if the user moves that window.
  private func startTimer(interval: TimeInterval) {
    stopTimer()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.tick()
      }
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard let panel else { return }

    if !isGranted && permission.isGranted {
      isGranted = true
      AnalyticsService.shared.capture(
        "permission_helper_granted", ["permission": permission.rawValue])
      // Leave the "Granted" state up for a moment so the user sees it worked.
      stopTimer()
      cancelHint()
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.isGranted else { return }
          self.hide()
        }
      }
      return
    }

    if let waitingForSettingsSince {
      showWhenSettingsAppears(panel, waitingSince: waitingForSettingsSince)
      return
    }

    dockNextToSettings(panel)
    playHintIfDue(panel)
  }

  /// Fades the panel in already docked once System Settings has a window, or
  /// at the fallback spot if Settings takes too long.
  private func showWhenSettingsAppears(_ panel: NSPanel, waitingSince: Date) {
    if let settingsFrame = systemSettingsWindowFrame() {
      panel.setFrameOrigin(dockedOrigin(for: panel.frame.size, settingsFrame: settingsFrame))
      hasSnappedToSettings = true
    } else if Date().timeIntervalSince(waitingSince) >= Self.maxWaitForSettings {
      placeBeforeSettingsAppears(panel)
    } else {
      return
    }

    waitingForSettingsSince = nil
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      panel.animator().alphaValue = 1
    }
    startTimer(interval: Self.shownPollInterval)
  }

  // MARK: - Drag hint

  /// Called by the panel view when the user starts dragging the real icon.
  func userStartedDrag() {
    userHasDragged = true
    cancelHint()
  }

  private func playHintIfDue(_ panel: NSPanel) {
    guard hasSnappedToSettings, !userHasDragged, iconFrameInPanel != .zero else { return }
    if let lastHintStart, Date().timeIntervalSince(lastHintStart) < Self.hintInterval { return }
    guard let settingsFrame = systemSettingsWindowFrame() else { return }

    // From the middle of the panel's icon to the app list in the right half
    // of System Settings.
    let start = NSPoint(
      x: panel.frame.minX + iconFrameInPanel.midX,
      y: panel.frame.maxY - iconFrameInPanel.midY)
    let end = NSPoint(
      x: settingsFrame.minX + settingsFrame.width * 0.62,
      y: settingsFrame.maxY - settingsFrame.height * 0.35)

    lastHintStart = Date()
    playHint(from: start, to: end)
  }

  private func playHint(from start: NSPoint, to end: NSPoint) {
    let size = Self.hintIconSize
    let area = NSRect(
      x: min(start.x, end.x) - size,
      y: min(start.y, end.y) - size,
      width: abs(end.x - start.x) + size * 2,
      height: abs(end.y - start.y) + size * 2)

    if hintWindow == nil {
      makeHintWindow()
    }
    guard let hintWindow, let hintView else { return }
    hintWindow.setFrame(area, display: false)

    // Positions inside the hint window, centred on the icon.
    let startOrigin = NSPoint(x: start.x - area.minX - size / 2, y: start.y - area.minY - size / 2)
    let endOrigin = NSPoint(x: end.x - area.minX - size / 2, y: end.y - area.minY - size / 2)
    hintView.setFrameOrigin(startOrigin)
    hintView.alphaValue = 0
    hintWindow.orderFrontRegardless()

    let generation = hintGeneration
    // Fade in on top of the real icon, glide across, then fade out.
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.25
        hintView.animator().alphaValue = 1
      },
      completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          guard let self, generation == self.hintGeneration else { return }
          NSAnimationContext.runAnimationGroup(
            { context in
              context.duration = 1.0
              context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
              hintView.animator().setFrameOrigin(endOrigin)
            },
            completionHandler: { [weak self] in
              MainActor.assumeIsolated {
                guard let self, generation == self.hintGeneration else { return }
                NSAnimationContext.runAnimationGroup(
                  { context in
                    context.duration = 0.3
                    hintView.animator().alphaValue = 0
                  },
                  completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                      guard let self, generation == self.hintGeneration else { return }
                      self.hintWindow?.orderOut(nil)
                    }
                  })
              }
            })
        }
      })
  }

  private func cancelHint() {
    hintGeneration += 1
    hintView?.alphaValue = 0
    hintWindow?.orderOut(nil)
  }

  private func makeHintWindow() {
    let window = PermissionHelperPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .floating
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.hidesOnDeactivate = false
    window.isReleasedWhenClosed = false

    let contentView = NSView()
    let size = Self.hintIconSize
    let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    container.wantsLayer = true

    // The icon stays see-through so it reads as a hint, but the cursor is
    // drawn solid, so it looks like the icon is being carried.
    let iconView = NSImageView(frame: container.bounds)
    iconView.image = NSApp.applicationIconImage
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.alphaValue = 0.6
    container.addSubview(iconView)

    let cursorImage = NSCursor.closedHand.image
    let cursorView = NSImageView(
      frame: NSRect(
        x: (size - cursorImage.size.width) / 2 + 4,
        y: (size - cursorImage.size.height) / 2 - 4,
        width: cursorImage.size.width,
        height: cursorImage.size.height))
    cursorView.image = cursorImage
    container.addSubview(cursorView)

    contentView.addSubview(container)
    window.contentView = contentView

    hintWindow = window
    hintView = container
  }

  // MARK: - Positioning

  /// Used when System Settings is slow to open: the screen's left side,
  /// where it will most likely be out of the way.
  private func placeBeforeSettingsAppears(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    panel.setFrameOrigin(
      NSPoint(x: visible.minX + 40, y: visible.midY - size.height / 2))
  }

  private func dockNextToSettings(_ panel: NSPanel) {
    // Never move while the mouse is down: the user may be dragging the icon
    // out of the panel, or dragging the Settings window (we catch up after).
    guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
    guard let settingsFrame = systemSettingsWindowFrame() else { return }
    let target = dockedOrigin(for: panel.frame.size, settingsFrame: settingsFrame)
    let current = panel.frame.origin
    guard abs(current.x - target.x) > 1 || abs(current.y - target.y) > 1 else { return }

    if hasSnappedToSettings {
      panel.setFrameOrigin(target)
    } else {
      // Only reached when Settings opened after the fallback timeout, so the
      // panel glides over from its fallback spot instead of jumping.
      hasSnappedToSettings = true
      panel.setFrame(NSRect(origin: target, size: panel.frame.size), display: true, animate: true)
    }
  }

  /// To the left of System Settings if there's room, otherwise to the right,
  /// otherwise overlapping its sidebar. Top edges line up a little below the
  /// Settings title bar.
  private func dockedOrigin(for size: CGSize, settingsFrame: CGRect) -> NSPoint {
    let visible =
      NSScreen.screens.first { $0.frame.intersects(settingsFrame) }?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? settingsFrame

    let gap = Self.gapFromSettings
    var x: CGFloat
    if settingsFrame.minX - gap - size.width >= visible.minX {
      x = settingsFrame.minX - gap - size.width
    } else if settingsFrame.maxX + gap + size.width <= visible.maxX {
      x = settingsFrame.maxX + gap
    } else {
      x = settingsFrame.minX + 16
    }
    x = min(max(x, visible.minX), visible.maxX - size.width)

    var y = settingsFrame.maxY - 60 - size.height
    y = min(max(y, visible.minY), visible.maxY - size.height)
    return NSPoint(x: x, y: y)
  }

  /// The frame of the main System Settings window, in AppKit screen
  /// coordinates. Reading window bounds needs no extra permission.
  private func systemSettingsWindowFrame() -> CGRect? {
    let settingsPIDs = Set(
      NSRunningApplication.runningApplications(withBundleIdentifier: Self.systemSettingsBundleID)
        .map(\.processIdentifier))
    guard !settingsPIDs.isEmpty else { return nil }

    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }

    let frames: [CGRect] = windows.compactMap { info in
      guard
        let pid = info[kCGWindowOwnerPID as String] as? pid_t,
        settingsPIDs.contains(pid),
        let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
        let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDict),
        bounds.width > 200, bounds.height > 200
      else { return nil }
      return bounds
    }
    // The biggest one is the main window; small ones are sheets or popovers.
    guard let cgFrame = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
      return nil
    }

    // Window bounds use a top-left origin on the primary screen; AppKit
    // uses bottom-left.
    guard let primaryScreen = NSScreen.screens.first else { return nil }
    return CGRect(
      x: cgFrame.minX,
      y: primaryScreen.frame.maxY - cgFrame.maxY,
      width: cgFrame.width,
      height: cgFrame.height)
  }

  // MARK: - Panel

  private func makePanel() -> NSPanel {
    let panel = PermissionHelperPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false

    let hostingView = NSHostingView(rootView: PermissionHelperView(controller: self))
    hostingView.sizingOptions = []
    panel.contentView = hostingView
    return panel
  }

  private func resizeToFit(_ panel: NSPanel) {
    guard let contentView = panel.contentView else { return }
    panel.setContentSize(contentView.fittingSize)
  }
}

/// Never takes focus, so System Settings stays the active app while the
/// user drags the icon across.
private final class PermissionHelperPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// MARK: - Panel content

private struct PermissionHelperView: View {
  @ObservedObject var controller: PermissionHelperPanelController

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Grant \(controller.permission.title)")
          .font(.custom("Figtree-Bold", size: 14))
          .foregroundColor(.black)
        Spacer()
        Button(action: { controller.hide() }) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(hex: "9A9A9A"))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      draggableIcon
        .frame(maxWidth: .infinity)

      if controller.isGranted {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
          Text("Granted")
        }
        .font(.custom("Figtree-SemiBold", size: 14))
        .foregroundColor(Color(hex: "2E9E5B"))
        .frame(maxWidth: .infinity)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          step(1, "Drag the Dayflow icon into the list in System Settings.")
          step(2, "Turn on the switch next to Dayflow.")
        }
      }
    }
    .padding(18)
    .frame(width: 280)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(Color.white)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color(hex: "F0E2D8"), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
    // Room for the shadow inside the transparent panel.
    .padding(24)
    .animation(.easeInOut(duration: 0.2), value: controller.isGranted)
  }

  /// Dragging this hands System Settings the app bundle's file URL, the
  /// same as dragging Dayflow.app from Finder.
  private var draggableIcon: some View {
    VStack(spacing: 6) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 72, height: 72)
        .background(
          GeometryReader { proxy in
            Color.clear
              .onAppear { controller.iconFrameInPanel = proxy.frame(in: .global) }
              .onChange(of: proxy.frame(in: .global)) { _, frame in
                controller.iconFrameInPanel = frame
              }
          }
        )
        .onDrag {
          controller.userStartedDrag()
          return NSItemProvider(object: Bundle.main.bundleURL as NSURL)
        }
        .help("Drag into the list in System Settings")
      Text("Dayflow")
        .font(.custom("Figtree-Medium", size: 12))
        .foregroundColor(Color(hex: "5B5B5B"))
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(hex: "FFF6F0"))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          Color(hex: "FFC9A8"), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    )
  }

  private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text("\(number)")
        .font(.custom("Figtree-Bold", size: 11))
        .foregroundColor(Color(hex: "492304"))
        .frame(width: 18, height: 18)
        .background(Circle().fill(Color(hex: "FFC9A8")))
      Text(text)
        .font(.custom("Figtree-Medium", size: 13))
        .foregroundColor(Color(hex: "5B5B5B"))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
