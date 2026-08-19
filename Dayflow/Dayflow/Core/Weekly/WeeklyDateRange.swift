import Foundation

struct WeeklyDateRange: Equatable, Sendable {
  let weekStart: Date
  let weekEnd: Date

  private static let titleStartFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter
  }()

  private static let titleEndFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter
  }()

  static func containing(_ date: Date, calendar: Calendar = Self.calendar) -> WeeklyDateRange {
    let labelDate = timelineDisplayDate(from: date, now: date).timelineLabelDate()
    return containingLabelDate(labelDate, calendar: calendar)
  }

  static func containingLabelDate(
    _ date: Date, calendar: Calendar = Self.calendar
  ) -> WeeklyDateRange {
    let monday = calendar.date(
      from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
    let weekStart =
      calendar.date(
        bySettingHour: DayBoundaryPreferences.boundaryHour, minute: 0, second: 0, of: monday)
      ?? monday
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
    return WeeklyDateRange(weekStart: weekStart, weekEnd: weekEnd)
  }

  func shifted(byWeeks weeks: Int, calendar: Calendar = Self.calendar) -> WeeklyDateRange {
    let shiftedStart = calendar.date(byAdding: .day, value: weeks * 7, to: weekStart) ?? weekStart
    let shiftedEnd = calendar.date(byAdding: .day, value: 7, to: shiftedStart) ?? shiftedStart
    return WeeklyDateRange(weekStart: shiftedStart, weekEnd: shiftedEnd)
  }

  var canNavigateForward: Bool {
    weekStart < Self.containing(Date()).weekStart
  }

  var storageRange: (start: Date, end: Date) {
    let start = normalizedTimelineDate(weekStart.timelineDateFromLabel())
    let end = Self.calendar.date(byAdding: .day, value: 7, to: start) ?? start
    return (start, end)
  }

  var title: String {
    let displayWeekEnd = Self.calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
    let startText = Self.titleStartFormatter.string(from: weekStart)
    let endText = Self.titleEndFormatter.string(from: displayWeekEnd)
    return "\(startText) - \(endText)"
  }

  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }()

}
