//
//  StorageManager.swift
//  Dayflow
//

import Foundation
import GRDB
import Sentry

extension DateFormatter {
  /// Day keys like "2026-11-17". The zone is left unset on purpose, so the formatter follows the
  /// Mac's current timezone even after it changes while the app is running.
  static let yyyyMMdd: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}

extension Date {
  /// Calculates the "day" based on a 4 AM start time.
  /// Returns the date string (YYYY-MM-DD) and the Date objects for the start and end of that day.
  /// Pass a calendar to work out the day in a zone other than the Mac's current one, such as the
  /// zone a batch was recorded in.
  func getDayInfoFor4AMBoundary(in calendar: Calendar = .current) -> (
    dayString: String, startOfDay: Date, endOfDay: Date
  ) {
    guard let fourAMToday = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: self) else {
      print("Error: Could not calculate 4 AM for date \(self). Falling back to standard day.")
      let start = calendar.startOfDay(for: self)
      let end = calendar.date(byAdding: .day, value: 1, to: start)!
      return (ClockTime.dayString(from: start, in: calendar.timeZone), start, end)
    }

    let startOfDay: Date
    if self < fourAMToday {
      startOfDay = calendar.date(byAdding: .day, value: -1, to: fourAMToday)!
    } else {
      startOfDay = fourAMToday
    }
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
    let dayString = ClockTime.dayString(from: startOfDay, in: calendar.timeZone)
    return (dayString, startOfDay, endOfDay)
  }
}

/// Converts between timeline clock labels like "2:30 PM" and real moments.
///
/// Cards are shown in the timezone they were recorded in, so every conversion names its zone.
enum ClockTime {
  static func calendar(in timeZone: TimeZone) -> Calendar {
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    return calendar
  }

  /// "2:30 PM" for a moment, as a clock in `timeZone` shows it.
  static func label(for date: Date, in timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    return formatter.string(from: date)
  }

  /// "2026-11-17" for a moment, as a calendar in `timeZone` shows it.
  static func dayString(from date: Date, in timeZone: TimeZone) -> String {
    let shared = DateFormatter.yyyyMMdd
    guard shared.timeZone != timeZone else { return shared.string(from: date) }
    let formatter = DateFormatter()
    formatter.dateFormat = shared.dateFormat
    formatter.timeZone = timeZone
    return formatter.string(from: date)
  }

  /// Hour (0-23) and minute of a label like "2:30 PM", or nil if it isn't one.
  static func hourAndMinute(of label: String) -> (hour: Int, minute: Int)? {
    let compact = label.uppercased().filter { !$0.isWhitespace }
    guard compact.count >= 5 else { return nil }
    let meridiem = compact.suffix(2)
    let parts = compact.dropLast(2).split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
      (1...12).contains(hour), (0...59).contains(minute), meridiem == "AM" || meridiem == "PM"
    else { return nil }
    return (hour % 12 + (meridiem == "PM" ? 12 : 0), minute)
  }

  /// The moment nearest `anchor` when a clock in `calendar`'s zone reads hour:minute.
  ///
  /// It checks the day before, the same day and the day after, so labels just across midnight
  /// work. On the night clocks fall back it checks both copies of the repeated hour, and a time
  /// skipped when clocks spring forward moves to the same moment an hour later on the clock.
  static func resolve(hour: Int, minute: Int, nearest anchor: Date, calendar: Calendar) -> Date? {
    candidates(hour: hour, minute: minute, around: anchor, calendar: calendar).min {
      abs($0.timeIntervalSince(anchor)) < abs($1.timeIntervalSince(anchor))
    }
  }

  /// The first moment at or after `start` when a clock in `calendar`'s zone reads hour:minute.
  /// Used for a card's end, given its start.
  static func resolve(hour: Int, minute: Int, onOrAfter start: Date, calendar: Calendar) -> Date? {
    candidates(hour: hour, minute: minute, around: start, calendar: calendar)
      .filter { $0 >= start }
      .min()
  }

  /// Every moment on the day before, of and after `anchor` when the clock reads hour:minute.
  private static func candidates(hour: Int, minute: Int, around anchor: Date, calendar: Calendar)
    -> [Date]
  {
    let anchorDay = calendar.startOfDay(for: anchor)
    let target = DateComponents(hour: hour, minute: minute, second: 0)
    var candidates: [Date] = []
    for dayOffset in -1...1 {
      guard let day = calendar.date(byAdding: .day, value: dayOffset, to: anchorDay) else {
        continue
      }
      for policy in [Calendar.RepeatedTimePolicy.first, .last] {
        if let date = calendar.nextDate(
          after: day.addingTimeInterval(-1),
          matching: target,
          matchingPolicy: .nextTimePreservingSmallerComponents,
          repeatedTimePolicy: policy,
          direction: .forward
        ) {
          candidates.append(date)
        }
      }
    }
    return candidates
  }

  /// The UTC offset, in seconds, a card was labelled in, worked out from its clock label, its
  /// start timestamp and its stored day. Used to fill in cards saved before offsets were stored.
  static func inferredUTCOffset(label: String, startTs: Int, day: String) -> Int? {
    guard let clockTime = hourAndMinute(of: label) else { return nil }
    let labelMinutes = clockTime.hour * 60 + clockTime.minute
    let utcMinutes = ((startTs % 86_400) + 86_400) % 86_400 / 60
    let difference = labelMinutes - utcMinutes
    // Real offsets run from UTC-12 to UTC+14.
    let candidates = [difference - 1440, difference, difference + 1440].filter {
      (-12 * 60)...(14 * 60) ~= $0
    }

    let matchingDay = candidates.first { offsetMinutes in
      logicalDay(of: startTs, offset: offsetMinutes * 60) == day
    }
    let offsetMinutes =
      matchingDay ?? candidates.min { abs($0) < abs($1) } ?? difference
    // Round to the nearest quarter hour; every real offset is a multiple of 15 minutes.
    let rounded = Int((Double(offsetMinutes) / 15).rounded()) * 15
    return rounded * 60
  }

  /// The 4 AM day key ("2026-11-17") of a moment, read on a clock `offset` seconds east of UTC.
  static func logicalDay(of timestamp: Int, offset: Int) -> String {
    // The local clock reading, written as if it were UTC, with the 4 AM rule applied.
    let shifted = Date(timeIntervalSince1970: TimeInterval(timestamp + offset - 4 * 3600))
    return utcDayFormatter.string(from: shifted)
  }

  private static let utcDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()
}
