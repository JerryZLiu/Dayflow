import SwiftUI

struct SettingsStorageTabView: View {
  @ObservedObject var viewModel: StorageSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      recordingStatusSection
      recordingQualitySection
      diskUsageSection
    }
    .alert(isPresented: $viewModel.showLimitConfirmation) {
      guard let pending = viewModel.pendingLimit,
        StorageSettingsViewModel.storageOptions.indices.contains(pending.index)
      else {
        return Alert(
          title: Text(L10n.tr("Adjust storage limit")),
          dismissButton: .default(Text(L10n.tr("OK")))
        )
      }

      let option = StorageSettingsViewModel.storageOptions[pending.index]
      let categoryName = pending.category.displayName
      return Alert(
        title: Text(L10n.tr("Lower %@ limit?", categoryName)),
        message: Text(
          L10n.tr(
            "Reducing the %@ limit to %@ will immediately delete the oldest %@ data to stay under the new cap.",
            categoryName, option.label, categoryName)
        ),
        primaryButton: .destructive(Text(L10n.tr("Confirm"))) {
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
    let recordingEnabled = AppState.shared.isRecording
    let isRecording = permissionGranted && recordingEnabled
    let recorderStatus: SettingsStatusDot.State =
      isRecording ? .good : (permissionGranted ? .idle : .bad)
    let recorderLabel = isRecording ? L10n.tr("Active") : (permissionGranted ? L10n.tr("Idle") : L10n.tr("Blocked"))

    return SettingsSection(
      title: L10n.tr("Recording status"),
      subtitle: L10n.tr("Ensure Dayflow can capture your screen.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(label: L10n.tr("Screen recording permission")) {
          SettingsStatusDot(
            state: permissionGranted ? .good : .bad,
            label: permissionGranted ? L10n.tr("Granted") : L10n.tr("Missing")
          )
        }

        SettingsRow(label: L10n.tr("Recorder"), showsDivider: false) {
          SettingsStatusDot(
            state: recorderStatus,
            label: recorderLabel
          )
        }

        HStack(spacing: 14) {
          SettingsPrimaryButton(
            title: viewModel.isRefreshingStorage ? L10n.tr("Checking…") : L10n.tr("Run status check"),
            isLoading: viewModel.isRefreshingStorage,
            action: viewModel.runStorageStatusCheck
          )

          if let last = viewModel.lastStorageCheck {
            SettingsMetadata(text: L10n.tr("Last checked %@", relativeDate(last)))
          }
        }
        .padding(.top, 18)
      }
    }
  }

  // MARK: - Recording quality

  private var recordingQualitySection: some View {
    SettingsSection(
      title: L10n.tr("Recording quality"),
      subtitle: L10n.tr("Higher resolution and more frequent captures use more disk.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(label: L10n.tr("Resolution"), subtitle: L10n.tr("Height each frame is scaled to")) {
          settingsMenu(
            selected: ScreenshotConfig.label(forHeight: viewModel.captureHeight),
            options: ScreenshotConfig.heightOptions.map {
              ($0, ScreenshotConfig.label(forHeight: $0))
            },
            onSelect: viewModel.setCaptureHeight
          )
        }

        SettingsRow(
          label: L10n.tr("Capture frequency"), subtitle: L10n.tr("How often a frame is taken"), showsDivider: false
        ) {
          settingsMenu(
            selected: ScreenshotConfig.label(forInterval: viewModel.captureInterval),
            options: ScreenshotConfig.intervalOptions.map {
              ($0, ScreenshotConfig.label(forInterval: $0))
            },
            onSelect: viewModel.setCaptureInterval
          )
        }

        VStack(alignment: .leading, spacing: 4) {
          SettingsMetadata(text: viewModel.recordingEstimateText())
          if let observed = viewModel.observedRateText() {
            SettingsMetadata(text: observed)
          }
        }
        .padding(.top, 18)
      }
    }
  }

  /// Compact dropdown matching the storage-limit picker below.
  private func settingsMenu<Value: Hashable>(
    selected: String,
    options: [(value: Value, label: String)],
    onSelect: @escaping (Value) -> Void
  ) -> some View {
    Menu {
      ForEach(options, id: \.value) { option in
        Button(option.label) { onSelect(option.value) }
      }
    } label: {
      HStack(spacing: 5) {
        Text(selected)
          .font(.custom("Figtree", size: 13))
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

  // MARK: - Disk usage

  private var diskUsageSection: some View {
    SettingsSection(
      title: L10n.tr("Disk usage"),
      subtitle: L10n.tr("Open folders or adjust per-type storage caps.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        usageRow(
          category: .recordings,
          label: L10n.tr("Recordings"),
          size: viewModel.recordingsUsageBytes,
          limitIndex: viewModel.recordingsLimitIndex,
          limitBytes: viewModel.recordingsLimitBytes,
          action: viewModel.openRecordingsFolder
        )
        usageRow(
          category: .timelapses,
          label: L10n.tr("Timelapses"),
          size: viewModel.timelapseUsageBytes,
          limitIndex: viewModel.timelapsesLimitIndex,
          limitBytes: viewModel.timelapsesLimitBytes,
          action: viewModel.openTimelapseFolder,
          showsDivider: false
        )

        Text(viewModel.storageFooterText())
          .font(.custom("Figtree", size: 12))
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
            .font(.custom("Figtree", size: 14))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          Text(metadata)
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.secondary)
        }
        Spacer(minLength: 12)

        HStack(spacing: 8) {
          SettingsSecondaryButton(title: L10n.tr("Open"), action: action)

          Menu {
            ForEach(StorageSettingsViewModel.storageOptions) { candidate in
              Button(candidate.label) {
                viewModel.handleLimitSelection(for: category, index: candidate.id)
              }
            }
          } label: {
            HStack(spacing: 5) {
              Text(option.label)
                .font(.custom("Figtree", size: 13))
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
