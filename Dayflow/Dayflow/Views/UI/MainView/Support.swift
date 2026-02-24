import SwiftUI

// MARK: - Cached DateFormatters (creating DateFormatters is expensive due to ICU initialization)
// These are internal (not private) so they can be shared with DateNavigationControls

let cachedTodayDisplayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "'Today,' MMM d"
  return formatter
}()

let cachedOtherDayDisplayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "E, MMM d"
  return formatter
}()

let cachedDayStringFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()

struct WeeklyHoursFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero {
      value = next
    }
  }
}

enum TimelineCopyState: Equatable {
  case idle
  case copying
  case copied
}

extension View {
  @ViewBuilder
  func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }
}

extension MainView {
  func formatDateForDisplay(_ date: Date) -> String {
    let now = Date()
    let calendar = Calendar.current

    let displayDate = timelineDisplayDate(from: date, now: now)
    let timelineToday = timelineDisplayDate(from: now, now: now)

    if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
      return cachedTodayDisplayFormatter.string(from: displayDate)
    } else {
      return cachedOtherDayDisplayFormatter.string(from: displayDate)
    }
  }

  func setSelectedDate(_ date: Date) {
    selectedDate = normalizedTimelineDate(date)
  }

  func dayString(_ date: Date) -> String {
    return cachedDayStringFormatter.string(from: date)
  }
}

struct BlurReplaceModifier: ViewModifier {
  let active: Bool

  func body(content: Content) -> some View {
    content
      .blur(radius: active ? 2 : 0)
      .opacity(active ? 0 : 1)
  }
}

extension AnyTransition {
  static var blurReplace: AnyTransition {
    .modifier(
      active: BlurReplaceModifier(active: true),
      identity: BlurReplaceModifier(active: false)
    )
  }
}

func canNavigateForward(from date: Date, now: Date = Date()) -> Bool {
  let calendar = Calendar.current
  let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
  let timelineToday = timelineDisplayDate(from: now, now: now)
  return calendar.compare(tomorrow, to: timelineToday, toGranularity: .day) != .orderedDescending
}

func normalizedTimelineDate(_ date: Date) -> Date {
  let calendar = Calendar.current
  if let normalized = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) {
    return normalized
  }
  let startOfDay = calendar.startOfDay(for: date)
  return calendar.date(byAdding: DateComponents(hour: 12), to: startOfDay) ?? date
}

func timelineDisplayDate(from date: Date, now: Date = Date()) -> Date {
  let calendar = Calendar.current
  var normalizedDate = normalizedTimelineDate(date)
  let normalizedNow = normalizedTimelineDate(now)
  let nowHour = calendar.component(.hour, from: now)

  if nowHour < 4 && calendar.isDate(normalizedDate, inSameDayAs: normalizedNow) {
    normalizedDate = calendar.date(byAdding: .day, value: -1, to: normalizedDate) ?? normalizedDate
  }

  return normalizedDate
}

func timelineIsToday(_ date: Date, now: Date = Date()) -> Bool {
  let calendar = Calendar.current
  let timelineDate = timelineDisplayDate(from: date, now: now)
  let timelineToday = timelineDisplayDate(from: now, now: now)
  return calendar.isDate(timelineDate, inSameDayAs: timelineToday)
}
