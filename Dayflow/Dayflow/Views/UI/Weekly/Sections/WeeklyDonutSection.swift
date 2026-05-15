import Charts
import SwiftUI

struct WeeklyDonutSection: View {
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
    static let borderColor = Color(hex: "EBE6E3")
    static let backgroundColor = Color.white.opacity(0.6)
    static let titleColor = Color(hex: "B46531")
    static let contentHorizontalPadding: CGFloat = 18
    static let contentSpacing: CGFloat = 18
    static let donutSize: CGFloat = 205
  }

  private var donutSize: CGFloat {
    min(235, max(176, width * 0.43))
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

      HStack(alignment: .center, spacing: Design.contentSpacing) {
        donutContent

        legendContent
      }
      .padding(.top, 56)
      .padding(.horizontal, Design.contentHorizontalPadding)

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
          totalMinutes: snapshot.totalMinutes
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct WeeklyDonutChart: View {
  let snapshot: WeeklyDonutSnapshot
  let size: CGFloat

  private let innerRadiusRatio: CGFloat = 0.62
  private let innerGap: CGFloat = 8

  private var chartSize: CGFloat {
    size - 8
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(Color.white)
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.39, green: 0.28, blue: 0.22).opacity(0.35), radius: 5)

      Chart(snapshot.items) { item in
        SectorMark(
          angle: .value("Minutes", item.minutes),
          innerRadius: .ratio(innerRadiusRatio),
          angularInset: 1.5
        )
        .cornerRadius(6)
        .foregroundStyle(Color(hex: item.colorHex))
      }
      .chartLegend(.hidden)
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

      Circle()
        .fill(Color.white)
        .frame(
          width: chartSize * innerRadiusRatio - innerGap,
          height: chartSize * innerRadiusRatio - innerGap
        )

      WeeklyDonutCenterContent(totalMinutes: snapshot.totalMinutes)
    }
    .frame(width: size, height: size)
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
        .foregroundStyle(Color(hex: "A5A5A5"))

      VStack(spacing: 0) {
        Text("\(totalHours) \(hourLabel)")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundStyle(Color(hex: "333333"))

        Text("\(remainingMinutes) \(minuteLabel)")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundStyle(Color(hex: "333333"))
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
          .foregroundStyle(Color.black)
          .lineLimit(1)
          .layoutPriority(1)
      }

      Spacer(minLength: 8)

      Text(percentageText)
        .font(.custom("Figtree-Regular", size: 14))
        .foregroundStyle(Color.black)
        .frame(minWidth: 32, alignment: .trailing)
    }
  }
}

private struct WeeklyDonutEmptyState: View {
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .fill(Color.white)
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.39, green: 0.28, blue: 0.22).opacity(0.12), radius: 5)

      Circle()
        .stroke(Color(hex: "E6E0DB"), lineWidth: 20)
        .frame(width: size - 20, height: size - 20)

      VStack(spacing: 4) {
        Text("TOTAL")
          .font(.custom("Figtree-Bold", size: 8))
          .foregroundStyle(Color(hex: "A5A5A5"))

        Text("No activity")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundStyle(Color(hex: "777777"))
      }
    }
    .frame(width: size, height: size)
  }
}

#Preview("Weekly Donut Section", traits: .fixedLayout(width: 488, height: 305)) {
  WeeklyDonutSection(
    snapshot: .figmaPreview,
    isLoading: false
  )
  .padding(16)
  .background(Color(hex: "F7F3F0"))
}
