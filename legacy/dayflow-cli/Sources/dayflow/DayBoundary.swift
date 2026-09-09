//
//  DayBoundary.swift
//  dayflow-cli
//
//  Dayflow's day runs 4 AM to 4 AM, and its week runs Monday 4 AM to Monday
//  4 AM. This mirrors StorageDateHelpers.swift and WeeklyDateRange.swift in
//  the app; when the CLI becomes an Xcode target these files should be
//  replaced by the app's own, compiled into both.
//

import Foundation

let dayKeyFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd"
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = Calendar.current.timeZone
  return formatter
}()

struct DayWindow {
  let dayKey: String  // "2026-03-11"
  let start: Date  // 4 AM that day
  let end: Date  // 4 AM the next day
}

/// The Dayflow day containing `date`. Before 4 AM this resolves to the
/// previous calendar day, matching Date.getDayInfoFor4AMBoundary() in the app.
func dayWindow(containing date: Date) -> DayWindow {
  let calendar = Calendar.current
  let fourAM = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: date) ?? date
  let start = date < fourAM ? calendar.date(byAdding: .day, value: -1, to: fourAM)! : fourAM
  let end = calendar.date(byAdding: .day, value: 1, to: start)!
  return DayWindow(dayKey: dayKeyFormatter.string(from: start), start: start, end: end)
}

/// The Dayflow day for an explicit "YYYY-MM-DD" label. Returns nil for
/// unparseable input. Matches fetchTimelineCards(forDay:) in the app: 4 AM on
/// the named day through 4 AM the next day.
func dayWindow(forKey key: String) -> DayWindow? {
  guard let dayDate = dayKeyFormatter.date(from: key) else { return nil }
  let calendar = Calendar.current
  var startComponents = calendar.dateComponents([.year, .month, .day], from: dayDate)
  startComponents.hour = 4
  guard let start = calendar.date(from: startComponents),
    let end = calendar.date(byAdding: .day, value: 1, to: start)
  else { return nil }
  return DayWindow(dayKey: key, start: start, end: end)
}

struct WeekWindow {
  let start: Date  // Monday 4 AM
  let end: Date  // next Monday 4 AM
}

/// The Dayflow week containing `date`. Mirrors WeeklyDateRange.containing().
func weekWindow(containing date: Date) -> WeekWindow {
  var calendar = Calendar.current
  calendar.firstWeekday = 2  // Monday

  let weekday = calendar.component(.weekday, from: date)
  // Days since Monday: weekday is 1=Sun...7=Sat, so Monday=2 maps to 0.
  let daysSinceMonday = (weekday + 5) % 7
  let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: date)!
  var components = calendar.dateComponents([.year, .month, .day], from: monday)
  components.hour = 4
  let mondayAtFourAM = calendar.date(from: components)!

  // If we're in the Monday-before-4AM sliver, we belong to the prior week.
  let start =
    date < mondayAtFourAM
    ? calendar.date(byAdding: .day, value: -7, to: mondayAtFourAM)!
    : mondayAtFourAM
  let end = calendar.date(byAdding: .day, value: 7, to: start)!
  return WeekWindow(start: start, end: end)
}

func formatDuration(minutes: Int) -> String {
  let hours = minutes / 60
  let mins = minutes % 60
  if hours == 0 { return "\(mins)m" }
  if mins == 0 { return "\(hours)h" }
  return "\(hours)h \(String(format: "%02d", mins))m"
}
