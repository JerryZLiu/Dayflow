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
  @Environment(\.dayflowTheme) private var theme

  let title: String
  let isSelected: Bool
  let isEnabled: Bool
  let action: () -> Void

  var backgroundColor: Color {
    if !isEnabled { return Color.clear }
    return isSelected ? theme.chatSoftAccentFill : theme.inputFill
  }

  var borderColor: Color {
    if !isEnabled { return theme.inputBorder }
    return isSelected ? theme.chatSoftAccentBorder : theme.inputBorder
  }

  var textColor: Color {
    if !isEnabled { return theme.textMuted }
    return isSelected ? theme.accentText : theme.textSecondary
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Figtree", size: 12).weight(.semibold))
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
  @Environment(\.dayflowTheme) private var theme

  let entry: ChatDebugEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Header with type and timestamp
      HStack(spacing: 6) {
        Text(entry.type.rawValue)
          .font(.custom("Figtree", size: 10).weight(.bold))
          .foregroundColor(Color(hex: entry.typeColor))

        Spacer()

        Text(formatTimestamp(entry.timestamp))
          .font(.custom("Figtree", size: 9))
          .foregroundColor(theme.textMuted)
      }

      // Content (scrollable if long)
      ScrollView(.horizontal, showsIndicators: false) {
        Text(entry.content)
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(theme.textPrimary)
          .textSelection(.enabled)
      }
      .frame(maxHeight: 150)
    }
    .padding(8)
    .background(theme.chatCodeFill)
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
  @Environment(\.dayflowTheme) private var theme

  @State var dotScale: [CGFloat] = [1, 1, 1]

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "sparkles")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(theme.accentText)

      Text("Thinking")
        .font(.custom("Figtree", size: 12).weight(.semibold))
        .foregroundColor(theme.textSecondary)

      HStack(spacing: 3) {
        ForEach(0..<3, id: \.self) { index in
          Circle()
            .fill(theme.accentText)
            .frame(width: 4, height: 4)
            .scaleEffect(dotScale[index])
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(theme.chatSoftAccentFill)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(theme.chatSoftAccentBorder, lineWidth: 1)
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
