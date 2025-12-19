//
//  DaySummaryView.swift
//  Dayflow
//
//  "Your day so far" dashboard showing category breakdown and focus stats
//

import SwiftUI

struct DaySummaryView: View {
    let selectedDate: Date
    let categories: [TimelineCategory]
    let storageManager: StorageManaging

    @State private var timelineCards: [TimelineCard] = []
    @State private var isLoading = true

    // MARK: - Computed Stats

    private var categoryDurations: [CategoryTimeData] {
        // Group cards by category and sum durations
        var durationsByCategory: [String: TimeInterval] = [:]

        for card in timelineCards {
            let duration = calculateDuration(start: card.startTimestamp, end: card.endTimestamp)
            durationsByCategory[card.category, default: 0] += duration
        }

        // Map to CategoryTimeData, matching colors from categories
        return durationsByCategory.compactMap { (name, duration) -> CategoryTimeData? in
            guard duration > 0 else { return nil }

            // Find matching category for color
            let colorHex = categories.first(where: { $0.name == name })?.colorHex ?? "#E5E7EB"

            return CategoryTimeData(
                name: name,
                colorHex: colorHex,
                duration: duration
            )
        }
        .sorted { $0.duration > $1.duration } // Sort by duration descending
    }

    private var totalFocusTime: TimeInterval {
        // Focus time = non-Idle, non-Distraction categories
        timelineCards
            .filter { card in
                let cat = card.category.lowercased()
                return cat != "idle" && cat != "distraction" && cat != "distractions"
            }
            .reduce(0) { total, card in
                total + calculateDuration(start: card.startTimestamp, end: card.endTimestamp)
            }
    }

    private var longestFocusDuration: TimeInterval {
        // Find the longest single card that's a focus category
        let focusCards = timelineCards.filter { card in
            let cat = card.category.lowercased()
            return cat != "idle" && cat != "distraction" && cat != "distractions"
        }

        guard !focusCards.isEmpty else { return 0 }

        return focusCards
            .map { calculateDuration(start: $0.startTimestamp, end: $0.endTimestamp) }
            .max() ?? 0
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                headerSection

                // Donut chart
                if isLoading {
                    ProgressView()
                        .frame(width: 180, height: 180)
                } else if !categoryDurations.isEmpty {
                    CategoryDonutChart(data: categoryDurations, size: 180)
                        .padding(.top, 8)
                } else {
                    emptyChartPlaceholder
                }

                // Stats cards
                if !isLoading {
                    statsSection
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadData()
        }
        .onChange(of: selectedDate) { _ in
            loadData()
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        isLoading = true

        Task.detached(priority: .userInitiated) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"

            // Use timeline display date to handle 4 AM boundary
            let timelineDate = timelineDisplayDate(from: selectedDate)
            let dayString = formatter.string(from: timelineDate)

            let cards = await storageManager.fetchTimelineCards(forDay: dayString)

            await MainActor.run {
                self.timelineCards = cards
                self.isLoading = false
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("Your day so far")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))

                Spacer()

                // Share button
                Button(action: {
                    // TODO: Implement share functionality
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                        Text("Share")
                            .font(.custom("Nunito", size: 10).weight(.medium))
                    }
                    .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 1.0, green: 0.43, blue: 0).opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 1.0, green: 0.43, blue: 0).opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            Text("This data will update every 15 minutes. Check back throughout the day to gain new understanding on your workflow.")
                .font(.custom("Nunito", size: 10).weight(.regular))
                .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                .lineSpacing(2)
        }
    }

    // MARK: - Empty State

    private var emptyChartPlaceholder: some View {
        VStack(spacing: 12) {
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 20)
                .frame(width: 140, height: 140)

            Text("No activity data yet")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(Color.gray.opacity(0.6))
        }
        .padding(.vertical, 20)
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(spacing: 12) {
            // Total focus time card
            StatCard(
                title: "Total focus time",
                value: formatDuration(totalFocusTime),
                showInfoButton: true
            )

            // TODO: Re-enable when LongestFocusCard timeline visualization is ready
            // Longest focus duration card
            // StatCard(
            //     title: "Longest focus duration",
            //     value: formatDuration(longestFocusDuration),
            //     showInfoButton: false
            // )
        }
    }

    // MARK: - Helpers

    private func calculateDuration(start: String, end: String) -> TimeInterval {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        guard let startDate = timeFormatter.date(from: start),
              let endDate = timeFormatter.date(from: end) else {
            return 0
        }

        var duration = endDate.timeIntervalSince(startDate)

        // Handle overnight wraparound (e.g., 11:00 PM to 1:00 AM)
        if duration < 0 {
            duration += 24 * 60 * 60
        }

        return duration
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours) Hours \(minutes) minutes"
        } else if hours > 0 {
            return "\(hours) Hours"
        } else if minutes > 0 {
            return "\(minutes) minutes"
        } else {
            return "0 minutes"
        }
    }
}

// MARK: - Stat Card Component

private struct StatCard: View {
    let title: String
    let value: String
    let showInfoButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.custom("Nunito", size: 11).weight(.medium))
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))

                if showInfoButton {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                }

                Spacer()
            }

            Text(value)
                .font(.custom("InstrumentSerif-Regular", size: 20))
                .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0)) // Orange color
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(red: 0.9, green: 0.88, blue: 0.86), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview("Day Summary") {
    let sampleCategories: [TimelineCategory] = [
        TimelineCategory(name: "Work", colorHex: "#B984FF", order: 0),
        TimelineCategory(name: "Personal", colorHex: "#6AADFF", order: 1),
        TimelineCategory(name: "Distraction", colorHex: "#FF5950", order: 2),
        TimelineCategory(name: "Idle", colorHex: "#A0AEC0", order: 3, isSystem: true, isIdle: true)
    ]

    DaySummaryView(
        selectedDate: Date(),
        categories: sampleCategories,
        storageManager: StorageManager.shared
    )
    .frame(width: 280, height: 600)
    .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
