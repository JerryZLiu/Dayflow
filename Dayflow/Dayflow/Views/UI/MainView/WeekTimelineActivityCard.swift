import SwiftUI

// Published by each card's hidden measurement view; collected by the parent grid.
struct CardExpandedHeightPreferenceKey: PreferenceKey {
  static var defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct WeekTimelineCardPalette {
  let accent: Color
  let fill: Color
  let border: Color
  let title: Color
}

struct WeekTimelineActivityCard: View {
  let cardId: String
  let title: String
  let hoverTimeLabel: String
  let height: CGFloat
  // Parent-computed: equals `height` normally, or the measured natural height when hovered.
  let effectiveHeight: CGFloat
  let durationMinutes: Double
  let palette: WeekTimelineCardPalette
  let isSelected: Bool
  // Parent-driven (debounced via hover-intent at the parent).
  let isHovered: Bool
  let showTimelineAppIcons: Bool
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
  let statusLine: String?
  let failureCount: Int
  let isRetryActive: Bool
  let onHoverChanged: (Bool) -> Void
  let onTap: () -> Void

  private var isCompact: Bool {
    durationMinutes < 24 || height < 40
  }

  // Mirrors the Day view's detection (`title == "Processing failed"`) so
  // both views flip to the failed-card styling together. Intentionally
  // title-based rather than category-based to stay in lockstep with the
  // Day view — if the failed-card format ever changes, both stay synced
  // as long as the title string stays canonical.
  private var isFailedCard: Bool {
    title == "Processing failed"
  }

  private var displayTitle: String {
    guard isFailedCard, failureCount > 1 else { return title }
    return "\(title) · \(failureCount) intervals"
  }

  // Title font size is a single constant across every card in the grid — no
  // compact/long split, no hover switch — so text never changes size for any
  // reason. The hover interaction handles "too small to read" by revealing
  // more lines, not by shrinking the font.
  private var titleFontSize: CGFloat { 10 }

  // Vertical padding still varies by card size (compact cards need a tighter
  // fit at rest), but it's stable across hover states so the first line's Y
  // position doesn't shift when the card expands.
  private var verticalPadding: CGFloat {
    isCompact ? 2 : 4
  }

  private var showsRetryStatus: Bool {
    isFailedCard && statusLine != nil
  }

  // Max lines the title can wrap to *at rest* (not hovered) — bounded by
  // how much vertical space the card actually has. Previously we binary-
  // gated on `isCompact` and forced 1 line for any "short-duration" card,
  // which truncated titles even when 2+ lines would clearly fit. Here we
  // derive the line count from the real text-area height: card height
  // minus both vertical paddings, divided by Figtree 10's line-height
  // (~12pt). `max(1, …)` guarantees at least one line for the smallest
  // cards.
  private var maxUnhoveredTitleLines: Int {
    let reservedStatusHeight: CGFloat = showsRetryStatus ? 14 : 0
    let available = height - 2 * verticalPadding - reservedStatusHeight
    let perLine: CGFloat = 12
    return max(1, Int(available / perLine))
  }

  private var hasFavicon: Bool {
    showTimelineAppIcons && (faviconPrimaryRaw != nil || faviconSecondaryRaw != nil)
  }

  var body: some View {
    Button(action: {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
        onTap()
      }
    }) {
      cardCanvas(renderingExpanded: isHovered)
        .frame(
          maxWidth: .infinity,
          minHeight: effectiveHeight,
          maxHeight: effectiveHeight,
          alignment: .topLeading
        )
    }
    .buttonStyle(CanvasCardButtonStyle())
    .pointingHandCursor()
    .hoverScaleEffect(scale: 1.01)
    .zIndex(isHovered ? 10 : (isSelected ? 2 : 0))
    .onHover { hovering in
      onHoverChanged(hovering)
    }
    // Hidden natural-height measurement published to parent via preference.
    .background(alignment: .topLeading) {
      expandedHeightMeasurement
    }
  }

  // Shared visual canvas — identical layout whether compact or hovered, so no
  // existing text shifts when the card expands. Only the line limit changes:
  // compact clamps to 1 line with tail truncation; hovered unlocks the wrap.
  @ViewBuilder
  private func cardCanvas(renderingExpanded: Bool) -> some View {
    HStack(alignment: .top, spacing: 4) {
      if hasFavicon {
        FaviconImageView(
          primaryRaw: faviconPrimaryRaw,
          secondaryRaw: faviconSecondaryRaw,
          primaryHost: faviconPrimaryHost,
          secondaryHost: faviconSecondaryHost,
          size: 12
        )
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(displayTitle)
          .font(.custom("Figtree", size: titleFontSize).weight(.semibold))
          .foregroundColor(palette.title)
          .multilineTextAlignment(.leading)
          .lineLimit(renderingExpanded ? nil : maxUnhoveredTitleLines)
          .truncationMode(.tail)

        if let statusLine, isFailedCard {
          retryStatusRow(statusLine: statusLine, renderingExpanded: renderingExpanded)
        }

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      Spacer(minLength: 0)
    }
    .padding(.leading, 9)
    .padding(.trailing, 6)
    .padding(.vertical, verticalPadding)
    // Failed-card styling (matches Day view): peach background, red dashed
    // stroke, and no left accent bar. Kept as three inline branches rather
    // than a dedicated Modifier so it's obvious at read-time what's
    // special-cased.
    .background(isFailedCard ? Color(hex: "FFECE4") : palette.fill)
    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .stroke(
          isFailedCard
            ? Color(red: 1, green: 0.16, blue: 0.11)
            : (isSelected ? palette.accent : palette.border),
          style: isFailedCard
            ? StrokeStyle(lineWidth: 0.5, dash: [2.5, 2.5])
            : StrokeStyle(lineWidth: isSelected ? 1 : 0.5)
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
        .fill(palette.accent)
        .frame(width: 5)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .stroke(Color.black.opacity(isHovered ? 0.10 : 0), lineWidth: 1)
    )
    // Shadow deepens when hovered — the "card lifts toward you" cue. Opacity
    // halved (0.12→0.06, 0.10→0.05) so the lift reads as a subtle cue rather
    // than a prominent drop-shadow. Radius and offsets kept so the shadow's
    // spread/direction is unchanged; only intensity drops.
    .shadow(
      color: .black.opacity(isHovered ? 0.06 : 0),
      radius: isHovered ? 4 : 1,
      x: 0,
      y: isHovered ? 2 : 1
    )
    .shadow(
      color: .black.opacity(isHovered ? 0.05 : 0),
      radius: isHovered ? 8 : 2,
      x: 0,
      y: isHovered ? 4 : 2
    )
  }

  // Hidden measurement of the expanded card's natural height. Structurally
  // identical to `cardCanvas(renderingExpanded: true)` so the measured height
  // matches the actual rendered height exactly — no font, no padding, no
  // component differences, otherwise the two disagree and text gets clipped.
  @ViewBuilder
  private var expandedHeightMeasurement: some View {
    HStack(alignment: .top, spacing: 4) {
      if hasFavicon {
        Color.clear.frame(width: 12, height: 12)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(displayTitle)
          .font(.custom("Figtree", size: titleFontSize).weight(.semibold))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)

        if let statusLine, isFailedCard {
          retryStatusRow(statusLine: statusLine, renderingExpanded: true)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.leading, 9)
    .padding(.trailing, 6)
    .padding(.vertical, verticalPadding)
    .fixedSize(horizontal: false, vertical: true)
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: CardExpandedHeightPreferenceKey.self,
          value: [cardId: proxy.size.height]
        )
      }
    )
    .hidden()
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func retryStatusRow(statusLine: String, renderingExpanded: Bool) -> some View {
    HStack(alignment: .center, spacing: 4) {
      if isRetryActive {
        ProgressView()
          .controlSize(.mini)
          .scaleEffect(0.5)
          .frame(width: 8, height: 8)
      }

      Text(statusLine)
        .font(.custom("Figtree", size: 9))
        .foregroundColor(Color(hex: "7A6254"))
        .lineLimit(renderingExpanded ? nil : 1)
        .truncationMode(.tail)
    }
  }
}
