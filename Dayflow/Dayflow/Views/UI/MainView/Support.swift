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
  var weekInspectorWidth: CGFloat { 340 }

  var timelineWeekRange: TimelineWeekRange {
    cachedTimelineWeekRange
  }

  var isWeekTimelineInspectorVisible: Bool {
    timelineMode == .week && selectedActivity != nil
  }

  var timelineInspectorWidth: CGFloat {
    switch timelineMode {
    case .day:
      return 358
    case .week:
      return isWeekTimelineInspectorVisible ? weekInspectorWidth : 0
    }
  }

  var timelineInspectorDividerWidth: CGFloat {
    switch timelineMode {
    case .day:
      return 1
    case .week:
      return isWeekTimelineInspectorVisible ? 1 : 0
    }
  }

  var shellAnimation: Animation {
    return .spring(duration: 0.28, bounce: 0)
  }

  var timelineModeSwitchAnimation: Animation {
    .spring(response: 0.26, dampingFraction: 0.84)
  }

  var timelineModeContentAnimation: Animation {
    .easeInOut(duration: 0.22)
  }

  var inspectorContentAnimation: Animation {
    return .easeOut(duration: 0.18)
  }

  var timelineTitleText: String {
    switch timelineMode {
    case .day:
      return formatDateForDisplay(selectedDate)
    case .week:
      return timelineWeekRange.title
    }
  }

  var canNavigateTimelineForward: Bool {
    switch timelineMode {
    case .day:
      return canNavigateForward(from: selectedDate)
    case .week:
      return timelineWeekRange.canNavigateForward
    }
  }

  var shouldShowTodayButton: Bool {
    switch timelineMode {
    case .day:
      return !timelineIsToday(selectedDate)
    case .week:
      return !timelineWeekRange.containsToday
    }
  }

  var timelineTrackedMinutesParts: (bold: String, rest: String) {
    let totalHours = Int(weeklyTrackedMinutes / 60)
    switch timelineMode {
    case .day:
      return ("\(totalHours) hours", " tracked this week")
    case .week:
      return ("\(totalHours) hours", " of activities tracked this week")
    }
  }

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

  func previousTimelineDate() -> Date {
    switch timelineMode {
    case .day:
      return Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
    case .week:
      return Calendar.current.date(byAdding: .day, value: -7, to: selectedDate) ?? selectedDate
    }
  }

  func nextTimelineDate() -> Date {
    switch timelineMode {
    case .day:
      return Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
    case .week:
      return Calendar.current.date(byAdding: .day, value: 7, to: selectedDate) ?? selectedDate
    }
  }

  func dayString(_ date: Date) -> String {
    return cachedDayStringFormatter.string(from: date)
  }

  func setTimelineMode(_ mode: TimelineMode) {
    guard timelineMode != mode else { return }

    withAnimation(timelineModeContentAnimation) {
      timelineMode = mode
      selectedActivity = nil
    }

    loadWeeklyTrackedMinutes()
  }

  func selectTimelineActivity(_ activity: TimelineActivity) {
    switch timelineMode {
    case .day:
      selectedActivity = activity
    case .week:
      if isWeekTimelineInspectorVisible {
        guard selectedActivity?.id != activity.id else { return }
        withAnimation(inspectorContentAnimation) {
          selectedActivity = activity
        }
      } else {
        withAnimation(shellAnimation) {
          selectedActivity = activity
        }
      }
    }
  }

  func clearTimelineSelection(animated: Bool = true) {
    guard selectedActivity != nil else { return }

    guard animated else {
      selectedActivity = nil
      return
    }

    let animation = timelineMode == .week ? shellAnimation : inspectorContentAnimation
    withAnimation(animation) {
      selectedActivity = nil
    }
  }

  func navigateTimeline(to date: Date, method: String) {
    let from = selectedDate
    previousDate = selectedDate
    clearTimelineSelection(animated: false)
    setSelectedDate(date)
    lastDateNavMethod = method

    AnalyticsService.shared.capture(
      "date_navigation",
      [
        "method": method,
        "timeline_mode": timelineMode.rawValue,
        "from_day": dayString(from),
        "to_day": dayString(date),
      ]
    )
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
