import Charts
import SwiftUI

struct WeeklyContextChartsSection: View {
  let snapshot: WeeklyContextChartsSnapshot
  let width: CGFloat

  init(snapshot: WeeklyContextChartsSnapshot, width: CGFloat = 958) {
    self.snapshot = snapshot
    self.width = width
  }

  private enum Design {
    static let height: CGFloat = 300
    static let footerHeight: CGFloat = 58
    static let cornerRadius: CGFloat = 6
    static let horizontalPadding: CGFloat = 24
    static let topPadding: CGFloat = 16
    static let legendSpacing: CGFloat = 34
    static let chartHeight: CGFloat = 104
    static let titleSpacing: CGFloat = 14
    static let chartTopSpacing: CGFloat = 12
    static let xAxisTopSpacing: CGFloat = 8
    static let lineWidth: CGFloat = 2
    static let pointSize: CGFloat = 42
    static let borderColor = Color(hex: "EBE6E3")
    static let backgroundColor = Color.white.opacity(0.78)
    static let footerBackgroundColor = Color.white.opacity(0.58)
    static let axisColor = Color(hex: "5A534C").opacity(0.9)
    static let labelColor = Color.black
  }

  private var chartWidth: CGFloat {
    max(320, width - Design.horizontalPadding * 2)
  }

  private var series: [WeeklyContextLineSeries] {
    [
      WeeklyContextLineSeries(
        id: "distractions",
        label: "Number of times distracted",
        colorHex: "FF8A8A",
        values: snapshot.comparison.days.map(\.distracted)
      ),
      WeeklyContextLineSeries(
        id: "context-shifts",
        label: "Number of context shifts",
        colorHex: "A78CFF",
        values: snapshot.comparison.days.map(\.shifts)
      ),
    ]
  }

  private var yDomain: ClosedRange<Double> {
    let maxValue = series.flatMap(\.values).max() ?? 0
    return 0...Double(max(maxValue + 2, 4))
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: Design.chartTopSpacing) {
        Text("Context shift and distractions comparison")
          .font(.custom("InstrumentSerif-Regular", size: 20))
          .foregroundStyle(Color(hex: "B46531"))
          .lineLimit(1)
          .minimumScaleFactor(0.82)
          .padding(.bottom, Design.titleSpacing - Design.chartTopSpacing)

        legend
        chartColumn
      }
      .padding(.top, Design.topPadding)
      .padding(.horizontal, Design.horizontalPadding)
      .frame(width: width, height: Design.height - Design.footerHeight, alignment: .topLeading)
      .background(Design.backgroundColor)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color(hex: "EBE6E3"))
          .frame(height: 1)
      }

      footer
    }
    .frame(width: width, height: Design.height, alignment: .topLeading)
    .background(Design.backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(Design.borderColor, lineWidth: 1)
    )
  }

  private var legend: some View {
    HStack(spacing: Design.legendSpacing) {
      ForEach(series) { item in
        HStack(spacing: 6) {
          Circle()
            .fill(Color(hex: item.colorHex))
            .frame(width: 10, height: 10)

          Text(item.label)
            .font(.custom("Figtree-Regular", size: 12))
            .foregroundStyle(Design.labelColor)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
        }
      }
    }
  }

  private var chartColumn: some View {
    VStack(alignment: .leading, spacing: Design.xAxisTopSpacing) {
      Text("Count")
        .font(.custom("Figtree-Regular", size: 12))
        .foregroundStyle(Design.labelColor)

      lineChart

      HStack {
        ForEach(snapshot.comparison.days) { day in
          Text(day.day)
            .font(.custom("Figtree-Regular", size: 12))
            .foregroundStyle(Design.labelColor)

          if day.id != snapshot.comparison.days.last?.id {
            Spacer(minLength: 0)
          }
        }
      }
      .frame(width: chartWidth, alignment: .leading)
    }
  }

  private var lineChart: some View {
    Chart {
      ForEach(series) { item in
        ForEach(Array(item.values.enumerated()), id: \.offset) { index, value in
          LineMark(
            x: .value("Day", index),
            y: .value("Count", value),
            series: .value("Series", item.id)
          )
          .interpolationMethod(.catmullRom)
          .lineStyle(StrokeStyle(lineWidth: Design.lineWidth))
          .foregroundStyle(Color(hex: item.colorHex))

          PointMark(
            x: .value("Day", index),
            y: .value("Count", value)
          )
          .symbolSize(Design.pointSize)
          .foregroundStyle(Color(hex: item.colorHex))
        }
      }
    }
    .chartXScale(domain: 0...Double(max(snapshot.comparison.days.count - 1, 0)))
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
    .frame(width: chartWidth, height: Design.chartHeight)
  }

  private var footer: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(Color(hex: "F5AD41"))
        .frame(width: 10, height: 10)
        .padding(.top, 4)

      Text(snapshot.comparison.insight)
        .font(.custom("Figtree-Regular", size: 14))
        .foregroundStyle(Color.black)
        .lineLimit(2)
        .minimumScaleFactor(0.82)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .frame(width: width, height: Design.footerHeight, alignment: .center)
    .background(Design.footerBackgroundColor)
  }
}

private struct WeeklyContextLineSeries: Identifiable {
  let id: String
  let label: String
  let colorHex: String
  let values: [Int]
}

private struct WeeklyContextDistributionCard: View {
  let snapshot: WeeklyContextDistributionSnapshot
  let width: CGFloat

  private enum Design {
    static let width: CGFloat = 340
    static let height: CGFloat = 427
    static let plotWidth: CGFloat = 216
    static let plotHeight: CGFloat = 283
    static let contextColor = Color(hex: "B097FF")
    static let distractionColor = Color(hex: "FF7C5A")
    static let axisColor = Color(hex: "C9C2BC")
  }

  init(snapshot: WeeklyContextDistributionSnapshot, width: CGFloat = Design.width) {
    self.snapshot = snapshot
    self.width = width
  }

  private var plotWidth: CGFloat {
    max(Design.plotWidth, width - 124)
  }

  private var hourTicks: [String] {
    ["6pm", "5pm", "4pm", "3pm", "2pm", "1pm", "12pm", "11am", "10am"]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Context shift and distractions distribution")
        .font(.custom("InstrumentSerif-Regular", size: 18))
        .foregroundStyle(Color(hex: "B46531"))
        .padding(.leading, 25)
        .padding(.top, 18)

      HStack(spacing: 24) {
        legendItem("Context shift", color: Design.contextColor)
        legendItem("Distraction", color: Design.distractionColor)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 23)

      HStack(alignment: .top, spacing: 3) {
        VStack {
          ForEach(hourTicks, id: \.self) { tick in
            Text(tick)
              .font(.custom("Figtree-Regular", size: 8))
              .foregroundStyle(Color.black)

            if tick != hourTicks.last {
              Spacer(minLength: 0)
            }
          }
        }
        .frame(width: 21, height: 261)

        scatterPlot
      }
      .padding(.top, 24)
      .padding(.leading, 46)

      HStack(spacing: 8) {
        ForEach(snapshot.days, id: \.self) { day in
          Text(day)
            .font(.custom("Figtree-Regular", size: 10))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
        }
      }
      .frame(width: plotWidth)
      .padding(.top, 7)
      .padding(.leading, 70)
    }
    .frame(width: width, height: Design.height, alignment: .topLeading)
    .background(Color.white.opacity(0.75))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var scatterPlot: some View {
    ZStack(alignment: .topLeading) {
      HStack(spacing: 8) {
        ForEach(snapshot.days, id: \.self) { _ in
          Rectangle()
            .fill(Design.axisColor.opacity(0.13))
        }
      }

      VStack(spacing: 27) {
        ForEach(0..<10, id: \.self) { _ in
          Rectangle()
            .fill(Design.axisColor.opacity(0.16))
            .frame(height: 1)
        }
      }

      Rectangle()
        .fill(Design.axisColor)
        .frame(width: 1)

      Rectangle()
        .fill(Design.axisColor)
        .frame(height: 1)
        .frame(maxHeight: .infinity, alignment: .bottom)

      ForEach(snapshot.events) { event in
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(event.kind == .context ? Design.contextColor : Design.distractionColor)
          .frame(width: 28, height: 1.5)
          .position(point(for: event))
      }
    }
    .frame(width: plotWidth, height: Design.plotHeight)
  }

  private func point(for event: WeeklyContextDistributionEvent) -> CGPoint {
    let dayIndex = snapshot.days.firstIndex(of: event.day) ?? 0
    let x = ((CGFloat(dayIndex) + 0.5) / CGFloat(max(snapshot.days.count, 1))) * plotWidth
    let start = minutes(snapshot.start)
    let end = minutes(snapshot.end)
    let y =
      ((CGFloat(end - minutes(event.time))) / CGFloat(max(end - start, 1))) * Design.plotHeight
    return CGPoint(x: x, y: min(max(y, 0), Design.plotHeight))
  }

  private func legendItem(_ title: String, color: Color) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 9, height: 9)

      Text(title)
        .font(.custom("Figtree-Regular", size: 10))
        .foregroundStyle(Color.black)
    }
  }
}

private struct WeeklyContextComparisonBarCard: View {
  let snapshot: WeeklyContextComparisonSnapshot
  let width: CGFloat

  private enum Design {
    static let width: CGFloat = 574
    static let height: CGFloat = 427
    static let mainHeight: CGFloat = 369
    static let barAreaHeight: CGFloat = 204
    static let maxBarHeight: CGFloat = 180
    static let axisColor = Color(hex: "C9C2BC")
  }

  init(snapshot: WeeklyContextComparisonSnapshot, width: CGFloat = Design.width) {
    self.snapshot = snapshot
    self.width = width
  }

  private var maxValue: Int {
    snapshot.days.flatMap { [$0.distracted, $0.shifts] }.max() ?? 1
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        Text("Context shift and distractions comparison")
          .font(.custom("InstrumentSerif-Regular", size: 18))
          .foregroundStyle(Color(hex: "B46531"))
          .padding(.top, 22)
          .padding(.leading, 25)

        bars
          .padding(.top, 45)
          .padding(.horizontal, 32)

        legend
          .padding(.top, 40)
          .frame(maxWidth: .infinity)
      }
      .frame(width: width, height: Design.mainHeight, alignment: .topLeading)
      .background(Color.white.opacity(0.75))
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color(hex: "EBE6E3"))
          .frame(height: 1)
      }

      footer
    }
    .frame(width: width, height: Design.height, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var bars: some View {
    HStack(alignment: .bottom, spacing: 12) {
      ForEach(snapshot.days) { day in
        VStack(spacing: 0) {
          HStack(alignment: .bottom, spacing: 2) {
            metricBar(
              value: day.distracted, color: Color(hex: "FF653B"), softColor: Color(hex: "FF9999"))
            metricBar(
              value: day.shifts, color: Color(hex: "A88CFF"), softColor: Color(hex: "A1B7FF"))
          }
          .frame(height: 192, alignment: .bottom)

          Text(day.day)
            .font(.custom("Figtree-Regular", size: 12))
            .foregroundStyle(Color.black)
            .padding(.top, 10)
        }
      }
    }
    .padding(.leading, 10)
    .frame(
      maxWidth: .infinity, minHeight: Design.barAreaHeight, maxHeight: Design.barAreaHeight,
      alignment: .bottom
    )
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(Design.axisColor)
        .frame(width: 1)
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Design.axisColor)
        .frame(height: 1)
    }
  }

  private func metricBar(value: Int, color: Color, softColor: Color) -> some View {
    let height = max(CGFloat(2), CGFloat(value) / CGFloat(max(maxValue, 1)) * Design.maxBarHeight)

    return VStack(spacing: 4) {
      Text("\(value)")
        .font(.custom("Figtree-Regular", size: 10))
        .foregroundStyle(color)

      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(
          LinearGradient(
            colors: [color.opacity(0.9), softColor.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .frame(width: 18, height: height)
        .overlay(
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .stroke(color.opacity(0.72), lineWidth: 0.75)
        )
    }
  }

  private var legend: some View {
    HStack(spacing: 24) {
      legendItem("Number of times distracted", color: Color(hex: "FF653B"))
      legendItem("Number of context shifts", color: Color(hex: "A88CFF"))
    }
  }

  private func legendItem(_ title: String, color: Color) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(color.opacity(0.65))
        .frame(width: 10, height: 10)

      Text(title)
        .font(.custom("Figtree-Regular", size: 10))
        .foregroundStyle(Color.black)
    }
  }

  private var footer: some View {
    HStack(spacing: 14) {
      HStack(alignment: .top, spacing: 4) {
        Circle()
          .fill(Color(hex: "F5AD41"))
          .frame(width: 7, height: 7)
          .padding(.top, 3)

        Text(snapshot.insight)
          .font(.custom("Figtree-Regular", size: 12))
          .foregroundStyle(Color.black)
          .lineSpacing(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 18)
    .frame(width: width, height: 58, alignment: .center)
    .background(Color(hex: "FAF7F5"))
  }
}

struct WeeklyContextChartsSnapshot {
  let distribution: WeeklyContextDistributionSnapshot
  let comparison: WeeklyContextComparisonSnapshot

  static let figmaPreview = WeeklyContextChartsSnapshot(
    distribution: .figmaPreview,
    comparison: .figmaPreview
  )
}

struct WeeklyContextDistributionSnapshot {
  let days: [String]
  let start: String
  let end: String
  let events: [WeeklyContextDistributionEvent]

  static let figmaPreview = WeeklyContextDistributionSnapshot(
    days: ["Mon", "Tue", "Wed", "Thur", "Fri", "Sat", "Sun"],
    start: "10:00",
    end: "18:00",
    events: [
      .init(day: "Mon", kind: .context, time: "10:45"),
      .init(day: "Mon", kind: .distraction, time: "11:55"),
      .init(day: "Mon", kind: .context, time: "13:55"),
      .init(day: "Mon", kind: .distraction, time: "15:08"),
      .init(day: "Mon", kind: .context, time: "16:40"),
      .init(day: "Tue", kind: .context, time: "12:55"),
      .init(day: "Tue", kind: .distraction, time: "14:45"),
      .init(day: "Tue", kind: .context, time: "15:50"),
      .init(day: "Wed", kind: .distraction, time: "10:55"),
      .init(day: "Wed", kind: .context, time: "11:45"),
      .init(day: "Wed", kind: .distraction, time: "13:20"),
      .init(day: "Wed", kind: .context, time: "14:55"),
      .init(day: "Wed", kind: .distraction, time: "15:55"),
      .init(day: "Thu", kind: .distraction, time: "11:20"),
      .init(day: "Thu", kind: .context, time: "14:15"),
      .init(day: "Thu", kind: .distraction, time: "16:18"),
      .init(day: "Fri", kind: .context, time: "10:28"),
      .init(day: "Fri", kind: .distraction, time: "11:55"),
      .init(day: "Fri", kind: .distraction, time: "14:20"),
      .init(day: "Fri", kind: .context, time: "16:58"),
      .init(day: "Sat", kind: .context, time: "12:10"),
      .init(day: "Sun", kind: .distraction, time: "15:35"),
    ]
  )
}

struct WeeklyContextDistributionEvent: Identifiable {
  let id = UUID()
  let day: String
  let kind: WeeklyContextEventKind
  let time: String
}

enum WeeklyContextEventKind {
  case context
  case distraction
}

struct WeeklyContextComparisonSnapshot {
  let days: [WeeklyContextComparisonDay]
  let insight: String

  static let figmaPreview = WeeklyContextComparisonSnapshot(
    days: [
      .init(day: "Mon", distracted: 12, shifts: 15),
      .init(day: "Tue", distracted: 8, shifts: 10),
      .init(day: "Wed", distracted: 16, shifts: 28),
      .init(day: "Thur", distracted: 12, shifts: 5),
      .init(day: "Fri", distracted: 3, shifts: 10),
      .init(day: "Sat", distracted: 12, shifts: 12),
      .init(day: "Sun", distracted: 6, shifts: 8),
    ],
    insight:
      "Tue had the most interruptions, with 22 context shifts and 53 distractions."
  )
}

struct WeeklyContextComparisonDay: Identifiable {
  let id = UUID()
  let day: String
  let distracted: Int
  let shifts: Int
}

private func minutes(_ time: String) -> Int {
  let parts = time.split(separator: ":").compactMap { Int($0) }
  guard parts.count == 2 else { return 0 }
  return parts[0] * 60 + parts[1]
}

#Preview("Context Charts", traits: .fixedLayout(width: 958, height: 427)) {
  WeeklyContextChartsSection(snapshot: .figmaPreview)
    .padding(24)
    .background(Color(hex: "FBF6EF"))
}
