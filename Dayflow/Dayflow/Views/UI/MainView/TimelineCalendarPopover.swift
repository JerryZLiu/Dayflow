//
//  TimelineCalendarPopover.swift
//  Dayflow
//

import SwiftUI

// Compact month calendar popover (Figma 4291:4828).
// Single-variant rendering: every day is a cell in a flat grid, with the
// selected date shown as an 18pt orange circle. No week-pill; week-mode
// indication is conveyed elsewhere in the UI (the Day/Week toggle + the
// header title). Self-contained: tracks its own displayed month, reports
// picks via `onSelect`.
struct TimelineCalendarPopover: View {
  static let horizontalPadding: CGFloat = 28
  static let topPadding: CGFloat = 20
  static let bottomPadding: CGFloat = 20
  static let contentSpacing: CGFloat = 16
  static let columnWidth: CGFloat = 30
  static let columnSpacing: CGFloat = 12
  static let weekdayHeight: CGFloat = 20
  static let dayCellHeight: CGFloat = 24
  static let rowSpacing: CGFloat = 12
  static let selectedCircleSize: CGFloat = 24
  static let selectedWeekHighlightHeight: CGFloat = 30
  static let contentWidth: CGFloat = (columnWidth * 7) + (columnSpacing * 6)
  static let preferredWidth: CGFloat = contentWidth + (horizontalPadding * 2)

  @Binding var isPresented: Bool
  let selectedDate: Date
  let canSelectFutureDates: Bool
  let highlightsSelectedWeek: Bool
  let onSelect: (Date) -> Void

  @State private var displayMonth: Date

  // Monday-first ordering matches the timeline's week model, so each row in the
  // popover corresponds to a real Monday-Sunday week.
  private static let mondayCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .autoupdatingCurrent
    c.firstWeekday = 2
    return c
  }()

  private static let monthYearFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM yyyy"
    return f
  }()

  init(
    isPresented: Binding<Bool>,
    selectedDate: Date,
    canSelectFutureDates: Bool,
    highlightsSelectedWeek: Bool,
    onSelect: @escaping (Date) -> Void
  ) {
    self._isPresented = isPresented
    self.selectedDate = selectedDate
    self.canSelectFutureDates = canSelectFutureDates
    self.highlightsSelectedWeek = highlightsSelectedWeek
    self.onSelect = onSelect

    // Seed display month to the month containing the current selection.
    let calendar = Self.mondayCalendar
    let comps = calendar.dateComponents([.year, .month], from: selectedDate)
    let monthStart = calendar.date(from: comps) ?? selectedDate
    self._displayMonth = State(initialValue: monthStart)
  }

  var body: some View {
    let weeks = weeksToDisplay()

    VStack(alignment: .leading, spacing: Self.contentSpacing) {
      monthHeader
      weekdayRow
      dateGrid(weeks: weeks)
    }
    .frame(width: Self.contentWidth, alignment: .leading)
    .padding(.horizontal, Self.horizontalPadding)
    .padding(.top, Self.topPadding)
    .padding(.bottom, Self.bottomPadding)
    .frame(width: Self.preferredWidth, alignment: .topLeading)
    // Figma node 4291:4828: backdrop-blur 10pt + rgba(255,255,255,0.5) tint.
    .background {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.ultraThinMaterial)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.white.opacity(0.5))
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color(hex: "E9DAD1"), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 1)
    // Force the light variant of `.ultraThinMaterial` regardless of the
    // system appearance. Without this, macOS dark mode causes the material
    // to render as a dark blur — the popover looks like a gray slab even
    // though the rest of the app is light. Dayflow's palette is tuned for
    // light mode; the Figma explicitly specifies a light translucent card.
    .environment(\.colorScheme, .light)
  }

  private var monthHeader: some View {
    HStack(spacing: 0) {
      Text(Self.monthYearFormatter.string(from: displayMonth))
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black)
        .lineLimit(1)

      Spacer(minLength: 0)

      HStack(spacing: 2) {
        monthNavButton(systemName: "chevron.left") { shiftMonth(by: -1) }
        monthNavButton(systemName: "chevron.right") { shiftMonth(by: 1) }
      }
    }
    .frame(height: 20)
  }

  // Figma nav chevrons are plain gray glyphs, not the app's orange header
  // arrows. Using SF Symbols here keeps the size and tint exact while
  // avoiding extra asset work for a tiny 16pt icon.
  private func monthNavButton(
    systemName: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(Color(hex: "A8A09A"))
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  // Weekday header uses Instrument Serif 12pt per Figma (not Figtree).
  private var weekdayRow: some View {
    // `id: \.self` on ["S","M","T","W","T","F","S"] duplicates the "T" and
    // "S" IDs — SwiftUI logs "the ID T occurs multiple times" and the diff
    // becomes undefined. Keying by index is correct here: labels are
    // position-bound, not identity-bound.
    let labels = weekdayLabels()
    return HStack(spacing: Self.columnSpacing) {
      ForEach(labels.indices, id: \.self) { i in
        Text(labels[i])
          .font(.custom("InstrumentSerif-Regular", size: 12))
          .foregroundColor(.black)
          .frame(width: Self.columnWidth, height: Self.weekdayHeight)
      }
    }
  }

  // Fixed column widths keep weekday labels and dates perfectly aligned.
  private func dateGrid(weeks: [[CalendarDay]]) -> some View {
    return VStack(alignment: .leading, spacing: Self.rowSpacing) {
      ForEach(weeks.indices, id: \.self) { rowIndex in
        let week = weeks[rowIndex]
        let isSelectedWeek = highlightsSelectedWeek && isWeekSelected(week)

        ZStack {
          if isSelectedWeek {
            Capsule(style: .continuous)
              .fill(Color(hex: "FC7103"))
              .frame(
                width: Self.contentWidth,
                height: Self.selectedWeekHighlightHeight
              )
          }

          HStack(spacing: Self.columnSpacing) {
            ForEach(week) { day in
              dateCell(day: day, isInSelectedWeek: isSelectedWeek)
            }
          }
        }
        .frame(
          width: Self.contentWidth,
          height: Self.selectedWeekHighlightHeight
        )
      }
    }
  }

  private func dateCell(day: CalendarDay, isInSelectedWeek: Bool) -> some View {
    let calendar = Self.mondayCalendar
    let isSelected = calendar.isDate(day.date, inSameDayAs: selectedDate)
    let showsSelectedDayCircle = isSelected && !highlightsSelectedWeek
    let isDisabled: Bool = {
      guard !canSelectFutureDates else { return false }
      let todayStart = calendar.startOfDay(
        for: timelineDisplayDate(from: Date()).timelineLabelDate())
      let cellStart = calendar.startOfDay(for: day.date)
      return cellStart > todayStart
    }()
    let foregroundColor: Color = {
      if isInSelectedWeek {
        return (!day.isCurrentMonth || isDisabled) ? .white.opacity(0.55) : .white
      }
      if !day.isCurrentMonth || isDisabled {
        return Color(hex: "C1B5AC")
      }
      return showsSelectedDayCircle ? .white : .black
    }()

    return Button {
      guard !isDisabled else { return }
      onSelect(day.date)
    } label: {
      ZStack {
        if showsSelectedDayCircle {
          Circle()
            .fill(Color(hex: "FC7103"))
            .frame(width: Self.selectedCircleSize, height: Self.selectedCircleSize)
        }
        Text(day.label)
          .font(.custom("Figtree", size: 12))
          .foregroundColor(foregroundColor)
      }
      .frame(width: Self.columnWidth, height: Self.dayCellHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .pointingHandCursor(enabled: !isDisabled)
  }

  // MARK: - Data & navigation

  private struct CalendarDay: Identifiable {
    let date: Date
    let label: String
    let isCurrentMonth: Bool

    var id: Date { date }
  }

  private func shiftMonth(by months: Int) {
    let calendar = Self.mondayCalendar
    if let newMonth = calendar.date(byAdding: .month, value: months, to: displayMonth) {
      displayMonth = newMonth
    }
  }

  // Locale weekday symbols, rotated so Monday appears first.
  private func weekdayLabels() -> [String] {
    let calendar = Self.mondayCalendar
    let symbols = calendar.veryShortWeekdaySymbols
    let offset = calendar.firstWeekday - 1
    guard offset >= 0, offset < symbols.count else { return symbols }
    return Array(symbols[offset...]) + Array(symbols[..<offset])
  }

  // Build the visible month grid with leading/trailing days as needed to fill
  // complete Monday-Sunday weeks.
  private func daysToDisplay() -> [CalendarDay] {
    let calendar = Self.mondayCalendar
    let monthStart = displayMonth
    guard let monthRange = calendar.range(of: .day, in: .month, for: monthStart) else {
      return []
    }

    let firstWeekday = calendar.component(.weekday, from: monthStart)
    let leadingCount = (firstWeekday - calendar.firstWeekday + 7) % 7

    var days: [CalendarDay] = []

    // Leading days from the previous month.
    if leadingCount > 0,
      let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart),
      let prevMonthRange = calendar.range(of: .day, in: .month, for: prevMonthStart)
    {
      let prevLast = prevMonthRange.count
      let startDay = prevLast - leadingCount + 1
      for offset in 0..<leadingCount {
        if let date = calendar.date(
          byAdding: .day, value: startDay - 1 + offset, to: prevMonthStart)
        {
          days.append(
            CalendarDay(
              date: date,
              label: "\(calendar.component(.day, from: date))",
              isCurrentMonth: false
            )
          )
        }
      }
    }

    // Current month.
    for offset in 0..<monthRange.count {
      if let date = calendar.date(byAdding: .day, value: offset, to: monthStart) {
        days.append(
          CalendarDay(
            date: date,
            label: "\(calendar.component(.day, from: date))",
            isCurrentMonth: true
          )
        )
      }
    }

    // Trailing days from next month to complete the last visible week.
    let trailingNeeded = (7 - (days.count % 7)) % 7
    if trailingNeeded > 0,
      let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)
    {
      for offset in 0..<trailingNeeded {
        if let date = calendar.date(byAdding: .day, value: offset, to: nextMonthStart) {
          days.append(
            CalendarDay(
              date: date,
              label: "\(calendar.component(.day, from: date))",
              isCurrentMonth: false
            )
          )
        }
      }
    }

    return days
  }

  private func weeksToDisplay() -> [[CalendarDay]] {
    let days = daysToDisplay()
    return stride(from: 0, to: days.count, by: 7).map { start in
      Array(days[start..<min(start + 7, days.count)])
    }
  }

  private func isWeekSelected(_ week: [CalendarDay]) -> Bool {
    guard let firstDay = week.first else { return false }
    return isDateInSelectedWeek(firstDay.date)
  }

  private func isDateInSelectedWeek(_ date: Date) -> Bool {
    let calendar = Self.mondayCalendar
    return calendar.isDate(date, equalTo: selectedDate, toGranularity: .weekOfYear)
  }
}
