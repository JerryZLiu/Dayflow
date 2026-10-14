import SwiftUI

struct SettingsOtherTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @FocusState private var isOutputLanguageFocused: Bool
  @State private var appLanguage = AppLanguagePreferences.selection()

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
          label: String(localized: "App language"),
          subtitle: String(
            localized:
              "Choose a language for Dayflow only. Quit and reopen the app to apply a change.")
        ) {
          Picker("App language", selection: $appLanguage) {
            ForEach(AppLanguage.allCases) { language in
              Text(verbatim: language.title).tag(language)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(width: 210)
          .onChange(of: appLanguage) {
            AppLanguagePreferences.setSelection(appLanguage)
          }
        }

        SettingsRow(
          label: String(localized: "Light/Dark mode"),
          subtitle: String(localized: "Follow the system setting or pick light or dark.")
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
          label: String(localized: "Launch Dayflow at login"),
          subtitle:
            String(
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

        SettingsRow(
          label: String(localized: "Pause lengths"),
          subtitle: String(localized: "The three timed options shown when you pause Dayflow.")
        ) {
          HStack(spacing: 6) {
            ForEach(viewModel.pausePresetMinutes.indices, id: \.self) { index in
              Picker("Pause length", selection: $viewModel.pausePresetMinutes[index]) {
                ForEach(PausePresets.minuteOptions, id: \.self) { minutes in
                  Text(verbatim: PauseDuration.timed(minutes: minutes).shortLabel).tag(minutes)
                }
              }
              .pickerStyle(.menu)
              .labelsHidden()
              .frame(width: 78)
            }
          }
        }

        SettingsRow(
          label: String(localized: "Crash reports and usage data"),
          subtitle: String(
            localized:
              "Removed in this build. Dayflow does not send telemetry, recordings, OCR text, or traces off this Mac."
          )
        ) {
          EmptyView()
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
          subtitle:
            String(
              localized:
                "When off, Dayflow won't automatically open goal setup or yesterday's review after 4am."
            )
        ) {
          SettingsToggle(isOn: $viewModel.showDailyGoalPopups)
        }

        SettingsRow(
          label: String(localized: "Save all timelapses to disk"),
          subtitle:
            String(
              localized:
                "New and reprocessed timeline cards will pre-generate timelapse videos and store them on disk instead of building them on demand. Uses more storage and background processing."
            )
        ) {
          SettingsToggle(isOn: $viewModel.saveAllTimelapsesToDisk)
        }

        SettingsRow(
          label: String(localized: "Getting started guide"),
          subtitle: String(
            localized:
              "Replay the welcome tour and bring back the first-day checklist on your timeline."),
          showsDivider: false
        ) {
          SettingsSecondaryButton(
            title: String(localized: "Show again"),
            action: { GettingStarted.replay() }
          )
        }
      }
    }
  }

  // MARK: - Output language override

  private var outputLanguageSection: some View {
    SettingsSection(
      title: String(localized: "Output language override"),
      subtitle:
        String(
          localized:
            "AI output follows the app language by default. Enter a language to override it, or reset to follow the app language. Existing summaries stay unchanged."
        )
    ) {
      HStack(spacing: 10) {
        TextField("App language", text: $viewModel.outputLanguageOverride)
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
