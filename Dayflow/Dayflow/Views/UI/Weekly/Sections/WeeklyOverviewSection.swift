import AppKit
import SwiftUI

struct WeeklyOverviewSection: View {
  let snapshot: WeeklyOverviewSnapshot

  private enum Design {
    static let sectionWidth: CGFloat = 958
    static let cornerRadius: CGFloat = 4
    static let titleColor = Color(hex: "B46531")
    static let borderColor = Color(hex: "EBE6E3")
    static let topCardBackground = Color.white.opacity(0.6)
    static let footerBackground = Color(hex: "FAF7F5")
    static let bodyTextColor = Color(hex: "333333")
    static let secondaryTextColor = Color(hex: "777777")
    static let chartRowFill = Color(hex: "F2F2F2")
    static let chartRowBorder = Color(hex: "E5E4E3")
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
    static let rowFill = Color(hex: "F2F2F2")
    static let rowBorder = Color(hex: "E5E4E3")
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
              .font(.custom("Nunito-Regular", size: 12))
              .foregroundStyle(Color.black)
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
                .font(.custom("Nunito-Regular", size: 10))
                .foregroundStyle(Color.black)
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
              .font(.custom("Nunito-Regular", size: 10))
              .foregroundStyle(Color.black)

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
    static let fill = Color(hex: "F2F2F2")
    static let border = Color(hex: "E5E4E3")
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
      .offset(x: segmentX + 1, y: 3)
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
          .font(.custom("Nunito-Bold", size: 12))
          .foregroundStyle(Color(hex: "333333"))

        Text("Longest focus period")
          .font(.custom("Nunito-Medium", size: 12))
          .foregroundStyle(Color(hex: "333333"))

        Text("Least context shifts")
          .font(.custom("Nunito-Medium", size: 12))
          .foregroundStyle(Color(hex: "333333"))

        Text("Most context shifts")
          .font(.custom("Nunito-Medium", size: 12))
          .foregroundStyle(Color(hex: "333333"))
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
        .foregroundStyle(Color(hex: "B46531"))

      HStack(alignment: .top, spacing: 20) {
        ForEach(metrics) { metric in
          VStack(alignment: .leading, spacing: 8) {
            Text(metric.label)
              .font(.custom("Nunito-Regular", size: 12))
              .foregroundStyle(Color(hex: "777777"))

            Text(metric.value)
              .font(.custom("InstrumentSerif-Regular", size: 18))
              .foregroundStyle(Color(hex: "333333"))
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
