import AppKit
import Foundation
import SwiftUI
import UserNotifications

let dailyTodayDisplayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "'Today,' MMMM d"
  return formatter
}()

let dailyOtherDayDisplayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "EEEE, MMMM d"
  return formatter
}()

let dailyStandupSectionDayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "EEE, MMM d"
  return formatter
}()

let dailyStandupWeekdayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "EEEE"
  return formatter
}()

enum DailyGridConfig {
  static let visibleStartMinute: Double = 9 * 60
  static let visibleEndMinute: Double = 21 * 60
  static let slotDurationMinutes: Double = 15
  static let fallbackCategoryNames = ["Work", "Personal", "Distraction", "Idle"]
  static let fallbackColorHexes = ["B984FF", "6AADFF", "FF5950", "A0AEC0"]
}

enum DailyStandupCopyState: Equatable {
  case idle
  case copied
}

enum DailyStandupRegenerateState: Equatable {
  case idle
  case regenerating
  case regenerated
  case noData
}

struct DailyStandupSectionTitles {
  let highlights: String
  let tasks: String
  let blockers: String
}

struct DailyStandupDayInfo: Equatable, Sendable {
  let dayString: String
  let startOfDay: Date
  let endOfDay: Date
}

enum DailyAccessFlowStep {
  case intro
  case notifications
  case provider
}

struct DailyWorkflowSlotCardInfo: Sendable {
  let title: String
  let durationMinutes: Double
}
struct DailyWorkflowGridRow: Identifiable, Sendable {
  let id: String
  let name: String
  let colorHex: String
  let slotOccupancies: [Double]
  let slotCardInfos: [DailyWorkflowSlotCardInfo?]

  static func placeholderRows(slotCount: Int) -> [DailyWorkflowGridRow] {
    DailyGridConfig.fallbackCategoryNames.enumerated().map { index, name in
      DailyWorkflowGridRow(
        id: "placeholder-\(index)",
        name: name,
        colorHex: DailyGridConfig.fallbackColorHexes[
          index % DailyGridConfig.fallbackColorHexes.count],
        slotOccupancies: Array(repeating: 0, count: max(1, slotCount)),
        slotCardInfos: Array(repeating: nil, count: max(1, slotCount))
      )
    }
  }
}
struct DailyWorkflowTotalItem: Identifiable, Sendable {
  let id: String
  let name: String
  let minutes: Double
  let colorHex: String
}
struct DailyWorkflowDistractionMarker: Identifiable, Sendable {
  let id: String
  let title: String
  let startMinute: Double
  let endMinute: Double
}
struct DailyWorkflowComputationResult: Sendable {
  let rows: [DailyWorkflowGridRow]
  let totals: [DailyWorkflowTotalItem]
  let stats: [DailyWorkflowStatChip]
  let window: DailyWorkflowTimelineWindow
  let distractionMarkers: [DailyWorkflowDistractionMarker]
  let hasDistractionCategory: Bool
}
struct DailyWorkflowSegment: Sendable {
  let categoryKey: String
  let displayName: String
  let colorHex: String
  let startMinute: Double
  let endMinute: Double
  let hasDistraction: Bool
  let cardTitle: String
  let cardDurationMinutes: Double
}
struct DailyWorkflowStatChip: Identifiable, Sendable {
  let id: String
  let title: String
  let value: String

  static let placeholder: [DailyWorkflowStatChip] = [
    DailyWorkflowStatChip(id: "context-switched", title: L10n.tr("Context switched"), value: L10n.tr("%d times", 0)),
    DailyWorkflowStatChip(id: "interrupted", title: L10n.tr("Interrupted"), value: L10n.tr("%d times", 0)),
    DailyWorkflowStatChip(id: "focused-for", title: L10n.tr("Focused for"), value: L10n.tr("%d min", 0)),
    DailyWorkflowStatChip(id: "distracted-for", title: L10n.tr("Distracted for"), value: L10n.tr("%d min", 0)),
    DailyWorkflowStatChip(id: "transitioning-time", title: L10n.tr("Transitioning time"), value: L10n.tr("%d min", 0)),
  ]
}
struct DailyWorkflowTimelineWindow: Sendable {
  let startMinute: Double
  let endMinute: Double

  static let placeholder = DailyWorkflowTimelineWindow(
    startMinute: DailyGridConfig.visibleStartMinute,
    endMinute: DailyGridConfig.visibleEndMinute
  )

  var hourTickHours: [Int] {
    guard endMinute > startMinute else { return [9, 17] }

    let startHour = Int(floor(startMinute / 60))
    let endHour = Int(ceil(endMinute / 60))
    let adjustedEndHour = max(startHour + 1, endHour)
    return Array(startHour...adjustedEndHour)
  }

  var slotCount: Int {
    guard endMinute > startMinute else {
      let fallbackDuration = DailyGridConfig.visibleEndMinute - DailyGridConfig.visibleStartMinute
      return max(1, Int((fallbackDuration / DailyGridConfig.slotDurationMinutes).rounded()))
    }

    let durationMinutes = endMinute - startMinute
    return max(1, Int((durationMinutes / DailyGridConfig.slotDurationMinutes).rounded()))
  }

  var hourLabels: [String] {
    hourTickHours.map(formatAxisHourLabel(fromAbsoluteHour:))
  }
}
