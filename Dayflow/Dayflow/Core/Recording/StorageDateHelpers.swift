//
//  StorageManager.swift
//  Dayflow
//

import Foundation
import GRDB
import Sentry

extension DateFormatter {
  static let yyyyMMdd: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = Calendar.current.timeZone
    return formatter
  }()
}

/// User-configurable hour (0–23, local time) at which Dayflow rolls over to a
/// new "day". Historically this was hard-coded to 4 AM; it is now adjustable so
/// people with non-standard schedules can attribute late-night activity to the
/// correct day. Defaults to 4 AM to preserve the original behavior.
enum DayBoundaryPreferences {
  static let dayBoundaryHourKey = "dayBoundaryHour"
  static let defaultHour = 4

  /// Hour (0–23) at which a new day begins. Reads/writes `UserDefaults`,
  /// clamped to a valid hour and falling back to `defaultHour` when unset.
  static var boundaryHour: Int {
    get {
      guard let stored = UserDefaults.standard.object(forKey: dayBoundaryHourKey) as? Int else {
        return defaultHour
      }
      return min(max(stored, 0), 23)
    }
    set {
      UserDefaults.standard.set(min(max(newValue, 0), 23), forKey: dayBoundaryHourKey)
    }
  }

  /// The day boundary expressed as minutes since midnight (`boundaryHour * 60`).
  static var boundaryMinutes: Int { boundaryHour * 60 }
}

/// Whether a logical day that crosses midnight is labeled by the calendar date
/// it STARTS on or the date it ENDS on. This is display-only — storage and
/// fetch keys always use the start date, so switching modes needs no migration.
enum DayLabelMode: String {
  case startDate
  case endDate
}

enum DayLabelPreferences {
  static let dayLabelModeKey = "dayLabelMode"

  static var mode: DayLabelMode {
    get {
      DayLabelMode(rawValue: UserDefaults.standard.string(forKey: dayLabelModeKey) ?? "")
        ?? .startDate
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: dayLabelModeKey) }
  }

  static var usesEndDate: Bool {
    mode == .endDate && DayBoundaryPreferences.boundaryHour > 0
  }
}

extension Date {
  /// Converts a timeline "representative" date (as returned by
  /// `timelineDisplayDate`, anchored on the day's START calendar date) into the
  /// calendar date to SHOW the user, honoring `DayLabelPreferences`. In end-date
  /// mode with a boundary after midnight this is the following calendar date.
  /// Display only — does not affect storage or fetch keys.
  func timelineLabelDate() -> Date {
    guard DayLabelPreferences.usesEndDate else {
      return self
    }
    return Calendar.current.date(byAdding: .day, value: 1, to: self) ?? self
  }

  /// Inverse of `timelineLabelDate()`: maps a user-facing (label) date back to
  /// the internal timeline representative date used for navigation and fetches.
  func timelineDateFromLabel() -> Date {
    guard DayLabelPreferences.usesEndDate else {
      return self
    }
    return Calendar.current.date(byAdding: .day, value: -1, to: self) ?? self
  }

  /// Storage keys remain anchored to the logical day's start date. This is
  /// intentionally the inverse of the user-facing label mapping.
  var timelineStorageDayStringForLabel: String {
    DateFormatter.yyyyMMdd.string(from: timelineDateFromLabel())
  }
}

extension Date {
  /// Calculates the "day" this date belongs to, using the configurable day
  /// boundary hour (`DayBoundaryPreferences.boundaryHour`, default 4 AM).
  /// Returns the date string (YYYY-MM-DD) and the Date objects for the start and end of that day.
  func getDayInfoFor4AMBoundary() -> (dayString: String, startOfDay: Date, endOfDay: Date) {
    let calendar = Calendar.current
    let boundaryHour = DayBoundaryPreferences.boundaryHour
    guard let boundaryStartToday = calendar.date(bySettingHour: boundaryHour, minute: 0, second: 0, of: self) else {
      print("Error: Could not calculate day boundary (hour \(boundaryHour)) for date \(self). Falling back to standard day.")
      let start = calendar.startOfDay(for: self)
      let end = calendar.date(byAdding: .day, value: 1, to: start)!
      return (DateFormatter.yyyyMMdd.string(from: start), start, end)
    }

    let startOfDay: Date
    if self < boundaryStartToday {
      startOfDay = calendar.date(byAdding: .day, value: -1, to: boundaryStartToday)!
    } else {
      startOfDay = boundaryStartToday
    }
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
    let dayString = DateFormatter.yyyyMMdd.string(from: startOfDay)
    return (dayString, startOfDay, endOfDay)
  }
}
