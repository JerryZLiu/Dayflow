import SwiftUI
import AppKit

struct DateNavigationControls: View {
    @Binding var selectedDate: Date
    @Binding var showDatePicker: Bool
    @Binding var lastDateNavMethod: String?
    @Binding var previousDate: Date

    var body: some View {
        HStack(spacing: 12) {
            DayflowCircleButton {
                let from = selectedDate
                let to = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                previousDate = selectedDate
                selectedDate = normalizedTimelineDate(to)
                lastDateNavMethod = "prev"
                AnalyticsService.shared.capture("date_navigation", [
                    "method": "prev",
                    "from_day": dayString(from),
                    "to_day": dayString(to)
                ])
            } content: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.3))
            }

            Button(action: { showDatePicker = true; lastDateNavMethod = "picker" }) {
                DayflowPillButton(
                    text: formatDateForDisplay(selectedDate),
                    fixedWidth: calculateOptimalPillWidth()
                )
            }
            .buttonStyle(PlainButtonStyle())

            DayflowCircleButton {
                guard canNavigateForward(from: selectedDate) else { return }
                let from = selectedDate
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                previousDate = selectedDate
                selectedDate = normalizedTimelineDate(tomorrow)
                lastDateNavMethod = "next"
                AnalyticsService.shared.capture("date_navigation", [
                    "method": "next",
                    "from_day": dayString(from),
                    "to_day": dayString(tomorrow)
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
        let formatter = DateFormatter()

        let displayDate = timelineDisplayDate(from: date, now: now)
        let timelineToday = timelineDisplayDate(from: now, now: now)

        if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
            formatter.dateFormat = "'Today,' MMM d"
        } else {
            formatter.dateFormat = "E, MMM d"
        }

        return formatter.string(from: displayDate)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func calculateOptimalPillWidth() -> CGFloat {
        let sampleText = "Today, Sep 30"
        let nsFont = NSFont(name: "InstrumentSerif-Regular", size: 18) ?? NSFont.systemFont(ofSize: 18)
        let textSize = sampleText.size(withAttributes: [.font: nsFont])
        let horizontalPadding: CGFloat = 11.77829 * 2
        return textSize.width + horizontalPadding + 8
    }
}
