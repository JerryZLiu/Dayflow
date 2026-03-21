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
  @Published var reprocessDayDate: Date
  @Published var isReprocessingDay = false
  @Published var reprocessStatusMessage: String?
  @Published var reprocessErrorMessage: String?
  @Published var showReprocessDayConfirm = false

  init() {
    analyticsEnabled = AnalyticsService.shared.isOptedIn
    showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    showTimelineAppIcons =
      UserDefaults.standard.object(forKey: "showTimelineAppIcons") as? Bool ?? true
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
      var totalActivities = 0
      var dayCount = 0

      while cursor <= endDate {
        let dayString = dayFormatter.string(from: cursor)
        let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
        totalActivities += cards.count
        let section = TimelineClipboardFormatter.makeMarkdown(for: cursor, cards: cards)
        sections.append(section)
        dayCount += 1

        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
      }

      let divider = "\n\n---\n\n"
      let exportText = sections.joined(separator: divider)

      await MainActor.run {
        self.presentSavePanelAndWrite(
          exportText: exportText,
          startDate: start,
          endDate: end,
          dayCount: dayCount,
          activityCount: totalActivities
        )
      }
    }
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

  // Use begin(completionHandler:) instead of runModal() so the save panel
  // doesn't block the main run loop. runModal() was triggering "App hanging
  // for at least 5000 ms" reports whenever the user took more than 5 seconds
  // to pick a save location (Sentry APPLE-MACOS-QM).
  @MainActor
  private func presentSavePanelAndWrite(
    exportText: String,
    startDate: Date,
    endDate: Date,
    dayCount: Int,
    activityCount: Int
  ) {
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"

    let savePanel = NSSavePanel()
    savePanel.title = "Export timeline"
    savePanel.prompt = "Export"
    savePanel.nameFieldStringValue =
      "Dayflow timeline \(dayFormatter.string(from: startDate)) to \(dayFormatter.string(from: endDate)).md"
    savePanel.allowedContentTypes = [.text, .plainText]
    savePanel.canCreateDirectories = true

    savePanel.begin { [weak self] response in
      // The completion handler is called on the main thread.
      Task { @MainActor in
        guard let self else { return }
        defer { self.isExportingTimelineRange = false }

        guard response == .OK, let url = savePanel.url else {
          self.exportStatusMessage = nil
          self.exportErrorMessage = "Export canceled"
          return
        }

        do {
          try exportText.write(to: url, atomically: true, encoding: .utf8)
          self.exportErrorMessage = nil
          self.exportStatusMessage =
            "Saved \(activityCount) activit\(activityCount == 1 ? "y" : "ies") across \(dayCount) day\(dayCount == 1 ? "" : "s") to \(url.lastPathComponent)"

          AnalyticsService.shared.capture(
            "timeline_exported",
            [
              "start_day": dayFormatter.string(from: startDate),
              "end_day": dayFormatter.string(from: endDate),
              "day_count": dayCount,
              "activity_count": activityCount,
              "format": "markdown",
              "file_extension": url.pathExtension.lowercased(),
            ])
        } catch {
          self.exportStatusMessage = nil
          self.exportErrorMessage = "Couldn't save file: \(error.localizedDescription)"
        }
      }
    }
  }
}
