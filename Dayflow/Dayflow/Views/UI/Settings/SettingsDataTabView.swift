import SwiftUI

struct SettingsDataTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @State private var activeExportDatePicker: ExportDatePicker?
  @State private var isReprocessDatePickerExpanded = false

  private enum ExportDatePicker {
    case start
    case end
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      exportDataCard
      reprocessDayCard
    }
  }

  private var exportDataCard: some View {
    SettingsCard(
      title: "Export your data",
      subtitle: "Move your timeline into tools you already use"
    ) {
      let rangeInvalid =
        timelineDisplayDate(from: viewModel.exportStartDate)
        > timelineDisplayDate(from: viewModel.exportEndDate)

      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .bottom, spacing: 12) {
          datePillField(
            label: "From",
            date: viewModel.exportStartDate,
            isExpanded: activeExportDatePicker == .start,
            accessibilityLabel: "Export start date",
            onTap: {
              withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                activeExportDatePicker = activeExportDatePicker == .start ? nil : .start
                isReprocessDatePickerExpanded = false
              }
            }
          )

          Image(systemName: "arrow.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.black.opacity(0.35))
            .padding(.bottom, 12)

          datePillField(
            label: "To",
            date: viewModel.exportEndDate,
            isExpanded: activeExportDatePicker == .end,
            accessibilityLabel: "Export end date",
            onTap: {
              withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                activeExportDatePicker = activeExportDatePicker == .end ? nil : .end
                isReprocessDatePickerExpanded = false
              }
            }
          )
        }

        if let activeExportDatePicker {
          inlineCalendarField(
            label: activeExportDatePicker == .start ? "Start date" : "End date",
            date: exportDateBinding(for: activeExportDatePicker),
            onDateSelected: {
              withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                self.activeExportDatePicker = nil
              }
            }
          )
          .transition(.move(edge: .top).combined(with: .opacity))
        }

        Text(
          "Use Markdown exports to archive in Notion, share with teammates, or paste into ChatGPT/Claude/Gemini for deeper analysis and planning."
        )
        .font(.custom("Nunito", size: 11.5))
        .foregroundColor(.black.opacity(0.55))
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
          DayflowSurfaceButton(
            action: viewModel.exportTimelineRange,
            content: {
              HStack(spacing: 8) {
                if viewModel.isExportingTimelineRange {
                  ProgressView().scaleEffect(0.75)
                } else {
                  Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                }
                Text(viewModel.isExportingTimelineRange ? "Exporting…" : "Export as Markdown")
                  .font(.custom("Nunito", size: 13))
                  .fontWeight(.semibold)
              }
              .frame(minWidth: 150)
            },
            background: Color(red: 0.25, green: 0.17, blue: 0),
            foreground: .white,
            borderColor: .clear,
            cornerRadius: 8,
            horizontalPadding: 20,
            verticalPadding: 10,
            showOverlayStroke: true
          )
          .disabled(viewModel.isExportingTimelineRange || rangeInvalid)

          if rangeInvalid {
            Text("Start date must be on or before end date.")
              .font(.custom("Nunito", size: 12))
              .foregroundColor(Color(hex: "E91515"))
          }
        }

        if let message = viewModel.exportStatusMessage {
          Text(message)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(Color(red: 0.1, green: 0.5, blue: 0.22))
        }

        if let error = viewModel.exportErrorMessage {
          Text(error)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(Color(hex: "E91515"))
        }
      }
      .padding(.top, 4)
    }
  }

  private var reprocessDayCard: some View {
    SettingsCard(
      title: "Reprocess day",
      subtitle: "Re-run analysis for every batch on one timeline day"
    ) {
      let normalizedDate = timelineDisplayDate(from: viewModel.reprocessDayDate)
      let dayString = DateFormatter.yyyyMMdd.string(from: normalizedDate)

      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          datePillField(
            label: "Day",
            date: viewModel.reprocessDayDate,
            isExpanded: isReprocessDatePickerExpanded,
            accessibilityLabel: "Reprocess day",
            disabled: viewModel.isReprocessingDay,
            onTap: {
              withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                isReprocessDatePickerExpanded.toggle()
                activeExportDatePicker = nil
              }
            }
          )

          if isReprocessDatePickerExpanded {
            inlineCalendarField(
              label: "Day",
              date: $viewModel.reprocessDayDate,
              disabled: viewModel.isReprocessingDay,
              onDateSelected: {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                  isReprocessDatePickerExpanded = false
                }
              }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
          }

          Text(dayString)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(.black.opacity(0.5))
        }

        Text(
          "This clears existing cards and observations for that day, then runs analysis again from the original recordings."
        )
        .font(.custom("Nunito", size: 11.5))
        .foregroundColor(.black.opacity(0.55))
        .fixedSize(horizontal: false, vertical: true)

        Text("Heads up: this can consume a large number of API calls.")
          .font(.custom("Nunito", size: 11.5))
          .foregroundColor(.black.opacity(0.7))

        HStack(spacing: 10) {
          DayflowSurfaceButton(
            action: { viewModel.showReprocessDayConfirm = true },
            content: {
              HStack(spacing: 8) {
                if viewModel.isReprocessingDay {
                  ProgressView().scaleEffect(0.75)
                } else {
                  Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                }
                Text(viewModel.isReprocessingDay ? "Reprocessing…" : "Reprocess day")
                  .font(.custom("Nunito", size: 13))
                  .fontWeight(.semibold)
              }
              .frame(minWidth: 150)
            },
            background: Color(red: 0.25, green: 0.17, blue: 0),
            foreground: .white,
            borderColor: .clear,
            cornerRadius: 8,
            horizontalPadding: 20,
            verticalPadding: 10,
            showOverlayStroke: true
          )
          .disabled(viewModel.isReprocessingDay)

          if let status = viewModel.reprocessStatusMessage {
            Text(status)
              .font(.custom("Nunito", size: 12))
              .foregroundColor(.black.opacity(0.6))
          }
        }

        if let error = viewModel.reprocessErrorMessage {
          Text(error)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(Color(hex: "E91515"))
        }
      }
      .alert("Reprocess day?", isPresented: $viewModel.showReprocessDayConfirm) {
        Button("Cancel", role: .cancel) {}
        Button("Reprocess", role: .destructive) { viewModel.reprocessSelectedDay() }
      } message: {
        Text(
          "This will delete existing timeline cards for \(dayString) and re-run analysis. It can consume many API calls."
        )
      }
    }
  }

  private func formattedTimelineDate(_ date: Date) -> String {
    Self.dateLabelFormatter.string(from: timelineDisplayDate(from: date))
  }

  private func exportDateBinding(for picker: ExportDatePicker) -> Binding<Date> {
    switch picker {
    case .start:
      return $viewModel.exportStartDate
    case .end:
      return $viewModel.exportEndDate
    }
  }

  private func datePillField(
    label: String,
    date: Date,
    isExpanded: Bool,
    accessibilityLabel: String,
    disabled: Bool = false,
    onTap: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(label)
        .font(.custom("Nunito", size: 11.5))
        .foregroundColor(.black.opacity(0.52))

      Button {
        guard !disabled else { return }
        onTap()
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "calendar")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0).opacity(disabled ? 0.4 : 0.75))

          Text(formattedTimelineDate(date))
            .font(.custom("Nunito", size: 14))
            .foregroundColor(.black.opacity(disabled ? 0.35 : 0.82))

          Spacer(minLength: 4)

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.black.opacity(disabled ? 0.2 : 0.35))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minWidth: 176)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(disabled ? 0.45 : 0.88))
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .stroke(
                  isExpanded
                    ? Color(hex: "F9C36B")
                    : Color(hex: "FFE0A5"),
                  lineWidth: 1.2
                )
            )
        )
        .shadow(color: .black.opacity(disabled ? 0 : 0.05), radius: 6, x: 0, y: 2)
      }
      .buttonStyle(.plain)
      .disabled(disabled)
      .accessibilityLabel(Text(accessibilityLabel))
    }
  }

  private func inlineCalendarField(
    label: String,
    date: Binding<Date>,
    disabled: Bool = false,
    onDateSelected: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.custom("Nunito", size: 11.5))
        .foregroundColor(.black.opacity(0.5))

      DayflowCalendarGrid(selectedDate: date, onDateSelected: onDateSelected)
        .disabled(disabled)
    }
    .opacity(disabled ? 0.7 : 1)
  }

  private static let dateLabelFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    return formatter
  }()
}

// MARK: - Custom Calendar Grid

private struct DayflowCalendarGrid: View {
  @Binding var selectedDate: Date
  var onDateSelected: () -> Void

  @State private var displayedMonth: Date = Date()
  @Environment(\.isEnabled) private var isEnabled

  private let calendar = Calendar.current
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

  private let accentColor = Color(hex: "E8854A")
  private let strokeColor = Color(hex: "FFE0A5")

  var body: some View {
    VStack(spacing: 12) {
      monthHeader
      weekdayLabels
      dayGrid
    }
    .padding(14)
    .frame(maxWidth: 290, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.white.opacity(isEnabled ? 0.82 : 0.45))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(strokeColor, lineWidth: 1.2)
        )
    )
    .shadow(color: .black.opacity(isEnabled ? 0.04 : 0), radius: 7, x: 0, y: 2)
    .onAppear {
      displayedMonth =
        calendar.date(
          from: calendar.dateComponents([.year, .month], from: selectedDate)
        ) ?? selectedDate
    }
  }

  // MARK: Month header with navigation arrows

  private var monthHeader: some View {
    HStack {
      Text(monthYearString)
        .font(.custom("Nunito", size: 14))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(0.82))

      Spacer()

      HStack(spacing: 4) {
        Button {
          changeMonth(by: -1)
        } label: {
          Image("CalendarLeftButton")
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()

        Button {
          changeMonth(by: 1)
        } label: {
          Image("CalendarRightButton")
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
  }

  // MARK: Weekday labels row

  private var weekdayLabels: some View {
    let symbols = calendar.veryShortWeekdaySymbols
    let firstWeekday = calendar.firstWeekday
    let ordered = Array(symbols[(firstWeekday - 1)...]) + Array(symbols[..<(firstWeekday - 1)])

    return LazyVGrid(columns: columns, spacing: 2) {
      ForEach(ordered, id: \.self) { symbol in
        Text(symbol)
          .font(.custom("Nunito", size: 11))
          .fontWeight(.medium)
          .foregroundColor(.black.opacity(0.35))
          .frame(maxWidth: .infinity)
          .frame(height: 24)
      }
    }
  }

  // MARK: Day number grid

  private var dayGrid: some View {
    let firstOfMonth = calendar.date(
      from: calendar.dateComponents([.year, .month], from: displayedMonth)
    )!
    let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)!.count
    let weekday = calendar.component(.weekday, from: firstOfMonth)
    let offset = (weekday - calendar.firstWeekday + 7) % 7

    return LazyVGrid(columns: columns, spacing: 2) {
      // Leading blank cells
      ForEach(0..<offset, id: \.self) { _ in
        Color.clear.frame(height: 32)
      }

      // Day cells
      ForEach(1...daysInMonth, id: \.self) { day in
        let date = makeDate(
          year: calendar.component(.year, from: firstOfMonth),
          month: calendar.component(.month, from: firstOfMonth),
          day: day)
        let isSelected = date.map { calendar.isDate($0, inSameDayAs: selectedDate) } ?? false
        let isToday = date.map { calendar.isDateInToday($0) } ?? false

        Button {
          if let date {
            selectedDate = date
            onDateSelected()
          }
        } label: {
          Text("\(day)")
            .font(.custom("Nunito", size: 13))
            .fontWeight(isSelected ? .bold : (isToday ? .semibold : .regular))
            .foregroundColor(isSelected ? .white : (isToday ? accentColor : .black.opacity(0.75)))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background {
              if isSelected {
                Circle()
                  .fill(accentColor)
                  .frame(width: 30, height: 30)
              } else if isToday {
                Circle()
                  .stroke(accentColor.opacity(0.4), lineWidth: 1.2)
                  .frame(width: 30, height: 30)
              }
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
  }

  // MARK: Helpers

  private var monthYearString: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM yyyy"
    return formatter.string(from: displayedMonth)
  }

  private func changeMonth(by value: Int) {
    var components = calendar.dateComponents([.year, .month], from: displayedMonth)
    components.month = (components.month ?? 1) + value
    displayedMonth = calendar.date(from: components) ?? displayedMonth
  }

  private func makeDate(year: Int, month: Int, day: Int) -> Date? {
    calendar.date(from: DateComponents(year: year, month: month, day: day))
  }
}
