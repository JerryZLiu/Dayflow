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
    let mondayAtFourAM = mondayBoundary(containing: date, calendar: calendar)
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: mondayAtFourAM) ?? mondayAtFourAM
    return WeeklyDateRange(weekStart: mondayAtFourAM, weekEnd: weekEnd)
  }

  func shifted(byWeeks weeks: Int, calendar: Calendar = Self.calendar) -> WeeklyDateRange {
    let shiftedStart = calendar.date(byAdding: .day, value: weeks * 7, to: weekStart) ?? weekStart
    let shiftedEnd = calendar.date(byAdding: .day, value: 7, to: shiftedStart) ?? shiftedStart
    return WeeklyDateRange(weekStart: shiftedStart, weekEnd: shiftedEnd)
  }

  var canNavigateForward: Bool {
    weekStart < Self.containing(Date()).weekStart
  }

  var title: String {
    let workweekEnd = Self.calendar.date(byAdding: .day, value: 4, to: weekStart) ?? weekStart
    let startText = Self.titleStartFormatter.string(from: weekStart)
    let endText = Self.titleEndFormatter.string(from: workweekEnd)
    return "\(startText) - \(endText)"
  }

  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }()

  private static func mondayBoundary(containing date: Date, calendar: Calendar) -> Date {
    let baseWeekStart =
      calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))
      ?? date
    let mondayAtFourAM =
      calendar.date(bySettingHour: 4, minute: 0, second: 0, of: baseWeekStart) ?? baseWeekStart

    if date < mondayAtFourAM {
      return calendar.date(byAdding: .day, value: -7, to: mondayAtFourAM) ?? mondayAtFourAM
    }

    return mondayAtFourAM
  }
}
