import AppKit
import Charts
import SwiftUI

struct WelcomePrompt {
  let icon: String
  let text: String
}

struct WelcomeSuggestionRow: View {
  let prompt: WelcomePrompt
  let action: () -> Void

  @State var isHovered = false
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: prompt.icon)
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(Color(hex: "C9670D"))
          .frame(width: 24, height: 24)
          .background(
            Circle()
              .fill(Color(hex: "FFF0E1"))
          )

        Text(prompt.text)
          .font(.custom("Nunito", size: 13).weight(.semibold))
          .foregroundColor(Color(hex: "5C432F"))
          .frame(maxWidth: .infinity, alignment: .leading)
          .multilineTextAlignment(.leading)
          .lineLimit(2)

        Image(systemName: "arrow.up.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundColor(Color(hex: "D58A3D"))
          .padding(.trailing, 2)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(isHovered ? Color.white.opacity(0.88) : Color.white.opacity(0.7))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color(hex: "EED7BF"), lineWidth: 1)
      )
      .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.01 : 1))
      .offset(y: reduceMotion ? 0 : (isHovered ? -1 : 0))
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering in
      guard !reduceMotion else {
        isHovered = false
        return
      }
      withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)) {
        isHovered = hovering
      }
    }
  }
}

// MARK: - Suggestion Chip

struct SuggestionChip: View {
  let text: String
  let action: () -> Void

  @State var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(text)
        .font(.custom("Nunito", size: 12).weight(.medium))
        .foregroundColor(Color(hex: "F96E00"))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(hex: "FFF4E9"))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color(hex: "F96E00").opacity(0.3), lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering in
      withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
        isHovered = hovering
      }
    }
  }
}
