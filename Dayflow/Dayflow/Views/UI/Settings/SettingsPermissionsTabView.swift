//
//  SettingsPermissionsTabView.swift
//  Dayflow
//
//  The macOS permissions Dayflow needs, with live state and the same
//  grant flow onboarding uses. Most existing users finished onboarding before
//  Accessibility was asked for, so this is where they can turn it on.
//

import SwiftUI

struct SettingsPermissionsTabView: View {
  @StateObject private var permissions = SystemPermissionsMonitor()

  var body: some View {
    SettingsSection(
      title: String(localized: "Permissions"),
      subtitle: String(
        localized: "macOS access Dayflow needs. These stay off until you turn them on.")
    ) {
      rows
    }
    .onAppear { permissions.start() }
    .onDisappear { permissions.stop() }
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 8) {
      accessibilityRow
      screenRecordingRow
      footnote
    }
  }

  private var accessibilityRow: some View {
    SystemPermissionRow(
      title: SystemPermission.accessibility.title,
      detail:
        "Know which app you're in, so cards are labeled right — and so Dayflow can hide private browsing windows.",
      isGranted: permissions.accessibilityGranted,
      onGrant: { permissions.grantAccessibility() }
    )
  }

  private var screenRecordingRow: some View {
    // macOS usually applies Screen Recording only after a relaunch, which is
    // what Quit and Reopen is for. Accessibility applies immediately, so its
    // row never offers it.
    SystemPermissionRow(
      title: SystemPermission.screenRecording.title,
      detail: "Periodic screenshots let Dayflow write your timeline for you.",
      isGranted: permissions.screenRecordingGranted,
      onGrant: { permissions.grantScreenRecording() },
      onQuitAndReopen: permissions.screenRecordingRequested
        ? { permissions.quitAndReopen() } : nil
    )
  }

  private var footnote: some View {
    Text(
      "Screen Recording usually needs Dayflow to restart before macOS applies it. Accessibility takes effect right away."
    )
    .font(.custom("Figtree", size: 12))
    .foregroundColor(SettingsStyle.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.top, 4)
  }
}

#Preview("Permissions") {
  SettingsPermissionsTabView()
    .frame(width: 560)
    .padding()
}
