//
//  DistractionSummaryCard.swift
//  Dayflow
//
//  Summary block showing captured vs distracted time and a distraction pattern note
//

import SwiftUI

struct DistractionSummaryCard: View {
  let totalCaptured: String
  let totalDistracted: String
  let distractedRatio: Double
  let patternTitle: String
  let patternDescription: String

  init(
    totalCaptured: String,
    totalDistracted: String,
    distractedRatio: Double,
    patternTitle: String = "Main distraction pattern",
    patternDescription: String
  ) {
    self.totalCaptured = totalCaptured
    self.totalDistracted = totalDistracted
    self.distractedRatio = distractedRatio
    self.patternTitle = patternTitle
    self.patternDescription = patternDescription
  }

  private enum Design {
    static let contentWidth: CGFloat = 293
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 27
    static let statsSpacing: CGFloat = 24
    static let statsWidth: CGFloat = 130

    static let donutSize: CGFloat = 136
    static let donutInnerMaxSize: CGFloat = 136
    static let donutInnerBottomInset: CGFloat = 4.868

    static let donutFill = Color(hex: "F0F0F0").opacity(0.8)
    static let donutStroke = Color(hex: "DDDDDD")
    static let donutGradientStart = Color(hex: "FFE3DE")
    static let donutGradientEnd = Color(hex: "FF694B")

    static let capturedTextColor = Color(hex: "9C9C9C")
    static let distractedTextColor = Color(hex: "FF694B")
    static let bodyTextColor = Color(hex: "333333")

    static let labelFont = Font.custom("InstrumentSerif-Regular", size: 14)
    static let valueFont = Font.custom("InstrumentSerif-Regular", size: 20)
    static let patternTitleFont = Font.custom("Nunito", size: 12).weight(.bold)
    static let patternBodyFont = Font.custom("Nunito", size: 12)
  }

  var body: some View {
    let showPattern = !patternDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    VStack(alignment: .center, spacing: showPattern ? Design.sectionSpacing : 0) {
      HStack(alignment: .center, spacing: Design.rowSpacing) {
        donut
        statsBlock
      }

      if showPattern {
        patternBlock
      }
    }
    .frame(width: Design.contentWidth, alignment: .center)
  }

  private var donut: some View {
    let clampedRatio = min(max(distractedRatio, 0), 1)
    let innerDiameter = Design.donutInnerMaxSize * sqrt(clampedRatio)
    let innerX = (Design.donutSize - innerDiameter) / 2
    let innerY = Design.donutSize - Design.donutInnerBottomInset - innerDiameter

    return ZStack(alignment: .topLeading) {
      Circle()
        .fill(Design.donutFill)
        .overlay(
          Circle()
            .stroke(Design.donutStroke, lineWidth: 1)
        )
        .frame(width: Design.donutSize, height: Design.donutSize)

      if innerDiameter > 0.5 {
        Circle()
          .fill(
            LinearGradient(
              stops: [
                .init(color: Design.donutGradientStart, location: 0),
                .init(color: Design.donutGradientEnd, location: 0.78306),
                .init(color: Design.donutGradientEnd, location: 1),
              ],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: innerDiameter, height: innerDiameter)
          .rotationEffect(.degrees(90))
          .offset(x: innerX, y: innerY)
      }
    }
    .frame(width: Design.donutSize, height: Design.donutSize)
  }

  private var statsBlock: some View {
    VStack(alignment: .leading, spacing: Design.statsSpacing) {
      statText(
        title: "Total time captured",
        value: totalCaptured,
        color: Design.capturedTextColor
      )

      statText(
        title: "Total time distracted",
        value: totalDistracted,
        color: Design.distractedTextColor
      )
    }
    .frame(width: Design.statsWidth, alignment: .leading)
  }

  private func statText(title: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(Design.labelFont)
        .foregroundColor(color)
      Text(value)
        .font(Design.valueFont)
        .foregroundColor(color)
    }
    .lineSpacing(2)
  }

  private var patternBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 2) {
        Image("DistractionSummaryIcon")
          .resizable()
          .frame(width: 16, height: 16)

        Text(patternTitle)
          .font(Design.patternTitleFont)
          .foregroundColor(Design.bodyTextColor)
      }

      Text(patternDescription)
        .font(Design.patternBodyFont)
        .foregroundColor(Design.bodyTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: Design.contentWidth, alignment: .leading)
  }
}

#Preview("Distraction Summary Card") {
  DistractionSummaryCard(
    totalCaptured: "8 hours 49 minutes",
    totalDistracted: "2 hours 7 minutes",
    distractedRatio: 0.24,
    patternDescription:
      "YouTube recommendations pull attention from one video to the next for extended periods."
  )
  .padding(24)
  .background(Color.white)
}
