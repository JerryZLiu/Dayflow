import Foundation

enum TimelineMode: String, CaseIterable, Identifiable {
  case day
  case week

  var id: String { rawValue }

  var title: String {
    switch self {
    case .day:
      return "Day"
    case .week:
      return "Week"
    }
  }
}

struct TimelineWeekDay: Identifiable, Equatable, Sendable {
  let date: Date
  let dayString: String
  let weekdayLabel: String
  let dayNumber: String

  var id: String { dayString }
}

struct TimelineWeekRange: Equatable, Sendable {
  let weekStart: Date
  let weekEnd: Date
  let days: [TimelineWeekDay]

  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    return calendar
  }()

  private static let titleFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM d"
    return formatter
  }()

  private static let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "E"
    return formatter
  }()

  private static let dayNumberFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d"
    return formatter
  }()

  private init(weekStart: Date, weekEnd: Date) {
    self.weekStart = weekStart
    self.weekEnd = weekEnd
    self.days = Self.buildDays(weekStart: weekStart)
  }

  private static func buildDays(weekStart: Date) -> [TimelineWeekDay] {
    let calendar = Self.calendar
    return (0..<7).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
        return nil
      }
      let normalizedDate = normalizedTimelineDate(date)
      return TimelineWeekDay(
        date: normalizedDate,
        dayString: DateFormatter.yyyyMMdd.string(from: normalizedDate),
        weekdayLabel: Self.weekdayFormatter.string(from: normalizedDate),
        dayNumber: Self.dayNumberFormatter.string(from: normalizedDate)
      )
    }
  }

  static func containing(_ date: Date, calendar: Calendar = Self.calendar) -> TimelineWeekRange {
    let timelineDate = timelineDisplayDate(from: date, now: date)
    let anchorDay = calendar.startOfDay(for: timelineDate)
    let weekday = calendar.component(.weekday, from: anchorDay)
    let daysFromWeekStart = (weekday - calendar.firstWeekday + 7) % 7
    let weekStartDay =
      calendar.date(byAdding: .day, value: -daysFromWeekStart, to: anchorDay)
      ?? anchorDay
    let weekStart =
      calendar.date(bySettingHour: 4, minute: 0, second: 0, of: weekStartDay) ?? weekStartDay
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
    return TimelineWeekRange(weekStart: weekStart, weekEnd: weekEnd)
  }

  func shifted(byWeeks weeks: Int, calendar: Calendar = Self.calendar) -> TimelineWeekRange {
    let shiftedStart = calendar.date(byAdding: .day, value: weeks * 7, to: weekStart) ?? weekStart
    let shiftedEnd = calendar.date(byAdding: .day, value: 7, to: shiftedStart) ?? shiftedStart
    return TimelineWeekRange(weekStart: shiftedStart, weekEnd: shiftedEnd)
  }

  var title: String {
    let displayedWeekEnd = Self.calendar.date(byAdding: .day, value: -1, to: weekEnd) ?? weekEnd
    return
      "\(Self.titleFormatter.string(from: weekStart)) - \(Self.titleFormatter.string(from: displayedWeekEnd))"
  }

  var canNavigateForward: Bool {
    weekStart < Self.containing(Date()).weekStart
  }

  var containsToday: Bool {
    contains(Date())
  }

  func contains(_ date: Date) -> Bool {
    let timelineDate = timelineDisplayDate(from: date, now: date)
    let dayStart = timelineDate.getDayInfoFor4AMBoundary().startOfDay
    return dayStart >= weekStart && dayStart < weekEnd
  }
}
