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
