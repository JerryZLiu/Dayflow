import SwiftUI

struct SettingsStorageTabView: View {
    @ObservedObject var viewModel: StorageSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsCard(title: "Recording Status", subtitle: "Ensure Dayflow can capture your screen") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        statusPill(
                            icon: viewModel.storagePermissionGranted == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            tint: viewModel.storagePermissionGranted == true ? Color(red: 0.35, green: 0.7, blue: 0.32) : Color(hex: "E91515"),
                            text: viewModel.storagePermissionGranted == true ? "Screen recording permission granted" : "Screen recording permission missing"
                        )

                        statusPill(
                            icon: AppState.shared.isRecording ? "dot.radiowaves.left.and.right" : "pause.circle",
                            tint: AppState.shared.isRecording ? Color(hex: "FF7506") : Color.black.opacity(0.25),
                            text: AppState.shared.isRecording ? "Recorder active" : "Recorder idle"
                        )
                    }

                    HStack(spacing: 12) {
                        DayflowSurfaceButton(
                            action: viewModel.runStorageStatusCheck,
                            content: {
                                HStack(spacing: 10) {
                                    if viewModel.isRefreshingStorage {
                                        ProgressView().scaleEffect(0.75)
                                    }
                                    Text(viewModel.isRefreshingStorage ? "Checking…" : "Run status check")
                                        .font(.custom("Nunito", size: 13))
                                        .fontWeight(.semibold)
                                }
                                .frame(minWidth: 170)
                            },
                            background: Color(red: 0.25, green: 0.17, blue: 0),
                            foreground: .white,
                            borderColor: .clear,
                            cornerRadius: 8,
                            horizontalPadding: 20,
                            verticalPadding: 11,
                            showOverlayStroke: true
                        )
                        .disabled(viewModel.isRefreshingStorage)

                        if let last = viewModel.lastStorageCheck {
                            Text("Last checked \(relativeDate(last))")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.45))
                        }
                    }
                }
            }

            SettingsCard(title: "Disk usage", subtitle: "Open folders or adjust per-type storage caps") {
                VStack(alignment: .leading, spacing: 18) {
                    usageRow(
                        category: .recordings,
                        label: "Recordings",
                        size: viewModel.recordingsUsageBytes,
                        tint: Color(hex: "FF7506"),
                        limitIndex: viewModel.recordingsLimitIndex,
                        limitBytes: viewModel.recordingsLimitBytes,
                        actionTitle: "Open",
                        action: viewModel.openRecordingsFolder
                    )
                    usageRow(
                        category: .timelapses,
                        label: "Timelapses",
                        size: viewModel.timelapseUsageBytes,
                        tint: Color(hex: "1D7FFE"),
                        limitIndex: viewModel.timelapsesLimitIndex,
                        limitBytes: viewModel.timelapsesLimitBytes,
                        actionTitle: "Open",
                        action: viewModel.openTimelapseFolder
                    )

                    Text(viewModel.storageFooterText())
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .alert(isPresented: $viewModel.showLimitConfirmation) {
            guard let pending = viewModel.pendingLimit,
                  StorageSettingsViewModel.storageOptions.indices.contains(pending.index) else {
                return Alert(title: Text("Adjust storage limit"), dismissButton: .default(Text("OK")))
            }

            let option = StorageSettingsViewModel.storageOptions[pending.index]
            let categoryName = pending.category.displayName
            return Alert(
                title: Text("Lower \(categoryName) limit?"),
                message: Text("Reducing the \(categoryName) limit to \(option.label) will immediately delete the oldest \(categoryName) data to stay under the new cap."),
                primaryButton: .destructive(Text("Confirm")) {
                    viewModel.applyLimit(for: pending.category, index: pending.index)
                },
                secondaryButton: .cancel {
                    viewModel.pendingLimit = nil
                    viewModel.showLimitConfirmation = false
                }
            )
        }
    }

    private func usageRow(category: StorageCategory,
                          label: String,
                          size: Int64,
                          tint: Color,
                          limitIndex: Int,
                          limitBytes: Int64,
                          actionTitle: String,
                          action: @escaping () -> Void) -> some View {
        let usageString = viewModel.usageFormatter.string(fromByteCount: size)
        let progress: Double? = limitBytes == Int64.max || limitBytes == 0 ? nil : min(Double(size) / Double(limitBytes), 1.0)
        let percentString: String? = progress.map { value in
            String(format: "%.0f%% of limit", value * 100)
        }
        let option = StorageSettingsViewModel.storageOptions[limitIndex]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.custom("Nunito", size: 14))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.75))
                    HStack(spacing: 6) {
                        Text(usageString)
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.55))
                        if let percentString {
                            Text(percentString)
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.45))
                        }
                    }
                }
                Spacer()
                DayflowSurfaceButton(
                    action: action,
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                            Text(actionTitle)
                                .font(.custom("Nunito", size: 13))
                        }
                    },
                    background: Color.white,
                    foreground: Color(red: 0.25, green: 0.17, blue: 0),
                    borderColor: Color(hex: "FFE0A5"),
                    cornerRadius: 8,
                    horizontalPadding: 20,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )

                Menu {
                    ForEach(StorageSettingsViewModel.storageOptions) { candidate in
                        Button(candidate.label) {
                            viewModel.handleLimitSelection(for: category, index: candidate.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text(option.label)
                            .font(.custom("Nunito", size: 12))
                    }
                    .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "FFE0A5"), lineWidth: 1)
                    )
                }
                .menuStyle(BorderlessButtonMenuStyle())
            }

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: tint))
            }
        }
    }

    private func statusPill(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.65))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.75))
                .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 0.8))
        )
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
