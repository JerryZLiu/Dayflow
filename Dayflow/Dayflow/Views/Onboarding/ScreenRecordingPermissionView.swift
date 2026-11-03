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

  /// Shared with Settings, so the two permission surfaces can't drift apart.
  @StateObject private var permissions = SystemPermissionsMonitor()
  @State private var leftColumnSize: CGSize = .zero

  private var accessibilityGranted: Bool { permissions.accessibilityGranted }
  private var screenRecordingGranted: Bool { permissions.screenRecordingGranted }
  private var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

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
      permissions.start()
      if screenRecordingGranted {
        AppDelegate.allowTermination = false
      } else {
        AppDelegate.permitTermination(reason: "screen_permission_step")
      }
    }
    .onChange(of: screenRecordingGranted) { _, granted in
      if granted { AppDelegate.allowTermination = false }
    }
    .onDisappear {
      permissions.stop()
      AppDelegate.allowTermination = false
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
        permissionRows
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

  private var permissionRows: some View {
    VStack(spacing: 8) {
      SystemPermissionRow(
        title: SystemPermission.accessibility.title,
        detail: "Know which app you're in, so cards are labeled right.",
        isGranted: accessibilityGranted,
        onGrant: { permissions.grantAccessibility() }
      )
      SystemPermissionRow(
        title: SystemPermission.screenRecording.title,
        detail: "Periodic screenshots let Dayflow write your timeline for you.",
        isGranted: screenRecordingGranted,
        isEnabled: accessibilityGranted,
        onGrant: grantScreenRecording,
        onQuitAndReopen: permissions.screenRecordingRequested
          ? { permissions.quitAndReopen() } : nil
      )
    }
  }

  private func grantScreenRecording() {
    AppDelegate.permitTermination(reason: "screen_permission_step")
    permissions.grantScreenRecording()
  }
}
