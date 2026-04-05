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

struct ScreenRecordingPermissionView: View {
  var onBack: () -> Void
  var onNext: () -> Void

  @State private var permissionState: PermissionState = .notRequested
  @State private var isCheckingPermission = false
  @State private var initiatedFlow = false

  enum PermissionState {
    case notRequested
    case granted
    case needsAction  // requested or settings opened, awaiting quit & reopen / toggle
  }

  private let brownAccent = Color(hex: "492304")
  private let privacyTextColor = Color(hex: "89380E")

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      HStack(alignment: .top, spacing: 60) {
        // Left side — text and controls
        VStack(alignment: .leading, spacing: 10) {
          Text("Last step!")
            .font(.custom("Nunito-Bold", size: 16))
            .foregroundColor(Color(hex: "F96E00"))

          Text("Permission")
            .font(.custom("InstrumentSerif-Regular", size: 28))
            .foregroundColor(.black)

          Text("Dayflow can help understand your day.")
            .font(.custom("Nunito-Medium", size: 14))
            .foregroundColor(Color(hex: "5B5B5B"))
            .fixedSize(horizontal: false, vertical: true)

          // Privacy info box
          VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "shield.fill")
                .font(.system(size: 14))
                .foregroundColor(privacyTextColor)
              Text("Dayflow is built to be private and secure.")
                .font(.custom("Nunito-Bold", size: 14))
                .foregroundColor(privacyTextColor)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(
              "Dayflow stores all recordings locally on your Mac, and can process everything privately on your device using local AI models."
            )
            .font(.custom("Nunito-Medium", size: 14))
            .foregroundColor(privacyTextColor)

            Text("You are always in control — you can pause or turn off Dayflow whenever you like.")
              .font(.custom("Nunito-Medium", size: 14))
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

          // State-based messaging
          Group {
            switch permissionState {
            case .notRequested:
              EmptyView()
            case .granted:
              Text("✓ Permission granted! Click Next to continue.")
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.green)
            case .needsAction:
              Text("Turn on Screen Recording for Dayflow, then quit and reopen the app to finish.")
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.orange)
            }
          }

          // Action buttons
          Group {
            switch permissionState {
            case .notRequested:
              Button(action: requestPermission) {
                HStack(spacing: 6) {
                  if isCheckingPermission {
                    ProgressView()
                      .scaleEffect(0.7)
                      .progressViewStyle(CircularProgressViewStyle())
                  }
                  Text(isCheckingPermission ? "Checking..." : "Open System Settings")
                    .font(.custom("Nunito-SemiBold", size: 12))
                    .tracking(-0.48)
                    .foregroundColor(brownAccent)
                }
                .padding(12)
              }
              .buttonStyle(.plain)
              .background(
                LinearGradient(
                  stops: [
                    .init(
                      color: Color(red: 1, green: 0.773, blue: 0.341).opacity(0.7), location: 0.73),
                    .init(
                      color: Color(red: 1, green: 0.98, blue: 0.945).opacity(0), location: 0.99),
                  ],
                  startPoint: UnitPoint(x: 0.7, y: 1),
                  endPoint: UnitPoint(x: 0.3, y: 0)
                )
                .background(Color.white.opacity(0.69))
              )
              .cornerRadius(6)
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(Color(hex: "FFBC80"), lineWidth: 1)
              )
              .disabled(isCheckingPermission)
            case .needsAction:
              HStack {
                Spacer(minLength: 0)

                HStack(spacing: 12) {
                  Button(action: openSystemSettings) {
                    Text("Open System Settings")
                      .font(.custom("Nunito-SemiBold", size: 12))
                      .tracking(-0.48)
                      .foregroundColor(brownAccent)
                      .padding(12)
                  }
                  .buttonStyle(.plain)
                  .background(
                    LinearGradient(
                      stops: [
                        .init(
                          color: Color(red: 1, green: 0.773, blue: 0.341).opacity(0.7),
                          location: 0.73
                        ),
                        .init(
                          color: Color(red: 1, green: 0.98, blue: 0.945).opacity(0),
                          location: 0.99),
                      ],
                      startPoint: UnitPoint(x: 0.7, y: 1),
                      endPoint: UnitPoint(x: 0.3, y: 0)
                    )
                    .background(Color.white.opacity(0.69))
                  )
                  .cornerRadius(6)
                  .overlay(
                    RoundedRectangle(cornerRadius: 6)
                      .stroke(Color(hex: "FFBC80"), lineWidth: 1)
                  )

                  Button(action: quitAndReopen) {
                    Text("Quit & Reopen")
                      .font(.custom("Nunito-SemiBold", size: 12))
                      .tracking(-0.48)
                      .foregroundColor(brownAccent)
                      .padding(12)
                  }
                  .buttonStyle(.plain)
                  .background(Color.white.opacity(0.69))
                  .cornerRadius(6)
                  .overlay(
                    RoundedRectangle(cornerRadius: 6)
                      .stroke(Color(hex: "FFBC80"), lineWidth: 1)
                  )
                }
              }
            case .granted:
              EmptyView()
            }
          }

          Spacer()
        }
        .frame(maxWidth: 374)

        Spacer()

        // Right side - image
        if let image = NSImage(named: "ScreenRecordingPermissions") {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 486)
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

      // Navigation buttons — bottom right
      HStack(spacing: 15) {
        DayflowSurfaceButton(
          action: onBack,
          content: { Text("Back").font(.custom("Nunito-Medium", size: 12)).tracking(-0.48) },
          background: .white,
          foreground: Color(hex: "B6B6B6"),
          borderColor: Color(hex: "B6B6B6"),
          cornerRadius: 4,
          horizontalPadding: 40,
          verticalPadding: 12,
          isSecondaryStyle: true
        )
        DayflowSurfaceButton(
          action: {
            if permissionState == .granted { onNext() }
          },
          content: { Text("Next").font(.custom("Nunito-Medium", size: 12)).tracking(-0.48) },
          background: permissionState == .granted
            ? Color(hex: "402B00")
            : Color(hex: "402B00").opacity(0.3),
          foreground: .white,
          borderColor: .clear,
          cornerRadius: 4,
          horizontalPadding: 40,
          verticalPadding: 12,
          showOverlayStroke: permissionState == .granted
        )
        .disabled(permissionState != .granted)
      }
    }
    .padding(.leading, 105)
    .padding(.trailing, 60)
    .padding(.top, 30)
    .padding(.bottom, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      // If already granted, mark as granted; otherwise start in notRequested
      if CGPreflightScreenCaptureAccess() {
        permissionState = .granted
        Task { @MainActor in AppDelegate.allowTermination = false }
      } else {
        permissionState = .notRequested
        Task { @MainActor in AppDelegate.allowTermination = true }
      }
    }
    // Re-check when app becomes active again (e.g., returning from System Settings)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      // Only transition to granted here; avoid flipping notChecked to denied automatically
      if CGPreflightScreenCaptureAccess() {
        permissionState = .granted
        Task { @MainActor in AppDelegate.allowTermination = false }
      }
    }
    .onDisappear {
      Task { @MainActor in AppDelegate.allowTermination = false }
    }
  }

  private func requestPermission() {
    guard !isCheckingPermission else { return }
    isCheckingPermission = true
    initiatedFlow = true

    // This will prompt and register the app with TCC; may return false
    _ = CGRequestScreenCaptureAccess()
    if CGPreflightScreenCaptureAccess() {
      permissionState = .granted
      AnalyticsService.shared.capture("screen_permission_granted")
      Task { @MainActor in AppDelegate.allowTermination = false }
    } else {
      permissionState = .needsAction
      AnalyticsService.shared.capture("screen_permission_denied")
      Task { @MainActor in AppDelegate.allowTermination = true }
    }
    isCheckingPermission = false
  }

  private func openSystemSettings() {
    initiatedFlow = true
    Task { @MainActor in AppDelegate.allowTermination = true }
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      _ = NSWorkspace.shared.open(url)
    }
    // Move to needsAction so we show Quit & Reopen guidance
    if permissionState != .granted { permissionState = .needsAction }
  }

  private func quitAndReopen() {
    Task { @MainActor in
      AppDelegate.allowTermination = true
      NSApp.terminate(nil)
    }
  }
}
