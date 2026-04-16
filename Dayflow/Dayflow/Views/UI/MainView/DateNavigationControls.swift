import AppKit
import SwiftUI

struct DateNavigationControls: View {
  @Binding var selectedDate: Date
  @Binding var showDatePicker: Bool
  @Binding var lastDateNavMethod: String?
  @Binding var previousDate: Date

  // Emil Kowalski-style "expand and contract" press: a deeper press-in (scale
  // 0.88) with an underdamped spring so the release overshoots slightly past
  // 1.0 before settling. Applied only to the two chevrons — other
  // DayflowCircleButton callers keep the subtler 0.97/critically-damped feel.
  private static let chevronPressedScale: CGFloat = 0.88
  private static let chevronPressAnimation: Animation = .spring(
    response: 0.32, dampingFraction: 0.58
  )

  var body: some View {
    HStack(spacing: 12) {
      DayflowCircleButton(
        pressedScale: Self.chevronPressedScale,
        pressAnimation: Self.chevronPressAnimation
      ) {
        let from = selectedDate
        let to = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        previousDate = selectedDate
        selectedDate = normalizedTimelineDate(to)
        lastDateNavMethod = "prev"
        AnalyticsService.shared.capture(
          "date_navigation",
          [
            "method": "prev",
            "from_day": dayString(from),
            "to_day": dayString(to),
          ])
      } content: {
        Image(systemName: "chevron.left")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.3))
      }

      Button(action: {
        showDatePicker = true
        lastDateNavMethod = "picker"
      }) {
        DayflowPillButton(
          text: formatDateForDisplay(selectedDate),
          fixedWidth: calculateOptimalPillWidth()
        )
      }
      .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
      .pointingHandCursor()

      DayflowCircleButton(
        pressedScale: Self.chevronPressedScale,
        pressAnimation: Self.chevronPressAnimation
      ) {
        guard canNavigateForward(from: selectedDate) else { return }
        let from = selectedDate
        let tomorrow =
          Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        previousDate = selectedDate
        selectedDate = normalizedTimelineDate(tomorrow)
        lastDateNavMethod = "next"
        AnalyticsService.shared.capture(
          "date_navigation",
          [
            "method": "next",
            "from_day": dayString(from),
            "to_day": dayString(tomorrow),
          ])
      } content: {
        Image(systemName: "chevron.right")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(
            canNavigateForward(from: selectedDate)
              ? Color(red: 0.3, green: 0.3, blue: 0.3)
              : Color.gray.opacity(0.3)
          )
      }
    }
  }

  private func formatDateForDisplay(_ date: Date) -> String {
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

  private func dayString(_ date: Date) -> String {
    return cachedDayStringFormatter.string(from: date)
  }

  private func calculateOptimalPillWidth() -> CGFloat {
    let sampleText = "Today, Sep 30"
    let nsFont = NSFont(name: "InstrumentSerif-Regular", size: 18) ?? NSFont.systemFont(ofSize: 18)
    let textSize = sampleText.size(withAttributes: [.font: nsFont])
    let horizontalPadding: CGFloat = 11.77829 * 2
    return textSize.width + horizontalPadding + 8
  }
}
