import AppKit
import SwiftUI

struct WeeklyFocusHeatmapSection: View {
  let snapshot: WeeklyFocusHeatmapSnapshot
  let cellGap: CGFloat

  private enum Design {
    static let cardWidth: CGFloat = 958
    static let cardHeight: CGFloat = 238
    static let cornerRadius: CGFloat = 4
    static let borderColor = Color(hex: "EBE6E3")
    static let backgroundColor = Color.white.opacity(0.75)
    static let titleColor = Color(hex: "B46531")

    static let topPadding: CGFloat = 34
    static let leadingPadding: CGFloat = 44
    static let trailingPadding: CGFloat = 46
    static let bottomPadding: CGFloat = 42
    static let headerBottomSpacing: CGFloat = 25

    static let labelsWidth: CGFloat = 22
    static let labelsToGridSpacing: CGFloat = 6
    static let rowHeight: CGFloat = 12
    static let cellWidth: CGFloat = 7
    static let cellHeight: CGFloat = 12
    static let axisWidth: CGFloat = 755
    static let axisTopSpacing: CGFloat = 8
    static let legendWidth: CGFloat = 282.156
    static let legendBarHeight: CGFloat = 8
    static let legendCornerRadius: CGFloat = 2
  }

  init(snapshot: WeeklyFocusHeatmapSnapshot, cellGap: CGFloat = 0.5) {
    self.snapshot = snapshot
    self.cellGap = cellGap
  }

  private var resolvedCellGap: CGFloat {
    max(cellGap, 0)
  }

  private var columnCount: Int {
    snapshot.rows.map { $0.values.count }.max() ?? 0
  }

  private var gridWidth: CGFloat {
    guard columnCount > 0 else { return 0 }

    return (CGFloat(columnCount) * Design.cellWidth)
      + (CGFloat(columnCount - 1) * resolvedCellGap)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.headerBottomSpacing) {
      header
      heatmap
    }
    .padding(.top, Design.topPadding)
    .padding(.leading, Design.leadingPadding)
    .padding(.trailing, Design.trailingPadding)
    .padding(.bottom, Design.bottomPadding)
    .frame(width: Design.cardWidth, height: Design.cardHeight, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Design.backgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(Design.borderColor, lineWidth: 1)
    )
  }

  private var header: some View {
    HStack(alignment: .top) {
      Text(snapshot.title)
        .font(.custom("InstrumentSerif-Regular", size: 20))
        .foregroundStyle(Design.titleColor)

      Spacer(minLength: 24)

      legend
        .padding(.top, 7)
    }
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: 4) {
      LinearGradient(
        colors: [
          DesignColor.focusDark,
          DesignColor.focusSoft,
          DesignColor.distractionSoft,
          DesignColor.distractionDark,
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: Design.legendWidth, height: Design.legendBarHeight)
      .clipShape(
        RoundedRectangle(cornerRadius: Design.legendCornerRadius, style: .continuous)
      )

      HStack {
        Text(snapshot.focusedLabel)
        Spacer(minLength: 8)
        Text(snapshot.distractedLabel)
      }
      .font(.custom("Nunito-Regular", size: 10))
      .foregroundStyle(Color.black)
      .frame(width: Design.legendWidth)
    }
  }

  private var heatmap: some View {
    HStack(alignment: .top, spacing: Design.labelsToGridSpacing) {
      dayLabels
      gridAndAxis
    }
  }

  private var dayLabels: some View {
    VStack(alignment: .leading, spacing: resolvedCellGap) {
      ForEach(snapshot.rows) { row in
        Text(row.label)
          .font(.custom("Nunito-Regular", size: 10))
          .foregroundStyle(Color.black)
          .frame(width: Design.labelsWidth, height: Design.rowHeight, alignment: .leading)
      }
    }
  }

  private var gridAndAxis: some View {
    VStack(alignment: .leading, spacing: Design.axisTopSpacing) {
      VStack(alignment: .leading, spacing: resolvedCellGap) {
        ForEach(snapshot.rows) { row in
          HStack(spacing: resolvedCellGap) {
            ForEach(Array(row.values.enumerated()), id: \.offset) { entry in
              RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                .fill(color(for: entry.element))
                .frame(width: Design.cellWidth, height: Design.cellHeight)
            }
          }
        }
      }
      .frame(width: gridWidth, alignment: .leading)

      HStack {
        ForEach(Array(snapshot.timeLabels.enumerated()), id: \.offset) { entry in
          Text(entry.element)
            .font(.custom("Nunito-Regular", size: 10))
            .foregroundStyle(Color.black)

          if entry.offset < snapshot.timeLabels.count - 1 {
            Spacer(minLength: 0)
          }
        }
      }
      .frame(width: Design.axisWidth, alignment: .leading)
      .frame(width: gridWidth, alignment: .center)
    }
  }

  private func color(for value: Double) -> Color {
    let clampedValue = max(-1, min(1, value))
    let intensity = abs(clampedValue)

    if intensity < 0.06 {
      return DesignColor.neutral
    }

    if clampedValue < 0 {
      let nsColor = interpolatedColor(
        from: DesignColor.focusSoftNS,
        to: DesignColor.focusDarkNS,
        progress: intensity
      )
      return Color(nsColor: nsColor)
    }

    let nsColor = interpolatedColor(
      from: DesignColor.distractionSoftNS,
      to: DesignColor.distractionDarkNS,
      progress: intensity
    )
    return Color(nsColor: nsColor)
  }

  private func interpolatedColor(from start: NSColor, to end: NSColor, progress: Double) -> NSColor
  {
    let fraction = CGFloat(max(0, min(1, progress)))
    let startRGB = start.usingColorSpace(.deviceRGB) ?? start
    let endRGB = end.usingColorSpace(.deviceRGB) ?? end

    let red = startRGB.redComponent + ((endRGB.redComponent - startRGB.redComponent) * fraction)
    let green =
      startRGB.greenComponent + ((endRGB.greenComponent - startRGB.greenComponent) * fraction)
    let blue = startRGB.blueComponent + ((endRGB.blueComponent - startRGB.blueComponent) * fraction)
    let alpha =
      startRGB.alphaComponent + ((endRGB.alphaComponent - startRGB.alphaComponent) * fraction)

    return NSColor(
      calibratedRed: red,
      green: green,
      blue: blue,
      alpha: alpha
    )
  }
}

struct WeeklyFocusHeatmapSnapshot {
  let title: String
  let focusedLabel: String
  let distractedLabel: String
  let timeLabels: [String]
  let rows: [WeeklyFocusHeatmapRow]

  static let figmaPreview = WeeklyFocusHeatmapSnapshot(
    title: "Focus and distraction heat map",
    focusedLabel: "Focused work",
    distractedLabel: "Distracted",
    timeLabels: ["9am", "10am", "11am", "12pm", "1pm", "2pm", "3pm", "4pm", "5pm"],
    rows: [
      .init(
        id: "sun",
        label: "Sun",
        values: buckets(
          runs: [
            .neutral(0..<19),
            .distracted(19..<22, 0.34),
            .neutral(22..<31),
            .focused(31..<34, 0.18),
            .neutral(34..<108),
          ]
        )
      ),
      .init(
        id: "mon",
        label: "Mon",
        values: buckets(
          runs: [
            .focused(2..<11, 0.20),
            .focused(11..<20, 0.78),
            .focused(20..<37, 0.42),
            .distracted(37..<41, 0.40),
            .focused(41..<49, 0.24),
            .distracted(49..<54, 0.36),
            .focused(54..<102, 0.82),
            .focused(102..<108, 0.18),
          ]
        )
      ),
      .init(
        id: "tue",
        label: "Tue",
        values: buckets(
          runs: [
            .focused(0..<7, 0.12),
            .focused(7..<22, 0.62),
            .focused(22..<29, 0.20),
            .focused(29..<42, 0.88),
            .distracted(42..<45, 0.44),
            .neutral(45..<53),
            .distracted(53..<57, 0.42),
            .focused(57..<103, 0.92),
            .focused(103..<108, 0.22),
          ]
        )
      ),
      .init(
        id: "wed",
        label: "Wed",
        values: buckets(
          runs: [
            .focused(0..<10, 0.10),
            .focused(10..<18, 0.58),
            .focused(18..<24, 0.72),
            .neutral(24..<31),
            .focused(31..<40, 0.66),
            .focused(40..<60, 0.32),
            .distracted(60..<76, 0.86),
            .neutral(76..<82),
            .distracted(82..<88, 0.62),
            .focused(88..<98, 0.54),
            .focused(98..<104, 0.24),
          ]
        )
      ),
      .init(
        id: "thu",
        label: "Thu",
        values: buckets(
          runs: [
            .focused(8..<14, 0.96),
            .distracted(14..<19, 0.32),
            .neutral(19..<22),
            .focused(22..<40, 0.94),
            .neutral(40..<58),
            .distracted(58..<73, 0.92),
            .neutral(73..<83),
            .focused(83..<101, 0.88),
            .focused(101..<105, 0.24),
          ]
        )
      ),
      .init(
        id: "fri",
        label: "Fri",
        values: buckets(
          runs: [
            .focused(0..<5, 0.24),
            .focused(5..<9, 0.54),
            .distracted(9..<12, 0.48),
            .focused(12..<17, 0.32),
            .focused(17..<23, 0.86),
            .distracted(23..<27, 0.72),
            .neutral(27..<33),
            .focused(33..<49, 0.90),
            .focused(49..<58, 0.46),
            .neutral(58..<69),
            .focused(69..<84, 0.84),
            .focused(84..<98, 0.46),
            .focused(98..<103, 0.16),
          ]
        )
      ),
      .init(
        id: "sat",
        label: "Sat",
        values: buckets(
          runs: [
            .neutral(0..<6),
            .focused(6..<10, 0.24),
            .neutral(10..<45),
            .focused(45..<49, 0.34),
            .focused(49..<53, 0.54),
            .focused(53..<58, 0.34),
            .neutral(58..<108),
          ]
        )
      ),
    ]
  )

  private enum Run {
    case neutral(Range<Int>)
    case focused(Range<Int>, Double)
    case distracted(Range<Int>, Double)
  }

  private static func buckets(runs: [Run]) -> [Double] {
    var values = Array(repeating: 0.0, count: 108)

    for run in runs {
      switch run {
      case .neutral(let range):
        for index in range where values.indices.contains(index) {
          values[index] = 0
        }
      case .focused(let range, let intensity):
        for index in range where values.indices.contains(index) {
          values[index] = -intensity
        }
      case .distracted(let range, let intensity):
        for index in range where values.indices.contains(index) {
          values[index] = intensity
        }
      }
    }

    return values
  }
}

struct WeeklyFocusHeatmapRow: Identifiable {
  let id: String
  let label: String
  let values: [Double]
}

private enum DesignColor {
  static let neutral = Color(hex: "F2F2F2")
  static let focusSoft = Color(hex: "E3DBFD")
  static let focusDark = Color(hex: "4276E9")
  static let distractionSoft = Color(hex: "F8D1CA")
  static let distractionDark = Color(hex: "FC7645")

  static let focusSoftNS = NSColor(hex: "E3DBFD") ?? .systemBlue
  static let focusDarkNS = NSColor(hex: "4276E9") ?? .systemBlue
  static let distractionSoftNS = NSColor(hex: "F8D1CA") ?? .systemOrange
  static let distractionDarkNS = NSColor(hex: "FC7645") ?? .systemOrange
}

private struct WeeklyFocusHeatmapGapPreview: View {
  @State private var cellGap: CGFloat = 0.5

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Text("Gap")
          .font(.custom("Nunito-Regular", size: 12))

        Slider(value: $cellGap, in: 0...1.5, step: 0.1)
          .frame(width: 220)

        Text("\(cellGap, format: .number.precision(.fractionLength(1))) pt")
          .font(.custom("Nunito-Regular", size: 12))
          .monospacedDigit()
      }

      WeeklyFocusHeatmapSection(
        snapshot: .figmaPreview,
        cellGap: cellGap
      )
    }
    .padding(24)
    .background(Color(hex: "F7F3F0"))
  }
}

#Preview("Weekly Focus Heatmap Tuning") {
  WeeklyFocusHeatmapGapPreview()
}
