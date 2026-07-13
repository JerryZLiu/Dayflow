import SwiftUI

struct CanvasActivityCardStyle {
  let text: Color
  let time: Color
  let accent: Color
  let isIdle: Bool
}

struct CanvasActivityCard: View {
  @AppStorage("showTimelineAppIcons") private var showTimelineAppIcons: Bool = true
  @State private var isHovering = false

  let title: String
  let time: String
  let height: CGFloat
  let durationMinutes: Double
  let style: CanvasActivityCardStyle
  let isSelected: Bool
  let isSystemCategory: Bool
  let isBackupGenerated: Bool
  /// "MiniMax M3 · MiniMax-M3" — small text shown in the card footer so the
  /// user always sees which provider/model produced this card. Optional
  /// because older saved cards don't carry the metadata.
  let providerBadge: String?
  let onTap: () -> Void
  // Raw values for pattern matching (may contain paths)
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  // Normalized hosts for network fetch
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
  let statusLine: String?
  let fontSize: CGFloat
  let fontWeight: TimelineCardTextWeight
  let iconLeadingInset: CGFloat
  let iconTextSpacing: CGFloat
  let faviconSize: CGFloat
  let faviconVerticalOffset: CGFloat
  let compactDurationThreshold: CGFloat
  let compactVerticalPadding: CGFloat
  let normalVerticalPadding: CGFloat
  let hoverScale: CGFloat
  let pressedScale: CGFloat

  private var isFailedCard: Bool {
    title == "Processing failed"
  }

  private var isCompactCard: Bool {
    durationMinutes < Double(compactDurationThreshold)
  }

  private var verticalPadding: CGFloat {
    guard !isFailedCard else { return 0 }
    return isCompactCard ? compactVerticalPadding : normalVerticalPadding
  }

  private var secondaryFontSize: CGFloat {
    TimelineTypography.cardSecondaryTextFontSize(for: fontSize)
  }

  private var backupIndicator: some View {
    Text("!")
      .font(Font.custom("Figtree", size: 9).weight(.semibold))
      .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
      .frame(width: 14, height: 14)
      .background(
        Circle()
          .fill(Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.9))
      )
      .overlay(
        Circle()
          .stroke(Color(red: 0.9, green: 0.9, blue: 0.9), lineWidth: 0.75)
      )
      .help(
        "This card fell back to a lower-quality Gemini model due to rate limiting, so output quality may be lower."
      )
  }

  private var selectionStroke: Color {
    if isSystemCategory {
      return Color(red: 1, green: 0.16, blue: 0.11)
    }
    return style.accent
  }

  var body: some View {
    Button(action: {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
        onTap()
      }
    }) {
      HStack(alignment: .top, spacing: isFailedCard ? 10 : iconTextSpacing) {
        if durationMinutes >= 10 {
          if isFailedCard {
            VStack(alignment: .leading, spacing: 4) {
              HStack(alignment: .top, spacing: 8) {
                Text(title)
                  .font(
                    Font.custom("Figtree", size: fontSize)
                      .weight(fontWeight.fontWeight)
                  )
                  .foregroundColor(style.text)

                Spacer()

                Text(time)
                  .font(
                    Font.custom("Figtree", size: secondaryFontSize)
                      .weight(.medium)
                  )
                  .foregroundColor(style.time)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }

              if let statusLine = statusLine {
                Text(statusLine)
                  .font(Font.custom("Figtree", size: secondaryFontSize))
                  .foregroundColor(Color(red: 0.55, green: 0.45, blue: 0.4))
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
            }
          } else {
            if showTimelineAppIcons && (faviconPrimaryRaw != nil || faviconSecondaryRaw != nil) {
              FaviconImageView(
                primaryRaw: faviconPrimaryRaw,
                secondaryRaw: faviconSecondaryRaw,
                primaryHost: faviconPrimaryHost,
                secondaryHost: faviconSecondaryHost,
                size: faviconSize
              )
              .offset(y: faviconVerticalOffset)
            }

            Text(title)
              .font(
                Font.custom("Figtree", size: fontSize)
                  .weight(fontWeight.fontWeight)
              )
              .foregroundColor(style.text)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
              HStack(spacing: 6) {
                if isBackupGenerated {
                  backupIndicator
                }
                Text(time)
                  .font(
                    Font.custom("Figtree", size: secondaryFontSize)
                      .weight(.medium)
                  )
                  .foregroundColor(style.time)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
              if let badge = providerBadge, !badge.isEmpty {
                Text(badge)
                  .font(.custom("Figtree", size: 9))
                  .foregroundColor(.secondary)
                  .lineLimit(1)
                  .truncationMode(.tail)
                  .help("This card was produced by \(badge)")
              }
            }
          }
        }
      }
      .padding(.leading, iconLeadingInset)
      .padding(.trailing, 10)
      .padding(.vertical, verticalPadding)
      .frame(
        maxWidth: .infinity,
        minHeight: height,
        maxHeight: height,
        alignment: isCompactCard ? .leading : .topLeading
      )
      .background(isFailedCard ? Color(hex: "FFECE4") : Color(hex: "FFFBF8"))
      .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .inset(by: 0.25)
          .stroke(
            isFailedCard ? Color(red: 1, green: 0.16, blue: 0.11) : Color(hex: "E8E8E8"),
            style: isFailedCard
              ? StrokeStyle(lineWidth: 0.5, dash: [2.5, 2.5]) : StrokeStyle(lineWidth: 0.25)
          )
      )
      .overlay(alignment: .leading) {
        if !isFailedCard {
          UnevenRoundedRectangle(
            topLeadingRadius: 2,
            bottomLeadingRadius: 2,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
          )
          .fill(style.accent)
          .frame(width: 6)
        }
      }
      // Selection halo for the active activity
      .overlay(
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .stroke(selectionStroke, lineWidth: 1.5)
          .opacity(isSelected ? 1 : 0)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .stroke(Color.black.opacity(isHovering ? 0.08 : 0), lineWidth: 1)
      )
      .shadow(
        color: .black.opacity(isHovering ? 0.08 : 0),
        radius: 1,
        x: 0,
        y: 1
      )
      .shadow(
        color: .black.opacity(isHovering ? 0.06 : 0),
        radius: 2,
        x: 0,
        y: 2
      )
    }
    .buttonStyle(CanvasCardButtonStyle(pressedScale: pressedScale))
    .pointingHandCursor()
    .hoverScaleEffect(scale: hoverScale)
    .onHover { hovering in
      isHovering = hovering
    }
    .animation(.easeOut(duration: 0.18), value: isHovering)
    .padding(.horizontal, 6)
  }
}

struct CanvasCardButtonStyle: ButtonStyle {
  var pressedScale: CGFloat = TimelineCardLayout.pressedScale

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .dayflowPressScale(
        configuration.isPressed,
        pressedScale: pressedScale,
        animation: .spring(response: 0.3, dampingFraction: 0.6)
      )
  }
}
