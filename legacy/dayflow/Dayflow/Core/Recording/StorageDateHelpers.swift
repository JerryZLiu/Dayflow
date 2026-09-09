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

extension Date {
  /// Calculates the "day" based on a 4 AM start time.
  /// Returns the date string (YYYY-MM-DD) and the Date objects for the start and end of that day.
  func getDayInfoFor4AMBoundary() -> (dayString: String, startOfDay: Date, endOfDay: Date) {
    let calendar = Calendar.current
    guard let fourAMToday = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: self) else {
      print("Error: Could not calculate 4 AM for date \(self). Falling back to standard day.")
      let start = calendar.startOfDay(for: self)
      let end = calendar.date(byAdding: .day, value: 1, to: start)!
      return (DateFormatter.yyyyMMdd.string(from: start), start, end)
    }

    let startOfDay: Date
    if self < fourAMToday {
      startOfDay = calendar.date(byAdding: .day, value: -1, to: fourAMToday)!
    } else {
      startOfDay = fourAMToday
    }
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
    let dayString = DateFormatter.yyyyMMdd.string(from: startOfDay)
    return (dayString, startOfDay, endOfDay)
  }
}
