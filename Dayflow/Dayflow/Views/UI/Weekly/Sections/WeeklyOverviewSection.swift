import AppKit
import SwiftUI

struct WeeklyOverviewSection: View {
  let snapshot: WeeklyOverviewSnapshot

  private enum Design {
    static let sectionWidth: CGFloat = 958
    static let cornerRadius: CGFloat = 4
    static let titleColor = WeeklyPalette.title
    static let borderColor = WeeklyPalette.cardBorder
    @MainActor static var topCardBackground: Color { WeeklyPalette.cardFill }
    static let footerBackground = WeeklyPalette.footer
    static let bodyTextColor = WeeklyPalette.text
    static let secondaryTextColor = WeeklyPalette.secondaryText
    static let chartRowFill = WeeklyPalette.rowFill
    static let chartRowBorder = WeeklyPalette.rowBorder
    static let accentUnderline = Color(hex: "F0A54D")
    static let summaryDividerX: CGFloat = 295

    static let topPadding = EdgeInsets(top: 32, leading: 40, bottom: 32, trailing: 40)
    static let headerSpacing: CGFloat = 32
    static let chartSpacing: CGFloat = 28
    static let chartLabelGap: CGFloat = 8
    static let chartRowsSpacing: CGFloat = 2
    static let axisSpacing: CGFloat = 8
    static let rowHeight: CGFloat = 18
    static let segmentHeight: CGFloat = 12
    static let dayLabelWidth: CGFloat = 26
    static let barsWidth: CGFloat = 836
    static let axisWidth: CGFloat = 837
    static let footerHeight: CGFloat = 65

    static let dayLabels = [
      "9am", "10am", "11am", "12pm", "1pm", "2pm", "3pm", "4pm", "5pm", "6pm",
    ]
  }

  private var topCardShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      cornerRadii: .init(
        topLeading: Design.cornerRadius,
        bottomLeading: 0,
        bottomTrailing: 0,
        topTrailing: Design.cornerRadius
      ),
      style: .continuous
    )
  }

  private var footerShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      cornerRadii: .init(
        topLeading: 0,
        bottomLeading: Design.cornerRadius,
        bottomTrailing: Design.cornerRadius,
        topTrailing: 0
      ),
      style: .continuous
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      topPanel
      footerPanel
    }
    .frame(maxWidth: Design.sectionWidth, alignment: .leading)
  }

  private var topPanel: some View {
    VStack(alignment: .leading, spacing: Design.headerSpacing) {
      HStack(alignment: .bottom) {
        Text("Time distribution")
          .font(.custom("InstrumentSerif-Regular", size: 20))
          .foregroundStyle(Design.titleColor)

        Spacer(minLength: 20)

        WeeklyOverviewTabStrip()
      }

      WeeklyOverviewTimelineChart(snapshot: snapshot)
    }
    .padding(Design.topPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Design.topCardBackground)
    .clipShape(topCardShape)
    .overlay {
      topCardShape
        .stroke(Design.borderColor, lineWidth: 1)
    }
  }

  private var footerPanel: some View {
    HStack(spacing: 0) {
      WeeklyOverviewSummaryGroup(
        title: "Context switch",
        metrics: [
          .init(label: "Total", value: "\(snapshot.contextSwitchTotal) times"),
          .init(label: "Average", value: "\(snapshot.contextSwitchAverage) times / day"),
        ]
      )
      .frame(width: Design.summaryDividerX, alignment: .leading)

      WeeklyOverviewSummaryGroup(
        title: "Focus",
        metrics: [
          .init(label: "Total length", value: compactDurationText(snapshot.totalFocusMinutes)),
          .init(label: "Longest duration", value: longestFocusText),
          .init(label: "Primary focus", value: primaryFocusText),
        ]
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: Design.footerHeight)
    .background(
      HStack(spacing: 0) {
        Design.footerBackground
          .frame(width: Design.summaryDividerX)
        Design.footerBackground
      }
    )
    .clipShape(footerShape)
    .overlay {
      GeometryReader { geometry in
        let width = geometry.size.width
        let height = geometry.size.height
        let radius = Design.cornerRadius

        Path { path in
          path.move(to: CGPoint(x: 0, y: 0))
          path.addLine(to: CGPoint(x: 0, y: height - radius))
          path.addQuadCurve(
            to: CGPoint(x: radius, y: height),
            control: CGPoint(x: 0, y: height)
          )

          path.move(to: CGPoint(x: radius, y: height))
          path.addLine(to: CGPoint(x: width - radius, y: height))

          path.move(to: CGPoint(x: width, y: 0))
          path.addLine(to: CGPoint(x: width, y: height - radius))
          path.addQuadCurve(
            to: CGPoint(x: width - radius, y: height),
            control: CGPoint(x: width, y: height)
          )

          path.move(to: CGPoint(x: Design.summaryDividerX, y: 0))
          path.addLine(to: CGPoint(x: Design.summaryDividerX, y: height))
        }
        .stroke(Design.borderColor, lineWidth: 1)
      }
    }
  }

  private var longestFocusText: String {
    guard let longestFocus = snapshot.longestFocus else {
      return "No focus yet"
    }
    return "\(compactDurationText(longestFocus.minutes)), \(longestFocus.weekdayName)"
  }

  private var primaryFocusText: String {
    guard let primaryFocus = snapshot.primaryFocus else {
      return "No focus yet"
    }
    return "\(primaryFocus.name), \(compactDurationText(primaryFocus.minutes))"
  }

  private func compactDurationText(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if hours > 0 && remainingMinutes > 0 {
      return "\(hours)hr \(remainingMinutes)m"
    }
    if hours > 0 {
      return "\(hours)hr"
    }
    return "\(remainingMinutes)m"
  }
}

private struct WeeklyOverviewTimelineChart: View {
  let snapshot: WeeklyOverviewSnapshot

  private enum Design {
    static let chartSpacing: CGFloat = 28
    static let rowSpacing: CGFloat = 2
    static let axisSpacing: CGFloat = 8
    static let dayLabelWidth: CGFloat = 26
    static let labelGap: CGFloat = 8
    static let barsWidth: CGFloat = 836
    static let axisWidth: CGFloat = 837
    static let rowHeight: CGFloat = 18
    static let segmentHeight: CGFloat = 12
    static let rowFill = WeeklyPalette.rowFill
    static let rowBorder = WeeklyPalette.rowBorder
    static let axisLabels = [
      "9am", "10am", "11am", "12pm", "1pm", "2pm", "3pm", "4pm", "5pm", "6pm",
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.chartSpacing) {
      HStack(alignment: .top, spacing: Design.labelGap) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(snapshot.rows) { row in
            Text(row.label)
              .font(.custom("Figtree-Regular", size: 12))
              .foregroundStyle(WeeklyPalette.text)
              .frame(width: Design.dayLabelWidth, height: 14, alignment: .leading)
          }
        }

        VStack(alignment: .leading, spacing: Design.axisSpacing) {
          VStack(spacing: Design.rowSpacing) {
            ForEach(snapshot.rows) { row in
              WeeklyOverviewTimelineBar(row: row)
            }
          }

          HStack {
            ForEach(Design.axisLabels, id: \.self) { label in
              Text(label)
                .font(.custom("Figtree-Regular", size: 10))
                .foregroundStyle(WeeklyPalette.text)
              if label != Design.axisLabels.last {
                Spacer(minLength: 0)
              }
            }
          }
          .frame(width: Design.axisWidth, alignment: .leading)
        }
      }

      HStack(spacing: 25) {
        ForEach(snapshot.legendItems) { item in
          HStack(spacing: 6) {
            Text(item.name)
              .font(.custom("Figtree-Regular", size: 10))
              .foregroundStyle(WeeklyPalette.text)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
              .fill(Color(hex: item.colorHex))
              .frame(width: 12, height: 8)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(minHeight: 8)
    }
  }
}

private struct WeeklyOverviewTimelineBar: View {
  let row: WeeklyOverviewRow

  private enum Design {
    static let barWidth: CGFloat = 836
    static let rowHeight: CGFloat = 18
    static let segmentHeight: CGFloat = 12
    static let visibleStartMinute = 9.0 * 60.0
    static let visibleEndMinute = 18.0 * 60.0
    static let fill = WeeklyPalette.rowFill
    static let border = WeeklyPalette.rowBorder
  }

  var body: some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(Design.fill)
        .frame(width: Design.barWidth, height: Design.rowHeight)
        .overlay {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .stroke(Design.border, lineWidth: 0.5)
        }

      ForEach(row.segments) { segment in
        segmentView(segment)
      }
    }
    .frame(width: Design.barWidth, height: Design.rowHeight, alignment: .leading)
  }

  private func segmentView(_ segment: WeeklyOverviewSegment) -> some View {
    let visibleDuration = Design.visibleEndMinute - Design.visibleStartMinute
    let xProgress = (segment.startMinute - Design.visibleStartMinute) / visibleDuration
    let widthProgress = (segment.endMinute - segment.startMinute) / visibleDuration
    let segmentX = max(0, CGFloat(xProgress) * Design.barWidth)
    let segmentWidth = max(2, (CGFloat(widthProgress) * Design.barWidth) - 2)

    return RoundedRectangle(cornerRadius: 1, style: .continuous)
      .fill(gradient(for: segment.colorHex))
      .frame(width: segmentWidth, height: Design.segmentHeight)
      .offset(x: segmentX + 1)
  }

  private func gradient(for colorHex: String) -> LinearGradient {
    let baseColor = NSColor(hex: colorHex) ?? .systemGray
    let leading = baseColor.blended(with: 0.22, of: .white) ?? baseColor
    let trailing = baseColor.blended(with: 0.08, of: .black) ?? baseColor

    return LinearGradient(
      colors: [Color(nsColor: leading), Color(nsColor: trailing)],
      startPoint: .leading,
      endPoint: .trailing
    )
  }
}

private struct WeeklyOverviewTabStrip: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Text("All")
          .font(.custom("Figtree-Bold", size: 12))
          .foregroundStyle(WeeklyPalette.text)

        Text("Longest focus period")
          .font(.custom("Figtree-Medium", size: 12))
          .foregroundStyle(WeeklyPalette.text)

        Text("Least context shifts")
          .font(.custom("Figtree-Medium", size: 12))
          .foregroundStyle(WeeklyPalette.text)

        Text("Most context shifts")
          .font(.custom("Figtree-Medium", size: 12))
          .foregroundStyle(WeeklyPalette.text)
      }

      Rectangle()
        .fill(Color(hex: "F0A54D"))
        .frame(width: 22, height: 1)
    }
  }
}

private struct WeeklyOverviewSummaryGroup: View {
  let title: String
  let metrics: [WeeklyOverviewSummaryMetric]

  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      Text(title)
        .font(.custom("InstrumentSerif-Regular", size: 16))
        .foregroundStyle(WeeklyPalette.title)

      HStack(alignment: .top, spacing: 20) {
        ForEach(metrics) { metric in
          VStack(alignment: .leading, spacing: 8) {
            Text(metric.label)
              .font(.custom("Figtree-Regular", size: 12))
              .foregroundStyle(WeeklyPalette.secondaryText)

            Text(metric.value)
              .font(.custom("InstrumentSerif-Regular", size: 18))
              .foregroundStyle(WeeklyPalette.text)
              .lineLimit(1)
          }
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

private struct WeeklyOverviewSummaryMetric: Identifiable {
  let id = UUID()
  let label: String
  let value: String
}

extension WeeklyOverviewSnapshot {
  static let figmaPreview = WeeklyOverviewSnapshot(
    rows: [
      WeeklyOverviewRow(
        id: "mon",
        label: "Mon",
        weekdayName: "Monday",
        segments: [
          segment("mon-alignment-1", "alignment", "6CDACD", 555, 573),
          segment("mon-testing", "testing", "FFA189", 574, 725),
          segment("mon-general-1", "general", "BFB6AE", 727, 771),
          segment("mon-alignment-2", "alignment", "6CDACD", 773, 873),
          segment("mon-general-2", "general", "BFB6AE", 875, 919),
          segment("mon-research", "research", "93BCFF", 921, 1065),
        ]
      ),
      WeeklyOverviewRow(
        id: "tue",
        label: "Tue",
        weekdayName: "Tuesday",
        segments: [
          segment("tue-testing", "testing", "FFA189", 547, 731),
          segment("tue-design", "design", "DE9DFC", 732, 760),
          segment("tue-alignment", "alignment", "6CDACD", 761, 880),
          segment("tue-research", "research", "93BCFF", 881, 1040),
        ]
      ),
      WeeklyOverviewRow(
        id: "wed",
        label: "Wed",
        weekdayName: "Wednesday",
        segments: [
          segment("wed-alignment-1", "alignment", "6CDACD", 555, 572),
          segment("wed-design-1", "design", "DE9DFC", 574, 754),
          segment("wed-research-1", "research", "93BCFF", 755, 773),
          segment("wed-design-2", "design", "DE9DFC", 774, 815),
          segment("wed-research-2", "research", "93BCFF", 816, 856),
          segment("wed-design-3", "design", "DE9DFC", 858, 899),
          segment("wed-alignment-2", "alignment", "6CDACD", 900, 1017),
        ]
      ),
      WeeklyOverviewRow(
        id: "thu",
        label: "Thu",
        weekdayName: "Thursday",
        segments: [
          segment("thu-alignment-1", "alignment", "6CDACD", 542, 603),
          segment("thu-design-1", "design", "DE9DFC", 604, 736),
          segment("thu-testing", "testing", "FFA189", 737, 782),
          segment("thu-general", "general", "BFB6AE", 783, 826),
          segment("thu-design-2", "design", "DE9DFC", 827, 871),
          segment("thu-alignment-2", "alignment", "6CDACD", 872, 1010),
          segment("thu-design-3", "design", "DE9DFC", 1011, 1038),
          segment("thu-alignment-3", "alignment", "6CDACD", 1039, 1052),
        ]
      ),
      WeeklyOverviewRow(
        id: "fri",
        label: "Fri",
        weekdayName: "Friday",
        segments: [
          segment("fri-alignment-1", "alignment", "6CDACD", 547, 567),
          segment("fri-design", "design", "DE9DFC", 569, 766),
          segment("fri-alignment-2", "alignment", "6CDACD", 767, 863),
          segment("fri-testing", "testing", "FFA189", 864, 1007),
          segment("fri-alignment-3", "alignment", "6CDACD", 1008, 1019),
        ]
      ),
    ],
    legendItems: [
      WeeklyOverviewLegendItem(id: "research", name: "Research", colorHex: "93BCFF"),
      WeeklyOverviewLegendItem(id: "design", name: "Design", colorHex: "DE9DFC"),
      WeeklyOverviewLegendItem(id: "alignment", name: "Alignment", colorHex: "6CDACD"),
      WeeklyOverviewLegendItem(id: "testing", name: "Testing", colorHex: "FFA189"),
      WeeklyOverviewLegendItem(id: "general", name: "General", colorHex: "BFB6AE"),
    ],
    contextSwitchTotal: 52,
    contextSwitchAverage: 7,
    totalFocusMinutes: 1478,
    longestFocus: WeeklyOverviewFocusSummary(weekdayName: "Wednesday", minutes: 245),
    primaryFocus: WeeklyOverviewCategorySummary(
      name: "Design",
      minutes: 734,
      colorHex: "DE9DFC"
    )
  )

  fileprivate static func segment(
    _ id: String,
    _ categoryKey: String,
    _ colorHex: String,
    _ startMinute: Double,
    _ endMinute: Double
  ) -> WeeklyOverviewSegment {
    WeeklyOverviewSegment(
      id: id,
      categoryKey: categoryKey,
      colorHex: colorHex,
      startMinute: startMinute,
      endMinute: endMinute
    )
  }
}

#Preview("Weekly Overview Section", traits: .fixedLayout(width: 958, height: 339)) {
  WeeklyOverviewSection(snapshot: .figmaPreview)
    .padding(24)
    .background(WeeklyPalette.canvas)
}
