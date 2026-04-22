import SwiftUI

struct SettingsStorageTabView: View {
  @ObservedObject var viewModel: StorageSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      recordingStatusSection
      diskUsageSection
    }
    .alert(isPresented: $viewModel.showLimitConfirmation) {
      guard let pending = viewModel.pendingLimit,
        StorageSettingsViewModel.storageOptions.indices.contains(pending.index)
      else {
        return Alert(title: Text("Adjust storage limit"), dismissButton: .default(Text("OK")))
      }

      let option = StorageSettingsViewModel.storageOptions[pending.index]
      let categoryName = pending.category.displayName
      return Alert(
        title: Text("Lower \(categoryName) limit?"),
        message: Text(
          "Reducing the \(categoryName) limit to \(option.label) will immediately delete the oldest \(categoryName) data to stay under the new cap."
        ),
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

  // MARK: - Recording Status

  private var recordingStatusSection: some View {
    let permissionGranted = viewModel.storagePermissionGranted == true
    let isRecording = AppState.shared.isRecording

    return SettingsSection(
      title: "Recording status",
      subtitle: "Ensure Dayflow can capture your screen."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(label: "Screen recording permission") {
          SettingsStatusDot(
            state: permissionGranted ? .good : .bad,
            label: permissionGranted ? "Granted" : "Missing"
          )
        }

        SettingsRow(label: "Recorder", showsDivider: false) {
          SettingsStatusDot(
            state: isRecording ? .good : .idle,
            label: isRecording ? "Active" : "Idle"
          )
        }

        HStack(spacing: 14) {
          SettingsPrimaryButton(
            title: viewModel.isRefreshingStorage ? "Checking…" : "Run status check",
            isLoading: viewModel.isRefreshingStorage,
            action: viewModel.runStorageStatusCheck
          )

          if let last = viewModel.lastStorageCheck {
            SettingsMetadata(text: "Last checked \(relativeDate(last))")
          }
        }
        .padding(.top, 18)
      }
    }
  }

  // MARK: - Disk usage

  private var diskUsageSection: some View {
    SettingsSection(
      title: "Disk usage",
      subtitle: "Open folders or adjust per-type storage caps."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        usageRow(
          category: .recordings,
          label: "Recordings",
          size: viewModel.recordingsUsageBytes,
          limitIndex: viewModel.recordingsLimitIndex,
          limitBytes: viewModel.recordingsLimitBytes,
          action: viewModel.openRecordingsFolder
        )
        usageRow(
          category: .timelapses,
          label: "Timelapses",
          size: viewModel.timelapseUsageBytes,
          limitIndex: viewModel.timelapsesLimitIndex,
          limitBytes: viewModel.timelapsesLimitBytes,
          action: viewModel.openTimelapseFolder,
          showsDivider: false
        )

        Text(viewModel.storageFooterText())
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.meta)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 18)
      }
    }
  }

  /// One category of storage: label + usage metadata on the left, Open +
  /// limit controls on the right, progress bar spanning full width below.
  /// Uses the single ink accent — categories differ by label, not color.
  private func usageRow(
    category: StorageCategory,
    label: String,
    size: Int64,
    limitIndex: Int,
    limitBytes: Int64,
    action: @escaping () -> Void,
    showsDivider: Bool = true
  ) -> some View {
    let usageString = viewModel.usageFormatter.string(fromByteCount: size)
    let progress: Double? =
      limitBytes == Int64.max || limitBytes == 0
      ? nil : min(Double(size) / Double(limitBytes), 1.0)
    let percentString: String? = progress.map { String(format: "%.0f%%", $0 * 100) }
    let metadata = [usageString, percentString].compactMap { $0 }.joined(separator: " · ")
    let option = StorageSettingsViewModel.storageOptions[limitIndex]

    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(label)
            .font(.custom("Nunito", size: 14))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          Text(metadata)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(SettingsStyle.secondary)
        }
        Spacer(minLength: 12)

        HStack(spacing: 8) {
          SettingsSecondaryButton(title: "Open", action: action)

          Menu {
            ForEach(StorageSettingsViewModel.storageOptions) { candidate in
              Button(candidate.label) {
                viewModel.handleLimitSelection(for: category, index: candidate.id)
              }
            }
          } label: {
            HStack(spacing: 5) {
              Text(option.label)
                .font(.custom("Nunito", size: 13))
                .fontWeight(.semibold)
              Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(SettingsStyle.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.05))
            )
          }
          .menuStyle(BorderlessButtonMenuStyle())
          .menuIndicator(.hidden)
          .fixedSize()
          .pointingHandCursor()
        }
      }
      .padding(.vertical, SettingsStyle.rowVerticalPadding)

      if let progress {
        ProgressView(value: progress)
          .progressViewStyle(LinearProgressViewStyle(tint: SettingsStyle.ink))
          .padding(.bottom, 14)
      }

      if showsDivider {
        Rectangle()
          .fill(SettingsStyle.divider)
          .frame(height: 1)
      }
    }
  }

  private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
