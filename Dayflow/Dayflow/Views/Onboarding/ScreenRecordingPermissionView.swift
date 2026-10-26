//
//  ScreenRecordingPermissionView.swift
//  Dayflow
//
//  Screen recording permission request using idiomatic ScreenCaptureKit approach
//

import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

private struct LeftColumnSizeKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}

struct ScreenRecordingPermissionView: View {
  var onBack: () -> Void
  var onNext: () -> Void

  @State private var screenRecordingGranted = false
  @State private var accessibilityGranted = false
  /// Set once the user has clicked Grant for screen recording, so the row can
  /// offer Quit and Reopen (macOS often needs a relaunch before it applies).
  @State private var screenRecordingRequested = false
  @State private var leftColumnSize: CGSize = .zero

  /// Re-checks both permissions while the user is over in System Settings.
  private let permissionPoll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  private var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

  private let brownAccent = Color(hex: "492304")
  private let privacyTextColor = Color(hex: "89380E")

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .bottomTrailing) {
        content(size: geo.size)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onPreferenceChange(LeftColumnSizeKey.self) { leftColumnSize = $0 }
    }
    .onAppear {
      screenRecordingGranted = SystemPermission.screenRecording.isGranted
      accessibilityGranted = SystemPermission.accessibility.isGranted
      if screenRecordingGranted {
        Task { @MainActor in AppDelegate.allowTermination = false }
      } else {
        Task { @MainActor in AppDelegate.permitTermination(reason: "screen_permission_step") }
      }
    }
    .onReceive(permissionPoll) { _ in
      refreshPermissions()
    }
    .onDisappear {
      PermissionHelperPanelController.shared.hide()
      Task { @MainActor in AppDelegate.allowTermination = false }
    }
  }

  // Margins and column gap scale with window size (12 : 7 : 11 ratio from the design mock);
  // the image never grows taller than the left column, extra space flows into the gaps
  private func layoutMetrics(size: CGSize) -> (
    leading: CGFloat, gap: CGFloat, trailing: CGFloat, imageWidth: CGFloat, imageHeight: CGFloat
  ) {
    let aspect: CGFloat = {
      if let img = NSImage(named: "ScreenRecordingPermissions"), img.size.height > 0 {
        return img.size.width / img.size.height
      }
      return 4.0 / 3.0
    }()
    let leftW = leftColumnSize.width > 0 ? leftColumnSize.width : min(374, size.width * 0.4)
    var imgW = max(0, size.width * 0.70 - leftW)
    var imgH = imgW / aspect
    // Match the left column's height (fallback ≈ its natural height before measurement lands)
    let columnHeight = leftColumnSize.height > 0 ? leftColumnSize.height : 300
    let heightCap = min(max(0, size.height - 70), columnHeight)
    if imgH > heightCap {
      imgH = heightCap
      imgW = imgH * aspect
    }
    let free = max(0, size.width - leftW - imgW)
    return (free * 12 / 30, free * 7 / 30, free * 11 / 30, imgW, imgH)
  }

  @ViewBuilder
  private func content(size: CGSize) -> some View {
    let metrics = layoutMetrics(size: size)
    HStack(alignment: .center, spacing: metrics.gap) {
      // Left side — text and controls
      VStack(alignment: .leading, spacing: 10) {
        Text("Last step!")
          .font(.custom("Figtree-Bold", size: 16))
          .foregroundColor(Color(hex: "F96E00"))

        Text("Permissions")
          .font(.custom("InstrumentSerif-Regular", size: 28))
          .foregroundColor(.black)

        Text("Dayflow can help understand your day.")
          .font(.custom("Figtree-Medium", size: 14))
          .foregroundColor(Color(hex: "5B5B5B"))
          .fixedSize(horizontal: false, vertical: true)

        // Privacy info box
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.fill")
              .font(.system(size: 14))
              .foregroundColor(privacyTextColor)
            Text("Dayflow is built to be private and secure.")
              .font(.custom("Figtree-Bold", size: 14))
              .foregroundColor(privacyTextColor)
              .fixedSize(horizontal: false, vertical: true)
          }

          Text(
            "Dayflow stores all recordings locally on your Mac, and can process everything privately on your device using local AI models."
          )
          .font(.custom("Figtree-Medium", size: 14))
          .foregroundColor(privacyTextColor)

          Text("You are always in control. You can pause or turn off Dayflow whenever you like.")
            .font(.custom("Figtree-Medium", size: 14))
            .foregroundColor(privacyTextColor)
        }
        .padding(16)
        .frame(maxWidth: 351, alignment: .leading)
        .background(Color.white.opacity(0.3))
        .cornerRadius(5)
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .stroke(Color(red: 0.8, green: 0.278, blue: 0).opacity(0.15), lineWidth: 1)
        )
        .shadow(
          color: Color(red: 0.725, green: 0.608, blue: 0.482).opacity(0.3), radius: 4, x: 0, y: 0)

        // One row per permission. Accessibility comes first because it applies
        // right away; Screen Recording usually needs a relaunch, so it goes last.
        VStack(spacing: 8) {
          permissionRow(
            title: SystemPermission.accessibility.title,
            detail: "Know which app you're in, so cards are labeled right.",
            isGranted: accessibilityGranted,
            isEnabled: true,
            onGrant: grantAccessibility,
            onQuitAndReopen: nil
          )
          permissionRow(
            title: SystemPermission.screenRecording.title,
            detail: "Periodic screenshots let Dayflow write your timeline for you.",
            isGranted: screenRecordingGranted,
            isEnabled: accessibilityGranted,
            onGrant: grantScreenRecording,
            onQuitAndReopen: screenRecordingRequested ? quitAndReopen : nil
          )
        }
        .frame(maxWidth: 351)
      }
      .frame(maxWidth: 374)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: LeftColumnSizeKey.self, value: proxy.size)
        }
      )

      // Right side - image
      if let image = NSImage(named: "ScreenRecordingPermissions") {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: metrics.imageWidth, height: metrics.imageHeight)
          .background(Color(hex: "FCFCFC"))
          .cornerRadius(8)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color(hex: "F0F0F0"), lineWidth: 1)
          )
          .shadow(
            color: Color(red: 0.725, green: 0.608, blue: 0.482).opacity(0.25), radius: 3, x: 0,
            y: 2)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.leading, metrics.leading)
    .padding(.trailing, metrics.trailing)
    .padding(.top, 30)
    .padding(.bottom, 40)

    // Navigation buttons — bottom right
    HStack(spacing: 15) {
      DayflowSurfaceButton(
        action: onBack,
        content: { Text("Back").font(.custom("Figtree-Medium", size: 14)).tracking(-0.48) },
        background: .white,
        foreground: Color(hex: "B6B6B6"),
        borderColor: Color(hex: "B6B6B6"),
        cornerRadius: 200,
        horizontalPadding: 32,
        verticalPadding: 0,
        fixedHeight: 44,
        showShadow: false
      )
      DayflowSurfaceButton(
        action: {
          if allGranted { onNext() }
        },
        content: {
          HStack(spacing: 6) {
            Text("Next").font(.custom("Figtree-Medium", size: 14)).tracking(-0.48)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
          }
          .padding(.leading, 4)
        },
        background: allGranted
          ? Color(hex: "FF9F6F")
          : Color(hex: "FF9F6F").opacity(0.3),
        foreground: .white,
        borderColor: Color(hex: "F4C8B1"),
        cornerRadius: 200,
        horizontalPadding: 32,
        verticalPadding: 0,
        fixedHeight: 44,
        showOverlayStroke: false,
        innerGlowColor: Color(hex: "FFDCCB").opacity(0.9)
      )
      .disabled(!allGranted)
    }
    .padding(.trailing, 60)
    .padding(.bottom, 40)
  }

  private func permissionRow(
    title: String,
    detail: LocalizedStringKey,
    isGranted: Bool,
    isEnabled: Bool,
    onGrant: @escaping () -> Void,
    onQuitAndReopen: (() -> Void)?
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.custom("Figtree-Bold", size: 14))
          .foregroundColor(.black)
        Text(detail)
          .font(.custom("Figtree-Medium", size: 12))
          .foregroundColor(Color(hex: "5B5B5B"))
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

          if let onQuitAndReopen {
            Button(action: onQuitAndReopen) {
              Text("Quit and Reopen")
                .font(.custom("Figtree-Medium", size: 11))
                .foregroundColor(brownAccent.opacity(0.7))
                .underline()
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .padding(12)
    .background(Color.white.opacity(0.5))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(hex: "E8DDD5"), lineWidth: 1)
    )
    // Waiting on the row above: fade it so it reads as the next step.
    .opacity(isEnabled || isGranted ? 1 : 0.5)
    .animation(.easeInOut(duration: 0.2), value: isEnabled)
  }

  private func refreshPermissions() {
    let screenNow = SystemPermission.screenRecording.isGranted
    if screenNow && !screenRecordingGranted {
      AnalyticsService.shared.capture("screen_permission_granted")
      Task { @MainActor in AppDelegate.allowTermination = false }
    }
    screenRecordingGranted = screenNow

    let accessibilityNow = SystemPermission.accessibility.isGranted
    if accessibilityNow && !accessibilityGranted {
      AnalyticsService.shared.capture("accessibility_permission_granted")
    }
    accessibilityGranted = accessibilityNow
  }

  private func grantScreenRecording() {
    screenRecordingRequested = true
    Task { @MainActor in AppDelegate.permitTermination(reason: "screen_permission_step") }
    // Adds Dayflow to the Screen Recording list (switched off) so the user
    // only has to flip the switch, even if they never drag the icon across.
    _ = CGRequestScreenCaptureAccess()
    if SystemPermission.screenRecording.isGranted {
      refreshPermissions()
      return
    }
    PermissionHelperPanelController.shared.show(for: .screenRecording)
  }

  private func grantAccessibility() {
    PermissionHelperPanelController.shared.show(for: .accessibility)
  }

  private func quitAndReopen() {
    Task { @MainActor in
      scheduleRelaunch()
      AppDelegate.permitTermination(reason: "screen_permission_quit_and_reopen")
      NSApp.terminate(nil)
    }
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
