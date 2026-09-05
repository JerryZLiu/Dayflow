import SwiftUI

struct SettingsOtherTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
  @ObservedObject private var updaterManager = UpdaterManager.shared
  @FocusState private var isOutputLanguageFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      appPreferencesSection
      updatesSection
      outputLanguageSection
    }
  }

  // MARK: - App preferences

  private var appPreferencesSection: some View {
    SettingsSection(
      title: "App preferences",
      subtitle: "General toggles and telemetry settings."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: "Launch Dayflow at login",
          subtitle:
            "Keeps the menu bar controller running right after you sign in so capture can resume instantly."
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { launchAtLoginManager.isEnabled },
              set: { launchAtLoginManager.setEnabled($0) }
            )
          )
        }

        SettingsRow(label: "Share crash reports and anonymous usage data") {
          SettingsToggle(isOn: $viewModel.analyticsEnabled)
        }

        SettingsRow(
          label: "Show Dock icon",
          subtitle: "When off, Dayflow runs as a menu bar-only app."
        ) {
          SettingsToggle(isOn: $viewModel.showDockIcon)
        }

        SettingsRow(
          label: "Show app/website icons in timeline",
          subtitle: "When off, timeline cards won't show app or website icons."
        ) {
          SettingsToggle(isOn: $viewModel.showTimelineAppIcons)
        }

        SettingsRow(
          label: "Show daily goal popups",
          subtitle:
            "When off, Dayflow won't automatically open goal setup or yesterday's review after 4am."
        ) {
          SettingsToggle(isOn: $viewModel.showDailyGoalPopups)
        }

        SettingsRow(
          label: "Save all timelapses to disk",
          subtitle:
            "New and reprocessed timeline cards will pre-generate timelapse videos and store them on disk instead of building them on demand. Uses more storage and background processing.",
          showsDivider: false
        ) {
          SettingsToggle(isOn: $viewModel.saveAllTimelapsesToDisk)
        }
      }
    }
  }

  // MARK: - Output language override

  private var outputLanguageSection: some View {
    SettingsSection(
      title: "Output language override",
      subtitle:
        "The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français)."
    ) {
      HStack(spacing: 10) {
        TextField("English", text: $viewModel.outputLanguageOverride)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
          .frame(maxWidth: 220)
          .focused($isOutputLanguageFocused)
          .onChange(of: viewModel.outputLanguageOverride) {
            viewModel.markOutputLanguageOverrideEdited()
          }

        SettingsSecondaryButton(
          title: viewModel.isOutputLanguageOverrideSaved ? "Saved" : "Save",
          systemImage: viewModel.isOutputLanguageOverrideSaved
            ? "checkmark" : nil,
          isDisabled: viewModel.isOutputLanguageOverrideSaved,
          action: {
            viewModel.saveOutputLanguageOverride()
            isOutputLanguageFocused = false
          }
        )

        SettingsSecondaryButton(
          title: "Reset",
          action: {
            viewModel.resetOutputLanguageOverride()
            isOutputLanguageFocused = false
          }
        )

        Spacer()
      }
    }
  }

  // MARK: - Updates

  private var updatesSection: some View {
    SettingsSection(
      title: "Updates",
      subtitle: "Control how Dayflow checks for new versions."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: "Automatically check for updates",
          subtitle:
            "When off, Dayflow only checks for updates when you click the button below."
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { updaterManager.automaticallyChecksForUpdates },
              set: { updaterManager.setAutomaticallyChecksForUpdates($0) }
            ))
        }

        SettingsRow(
          label: "Automatically download and install updates",
          subtitle: "Requires automatic checking to be enabled."
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { updaterManager.automaticallyDownloadsUpdates },
              set: { updaterManager.setAutomaticallyDownloadsUpdates($0) }
            ))
          .disabled(!updaterManager.automaticallyChecksForUpdates)
        }

        SettingsRow(
          label: "Check for updates now",
          subtitle: updaterManager.statusText.isEmpty ? nil : updaterManager.statusText
        ) {
          if updaterManager.isChecking {
            ProgressView()
              .controlSize(.small)
          } else {
            SettingsSecondaryButton(
              title: "Check now",
              action: { updaterManager.checkForUpdates(showUI: true) }
            )
            .disabled(!updaterManager.canCheckForUpdates)
          }
        }

        if let url = updaterManager.pendingReleaseNotesURL {
          SettingsRow(
            label: "Latest release notes",
            subtitle: url.host ?? url.absoluteString
          ) {
            SettingsSecondaryButton(
              title: "View changelog",
              action: { updaterManager.openReleaseNotes() }
            )
          }
        }
      }
    }
  }
}
