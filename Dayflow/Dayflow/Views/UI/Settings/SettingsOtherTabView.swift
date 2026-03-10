import AppKit
import SwiftUI

struct SettingsOtherTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
  @FocusState private var isOutputLanguageFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      SettingsCard(title: "App preferences", subtitle: "General toggles and telemetry settings") {
        VStack(alignment: .leading, spacing: 14) {
          Toggle(
            isOn: Binding(
              get: { launchAtLoginManager.isEnabled },
              set: { launchAtLoginManager.setEnabled($0) }
            )
          ) {
            Text("Launch Dayflow at login")
              .font(.custom("Nunito", size: 13))
              .foregroundColor(.black.opacity(0.7))
          }
          .toggleStyle(.switch)
          .pointingHandCursor()

          Text(
            "Keeps the menu bar controller running right after you sign in so capture can resume instantly."
          )
          .font(.custom("Nunito", size: 11.5))
          .foregroundColor(.black.opacity(0.5))

          Toggle(isOn: $viewModel.analyticsEnabled) {
            Text("Share crash reports and anonymous usage data")
              .font(.custom("Nunito", size: 13))
              .foregroundColor(.black.opacity(0.7))
          }
          .toggleStyle(.switch)
          .pointingHandCursor()

          Toggle(isOn: $viewModel.showDockIcon) {
            Text("Show Dock icon")
              .font(.custom("Nunito", size: 13))
              .foregroundColor(.black.opacity(0.7))
          }
          .toggleStyle(.switch)
          .pointingHandCursor()

          Text("When off, Dayflow runs as a menu bar-only app.")
            .font(.custom("Nunito", size: 11.5))
            .foregroundColor(.black.opacity(0.5))

          Toggle(isOn: $viewModel.showTimelineAppIcons) {
            Text("Show app/website icons in timeline")
              .font(.custom("Nunito", size: 13))
              .foregroundColor(.black.opacity(0.7))
          }
          .toggleStyle(.switch)
          .pointingHandCursor()

          Text("When off, timeline cards won't show app or website icons.")
            .font(.custom("Nunito", size: 11.5))
            .foregroundColor(.black.opacity(0.5))

          notificationPermissionSection

          VStack(alignment: .leading, spacing: 8) {
            Text("Output language override")
              .font(.custom("Nunito", size: 13))
              .foregroundColor(.black.opacity(0.7))
            HStack(spacing: 10) {
              TextField("English", text: $viewModel.outputLanguageOverride)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .frame(maxWidth: 220)
                .focused($isOutputLanguageFocused)
                .onChange(of: viewModel.outputLanguageOverride) {
                  viewModel.markOutputLanguageOverrideEdited()
                }
              DayflowSurfaceButton(
                action: {
                  viewModel.saveOutputLanguageOverride()
                  isOutputLanguageFocused = false
                },
                content: {
                  HStack(spacing: 6) {
                    Image(
                      systemName: viewModel.isOutputLanguageOverrideSaved
                        ? "checkmark" : "square.and.arrow.down"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    Text(viewModel.isOutputLanguageOverrideSaved ? "Saved" : "Save")
                      .font(.custom("Nunito", size: 12))
                  }
                  .padding(.horizontal, 2)
                },
                background: Color.white,
                foreground: Color(red: 0.25, green: 0.17, blue: 0),
                borderColor: Color(hex: "FFE0A5"),
                cornerRadius: 8,
                horizontalPadding: 12,
                verticalPadding: 7,
                showOverlayStroke: true
              )
              .disabled(viewModel.isOutputLanguageOverrideSaved)
              DayflowSurfaceButton(
                action: {
                  viewModel.resetOutputLanguageOverride()
                  isOutputLanguageFocused = false
                },
                content: {
                  Text("Reset")
                    .font(.custom("Nunito", size: 11))
                },
                background: Color.white,
                foreground: Color(red: 0.25, green: 0.17, blue: 0),
                borderColor: Color(hex: "FFE0A5"),
                cornerRadius: 8,
                horizontalPadding: 10,
                verticalPadding: 6,
                showOverlayStroke: true
              )
            }
            Text(
              "The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français)."
            )
            .font(.custom("Nunito", size: 11.5))
            .foregroundColor(.black.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
          }

          Text(
            "Dayflow v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
          )
          .font(.custom("Nunito", size: 12))
          .foregroundColor(.black.opacity(0.45))
        }
      }
    }
    .onAppear {
      viewModel.refreshNotificationPermissionState()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      viewModel.refreshNotificationPermissionState()
    }
  }

  private var notificationPermissionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Notifications")
        .font(.custom("Nunito", size: 13))
        .foregroundColor(.black.opacity(0.7))

      HStack(alignment: .center, spacing: 10) {
        notificationPermissionBadge

        if let actionTitle = notificationPermissionActionTitle {
          DayflowSurfaceButton(
            action: notificationPermissionAction,
            content: {
              HStack(spacing: 8) {
                if viewModel.isUpdatingNotificationPermission {
                  ProgressView()
                    .scaleEffect(0.75)
                } else {
                  Image(systemName: notificationPermissionActionSymbol)
                    .font(.system(size: 12, weight: .semibold))
                }

                Text(actionTitle)
                  .font(.custom("Nunito", size: 12))
              }
              .padding(.horizontal, 2)
            },
            background: Color.white,
            foreground: Color(red: 0.25, green: 0.17, blue: 0),
            borderColor: Color(hex: "FFE0A5"),
            cornerRadius: 8,
            horizontalPadding: 12,
            verticalPadding: 7,
            showOverlayStroke: true
          )
          .disabled(viewModel.isUpdatingNotificationPermission)
        }
      }

      Text(
        "Automatic recording resumes can send a system notification when access is enabled. Manual Resume never sends a notification."
      )
      .font(.custom("Nunito", size: 11.5))
      .foregroundColor(.black.opacity(0.5))
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var notificationPermissionBadge: some View {
    Text(notificationPermissionStatusTitle)
      .font(.custom("Nunito", size: 11.5))
      .foregroundColor(notificationPermissionStatusColor)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(notificationPermissionStatusColor.opacity(0.10))
      .overlay(
        Capsule()
          .strokeBorder(notificationPermissionStatusColor.opacity(0.25), lineWidth: 1)
      )
      .clipShape(Capsule())
  }

  private var notificationPermissionStatusTitle: String {
    switch viewModel.notificationPermissionState {
    case .authorized:
      return "Enabled"
    case .notDetermined:
      return "Not enabled"
    case .denied:
      return "Denied in System Settings"
    }
  }

  private var notificationPermissionStatusColor: Color {
    switch viewModel.notificationPermissionState {
    case .authorized:
      return Color(red: 0.14, green: 0.53, blue: 0.23)
    case .notDetermined:
      return Color(red: 0.53, green: 0.42, blue: 0.15)
    case .denied:
      return Color(hex: "C44D3A")
    }
  }

  private var notificationPermissionActionTitle: String? {
    switch viewModel.notificationPermissionState {
    case .authorized:
      return nil
    case .notDetermined:
      return "Enable notifications"
    case .denied:
      return "Open System Settings"
    }
  }

  private var notificationPermissionActionSymbol: String {
    switch viewModel.notificationPermissionState {
    case .authorized, .notDetermined:
      return "bell.badge"
    case .denied:
      return "arrow.up.right.square"
    }
  }

  private func notificationPermissionAction() {
    switch viewModel.notificationPermissionState {
    case .authorized:
      break
    case .notDetermined:
      viewModel.requestNotificationPermission()
    case .denied:
      viewModel.openNotificationSettings()
    }
  }
}
