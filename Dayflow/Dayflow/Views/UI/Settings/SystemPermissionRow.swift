//
//  SystemPermissionRow.swift
//  Dayflow
//
//  The permission card used by onboarding and by Settings. Onboarding owns the
//  visual design; Settings reuses it verbatim so the two can't drift apart.
//

import AppKit
import CoreGraphics
import SwiftUI

/// A single permission as a card: title, one explaining line, and either a
/// green "Granted" check or a peach "Grant" capsule, with an optional
/// "Quit and Reopen" link underneath for permissions macOS only applies
/// after a relaunch.
struct SystemPermissionRow: View {
  let title: String
  let detail: LocalizedStringKey
  let isGranted: Bool
  var isEnabled: Bool = true
  let onGrant: () -> Void
  var onQuitAndReopen: (() -> Void)? = nil

  // Spelled out because the synthesized memberwise initializer is private:
  // the private color constants below drag its access level down with them.
  init(
    title: String,
    detail: LocalizedStringKey,
    isGranted: Bool,
    isEnabled: Bool = true,
    onGrant: @escaping () -> Void,
    onQuitAndReopen: (() -> Void)? = nil
  ) {
    self.title = title
    self.detail = detail
    self.isGranted = isGranted
    self.isEnabled = isEnabled
    self.onGrant = onGrant
    self.onQuitAndReopen = onQuitAndReopen
  }

  private let brownAccent = Color(hex: "492304")

  // Light values are the onboarding design, pixel for pixel. Dark variants
  // exist only so the same card stays legible on the Settings surface, which
  // follows the system appearance.
  private let surface = Color.dayflowAdaptive(
    light: NSColor.white.withAlphaComponent(0.5),
    dark: NSColor.white.withAlphaComponent(0.06))
  private let border = Color.dayflowAdaptive(
    light: NSColor(red: 0.91, green: 0.867, blue: 0.835, alpha: 1),
    dark: NSColor.white.withAlphaComponent(0.12))
  private let titleColor = Color.dayflowAdaptive(
    light: .black,
    dark: NSColor.white.withAlphaComponent(0.92))
  private let detailColor = Color.dayflowAdaptive(
    light: NSColor(white: 0.357, alpha: 1),
    dark: NSColor.white.withAlphaComponent(0.6))

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.custom("Figtree-Bold", size: 14))
          .foregroundColor(titleColor)
        Text(detail)
          .font(.custom("Figtree-Medium", size: 12))
          .foregroundColor(detailColor)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)

      if isGranted {
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill")
          Text("Granted")
        }
        .font(.custom("Figtree-SemiBold", size: 12))
        .foregroundColor(Color(hex: "2E9E5B"))
      } else {
        VStack(alignment: .trailing, spacing: 4) {
          Button(action: onGrant) {
            Text("Grant")
              .font(.custom("Figtree-SemiBold", size: 12))
              .tracking(-0.48)
              .foregroundColor(brownAccent)
              .padding(.horizontal, 14)
              .frame(height: 30)
          }
          .buttonStyle(.plain)
          .background(Capsule().fill(Color(hex: "FFC9A8")))
          .disabled(!isEnabled)
          .pointingHandCursor()

          if let onQuitAndReopen {
            Button(action: onQuitAndReopen) {
              Text("Quit and Reopen")
                .font(.custom("Figtree-Medium", size: 11))
                .foregroundColor(brownAccent.opacity(0.7))
                .underline()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
          }
        }
      }
    }
    .padding(12)
    .background(surface)
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(border, lineWidth: 1)
    )
    // Waiting on the row above: fade it so it reads as the next step.
    .opacity(isEnabled || isGranted ? 1 : 0.5)
    .animation(.easeInOut(duration: 0.2), value: isEnabled)
  }
}

/// Watches the two permissions Dayflow needs and re-checks them twice a second
/// while the user is over in System Settings, so a row flips to "Granted" on
/// its own. Also owns the Grant actions, which open the helper panel.
@MainActor
final class SystemPermissionsMonitor: ObservableObject {
  @Published private(set) var accessibilityGranted: Bool
  @Published private(set) var screenRecordingGranted: Bool
  /// Set once the user has clicked Grant for screen recording, so the row can
  /// offer Quit and Reopen (macOS often needs a relaunch before it applies).
  @Published private(set) var screenRecordingRequested = false

  private var timer: Timer?

  init() {
    accessibilityGranted = SystemPermission.accessibility.isGranted
    screenRecordingGranted = SystemPermission.screenRecording.isGranted
  }

  deinit {
    timer?.invalidate()
  }

  func start() {
    refresh()
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Stops polling and closes the helper panel. Call from `onDisappear`.
  func stop() {
    timer?.invalidate()
    timer = nil
    PermissionHelperPanelController.shared.hide()
  }

  func refresh() {
    let screenNow = SystemPermission.screenRecording.isGranted
    if screenNow && !screenRecordingGranted {
      AnalyticsService.shared.capture("screen_permission_granted")
    }
    screenRecordingGranted = screenNow

    let accessibilityNow = SystemPermission.accessibility.isGranted
    if accessibilityNow && !accessibilityGranted {
      AnalyticsService.shared.capture("accessibility_permission_granted")
    }
    accessibilityGranted = accessibilityNow
  }

  /// Accessibility applies immediately — no relaunch needed.
  func grantAccessibility() {
    PermissionHelperPanelController.shared.show(for: .accessibility)
  }

  func grantScreenRecording() {
    screenRecordingRequested = true
    // Adds Dayflow to the Screen Recording list (switched off) so the user
    // only has to flip the switch, even if they never drag the icon across.
    _ = CGRequestScreenCaptureAccess()
    if SystemPermission.screenRecording.isGranted {
      refresh()
      return
    }
    PermissionHelperPanelController.shared.show(for: .screenRecording)
  }

  func quitAndReopen() {
    scheduleRelaunch()
    AppDelegate.permitTermination(reason: "permission_quit_and_reopen")
    NSApp.terminate(nil)
  }

  /// Starts a small shell script that waits for this process to exit, then opens
  /// the app again. The short pause lets macOS finish forgetting the old copy, so `open`
  /// starts a new one. Gives up after about 30 seconds if the app never quits.
  private func scheduleRelaunch() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let bundlePath = Bundle.main.bundlePath
    let script = """
      for i in $(seq 1 150); do
        kill -0 \(pid) 2>/dev/null || { sleep 0.5; /usr/bin/open "$1"; exit 0; }
        sleep 0.2
      done
      """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script, "relaunch", bundlePath]
    try? process.run()
  }
}
