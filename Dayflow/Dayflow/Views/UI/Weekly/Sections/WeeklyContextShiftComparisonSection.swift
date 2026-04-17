import Charts
import SwiftUI

struct WeeklyContextShiftComparisonSection: View {
  let snapshot: WeeklyContextShiftComparisonSnapshot
  let onPinpoint: () -> Void

  init(
    snapshot: WeeklyContextShiftComparisonSnapshot,
    onPinpoint: @escaping () -> Void = {}
  ) {
    self.snapshot = snapshot
    self.onPinpoint = onPinpoint
  }

  private enum Design {
    static let sectionWidth: CGFloat = 958
    static let sectionHeight: CGFloat = 414
    static let cornerRadius: CGFloat = 6
    static let background = Color(hex: "FBF6F0")
    static let axisColor = Color(hex: "5A534C").opacity(0.9)
    static let labelColor = Color.black
    static let insightBorder = Color(hex: "EBE6E3")

    static let horizontalPadding: CGFloat = 24
    static let topPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 30
    static let legendSpacing: CGFloat = 34
    static let contentTopSpacing: CGFloat = 36
    static let chartCalloutSpacing: CGFloat = 30
    static let calloutTopPadding: CGFloat = 96

    static let chartWidth: CGFloat = 544
    static let chartHeight: CGFloat = 220
    static let xAxisTopSpacing: CGFloat = 12
    static let pointSize: CGFloat = 42
    static let lineWidth: CGFloat = 2

    static let calloutWidth: CGFloat = 220
    static let calloutPadding: CGFloat = 16
    static let calloutSpacing: CGFloat = 14

    static let buttonHorizontalPadding: CGFloat = 12
    static let buttonVerticalPadding: CGFloat = 6
    static let buttonSpacing: CGFloat = 4
  }

  private var yDomain: ClosedRange<Double> {
    let maxValue = snapshot.series.flatMap(\.points).map(\.value).max() ?? 0
    return 0...(maxValue + 2)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.contentTopSpacing) {
      legend

      HStack(alignment: .top, spacing: Design.chartCalloutSpacing) {
        chartColumn
          .frame(width: Design.chartWidth, alignment: .leading)

        insightCard
          .padding(.top, Design.calloutTopPadding)
      }
    }
    .padding(.top, Design.topPadding)
    .padding(.horizontal, Design.horizontalPadding)
    .padding(.bottom, Design.bottomPadding)
    .frame(width: Design.sectionWidth, height: Design.sectionHeight, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Design.background)
    )
  }

  private var legend: some View {
    HStack(spacing: Design.legendSpacing) {
      ForEach(snapshot.series) { series in
        HStack(spacing: 6) {
          Circle()
            .fill(Color(hex: series.colorHex))
            .frame(width: 10, height: 10)

          Text(series.label)
            .font(.custom("Nunito-Regular", size: 12))
            .foregroundStyle(Design.labelColor)
        }
      }
    }
  }

  private var chartColumn: some View {
    VStack(alignment: .leading, spacing: Design.xAxisTopSpacing) {
      Text("Count")
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Design.labelColor)

      comparisonChart

      HStack {
        ForEach(snapshot.dayLabels, id: \.self) { label in
          Text(label)
            .font(.custom("Nunito-Regular", size: 12))
            .foregroundStyle(Design.labelColor)

          if label != snapshot.dayLabels.last {
            Spacer(minLength: 0)
          }
        }
      }
      .frame(width: Design.chartWidth, alignment: .leading)
    }
  }

  private var comparisonChart: some View {
    Chart {
      ForEach(snapshot.series) { series in
        ForEach(series.points.sorted(by: { $0.dayIndex < $1.dayIndex })) { point in
          LineMark(
            x: .value("Day Index", point.dayIndex),
            y: .value("Value", point.value),
            series: .value("Series", series.id)
          )
          .interpolationMethod(.catmullRom)
          .lineStyle(StrokeStyle(lineWidth: Design.lineWidth))
          .foregroundStyle(Color(hex: series.colorHex))

          PointMark(
            x: .value("Day Index", point.dayIndex),
            y: .value("Value", point.value)
          )
          .symbolSize(Design.pointSize)
          .foregroundStyle(Color(hex: series.colorHex))
        }
      }
    }
    .chartXScale(domain: 0...Double(max(snapshot.dayLabels.count - 1, 0)))
    .chartYScale(domain: yDomain)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .chartPlotStyle { plotArea in
      plotArea
        .background(Color.clear)
        .overlay(alignment: .leading) {
          GeometryReader { proxy in
            Path { path in
              path.move(to: CGPoint(x: 0, y: 0))
              path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
              path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
            }
            .stroke(Design.axisColor, lineWidth: 1)
          }
        }
    }
    .frame(width: Design.chartWidth, height: Design.chartHeight)
  }

  private var insightCard: some View {
    VStack(alignment: .leading, spacing: Design.calloutSpacing) {
      Text(snapshot.insightText)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Design.labelColor)
        .fixedSize(horizontal: false, vertical: true)

      Button(action: onPinpoint) {
        HStack(spacing: Design.buttonSpacing) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Design.labelColor)

          Text(snapshot.callToAction)
            .font(.custom("Nunito-Regular", size: 12))
            .foregroundStyle(Design.labelColor)
        }
        .padding(.horizontal, Design.buttonHorizontalPadding)
        .padding(.vertical, Design.buttonVerticalPadding)
        .background(Color.white)
        .overlay(
          Capsule(style: .continuous)
            .stroke(Design.insightBorder, lineWidth: 1)
        )
        .clipShape(Capsule(style: .continuous))
      }
      .buttonStyle(.plain)
      .hoverScaleEffect(scale: 1.02)
      .pointingHandCursorOnHover(reassertOnPressEnd: true)
    }
    .padding(Design.calloutPadding)
    .frame(width: Design.calloutWidth, alignment: .leading)
    .background(Color.white.opacity(0.45))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(Color.white, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
  }
}

struct WeeklyContextShiftComparisonSnapshot {
  let dayLabels: [String]
  let series: [WeeklyContextShiftComparisonSeries]
  let insightText: String
  let callToAction: String

  static let figmaPreview = WeeklyContextShiftComparisonSnapshot(
    dayLabels: ["Mon", "Tue", "Wed", "Thur", "Fri", "Sat"],
    series: [
      WeeklyContextShiftComparisonSeries(
        id: "distractions",
        label: "Number of times distracted",
        colorHex: "FF8A8A",
        points: [
          .init(dayIndex: 0, value: 12),
          .init(dayIndex: 1, value: 9),
          .init(dayIndex: 2, value: 16),
          .init(dayIndex: 3, value: 12),
          .init(dayIndex: 4, value: 5),
          .init(dayIndex: 5, value: 12),
        ]
      ),
      WeeklyContextShiftComparisonSeries(
        id: "context-shifts",
        label: "Number of context shifts",
        colorHex: "A78CFF",
        points: [
          .init(dayIndex: 0, value: 15),
          .init(dayIndex: 1, value: 10),
          .init(dayIndex: 2, value: 18),
          .init(dayIndex: 3, value: 7),
          .init(dayIndex: 4, value: 10),
          .init(dayIndex: 5, value: 15),
        ]
      ),
      WeeklyContextShiftComparisonSeries(
        id: "meetings",
        label: "Number of meetings",
        colorHex: "CEC5BC",
        points: [
          .init(dayIndex: 0, value: 4),
          .init(dayIndex: 1, value: 6),
          .init(dayIndex: 2, value: 0),
          .init(dayIndex: 3, value: 3),
          .init(dayIndex: 4, value: 3),
          .init(dayIndex: 5, value: 0),
        ]
      ),
    ],
    insightText:
      "You tend to be more distracted and have more context shifts on days with lighter meetings.",
    callToAction: "Pinpoint"
  )
}

struct WeeklyContextShiftComparisonSeries: Identifiable {
  let id: String
  let label: String
  let colorHex: String
  let points: [WeeklyContextShiftComparisonPoint]
}

struct WeeklyContextShiftComparisonPoint: Identifiable {
  let id = UUID()
  let dayIndex: Int
  let value: Double
}

#Preview("Weekly Context Shift Comparison", traits: .fixedLayout(width: 958, height: 414)) {
  WeeklyContextShiftComparisonSection(snapshot: .figmaPreview)
    .padding(24)
    .background(Color(hex: "F7F3F0"))
}
