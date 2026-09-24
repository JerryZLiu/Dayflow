import SwiftUI

/// Normalizes a category name so chips and timeline cards match regardless of
/// case or stray whitespace.
func categoryFilterKey(_ name: String) -> String {
  name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

struct TabFilterBar: View {
  let categories: [TimelineCategory]
  let idleCategory: TimelineCategory?
  @Binding var mutedCategoryKeys: Set<String>
  let onManageCategories: () -> Void

  @Environment(\.dayflowTheme) private var theme
  @State private var chipRowWidth: CGFloat = 0

  private let editButtonSize: CGFloat = 24
  private let chipButtonSpacing: CGFloat = 8
  private let chipRowHeight: CGFloat = 26

  var body: some View {
    GeometryReader { geometry in
      let availableWidth = max(0, geometry.size.width)
      let maxChipRowWidth = max(0, availableWidth - editButtonSize - chipButtonSpacing)
      let hasMeasuredChipRow = chipRowWidth > 0
      let isOverflowing = hasMeasuredChipRow && chipRowWidth > maxChipRowWidth
      let chipRowFrameWidth =
        hasMeasuredChipRow
        ? min(chipRowWidth, maxChipRowWidth)
        : maxChipRowWidth

      ZStack(alignment: .topLeading) {
        HStack(spacing: chipButtonSpacing) {
          visibleChipRow(width: chipRowFrameWidth)
          editButton
        }
        .frame(width: availableWidth, height: editButtonSize, alignment: .leading)
        .overlay(alignment: .trailing) {
          if isOverflowing {
            overflowGradient
              .padding(.trailing, editButtonSize + chipButtonSpacing)
          }
        }

        measuredChipRow
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .frame(width: availableWidth, height: editButtonSize, alignment: .leading)
    }
    .frame(height: editButtonSize)
    .onPreferenceChange(ChipRowWidthPreferenceKey.self) { chipRowWidth = $0 }
  }

  struct CategoryChip: View {
    @Environment(\.dayflowTheme) private var theme

    let category: TimelineCategory
    let isIdle: Bool
    let isMuted: Bool
    let onTap: () -> Void

    var body: some View {
      Button(action: onTap) {
        chipLabel
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .opacity(isMuted ? 0.4 : 1)
      .animation(.easeOut(duration: 0.15), value: isMuted)
    }

    private var chipLabel: some View {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(hex: category.colorHex))
          .frame(width: 10, height: 10)

        Text(category.name)
          .font(Font.custom("Figtree", size: 13).weight(.medium))
          .foregroundColor(theme.chipText)
          .lineLimit(1)
          .fixedSize()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(height: 26)
      .background(theme.chipFill)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(theme.chipBorder, lineWidth: 0.5)
      )
    }
  }

  private func visibleChipRow(width: CGFloat) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      chipRowContent
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: chipRowHeight)
    }
    .frame(width: max(0, width), height: chipRowHeight, alignment: .leading)
    .clipped()
  }

  private var measuredChipRow: some View {
    chipRowContent
      .fixedSize(horizontal: true, vertical: false)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: ChipRowWidthPreferenceKey.self, value: proxy.size.width)
        }
      )
  }

  private var chipRowContent: some View {
    HStack(spacing: 5) {
      ForEach(categories) { category in
        chip(for: category, isIdle: false)
      }

      if let idleCategory {
        chip(for: idleCategory, isIdle: true)
      }
    }
    .padding(.leading, 2)
  }

  private func chip(for category: TimelineCategory, isIdle: Bool) -> some View {
    let key = categoryFilterKey(category.name)
    return CategoryChip(
      category: category,
      isIdle: isIdle,
      isMuted: mutedCategoryKeys.contains(key),
      onTap: { toggleMuted(key) }
    )
  }

  private func toggleMuted(_ key: String) {
    if mutedCategoryKeys.contains(key) {
      mutedCategoryKeys.remove(key)
    } else {
      mutedCategoryKeys.insert(key)
    }
  }

  private var editButton: some View {
    CategoryEditCircleButton(
      action: onManageCategories,
      diameter: editButtonSize
    )
  }

  private var overflowGradient: some View {
    LinearGradient(
      gradient: Gradient(colors: [Color.clear, theme.panelSolid]),
      startPoint: .leading,
      endPoint: .trailing
    )
    .frame(width: 40)
    .allowsHitTesting(false)
  }

  private struct ChipRowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      value = nextValue()
    }
  }
}
