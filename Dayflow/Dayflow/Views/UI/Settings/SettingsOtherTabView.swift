import SwiftUI

struct SettingsOtherTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @AppStorage(AppLanguage.storageKey) private var appLanguage: AppLanguage = .system
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
      title: L10n.tr("App preferences"),
      subtitle: L10n.tr("General toggles and telemetry settings.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: L10n.tr("App language"),
          subtitle: L10n.tr("Choose the language used by the Dayflow interface.")
        ) {
          Picker("", selection: $appLanguage) {
            ForEach(AppLanguage.allCases) { language in
              Text(language.title).tag(language)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(width: 210)
        }

        SettingsRow(
          label: L10n.tr("Light/Dark mode"),
          subtitle: L10n.tr("Follow the system setting or pick light or dark.")
        ) {
          Picker("", selection: $appearance) {
            ForEach(DayflowAppearance.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 210)
          .onChange(of: appearance) { _, newValue in
            AnalyticsService.shared.capture(
              "appearance_changed", ["appearance": newValue.rawValue])
          }
        }

        SettingsRow(
          label: L10n.tr("Launch Dayflow at login"),
          subtitle: L10n.tr("Keeps the menu bar controller running right after you sign in so capture can resume instantly.")
        ) {
          SettingsToggle(
            isOn: Binding(
              get: { launchAtLoginManager.isEnabled },
              set: { launchAtLoginManager.setEnabled($0) }
            )
          )
        }

        SettingsRow(label: L10n.tr("Share crash reports and anonymous usage data")) {
          SettingsToggle(isOn: $viewModel.analyticsEnabled)
        }

        SettingsRow(
          label: L10n.tr("Show Dock icon"),
          subtitle: L10n.tr("When off, Dayflow runs as a menu bar-only app.")
        ) {
          SettingsToggle(isOn: $viewModel.showDockIcon)
        }

        SettingsRow(
          label: L10n.tr("Show app/website icons in timeline"),
          subtitle: L10n.tr("When off, timeline cards won't show app or website icons.")
        ) {
          SettingsToggle(isOn: $viewModel.showTimelineAppIcons)
        }

        SettingsRow(
          label: L10n.tr("Show daily goal popups"),
          subtitle: L10n.tr("When off, Dayflow won't automatically open goal setup or yesterday's review after 4am.")
        ) {
          SettingsToggle(isOn: $viewModel.showDailyGoalPopups)
        }

        SettingsRow(
          label: L10n.tr("Save all timelapses to disk"),
          subtitle: L10n.tr("New and reprocessed timeline cards will pre-generate timelapse videos and store them on disk instead of building them on demand. Uses more storage and background processing."),
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
      title: L10n.tr("Output language override"),
      subtitle: L10n.tr("The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français).")
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
          title: viewModel.isOutputLanguageOverrideSaved ? L10n.tr("Saved") : L10n.tr("Save"),
          systemImage: viewModel.isOutputLanguageOverrideSaved
            ? "checkmark" : nil,
          isDisabled: viewModel.isOutputLanguageOverrideSaved,
          action: {
            viewModel.saveOutputLanguageOverride()
            isOutputLanguageFocused = false
          }
        )

        SettingsSecondaryButton(
          title: L10n.tr("Reset"),
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
