//
//  LongestFocusCard.swift
//  Dayflow
//
//  A card showing the longest focus duration with a timeline visualization
//

import SwiftUI

// MARK: - Cached DateFormatter (creating DateFormatters is expensive due to ICU initialization)

private let cachedFocusTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  return formatter
}()

// MARK: - Data Model

struct FocusBlock: Identifiable {
  let id: UUID
  let startTime: Date
  let endTime: Date

  init(id: UUID = UUID(), startTime: Date, endTime: Date) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
  }

  var duration: TimeInterval {
    endTime.timeIntervalSince(startTime)
  }
}

// MARK: - Main View

struct LongestFocusCard: View {
  let focusBlocks: [FocusBlock]

  // MARK: - Design Constants

  private enum Design {
    // Colors
    static let backgroundColor = Color(hex: "f7f7f7")
    static let borderColor = Color(hex: "ececec")
    static let titleColor = Color(hex: "333333")
    static let orangeSolid = Color(hex: "f3854b")
    static let orangeLight = Color(hex: "f3854b").opacity(0.4)
    static let axisColor = Color(hex: "9A9393")

    // Sizing
    static let cardWidth: CGFloat = 322
    static let cardHeight: CGFloat = 185
    static let cardCornerRadius: CGFloat = 8
    static let blockCornerRadius: CGFloat = 6
    static let dotSize: CGFloat = 4

    // Typography positions (from Figma)
    static let titleX: CGFloat = 14.5
    static let titleY: CGFloat = 12.53
    static let valueX: CGFloat = 13.5
    static let valueY: CGFloat = 31.53

    // Timeline layout (from Figma)
    static let timelineX: CGFloat = 10.5
    static let timelineY: CGFloat = 92.5
    static let timelineWidth: CGFloat = 301
    static let timelineHeight: CGFloat = 70.02
    static let axisTop: CGFloat = 48
    static let axisHeight: CGFloat = 4

    // Block layout (from Figma)
    static let tallBlockHeight: CGFloat = 50
    static let shortBlockHeight: CGFloat = 27.88
    static let tallBlockTop: CGFloat = 0
    static let shortBlockTop: CGFloat = 22.44
    static let minimumBlockWidth: CGFloat = 8
    static let referenceLongestStartX: CGFloat = 94.05
    static let referenceLongestWidth: CGFloat = 88.02

    // Labels (from Figma)
    static let labelTop: CGFloat = 56.02
    static let labelHeight: CGFloat = 14
    static let labelStartCenterX: CGFloat = 94.05
    static let labelEndCenterX: CGFloat = 184.99
  }

  // MARK: - Computed Properties

  private var longestBlock: FocusBlock? {
    focusBlocks.max(by: { $0.duration < $1.duration })
  }

  private var formattedDuration: String {
    guard let longest = longestBlock else { return "0 minutes" }
    let totalMinutes = Int(longest.duration / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 && minutes > 0 {
      return "\(hours) hours \(minutes) minutes"
    } else if hours > 0 {
      return "\(hours) hours"
    } else {
      return "\(minutes) minutes"
    }
  }

  private var anchoredRange: (start: Date, end: Date)? {
    guard let longest = longestBlock, longest.duration > 0 else { return nil }
    let scale = Double(Design.timelineWidth / Design.referenceLongestWidth)
    let rangeDuration = longest.duration * scale
    let startOffset = rangeDuration * Double(Design.referenceLongestStartX / Design.timelineWidth)
    let rangeStart = longest.startTime.addingTimeInterval(-startOffset)
    let rangeEnd = rangeStart.addingTimeInterval(rangeDuration)
    return (rangeStart, rangeEnd)
  }

  // MARK: - Body

  var body: some View {
    ZStack(alignment: .topLeading) {
      Text("Longest focus duration")
        .font(.custom("InstrumentSerif-Regular", size: 16))
        .foregroundColor(Design.titleColor)
        .offset(x: Design.titleX, y: Design.titleY)

      Text(formattedDuration)
        .font(.custom("InstrumentSerif-Regular", size: 24))
        .foregroundColor(Design.orangeSolid)
        .offset(x: Design.valueX, y: Design.valueY)

      timelineVisualization
        .frame(width: Design.timelineWidth, height: Design.timelineHeight, alignment: .topLeading)
        .offset(x: Design.timelineX, y: Design.timelineY)
    }
    .frame(width: Design.cardWidth, height: Design.cardHeight, alignment: .topLeading)
    .background(Design.backgroundColor)
    .overlay(
      RoundedRectangle(cornerRadius: Design.cardCornerRadius)
        .stroke(Design.borderColor, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Design.cardCornerRadius))
  }

  // MARK: - Timeline Visualization

  private var timelineVisualization: some View {
    ZStack(alignment: .topLeading) {
      timelineAxis()
        .offset(y: Design.axisTop)

      focusBlocksView()

      if let longest = longestBlock {
        timeLabels(for: longest)
      }
    }
  }

  private func timelineAxis() -> some View {
    let dotCount = 12
    let dotSpacing = (Design.timelineWidth - Design.dotSize) / CGFloat(dotCount - 1)
    let lineY = Design.axisHeight / 2

    return ZStack(alignment: .leading) {
      Path { path in
        path.move(to: CGPoint(x: Design.dotSize / 2, y: lineY))
        path.addLine(to: CGPoint(x: Design.timelineWidth - Design.dotSize / 2, y: lineY))
      }
      .stroke(
        Design.axisColor,
        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 2])
      )

      ForEach(0..<dotCount, id: \.self) { index in
        Circle()
          .fill(Design.axisColor)
          .frame(width: Design.dotSize, height: Design.dotSize)
          .position(
            x: (Design.dotSize / 2) + (CGFloat(index) * dotSpacing),
            y: lineY
          )
      }
    }
    .frame(width: Design.timelineWidth, height: Design.axisHeight, alignment: .leading)
  }

  @ViewBuilder
  private func focusBlocksView() -> some View {
    if let range = anchoredRange {
      ZStack(alignment: .topLeading) {
        ForEach(focusBlocks) { block in
          let isLongest = block.id == longestBlock?.id
          let blockFrame = blockFrame(for: block, in: range)

          if blockFrame.width > 0 {
            UnevenRoundedRectangle(
              topLeadingRadius: Design.blockCornerRadius,
              bottomLeadingRadius: 0,
              bottomTrailingRadius: 0,
              topTrailingRadius: Design.blockCornerRadius
            )
            .fill(isLongest ? Design.orangeSolid : Design.orangeLight)
            .frame(
              width: max(blockFrame.width, Design.minimumBlockWidth),
              height: isLongest ? Design.tallBlockHeight : Design.shortBlockHeight
            )
            .offset(
              x: blockFrame.x,
              y: isLongest ? Design.tallBlockTop : Design.shortBlockTop
            )
          }
        }
      }
    }
  }

  private func timeLabels(for block: FocusBlock) -> some View {
    ZStack {
      Text(cachedFocusTimeFormatter.string(from: block.startTime))
        .font(.custom("Nunito-Bold", size: 10))
        .foregroundColor(Design.orangeSolid)
        .position(
          x: Design.labelStartCenterX,
          y: Design.labelTop + (Design.labelHeight / 2)
        )

      Text(cachedFocusTimeFormatter.string(from: block.endTime))
        .font(.custom("Nunito-Bold", size: 10))
        .foregroundColor(Design.orangeSolid)
        .position(
          x: Design.labelEndCenterX,
          y: Design.labelTop + (Design.labelHeight / 2)
        )
    }
  }

  // MARK: - Helper Functions

  private func xPosition(for date: Date, in range: (start: Date, end: Date)) -> CGFloat {
    let totalDuration = range.end.timeIntervalSince(range.start)
    let offset = date.timeIntervalSince(range.start)
    guard totalDuration > 0 else { return 0 }
    return CGFloat(offset / totalDuration) * Design.timelineWidth
  }

  private func blockFrame(for block: FocusBlock, in range: (start: Date, end: Date)) -> (
    x: CGFloat, width: CGFloat
  ) {
    let startX = xPosition(for: block.startTime, in: range)
    let endX = xPosition(for: block.endTime, in: range)
    let rawMin = min(startX, endX)
    let rawMax = max(startX, endX)
    let clampedMin = max(0, min(rawMin, Design.timelineWidth))
    let clampedMax = max(0, min(rawMax, Design.timelineWidth))
    let width = max(0, clampedMax - clampedMin)
    return (x: clampedMin, width: width)
  }
}

// MARK: - Preview

#Preview("Longest Focus Card") {
  // Create sample focus blocks for preview
  let calendar = Calendar.current
  let now = Date()
  let baseDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!

  let sampleBlocks: [FocusBlock] = [
    // Short block at 9:30 AM (15 min)
    FocusBlock(
      startTime: calendar.date(byAdding: .minute, value: 30, to: baseDate)!,
      endTime: calendar.date(byAdding: .minute, value: 45, to: baseDate)!
    ),
    // Longest block at 11:24 AM - 2:49 PM (3h 25m)
    FocusBlock(
      startTime: calendar.date(
        byAdding: .hour, value: 2, to: calendar.date(byAdding: .minute, value: 24, to: baseDate)!)!,
      endTime: calendar.date(
        byAdding: .hour, value: 5, to: calendar.date(byAdding: .minute, value: 49, to: baseDate)!)!
    ),
    // Medium block at 3:30 PM (45 min)
    FocusBlock(
      startTime: calendar.date(
        byAdding: .hour, value: 6, to: calendar.date(byAdding: .minute, value: 30, to: baseDate)!)!,
      endTime: calendar.date(
        byAdding: .hour, value: 7, to: calendar.date(byAdding: .minute, value: 15, to: baseDate)!)!
    ),
    // Short block at 4:30 PM (20 min)
    FocusBlock(
      startTime: calendar.date(
        byAdding: .hour, value: 7, to: calendar.date(byAdding: .minute, value: 30, to: baseDate)!)!,
      endTime: calendar.date(
        byAdding: .hour, value: 7, to: calendar.date(byAdding: .minute, value: 50, to: baseDate)!)!
    ),
  ]

  LongestFocusCard(focusBlocks: sampleBlocks)
    .frame(width: 322)
    .padding(20)
    .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}

#Preview("Empty State") {
  LongestFocusCard(focusBlocks: [])
    .frame(width: 322)
    .padding(20)
    .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}

#Preview("Single Block") {
  let calendar = Calendar.current
  let now = Date()
  let baseDate = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now)!

  let singleBlock: [FocusBlock] = [
    FocusBlock(
      startTime: baseDate,
      endTime: calendar.date(byAdding: .hour, value: 2, to: baseDate)!
    )
  ]

  LongestFocusCard(focusBlocks: singleBlock)
    .frame(width: 322)
    .padding(20)
    .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
