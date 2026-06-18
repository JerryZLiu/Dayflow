import SwiftUI

struct GoalReviewCard: View {
  let kind: DayGoalCategoryKind
  let title: String
  let subtitle: String
  let targetDuration: TimeInterval
  let actualDuration: TimeInterval
  let categories: [DayGoalCategoryResult]

  private var accent: Color {
    kind == .focus ? Color(hex: "628CFF") : Color(hex: "FA8282")
  }

  private var iconName: String {
    kind == .focus ? "DayGoalFocus" : "DayGoalDistraction"
  }

  private var succeeded: Bool {
    switch kind {
    case .focus:
      return actualDuration >= targetDuration
    case .distraction:
      return actualDuration <= targetDuration
    }
  }

  private var progressRatio: Double {
    guard targetDuration > 0 else { return 0 }
    return min(max(actualDuration / targetDuration, 0), 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
          Text(subtitle)
        }
        .font(.custom("Figtree", size: 15))
        .foregroundColor(.black)

        Spacer()

        resultBadge
      }

      HStack(spacing: 8) {
        if kind == .focus {
          GoalIconBubble(kind: kind)
        }

        GeometryReader { geometry in
          ZStack(alignment: kind == .focus ? .leading : .trailing) {
            RoundedRectangle(cornerRadius: 4)
              .fill(Color(hex: "E4E4E4"))

            RoundedRectangle(cornerRadius: 6)
              .fill(accent)
              .frame(width: barWidth(availableWidth: geometry.size.width), height: 8)
          }
        }
        .frame(height: 14)

        if kind == .distraction {
          GoalIconBubble(kind: kind)
        }
      }

      if kind == .focus {
        GoalCategoryBreakdown(categories: categories)
          .frame(height: 92)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, kind == .focus ? 18 : 18)
    .frame(width: 388, height: kind == .focus ? 236 : 123, alignment: .topLeading)
    .background(Color.white.opacity(0.8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(kind == .focus ? Color(hex: "CEDBFF") : Color(hex: "FFCDCD"), lineWidth: 1)
    )
    .shadow(
      color: (kind == .focus ? Color(hex: "8BAAFF") : Color(hex: "FA8282")).opacity(0.75),
      radius: 10
    )
  }

  private var resultBadge: some View {
    Text(succeeded ? "NAILED IT" : "MISSED")
      .font(.custom("Figtree", size: 10).weight(.heavy))
      .foregroundColor(succeeded ? Color(hex: "4AB43F") : Color(hex: "FA8282"))
      .padding(.horizontal, 15)
      .frame(height: 30)
      .background(succeeded ? Color(hex: "F1FFE3") : Color(hex: "FFF0F0"))
      .clipShape(Capsule())
      .overlay(Capsule().stroke(Color.white, lineWidth: 0.5))
      .rotationEffect(.degrees(7.5))
  }

  private func barWidth(availableWidth: CGFloat) -> CGFloat {
    let width = availableWidth * progressRatio
    if kind == .distraction {
      return max(0, width)
    }
    return max(0, width)
  }
}

private struct GoalCategoryBreakdown: View {
  let categories: [DayGoalCategoryResult]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if categories.isEmpty {
        Text("No focus categories tracked")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(Color(hex: "777777"))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        ForEach(categories.prefix(4)) { category in
          HStack(spacing: 9) {
            Text(category.name)
              .font(.custom("Figtree", size: 12))
              .foregroundColor(Color(hex: "333333"))
              .lineLimit(1)
              .frame(width: 74, alignment: .leading)

            RoundedRectangle(cornerRadius: 6)
              .fill(category.color)
              .frame(width: barWidth(for: category), height: 6)

            Text(formatDuration(category.duration))
              .font(.custom("Figtree", size: 8))
              .foregroundColor(.black)
              .lineLimit(1)

            Spacer(minLength: 0)
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .background(Color(hex: "F4F4F4"))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  private func barWidth(for category: DayGoalCategoryResult) -> CGFloat {
    guard let maxDuration = categories.map(\.duration).max(), maxDuration > 0 else { return 0 }
    return max(18, CGFloat(category.duration / maxDuration) * 86)
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    let totalMinutes = Int(duration / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 && minutes > 0 {
      return "\(hours)h \(minutes)m"
    }
    if hours > 0 {
      return "\(hours)h"
    }
    return "\(minutes)m"
  }
}

private struct GoalIconBubble: View {
  let kind: DayGoalCategoryKind

  var body: some View {
    ZStack {
      Circle()
        .fill(Color(hex: "E4E4E4"))
        .overlay(Circle().stroke(accent, lineWidth: 1))

      Image(kind == .focus ? "DayGoalFocus" : "DayGoalDistraction")
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
    }
    .frame(width: 36, height: 36)
  }

  private var accent: Color {
    kind == .focus ? Color(hex: "8BAAFF") : Color(hex: "FA8282")
  }
}
