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
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      exportSection
      reprocessSection
    }
  }

  // MARK: - Export

  private var exportSection: some View {
    let rangeInvalid =
      timelineDisplayDate(from: viewModel.exportStartDate)
      > timelineDisplayDate(from: viewModel.exportEndDate)

    return SettingsSection(
      title: "Export your data",
      subtitle: "Move your timeline into tools you already use."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center, spacing: 10) {
          datePill(
            label: "From",
            date: viewModel.exportStartDate,
            isExpanded: activeExportDatePicker == .start,
            accessibilityLabel: "Export start date",
            onTap: {
              withAnimation(.easeOut(duration: 0.2)) {
                activeExportDatePicker = activeExportDatePicker == .start ? nil : .start
                isReprocessDatePickerExpanded = false
              }
            }
          )

          Image(systemName: "arrow.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(SettingsStyle.meta)

          datePill(
            label: "To",
            date: viewModel.exportEndDate,
            isExpanded: activeExportDatePicker == .end,
            accessibilityLabel: "Export end date",
            onTap: {
              withAnimation(.easeOut(duration: 0.2)) {
                activeExportDatePicker = activeExportDatePicker == .end ? nil : .end
                isReprocessDatePickerExpanded = false
              }
            }
          )
        }

        if let activeExportDatePicker {
          inlineCalendar(
            date: exportDateBinding(for: activeExportDatePicker),
            onDateSelected: {
              withAnimation(.easeOut(duration: 0.2)) {
                self.activeExportDatePicker = nil
              }
            }
          )
          .transition(.move(edge: .top).combined(with: .opacity))
        }

        Text(
          "Use Markdown exports to archive in Notion, share with teammates, or paste into ChatGPT / Claude / Gemini for deeper analysis."
        )
        .font(.custom("Nunito", size: 12))
        .foregroundColor(SettingsStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
          SettingsPrimaryButton(
            title: viewModel.isExportingTimelineRange ? "Exporting…" : "Export as Markdown",
            systemImage: viewModel.isExportingTimelineRange ? nil : "square.and.arrow.down",
            isLoading: viewModel.isExportingTimelineRange,
            isDisabled: rangeInvalid,
            action: viewModel.exportTimelineRange
          )

          if rangeInvalid {
            Text("Start must be on or before end.")
              .font(.custom("Nunito", size: 12))
              .foregroundColor(SettingsStyle.destructive)
          }
        }

        if let message = viewModel.exportStatusMessage {
          Text(message)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(SettingsStyle.statusGood)
        }

        if let error = viewModel.exportErrorMessage {
          Text(error)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(SettingsStyle.destructive)
        }
      }
    }
  }

  // MARK: - Reprocess day

  private var reprocessSection: some View {
    let normalizedDate = timelineDisplayDate(from: viewModel.reprocessDayDate)
    let dayString = DateFormatter.yyyyMMdd.string(from: normalizedDate)

    return SettingsSection(
      title: "Reprocess day",
      subtitle: "Re-run analysis for every batch on one timeline day."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        datePill(
          label: "Day",
          date: viewModel.reprocessDayDate,
          isExpanded: isReprocessDatePickerExpanded,
          accessibilityLabel: "Reprocess day",
          disabled: viewModel.isReprocessingDay,
          onTap: {
            withAnimation(.easeOut(duration: 0.2)) {
              isReprocessDatePickerExpanded.toggle()
              activeExportDatePicker = nil
            }
          }
        )

        if isReprocessDatePickerExpanded {
          inlineCalendar(
            date: $viewModel.reprocessDayDate,
            disabled: viewModel.isReprocessingDay,
            onDateSelected: {
              withAnimation(.easeOut(duration: 0.2)) {
                isReprocessDatePickerExpanded = false
              }
            }
          )
          .transition(.move(edge: .top).combined(with: .opacity))
        }

        Text(dayString)
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.meta)

        VStack(alignment: .leading, spacing: 4) {
          Text(
            "Clears existing cards and observations for that day, then runs analysis again from the original recordings."
          )
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.secondary)
          .fixedSize(horizontal: false, vertical: true)

          Text("Heads up: this can consume a large number of API calls.")
            .font(.custom("Nunito", size: 12))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
        }

        HStack(spacing: 12) {
          SettingsPrimaryButton(
            title: viewModel.isReprocessingDay ? "Reprocessing…" : "Reprocess day",
            systemImage: viewModel.isReprocessingDay ? nil : "arrow.clockwise",
            isLoading: viewModel.isReprocessingDay,
            action: { viewModel.showReprocessDayConfirm = true }
          )

          if let status = viewModel.reprocessStatusMessage {
            Text(status)
              .font(.custom("Nunito", size: 12))
              .foregroundColor(SettingsStyle.secondary)
          }
        }

        if let error = viewModel.reprocessErrorMessage {
          Text(error)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(SettingsStyle.destructive)
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

  // MARK: - Date pill
  //
  // A small label+date button that opens the inline calendar. Visually
  // aligned with SettingsSecondaryButton but with a top-label for form
  // clarity. One style, used for all date inputs.

  private func datePill(
    label: String,
    date: Date,
    isExpanded: Bool,
    accessibilityLabel: String,
    disabled: Bool = false,
    onTap: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.custom("Nunito", size: 11))
        .fontWeight(.semibold)
        .textCase(.uppercase)
        .foregroundColor(SettingsStyle.meta)

      Button {
        guard !disabled else { return }
        onTap()
      } label: {
        HStack(spacing: 8) {
          Text(formattedTimelineDate(date))
            .font(.custom("Nunito", size: 13))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.ink.opacity(disabled ? 0.4 : 1))

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(SettingsStyle.ink.opacity(disabled ? 0.4 : 0.65))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 170, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.black.opacity(disabled ? 0.02 : 0.05))
        )
      }
      .buttonStyle(.plain)
      .disabled(disabled)
      .pointingHandCursor()
      .accessibilityLabel(Text(accessibilityLabel))
    }
  }

  // MARK: - Inline calendar
  //
  // Shown as an expanded panel underneath a date pill. Keeps its own
  // surface (white fill + hairline black stroke) because it's an input
  // widget, not a section container — like any dropdown menu.

  private func inlineCalendar(
    date: Binding<Date>,
    disabled: Bool = false,
    onDateSelected: @escaping () -> Void
  ) -> some View {
    DayflowCalendarGrid(selectedDate: date, onDateSelected: onDateSelected)
      .disabled(disabled)
      .opacity(disabled ? 0.7 : 1)
  }

  // MARK: - Helpers

  private func formattedTimelineDate(_ date: Date) -> String {
    Self.dateLabelFormatter.string(from: timelineDisplayDate(from: date))
  }

  private func exportDateBinding(for picker: ExportDatePicker) -> Binding<Date> {
    switch picker {
    case .start: return $viewModel.exportStartDate
    case .end: return $viewModel.exportEndDate
    }
  }

  private static let dateLabelFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    return formatter
  }()
}

// MARK: - Custom calendar grid
//
// Renamed and restyled — no amber accents, ink-brown selection circle,
// hairline black stroke on the panel. Everything else (layout, keyboard
// handling, month nav) preserved from the previous implementation.

private struct DayflowCalendarGrid: View {
  @Binding var selectedDate: Date
  var onDateSelected: () -> Void

  @State private var displayedMonth: Date = Date()
  @Environment(\.isEnabled) private var isEnabled

  private let calendar = Calendar.current
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

  var body: some View {
    VStack(spacing: 12) {
      monthHeader
      weekdayLabels
      dayGrid
    }
    .padding(14)
    .frame(maxWidth: 290, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(isEnabled ? 0.85 : 0.45))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
    )
    .onAppear {
      displayedMonth =
        calendar.date(
          from: calendar.dateComponents([.year, .month], from: selectedDate)
        ) ?? selectedDate
    }
  }

  private var monthHeader: some View {
    HStack {
      Text(monthYearString)
        .font(.custom("Nunito", size: 14))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)

      Spacer()

      HStack(spacing: 2) {
        Button {
          changeMonth(by: -1)
        } label: {
          Image(systemName: "chevron.left")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(SettingsStyle.ink)
            .frame(width: 24, height: 24)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()

        Button {
          changeMonth(by: 1)
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(SettingsStyle.ink)
            .frame(width: 24, height: 24)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
  }

  private var weekdayLabels: some View {
    let symbols = calendar.veryShortWeekdaySymbols
    let firstWeekday = calendar.firstWeekday
    let ordered = Array(symbols[(firstWeekday - 1)...]) + Array(symbols[..<(firstWeekday - 1)])

    return LazyVGrid(columns: columns, spacing: 2) {
      ForEach(ordered, id: \.self) { symbol in
        Text(symbol)
          .font(.custom("Nunito", size: 11))
          .fontWeight(.medium)
          .foregroundColor(SettingsStyle.meta)
          .frame(maxWidth: .infinity)
          .frame(height: 22)
      }
    }
  }

  private var dayGrid: some View {
    let firstOfMonth = calendar.date(
      from: calendar.dateComponents([.year, .month], from: displayedMonth)
    )!
    let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)!.count
    let weekday = calendar.component(.weekday, from: firstOfMonth)
    let offset = (weekday - calendar.firstWeekday + 7) % 7

    return LazyVGrid(columns: columns, spacing: 2) {
      ForEach(0..<offset, id: \.self) { _ in
        Color.clear.frame(height: 30)
      }

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
            .foregroundColor(
              isSelected ? .white : (isToday ? SettingsStyle.ink : SettingsStyle.text)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
              if isSelected {
                Circle().fill(SettingsStyle.ink).frame(width: 28, height: 28)
              } else if isToday {
                Circle()
                  .stroke(SettingsStyle.ink.opacity(0.35), lineWidth: 1.2)
                  .frame(width: 28, height: 28)
              }
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
  }

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
