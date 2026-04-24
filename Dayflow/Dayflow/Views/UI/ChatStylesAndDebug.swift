import AppKit
import Charts
import SwiftUI

// MARK: - Beta Button Style (hover + press animations)

struct PressScaleButtonStyle: ButtonStyle {
  let isEnabled: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .dayflowPressScale(
        configuration.isPressed,
        enabled: isEnabled,
        pressedScale: 0.97,
        animation: .easeOut(duration: 0.15)
      )
      .pointingHandCursor(enabled: isEnabled)
  }
}

struct BetaButtonStyle: ButtonStyle {
  let isEnabled: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .dayflowPressScale(
        configuration.isPressed,
        enabled: isEnabled,
        pressedScale: 0.97,
        animation: .easeOut(duration: 0.15)
      )
      .pointingHandCursor(enabled: isEnabled)
  }
}

struct ProviderTogglePill: View {
  let title: String
  let isSelected: Bool
  let isEnabled: Bool
  let action: () -> Void

  var backgroundColor: Color {
    if !isEnabled { return Color(hex: "F2F2F2") }
    return isSelected ? Color(hex: "FFF4E9") : Color.white
  }

  var borderColor: Color {
    if !isEnabled { return Color(hex: "E0E0E0") }
    return isSelected ? Color(hex: "F96E00").opacity(0.25) : Color(hex: "E0E0E0")
  }

  var textColor: Color {
    if !isEnabled { return Color(hex: "B0B0B0") }
    return isSelected ? Color(hex: "F96E00") : Color(hex: "666666")
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Nunito", size: 12).weight(.semibold))
        .foregroundColor(textColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(backgroundColor)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .pointingHandCursor(enabled: isEnabled)
  }
}

// MARK: - Debug Log Entry

struct DebugLogEntry: View {
  let entry: ChatDebugEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Header with type and timestamp
      HStack(spacing: 6) {
        Text(entry.type.rawValue)
          .font(.custom("Nunito", size: 10).weight(.bold))
          .foregroundColor(Color(hex: entry.typeColor))

        Spacer()

        Text(formatTimestamp(entry.timestamp))
          .font(.custom("Nunito", size: 9))
          .foregroundColor(Color(hex: "AAAAAA"))
      }

      // Content (scrollable if long)
      ScrollView(.horizontal, showsIndicators: false) {
        Text(entry.content)
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(Color(hex: "333333"))
          .textSelection(.enabled)
      }
      .frame(maxHeight: 150)
    }
    .padding(8)
    .background(Color(hex: "FAFAFA"))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color(hex: entry.typeColor).opacity(0.3), lineWidth: 1)
    )
  }

  func formatTimestamp(_ date: Date) -> String {
    chatViewDebugTimestampFormatter.string(from: date)
  }
}

// MARK: - Flow Layout

struct ChatFlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maxRowWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
        totalHeight += rowHeight + spacing
        maxRowWidth = max(maxRowWidth, rowWidth)
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
        rowHeight = max(rowHeight, size.height)
      }
    }
    maxRowWidth = max(maxRowWidth, rowWidth)
    totalHeight += rowHeight
    return CGSize(width: maxRowWidth, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var origin = CGPoint(x: bounds.minX, y: bounds.minY)
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: origin, proposal: ProposedViewSize(size))
      origin.x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

// MARK: - Thinking Indicator

struct ThinkingIndicator: View {
  @State var dotScale: [CGFloat] = [1, 1, 1]

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "sparkles")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(Color(hex: "F96E00"))

      Text("Thinking")
        .font(.custom("Nunito", size: 12).weight(.semibold))
        .foregroundColor(Color(hex: "8B5E3C"))

      HStack(spacing: 3) {
        ForEach(0..<3, id: \.self) { index in
          Circle()
            .fill(Color(hex: "F96E00"))
            .frame(width: 4, height: 4)
            .scaleEffect(dotScale[index])
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      LinearGradient(
        colors: [Color(hex: "FFF4E9"), Color(hex: "FFECD8")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color(hex: "F96E00").opacity(0.2), lineWidth: 1)
    )
    .onAppear {
      startAnimation()
    }
  }

  func startAnimation() {
    // Staggered bouncing dots animation
    for i in 0..<3 {
      withAnimation(
        .easeInOut(duration: 0.4)
          .repeatForever(autoreverses: true)
          .delay(Double(i) * 0.15)
      ) {
        dotScale[i] = 1.4
      }
    }
  }
}
