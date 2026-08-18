import SwiftUI

struct SettingsOtherTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
  @FocusState private var isOutputLanguageFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      appPreferencesSection
      outputLanguageSection
    }
  }

  // MARK: - App preferences

  private var appPreferencesSection: some View {
    SettingsSection(
      title: String(localized: "App preferences"),
      subtitle: String(localized: "General toggles and telemetry settings.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: String(localized: "Launch Dayflow at login"),
          subtitle: String(
            localized:
              "Keeps the menu bar controller running right after you sign in so capture can resume instantly."
          )
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { launchAtLoginManager.isEnabled },
              set: { launchAtLoginManager.setEnabled($0) }
            )
          )
        }

        SettingsRow(label: String(localized: "Share crash reports and anonymous usage data")) {
          SettingsToggle(isOn: $viewModel.analyticsEnabled)
        }

        SettingsRow(
          label: String(localized: "Show Dock icon"),
          subtitle: String(localized: "When off, Dayflow runs as a menu bar-only app.")
        ) {
          SettingsToggle(isOn: $viewModel.showDockIcon)
        }

        SettingsRow(
          label: String(localized: "Show app/website icons in timeline"),
          subtitle: String(localized: "When off, timeline cards won't show app or website icons.")
        ) {
          SettingsToggle(isOn: $viewModel.showTimelineAppIcons)
        }

        SettingsRow(
          label: String(localized: "Show daily goal popups"),
          subtitle: String(
            localized:
              "When off, Dayflow won't automatically open goal setup or yesterday's review after 4am."
          )
        ) {
          SettingsToggle(isOn: $viewModel.showDailyGoalPopups)
        }

        SettingsRow(
          label: String(localized: "Save all timelapses to disk"),
          subtitle: String(
            localized:
              "New and reprocessed timeline cards will pre-generate timelapse videos and store them on disk instead of building them on demand. Uses more storage and background processing."
          ),
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
      title: String(localized: "Output language override"),
      subtitle: String(
        localized:
          "The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français)."
      )
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
          title: viewModel.isOutputLanguageOverrideSaved
            ? String(localized: "Saved") : String(localized: "Save"),
          systemImage: viewModel.isOutputLanguageOverrideSaved
            ? "checkmark" : nil,
          isDisabled: viewModel.isOutputLanguageOverrideSaved,
          action: {
            viewModel.saveOutputLanguageOverride()
            isOutputLanguageFocused = false
          }
        )

        SettingsSecondaryButton(
          title: String(localized: "Reset"),
          action: {
            viewModel.resetOutputLanguageOverride()
            isOutputLanguageFocused = false
          }
        )

        Spacer()
      }
    }
  }
}
