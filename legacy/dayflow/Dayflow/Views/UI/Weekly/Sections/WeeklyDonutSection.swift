import Charts
import SwiftUI

struct WeeklyDonutSection: View {
  private let donutScale = WeeklyDonutLayout.scale
  private let legendGap = WeeklyDonutLayout.legendGap
  private let contentYOffset = WeeklyDonutLayout.contentY
  private let chartLegendGap = WeeklyDonutLayout.chartLegendGap
  private let contentXOffset = WeeklyDonutLayout.contentX

  let snapshot: WeeklyDonutSnapshot
  let isLoading: Bool
  let width: CGFloat

  init(
    snapshot: WeeklyDonutSnapshot,
    isLoading: Bool,
    width: CGFloat = Design.cardWidth
  ) {
    self.snapshot = snapshot
    self.isLoading = isLoading
    self.width = width
  }

  private enum Design {
    static let cardWidth: CGFloat = 461
    static let cardHeight: CGFloat = 300
    static let cornerRadius: CGFloat = 4
    static let borderColor = WeeklyPalette.cardBorder
    @MainActor static var backgroundColor: Color { WeeklyPalette.cardFill }
    static let titleColor = WeeklyPalette.title
    static let contentHorizontalPadding: CGFloat = 18
    static let contentSpacing: CGFloat = 18
    static let donutSize: CGFloat = 205
  }

  private var donutSize: CGFloat {
    let base = min(235, max(176, width * 0.43))
    // The card is 300pt tall with 56pt of header above the donut, so the
    // scaled size must stay under ~230pt to avoid clipping.
    return min(230, max(110, base * donutScale))
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Design.backgroundColor)

      Text("Weekly distribution")
        .font(.custom("InstrumentSerif-Regular", size: 20))
        .foregroundStyle(Design.titleColor)
        .padding(.top, 16)
        .padding(.leading, 18)

      // Chart and legend are one center-aligned block, vertically centered in
      // the card and nudged by the tuner's Y-offset. The title stays fixed.
      HStack(alignment: .center, spacing: chartLegendGap) {
        donutContent

        legendContent
      }
      .padding(.horizontal, Design.contentHorizontalPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .offset(x: contentXOffset, y: contentYOffset)

    }
    .frame(width: width, height: Design.cardHeight, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(Design.borderColor, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var donutContent: some View {
    if isLoading {
      ProgressView()
        .frame(width: donutSize, height: donutSize)
    } else if snapshot.items.isEmpty {
      WeeklyDonutEmptyState(size: donutSize)
    } else {
      WeeklyDonutChart(
        snapshot: snapshot,
        size: donutSize
      )
    }
  }

  private var legendContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(snapshot.items) { item in
        WeeklyDonutLegendRow(
          item: item,
          totalMinutes: snapshot.totalMinutes,
          percentInset: legendGap
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct WeeklyDonutChart: View {
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter
  @Environment(\.colorScheme) private var colorScheme

  let snapshot: WeeklyDonutSnapshot
  let size: CGFloat

  private let glowSpread: CGFloat = 4

  // "After" matches the timeline donut's ring geometry (CategoryDonutChart:
  // 0.75 inner ratio, 4pt track, 6pt center gap); "Before" keeps the shipped
  // thicker weekly ring.
  private var innerRadiusRatio: CGFloat {
    stylePreviewAfter ? 0.75 : 0.62
  }

  private var innerGap: CGFloat {
    stylePreviewAfter ? 6 : 8
  }

  private var chartSize: CGFloat {
    size - (stylePreviewAfter ? 4 : 8)
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(WeeklyPalette.solid)
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.39, green: 0.28, blue: 0.22).opacity(0.35), radius: 5)

      if stylePreviewAfter {
        // Sector fills: category color at 80% opacity (per mock)
        sectorChart(fillOpacity: 0.8)
          .frame(width: chartSize, height: chartSize)

        // Inner glow: a 4px full-color band just inside each sector's perimeter,
        // built by punching a shrunken copy out of a full-color copy, then blurring.
        ZStack {
          sectorChart(fillOpacity: 1)
          sectorChart(fillOpacity: 1, shrunkBy: glowSpread)
            .blendMode(.destinationOut)
        }
        .compositingGroup()
        .blur(radius: glowSpread)
        .mask(sectorChart(fillOpacity: 1))
        .frame(width: chartSize, height: chartSize)
        .allowsHitTesting(false)
      } else {
        // "Before": shipped rendering — full-opacity sectors with a white
        // radial sheen fading toward the outer edge.
        sectorChart(fillOpacity: 1)
          .frame(width: chartSize, height: chartSize)

        Circle()
          .fill(
            RadialGradient(
              stops: [
                .init(color: .white.opacity(0.35), location: innerRadiusRatio),
                .init(color: .white.opacity(0), location: 1),
              ],
              center: .center,
              startRadius: 0,
              endRadius: chartSize / 2
            )
          )
          .frame(width: chartSize, height: chartSize)
          .allowsHitTesting(false)
      }

      // In dark mode ("After") the hole is punched out so the panel background
      // shows through; otherwise it's filled with the weekly card solid.
      let punchOutHole = stylePreviewAfter && colorScheme == .dark
      Circle()
        .fill(punchOutHole ? Color.black : WeeklyPalette.solid)
        .blendMode(punchOutHole ? .destinationOut : .normal)
        .frame(
          width: chartSize * innerRadiusRatio - innerGap,
          height: chartSize * innerRadiusRatio - innerGap
        )

      WeeklyDonutCenterContent(totalMinutes: snapshot.totalMinutes)
    }
    .compositingGroup()
    .frame(width: size, height: size)
  }

  /// One copy of the donut's sector geometry. `shrunkBy` insets every edge
  /// (inner, outer, and angular) so the difference with the full-size copy
  /// forms the inner-glow band.
  private func sectorChart(fillOpacity: Double, shrunkBy spread: CGFloat = 0) -> some View {
    Chart(snapshot.items) { item in
      SectorMark(
        angle: .value("Minutes", item.minutes),
        innerRadius: spread > 0
          ? .fixed(chartSize / 2 * innerRadiusRatio + spread) : .ratio(innerRadiusRatio),
        outerRadius: spread > 0 ? .inset(spread) : .automatic,
        angularInset: 1.5 + spread
      )
      .cornerRadius(max(6 - spread, 0))
      .foregroundStyle(Color(hex: item.colorHex).opacity(fillOpacity))
    }
    .chartLegend(.hidden)
  }
}

private struct WeeklyDonutCenterContent: View {
  let totalMinutes: Int

  private var totalHours: Int { totalMinutes / 60 }
  private var remainingMinutes: Int { totalMinutes % 60 }

  var body: some View {
    VStack(spacing: 4) {
      Text("TOTAL")
        .font(.custom("Figtree-Bold", size: 8))
        .foregroundStyle(WeeklyPalette.mutedText)

      VStack(spacing: 0) {
        Text("\(totalHours) \(hourLabel)")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundStyle(WeeklyPalette.text)

        Text("\(remainingMinutes) \(minuteLabel)")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundStyle(WeeklyPalette.text)
      }
    }
  }

  private var hourLabel: String {
    totalHours == 1 ? "hour" : "hours"
  }

  private var minuteLabel: String {
    remainingMinutes == 1 ? "minute" : "minutes"
  }
}

private struct WeeklyDonutLegendRow: View {
  let item: WeeklyDonutItem
  let totalMinutes: Int
  /// Pulls the % column in from the right edge, toward the category names.
  var percentInset: Double = 0

  private var percentageText: String {
    guard totalMinutes > 0 else { return "0%" }
    let share = (Double(item.minutes) / Double(totalMinutes)) * 100
    return "\(Int(share.rounded()))%"
  }

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(Color(hex: item.colorHex))
          .frame(width: 12, height: 8)

        Text(item.name)
          .font(.custom("Figtree-Regular", size: 14))
          .foregroundStyle(WeeklyPalette.text)
          .lineLimit(1)
          .layoutPriority(1)
      }

      Spacer(minLength: 8)

      Text(percentageText)
        .font(.custom("Figtree-Regular", size: 14))
        .foregroundStyle(WeeklyPalette.text)
        .frame(minWidth: 32, alignment: .trailing)
        .padding(.trailing, percentInset)
    }
  }
}

private struct WeeklyDonutEmptyState: View {
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .fill(WeeklyPalette.solid)
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.39, green: 0.28, blue: 0.22).opacity(0.12), radius: 5)

      Circle()
        .stroke(WeeklyPalette.cardBorder, lineWidth: 20)
        .frame(width: size - 20, height: size - 20)

      VStack(spacing: 4) {
        Text("TOTAL")
          .font(.custom("Figtree-Bold", size: 8))
          .foregroundStyle(WeeklyPalette.mutedText)

        Text("No activity")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundStyle(WeeklyPalette.secondaryText)
      }
    }
    .frame(width: size, height: size)
  }
}

// Tuned design values: 86% size, 70pt name-% gap, 38pt chart-legend gap,
// and the chart + legend block centered then nudged +30pt right / +17pt down.
enum WeeklyDonutLayout {
  static let scale: Double = 0.86
  /// Trailing inset on the legend's % column, pulling it toward the names.
  static let legendGap: Double = 70
  /// Vertical offset of the chart + legend block from the card's center.
  /// The title stays put; chart and legend stay center-aligned to each other.
  static let contentY: Double = 17
  /// Spacing between the pie chart and the legend to its right.
  static let chartLegendGap: Double = 38
  /// Horizontal offset of the chart + legend block from its default position.
  static let contentX: Double = 30
}
