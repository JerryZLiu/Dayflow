//
//  CategoryDonutChart.swift
//  Dayflow
//
//  A donut chart showing time breakdown by category using Swift Charts
//

import Charts
import SwiftUI

// MARK: - Data Model

struct CategoryTimeData: Identifiable {
  let id: String
  let name: String
  let colorHex: String
  let duration: TimeInterval  // in seconds

  init(id: String? = nil, name: String, colorHex: String, duration: TimeInterval) {
    self.id = id ?? Self.stableFallbackID(name: name, colorHex: colorHex)
    self.name = name
    self.colorHex = colorHex
    self.duration = duration
  }

  init(category: TimelineCategory, duration: TimeInterval) {
    self.id = category.id.uuidString
    self.name = category.name
    self.colorHex = category.colorHex
    self.duration = duration
  }

  private static func stableFallbackID(name: String, colorHex: String) -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedColor = colorHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return "\(normalizedName)|\(normalizedColor)"
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
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

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
    VStack(spacing: 24) {
      // Donut chart
      donutChart

      // Legend grid
      legendGrid
    }
  }

  // MARK: - Donut Chart

  private var donutChart: some View {
    // Figma: 205pt donut, ~25pt ring, 2pt track showing outside and 3pt inside the ring.
    let chartSize = size - 4
    let innerRadiusRatio: CGFloat = 0.75
    let outerRadius = chartSize / 2
    let glowSpread: CGFloat = 4

    return ZStack {
      // Background circle with light grey fill and shadow
      Circle()
        .fill(theme.donutRingBackground)
        .frame(width: size, height: size)
        .shadow(color: theme.donutShadow, radius: 5, x: 0, y: 0)

      if stylePreviewAfter {
        // Sector fills: category color at 80% opacity (per mock)
        sectorChart(fillOpacity: 0.8, ringOuterRadius: outerRadius)
          .frame(width: chartSize, height: chartSize)

        // Inner glow: a 4px full-color band just inside each sector's perimeter,
        // built by punching a shrunken copy out of a full-color copy, then blurring.
        ZStack {
          sectorChart(fillOpacity: 1, ringOuterRadius: outerRadius)
          sectorChart(fillOpacity: 1, ringOuterRadius: outerRadius, shrunkBy: glowSpread)
            .blendMode(.destinationOut)
        }
        .compositingGroup()
        .blur(radius: glowSpread)
        .mask(sectorChart(fillOpacity: 1, ringOuterRadius: outerRadius))
        .frame(width: chartSize, height: chartSize)
        .allowsHitTesting(false)  // Don't block interactions
      } else {
        // "Before": shipped rendering — full-opacity sectors with a white
        // radial sheen fading toward the outer edge.
        sectorChart(fillOpacity: 1, ringOuterRadius: outerRadius)
          .frame(width: chartSize, height: chartSize)

        Circle()
          .fill(
            RadialGradient(
              stops: [
                .init(color: .white.opacity(0.35), location: innerRadiusRatio),
                .init(color: .white.opacity(0), location: 1.0),
              ],
              center: .center,
              startRadius: 0,
              endRadius: outerRadius
            )
          )
          .frame(width: chartSize, height: chartSize)
          .allowsHitTesting(false)  // Don't block interactions
      }

      // White circle in center - slightly smaller than donut hole to show grey gap on inner edge.
      // In dark mode ("After") the hole is punched out instead so the panel
      // background shows through.
      let innerGap: CGFloat = 6
      let punchOutHole = stylePreviewAfter && theme.isDark
      Circle()
        .fill(punchOutHole ? Color.black : theme.donutCenterFill)
        .blendMode(punchOutHole ? .destinationOut : .normal)
        .frame(
          width: chartSize * innerRadiusRatio - innerGap,
          height: chartSize * innerRadiusRatio - innerGap)

      // Center content
      centerContent
    }
    .compositingGroup()
    .frame(width: size, height: size)
  }

  /// One copy of the donut's sector geometry. `shrunkBy` insets every edge
  /// (inner, outer, and angular) so the difference with the full-size copy
  /// forms the inner-glow band.
  private func sectorChart(
    fillOpacity: Double, ringOuterRadius: CGFloat, shrunkBy spread: CGFloat = 0
  ) -> some View {
    Chart(data) { item in
      SectorMark(
        angle: .value("Duration", item.duration),
        innerRadius: spread > 0 ? .fixed(ringOuterRadius * 0.75 + spread) : .ratio(0.75),
        outerRadius: spread > 0 ? .inset(spread) : .automatic,
        angularInset: 1.5 + spread
      )
      .cornerRadius(max(6 - spread, 0))
      .foregroundStyle(item.color.opacity(fillOpacity))
    }
    .chartLegend(.hidden)
  }

  private var centerContent: some View {
    VStack(spacing: 4) {
      Text("TOTAL")
        .font(.custom("Figtree", size: 12).weight(.bold))
        .foregroundColor(Color(hex: "B1B1B1"))

      VStack(spacing: 0) {
        let total = formattedTotal
        Text("\(total.hours) hours")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundColor(theme.textPrimary)
        Text("\(total.minutes) minutes")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundColor(theme.textPrimary)
      }
    }
  }

  // MARK: - Legend Grid

  private var legendGrid: some View {
    let columns = Array(repeating: GridItem(.fixed(84.667), spacing: 14), count: 3)

    return LazyVGrid(columns: columns, spacing: 12) {
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
        RoundedRectangle(cornerRadius: 2)
          .fill(item.color.opacity(theme.legendSwatchOpacity))
          .overlay(
            RoundedRectangle(cornerRadius: 2)
              .stroke(item.color, lineWidth: 1.25)
          )
          .frame(width: 10.667, height: 8)

        // Category name
        Text(item.name)
          .font(.custom("Figtree", size: 10))
          .foregroundColor(theme.textSecondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(width: 70, alignment: .leading)
      }

      // Duration
      Text(item.formattedDuration)
        .font(.custom("Figtree", size: 12).weight(.semibold))
        .foregroundColor(theme.textPrimary)
        .padding(.leading, 14)  // Align with text above
    }
    .frame(width: 84.667, alignment: .leading)
  }
}

// MARK: - Preview

#Preview("Category Donut Chart") {
  // Dummy data matching the Figma design
  let previewData: [CategoryTimeData] = [
    CategoryTimeData(name: "Personal", colorHex: "#6AADFF", duration: 92 * 60),  // 1h 32m - blue
    CategoryTimeData(name: "Personal", colorHex: "#FF5950", duration: 45 * 60),  // 45m - red
    CategoryTimeData(name: "Long category title", colorHex: "#88E5DF", duration: 152 * 60),  // 2h 32m - teal
    CategoryTimeData(name: "Learning", colorHex: "#5650FF", duration: 32 * 60),  // 32m - purple
    CategoryTimeData(name: "Personal", colorHex: "#B984FF", duration: 204 * 60),  // 3h 24m - light purple
    CategoryTimeData(name: "Personal", colorHex: "#E2E2E2", duration: 152 * 60),  // 2h 32m - gray
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
