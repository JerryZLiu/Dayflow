//
//  CategoryDonutChart.swift
//  Dayflow
//
//  A donut chart showing time breakdown by category using Swift Charts
//

import SwiftUI
import Charts

// MARK: - Data Model

struct CategoryTimeData: Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
    let duration: TimeInterval // in seconds

    init(id: UUID = UUID(), name: String, colorHex: String, duration: TimeInterval) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.duration = duration
    }

    init(category: TimelineCategory, duration: TimeInterval) {
        self.id = category.id
        self.name = category.name
        self.colorHex = category.colorHex
        self.duration = duration
    }

    var color: Color {
        if let nsColor = NSColor(hex: colorHex) {
            return Color(nsColor: nsColor)
        }
        return Color.gray
    }

    var formattedDuration: String {
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Main View

struct CategoryDonutChart: View {
    let data: [CategoryTimeData]
    let size: CGFloat

    init(data: [CategoryTimeData], size: CGFloat = 205) {
        self.data = data
        self.size = size
    }

    private var totalDuration: TimeInterval {
        data.reduce(0) { $0 + $1.duration }
    }

    private var formattedTotal: (hours: Int, minutes: Int) {
        let totalMinutes = Int(totalDuration / 60)
        return (totalMinutes / 60, totalMinutes % 60)
    }

    var body: some View {
        VStack(spacing: 28) {
            // Donut chart
            donutChart

            // Legend grid
            legendGrid
        }
    }

    // MARK: - Donut Chart

    private var donutChart: some View {
        let chartSize = size - 8  // 4px gap on each side between white circle and colored ring
        let innerRadiusRatio: CGFloat = 0.62
        // Calculate actual radii for the gradient overlay
        let outerRadius = chartSize / 2

        return ZStack {
            // Background circle with light grey fill and shadow
            Circle()
                .fill(Color(red: 0.95, green: 0.94, blue: 0.94)) // Light grey background
                .frame(width: size, height: size)
                .shadow(color: Color(red: 0.39, green: 0.28, blue: 0.22).opacity(0.35), radius: 5, x: 0, y: 0)

            // Swift Charts donut
            Chart(data) { item in
                SectorMark(
                    angle: .value("Duration", item.duration),
                    innerRadius: .ratio(innerRadiusRatio),
                    angularInset: 1.5
                )
                .cornerRadius(6)
                .foregroundStyle(item.color)
            }
            .chartLegend(.hidden)
            .frame(width: chartSize, height: chartSize)

            // Gradient overlay: lighter at inner edge, fading to clear at outer edge
            Circle()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: .white.opacity(0.35), location: innerRadiusRatio),
                            .init(color: .white.opacity(0), location: 1.0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: outerRadius
                    )
                )
                .frame(width: chartSize, height: chartSize)
                .allowsHitTesting(false) // Don't block interactions

            // White circle in center - slightly smaller than donut hole to show grey gap on inner edge
            let innerGap: CGFloat = 8  // 4px gap on each side (matches outer gap)
            Circle()
                .fill(Color.white)
                .frame(width: chartSize * innerRadiusRatio - innerGap, height: chartSize * innerRadiusRatio - innerGap)

            // Center content
            centerContent
        }
        .frame(width: size, height: size)
    }

    private var centerContent: some View {
        VStack(spacing: 4) {
            Text("TOTAL")
                .font(.custom("Nunito", size: 8).weight(.bold))
                .foregroundColor(Color(red: 0.65, green: 0.65, blue: 0.65)) // #a5a5a5

            VStack(spacing: 0) {
                let total = formattedTotal
                Text("\(total.hours) hours")
                    .font(.custom("InstrumentSerif-Regular", size: 16))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2)) // #333333
                Text("\(total.minutes) minutes")
                    .font(.custom("InstrumentSerif-Regular", size: 16))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
            }
        }
    }

    // MARK: - Legend Grid

    private var legendGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(84.667), spacing: 14), count: 3)

        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(data) { item in
                legendItem(for: item)
            }
        }
    }

    private func legendItem(for item: CategoryTimeData) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Color indicator + name row
            HStack(spacing: 4) {
                // Colored rectangle with border
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.color.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(item.color, lineWidth: 1.25)
                    )
                    .frame(width: 10.667, height: 8)

                // Category name
                Text(item.name)
                    .font(.custom("NunitoSans-Regular", size: 10))
                    .foregroundColor(Color(red: 0.39, green: 0.39, blue: 0.39)) // #636363
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 70, alignment: .leading)
            }

            // Duration
            Text(item.formattedDuration)
                .font(.custom("NunitoSans-SemiBold", size: 12))
                .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2)) // #333333
                .padding(.leading, 14) // Align with text above
        }
        .frame(width: 84.667, alignment: .leading)
    }
}

// MARK: - Preview

#Preview("Category Donut Chart") {
    // Dummy data matching the Figma design
    let previewData: [CategoryTimeData] = [
        CategoryTimeData(name: "Personal", colorHex: "#6AADFF", duration: 92 * 60),      // 1h 32m - blue
        CategoryTimeData(name: "Personal", colorHex: "#FF5950", duration: 45 * 60),      // 45m - red
        CategoryTimeData(name: "Long category title", colorHex: "#88E5DF", duration: 152 * 60), // 2h 32m - teal
        CategoryTimeData(name: "Learning", colorHex: "#5650FF", duration: 32 * 60),      // 32m - purple
        CategoryTimeData(name: "Personal", colorHex: "#B984FF", duration: 204 * 60),     // 3h 24m - light purple
        CategoryTimeData(name: "Personal", colorHex: "#E2E2E2", duration: 152 * 60),     // 2h 32m - gray
    ]

    CategoryDonutChart(data: previewData)
        .padding(40)
        .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}

#Preview("Empty State") {
    CategoryDonutChart(data: [])
        .padding(40)
        .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
