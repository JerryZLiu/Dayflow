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

  var body: some View {
    HStack(spacing: 60) {
      // Left side - text and controls
      VStack(alignment: .leading, spacing: 24) {
        Text("Last step!")
          .font(.custom("Nunito", size: 20))
          .foregroundColor(.black.opacity(0.7))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 20)

        Text("Screen Recording")
          .font(.custom("Nunito", size: 32))
          .fontWeight(.bold)
          .foregroundColor(.black.opacity(0.9))

        Text(
          "Screen recordings are stored locally on your Mac and can be processed entirely on-device using local AI models."
        )
        .font(.custom("Nunito", size: 16))
        .foregroundColor(.black.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)

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
        .padding(.top, 8)

        // Action buttons
        Group {
          switch permissionState {
          case .notRequested:
            DayflowSurfaceButton(
              action: { requestPermission() },
              content: {
                HStack {
                  if isCheckingPermission {
                    ProgressView()
                      .scaleEffect(0.8)
                      .progressViewStyle(CircularProgressViewStyle())
                  }
                  Text(isCheckingPermission ? "Checking..." : "Grant Permission")
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.medium)
                }
              },
              background: Color(red: 0.25, green: 0.17, blue: 0),
              foreground: .white,
              borderColor: .clear,
              cornerRadius: 8,
              horizontalPadding: 24,
              verticalPadding: 12,
              showOverlayStroke: true
            )
            .disabled(isCheckingPermission)
          case .needsAction:
            HStack(spacing: 12) {
              DayflowSurfaceButton(
                action: openSystemSettings,
                content: {
                  Text("Open System Settings")
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.medium)
                },
                background: Color(red: 0.25, green: 0.17, blue: 0),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: true
              )
              DayflowSurfaceButton(
                action: quitAndReopen,
                content: {
                  Text("Quit & Reopen")
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.medium)
                },
                background: .white,
                foreground: Color(red: 0.25, green: 0.17, blue: 0),
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: true
              )
            }
          case .granted:
            EmptyView()
          }
        }
        .padding(.top, 16)

        // Navigation buttons
        HStack(spacing: 16) {
          DayflowSurfaceButton(
            action: onBack,
            content: { Text("Back").font(.custom("Nunito", size: 14)).fontWeight(.semibold) },
            background: .white,
            foreground: Color(red: 0.25, green: 0.17, blue: 0),
            borderColor: .clear,
            cornerRadius: 8,
            horizontalPadding: 20,
            verticalPadding: 12,
            minWidth: 120,
            isSecondaryStyle: true
          )
          DayflowSurfaceButton(
            action: {
              if permissionState == .granted {
                onNext()
              }
            },
            content: { Text("Next").font(.custom("Nunito", size: 14)).fontWeight(.semibold) },
            background: permissionState == .granted
              ? Color(red: 0.25, green: 0.17, blue: 0)
              : Color(red: 0.25, green: 0.17, blue: 0).opacity(0.3),
            foreground: permissionState == .granted ? .white : .white.opacity(0.5),
            borderColor: .clear,
            cornerRadius: 8,
            horizontalPadding: 20,
            verticalPadding: 12,
            minWidth: 120,
            showOverlayStroke: permissionState == .granted
          )
          .disabled(permissionState != .granted)
        }
        .padding(.top, 20)

        Spacer()
      }
      .frame(maxWidth: 400)

      // Right side - image
      if let image = NSImage(named: "ScreenRecordingPermissions") {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: 500)
          .cornerRadius(12)
          .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
      }
    }
    .padding(60)
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
