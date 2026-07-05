import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class OtherSettingsViewModel: ObservableObject {
  @Published var analyticsEnabled: Bool {
    didSet {
      guard analyticsEnabled != oldValue else { return }
      AnalyticsService.shared.setOptIn(analyticsEnabled)
    }
  }
  @Published var showDockIcon: Bool {
    didSet {
      guard showDockIcon != oldValue else { return }
      UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon")
      NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
  }
  @Published var showTimelineAppIcons: Bool {
    didSet {
      guard showTimelineAppIcons != oldValue else { return }
      UserDefaults.standard.set(showTimelineAppIcons, forKey: "showTimelineAppIcons")
    }
  }
  @Published var showDailyGoalPopups: Bool {
    didSet {
      guard showDailyGoalPopups != oldValue else { return }
      DayGoalPreferences.showDailyGoalPopups = showDailyGoalPopups
    }
  }
  @Published var saveAllTimelapsesToDisk: Bool {
    didSet {
      guard saveAllTimelapsesToDisk != oldValue else { return }
      TimelapsePreferences.saveAllTimelapsesToDisk = saveAllTimelapsesToDisk
    }
  }
  @Published var outputLanguageOverride: String
  @Published var isOutputLanguageOverrideSaved: Bool = true

  @Published var exportStartDate: Date
  @Published var exportEndDate: Date
  @Published var isExportingTimelineRange = false
  @Published var exportStatusMessage: String?
  @Published var exportErrorMessage: String?
  @Published var isExportingBackup = false
  @Published var isImportingBackup = false
  @Published var backupStatusMessage: String?
  @Published var backupErrorMessage: String?
  @Published var showBackupImportConfirm = false
  @Published var backupImportQueued = false
  @Published var reprocessDayDate: Date
  @Published var isReprocessingDay = false
  @Published var reprocessStatusMessage: String?
  @Published var reprocessErrorMessage: String?
  @Published var showReprocessDayConfirm = false
  var pendingBackupImportURL: URL?

  init() {
    analyticsEnabled = AnalyticsService.shared.isOptedIn
    showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    showTimelineAppIcons =
      UserDefaults.standard.object(forKey: "showTimelineAppIcons") as? Bool ?? true
    showDailyGoalPopups = DayGoalPreferences.showDailyGoalPopups
    saveAllTimelapsesToDisk = TimelapsePreferences.saveAllTimelapsesToDisk
    outputLanguageOverride = LLMOutputLanguagePreferences.override
    exportStartDate = timelineDisplayDate(from: Date())
    exportEndDate = timelineDisplayDate(from: Date())
    reprocessDayDate = timelineDisplayDate(from: Date())
  }

  func markOutputLanguageOverrideEdited() {
    let trimmed = outputLanguageOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    let savedValue = LLMOutputLanguagePreferences.override
    isOutputLanguageOverrideSaved = trimmed == savedValue
  }

  func saveOutputLanguageOverride() {
    let trimmed = outputLanguageOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    outputLanguageOverride = trimmed
    LLMOutputLanguagePreferences.override = trimmed
    isOutputLanguageOverrideSaved = true
  }

  func resetOutputLanguageOverride() {
    outputLanguageOverride = ""
    LLMOutputLanguagePreferences.override = ""
    isOutputLanguageOverrideSaved = true
  }

  func refreshAnalyticsState() {
    analyticsEnabled = AnalyticsService.shared.isOptedIn
  }

  func exportTimelineRange() {
    exportTimelineRange(as: .markdown)
  }

  func exportTimelineRangeAsCalendar() {
    exportTimelineRange(as: .calendar)
  }

  private func exportTimelineRange(as format: TimelineExportFormat) {
    guard !isExportingTimelineRange else { return }

    let start = timelineDisplayDate(from: exportStartDate)
    let end = timelineDisplayDate(from: exportEndDate)

    guard start <= end else {
      exportErrorMessage = "Start date must be on or before end date."
      exportStatusMessage = nil
      return
    }

    isExportingTimelineRange = true
    exportStatusMessage = nil
    exportErrorMessage = nil

    Task.detached(priority: .userInitiated) { [start, end] in
      let calendar = Calendar.current
      let dayFormatter = DateFormatter()
      dayFormatter.dateFormat = "yyyy-MM-dd"

      var cursor = start
      let endDate = end

      var sections: [String] = []
      var calendarCards: [TimelineCard] = []
      var totalActivities = 0
      var dayCount = 0

      while cursor <= endDate {
        let dayString = dayFormatter.string(from: cursor)
        let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
        totalActivities += cards.count
        switch format {
        case .markdown:
          let section = TimelineClipboardFormatter.makeMarkdown(for: cursor, cards: cards)
          sections.append(section)
        case .calendar:
          calendarCards.append(contentsOf: cards)
        }
        dayCount += 1

        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
      }

      let exportText: String
      let exportedActivityCount: Int

      switch format {
      case .markdown:
        let divider = "\n\n---\n\n"
        exportText = sections.joined(separator: divider)
        exportedActivityCount = totalActivities
      case .calendar:
        let importableCards = calendarCards.filter {
          TimelineCalendarFormatter.eventDateRange(for: $0) != nil
        }
        exportText = TimelineCalendarFormatter.makeICS(cards: importableCards)
        exportedActivityCount = importableCards.count
      }

      await MainActor.run {
        self.presentSavePanelAndWrite(
          exportText: exportText,
          startDate: start,
          endDate: end,
          dayCount: dayCount,
          activityCount: exportedActivityCount,
          skippedActivityCount: totalActivities - exportedActivityCount,
          format: format
        )
      }
    }
  }

  func exportDayflowBackup() {
    guard !isExportingBackup else { return }

    let savePanel = NSSavePanel()
    savePanel.title = "Export Dayflow backup"
    savePanel.prompt = "Export Backup"
    savePanel.nameFieldStringValue = DayflowBackupManager.defaultBackupFilename()
    savePanel.allowedContentTypes = [
      UTType(filenameExtension: DayflowBackupManager.backupFileExtension) ?? .data
    ]
    savePanel.canCreateDirectories = true

    let response = savePanel.runModal()
    guard response == .OK, let url = savePanel.url else { return }

    isExportingBackup = true
    backupStatusMessage = nil
    backupErrorMessage = nil

    Task.detached(priority: .userInitiated) {
      do {
        let summary = try DayflowBackupManager.exportBackup(to: url)
        let sizeText = Self.formattedBackupSize(summary.sizeBytes)

        await MainActor.run {
          self.isExportingBackup = false
          self.backupErrorMessage = nil
          self.backupStatusMessage =
            "Saved Dayflow backup to \(summary.packageURL.lastPathComponent) (\(sizeText))."

          AnalyticsService.shared.capture(
            "dayflow_backup_exported",
            [
              "size_bytes": summary.sizeBytes,
              "includes_recordings": summary.includesRecordings,
              "includes_timelapses": summary.includesTimelapses,
              "includes_preferences": summary.includesPreferences,
            ])
        }
      } catch {
        await MainActor.run {
          self.isExportingBackup = false
          self.backupStatusMessage = nil
          self.backupErrorMessage = "Couldn't export backup: \(error.localizedDescription)"
        }
      }
    }
  }

  func chooseDayflowBackupToImport() {
    guard !isImportingBackup else { return }

    let openPanel = NSOpenPanel()
    openPanel.title = "Import Dayflow backup"
    openPanel.prompt = "Choose Backup"
    openPanel.canChooseFiles = true
    openPanel.canChooseDirectories = true
    openPanel.allowsMultipleSelection = false
    openPanel.treatsFilePackagesAsDirectories = true

    let response = openPanel.runModal()
    guard response == .OK, let url = openPanel.url else { return }

    pendingBackupImportURL = url
    backupErrorMessage = nil
    showBackupImportConfirm = true
  }

  func importSelectedDayflowBackup() {
    guard let url = pendingBackupImportURL, !isImportingBackup else { return }

    isImportingBackup = true
    backupStatusMessage = nil
    backupErrorMessage = nil
    let wasQueued = backupImportQueued

    Task.detached(priority: .userInitiated) {
      do {
        let summary = try DayflowBackupManager.stageRestorePackage(from: url)
        let sizeText = Self.formattedBackupSize(summary.sizeBytes)

        await MainActor.run {
          self.isImportingBackup = false
          self.backupImportQueued = true
          self.pendingBackupImportURL = nil
          self.backupErrorMessage = nil
          self.backupStatusMessage =
            "Backup is ready to restore on next launch (\(sizeText)). Quit and reopen Dayflow to apply it."

          AnalyticsService.shared.capture(
            "dayflow_backup_import_queued",
            [
              "size_bytes": summary.sizeBytes,
              "includes_recordings": summary.includesRecordings,
              "includes_timelapses": summary.includesTimelapses,
              "includes_preferences": summary.includesPreferences,
            ])
        }
      } catch {
        await MainActor.run {
          self.isImportingBackup = false
          self.backupImportQueued = wasQueued
          self.backupStatusMessage = nil
          self.backupErrorMessage = "Couldn't import backup: \(error.localizedDescription)"
        }
      }
    }
  }

  func cancelDayflowBackupImport() {
    pendingBackupImportURL = nil
    showBackupImportConfirm = false
  }

  func quitToApplyBackupImport() {
    AppDelegate.allowTermination = true
    NSApp.terminate(nil)
  }

  func reprocessSelectedDay() {
    guard !isReprocessingDay else { return }

    let normalizedDate = timelineDisplayDate(from: reprocessDayDate)
    let dayString = DateFormatter.yyyyMMdd.string(from: normalizedDate)

    isReprocessingDay = true
    reprocessErrorMessage = nil
    reprocessStatusMessage = "Starting reprocess for \(dayString)…"

    AnalysisManager.shared.reprocessDay(
      dayString,
      progressHandler: { [weak self] message in
        Task { @MainActor in
          self?.reprocessStatusMessage = message
        }
      },
      completion: { [weak self] result in
        Task { @MainActor in
          guard let self else { return }
          switch result {
          case .success:
            if self.reprocessStatusMessage == nil {
              self.reprocessStatusMessage = "Reprocess completed."
            }
          case .failure(let error):
            self.reprocessErrorMessage = error.localizedDescription
          }
          self.isReprocessingDay = false
        }
      })
  }

  @MainActor
  private func presentSavePanelAndWrite(
    exportText: String,
    startDate: Date,
    endDate: Date,
    dayCount: Int,
    activityCount: Int,
    skippedActivityCount: Int,
    format: TimelineExportFormat
  ) {
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"

    let savePanel = NSSavePanel()
    savePanel.title = format.panelTitle
    savePanel.prompt = "Export"
    savePanel.nameFieldStringValue =
      "Dayflow timeline \(dayFormatter.string(from: startDate)) to \(dayFormatter.string(from: endDate)).\(format.fileExtension)"
    savePanel.allowedContentTypes = format.allowedContentTypes
    savePanel.canCreateDirectories = true

    let response = savePanel.runModal()

    defer { isExportingTimelineRange = false }

    guard response == .OK, let url = savePanel.url else {
      exportStatusMessage = nil
      exportErrorMessage = "Export canceled"
      return
    }

    do {
      try exportText.write(to: url, atomically: true, encoding: .utf8)
      exportErrorMessage = nil
      if format == .calendar {
        openCalendarImport(for: url)
      }

      let skippedSuffix =
        skippedActivityCount > 0
        ? " Skipped \(skippedActivityCount) without readable start/end times." : ""
      exportStatusMessage =
        "Saved \(activityCount) activit\(activityCount == 1 ? "y" : "ies") across \(dayCount) day\(dayCount == 1 ? "" : "s") to \(url.lastPathComponent).\(format == .calendar ? " Opened it for Calendar import." : "")\(skippedSuffix)"

      AnalyticsService.shared.capture(
        "timeline_exported",
        [
          "start_day": dayFormatter.string(from: startDate),
          "end_day": dayFormatter.string(from: endDate),
          "day_count": dayCount,
          "activity_count": activityCount,
          "skipped_activity_count": skippedActivityCount,
          "format": format.analyticsName,
          "file_extension": url.pathExtension.lowercased(),
        ])
    } catch {
      exportStatusMessage = nil
      exportErrorMessage = "Couldn't save file: \(error.localizedDescription)"
    }
  }

  private func openCalendarImport(for url: URL) {
    let workspace = NSWorkspace.shared
    guard let calendarURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
      workspace.open(url)
      return
    }

    workspace.open(
      [url],
      withApplicationAt: calendarURL,
      configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      if let error {
        print("[Settings] Failed to open Calendar import: \(error.localizedDescription)")
      }
    }
  }
}

private enum TimelineExportFormat: Sendable {
  case markdown
  case calendar

  var analyticsName: String {
    switch self {
    case .markdown: return "markdown"
    case .calendar: return "ics"
    }
  }

  var fileExtension: String {
    switch self {
    case .markdown: return "md"
    case .calendar: return "ics"
    }
  }

  var panelTitle: String {
    switch self {
    case .markdown: return "Export timeline"
    case .calendar: return "Export timeline to Calendar"
    }
  }

  var allowedContentTypes: [UTType] {
    switch self {
    case .markdown:
      return [.text, .plainText]
    case .calendar:
      return [UTType(filenameExtension: "ics") ?? .data]
    }
  }
}

extension OtherSettingsViewModel {
  nonisolated private static func formattedBackupSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}
