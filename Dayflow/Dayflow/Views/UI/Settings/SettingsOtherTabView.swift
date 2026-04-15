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

          Toggle(isOn: $viewModel.automaticUpdatesEnabled) {
            Text("Automatic app updates")
              .font(.custom("Nunito", size: 13))
              .foregroundColor(.black.opacity(0.7))
          }
          .toggleStyle(.switch)
          .pointingHandCursor()

          Text("When on, Dayflow automatically checks for and installs updates in the background.")
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

          Toggle(isOn: $viewModel.saveAllTimelapsesToDisk) {
            Text("Save all timelapses to disk")
              .font(.custom("Nunito", size: 13))
              .foregroundColor(.black.opacity(0.7))
          }
          .toggleStyle(.switch)
          .pointingHandCursor()

          Text(
            "New and reprocessed timeline cards will pre-generate timelapse videos and store them on disk instead of building them on demand. Uses more storage and background processing."
          )
          .font(.custom("Nunito", size: 11.5))
          .foregroundColor(.black.opacity(0.5))
          .fixedSize(horizontal: false, vertical: true)

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
  }
}
