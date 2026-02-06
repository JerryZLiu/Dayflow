import SwiftUI

struct SettingsOtherTabView: View {
    @ObservedObject var viewModel: OtherSettingsViewModel
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @FocusState private var isOutputLanguageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            timelineExportCard

            SettingsCard(title: "App preferences", subtitle: "General toggles and telemetry settings") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )) {
                        Text("Launch Dayflow at login")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .toggleStyle(.switch)

                    Text("Keeps the menu bar controller running right after you sign in so capture can resume instantly.")
                        .font(.custom("Nunito", size: 11.5))
                        .foregroundColor(.black.opacity(0.5))

                    Toggle(isOn: $viewModel.analyticsEnabled) {
                        Text("Share crash reports and anonymous usage data")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $viewModel.showJournalDebugPanel) {
                        Text("Show Journal debug panel")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $viewModel.showDockIcon) {
                        Text("Show Dock icon")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .toggleStyle(.switch)

                    Text("When off, Dayflow runs as a menu bar–only app.")
                        .font(.custom("Nunito", size: 11.5))
                        .foregroundColor(.black.opacity(0.5))

                    Toggle(isOn: $viewModel.showTimelineAppIcons) {
                        Text("Show app/website icons in timeline")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .toggleStyle(.switch)

                    Text("When off, timeline cards won't show app or website icons.")
                        .font(.custom("Nunito", size: 11.5))
                        .foregroundColor(.black.opacity(0.5))

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
                                        Image(systemName: viewModel.isOutputLanguageOverrideSaved ? "checkmark" : "square.and.arrow.down")
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
                        Text("The default language is English. You can specify any language here (examples: English, 简体中文, Español, 日本語, 한국어, Français).")
                            .font(.custom("Nunito", size: 11.5))
                            .foregroundColor(.black.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Dayflow v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.45))
                }
            }

            if viewModel.showJournalDebugPanel {
                reprocessDayCard
            }
        }
    }

    private var timelineExportCard: some View {
        SettingsCard(title: "Export timeline", subtitle: "Download a Markdown export for any date range") {
            let rangeInvalid = timelineDisplayDate(from: viewModel.exportStartDate) > timelineDisplayDate(from: viewModel.exportEndDate)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    DatePicker("Start", selection: $viewModel.exportStartDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .accessibilityLabel(Text("Export start date"))

                    Image(systemName: "arrow.right")
                        .foregroundColor(.black.opacity(0.35))

                    DatePicker("End", selection: $viewModel.exportEndDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .accessibilityLabel(Text("Export end date"))
                }

                Text("Includes titles, summaries, and details for each card.")
                    .font(.custom("Nunito", size: 11.5))
                    .foregroundColor(.black.opacity(0.55))

                HStack(spacing: 10) {
                    DayflowSurfaceButton(
                        action: viewModel.exportTimelineRange,
                        content: {
                            HStack(spacing: 8) {
                                if viewModel.isExportingTimelineRange {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(viewModel.isExportingTimelineRange ? "Exporting…" : "Export as Markdown")
                                    .font(.custom("Nunito", size: 13))
                                    .fontWeight(.semibold)
                            }
                            .frame(minWidth: 150)
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 20,
                        verticalPadding: 10,
                        showOverlayStroke: true
                    )
                    .disabled(viewModel.isExportingTimelineRange || rangeInvalid)

                    if rangeInvalid {
                        Text("Start date must be on or before end date.")
                            .font(.custom("Nunito", size: 12))
                            .foregroundColor(Color(hex: "E91515"))
                    }
                }

                if let message = viewModel.exportStatusMessage {
                    Text(message)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(Color(red: 0.1, green: 0.5, blue: 0.22))
                }

                if let error = viewModel.exportErrorMessage {
                    Text(error)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(Color(hex: "E91515"))
                }
            }
            .padding(.top, 4)
        }
    }

    private var reprocessDayCard: some View {
        SettingsCard(title: "Debug: Reprocess day", subtitle: "Re-run analysis for all batches on a selected day") {
            let normalizedDate = timelineDisplayDate(from: viewModel.reprocessDayDate)
            let dayString = DateFormatter.yyyyMMdd.string(from: normalizedDate)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    DatePicker("Day", selection: $viewModel.reprocessDayDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .accessibilityLabel(Text("Reprocess day"))
                        .disabled(viewModel.isReprocessingDay)

                    Text(dayString)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.5))
                }

                Text("Reprocessing deletes existing timeline cards for the selected day and re-runs analysis.")
                    .font(.custom("Nunito", size: 11.5))
                    .foregroundColor(.black.opacity(0.55))

                Text("This will consume a lot of API calls.")
                    .font(.custom("Nunito", size: 11.5))
                    .foregroundColor(.black.opacity(0.7))

                HStack(spacing: 10) {
                    DayflowSurfaceButton(
                        action: { viewModel.showReprocessDayConfirm = true },
                        content: {
                            HStack(spacing: 8) {
                                if viewModel.isReprocessingDay {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(viewModel.isReprocessingDay ? "Reprocessing…" : "Reprocess day")
                                    .font(.custom("Nunito", size: 13))
                                    .fontWeight(.semibold)
                            }
                            .frame(minWidth: 150)
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 20,
                        verticalPadding: 10,
                        showOverlayStroke: true
                    )
                    .disabled(viewModel.isReprocessingDay)

                    if let status = viewModel.reprocessStatusMessage {
                        Text(status)
                            .font(.custom("Nunito", size: 12))
                            .foregroundColor(.black.opacity(0.6))
                    }
                }

                if let error = viewModel.reprocessErrorMessage {
                    Text(error)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.red.opacity(0.8))
                }
            }
            .alert("Reprocess day?", isPresented: $viewModel.showReprocessDayConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reprocess", role: .destructive) { viewModel.reprocessSelectedDay() }
            } message: {
                Text("This will delete existing timeline cards for \(dayString) and re-run analysis. It will consume a large number of API calls.")
            }
        }
    }
}
