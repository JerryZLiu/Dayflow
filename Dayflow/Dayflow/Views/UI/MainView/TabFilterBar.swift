import SwiftUI

struct TabFilterBar: View {
  let categories: [TimelineCategory]
  let idleCategory: TimelineCategory?
  let onManageCategories: () -> Void

  @State private var chipRowWidth: CGFloat = 0

  private let editButtonSize: CGFloat = 24
  private let chipButtonSpacing: CGFloat = 8

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
    let category: TimelineCategory
    let isIdle: Bool

    var body: some View {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(hex: category.colorHex))
          .frame(width: 10, height: 10)

        Text(category.name)
          .font(
            Font.custom("Figtree", size: 13)
              .weight(.medium)
          )
          .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
          .lineLimit(1)
          .fixedSize()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(height: 26)
      .background(.white.opacity(0.76))
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .inset(by: 0.25)
          .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 0.5)
      )
    }
  }

  private func visibleChipRow(width: CGFloat) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      chipRowContent
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 26)
    }
    .frame(width: max(0, width), height: 26, alignment: .leading)
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
        CategoryChip(category: category, isIdle: false)
      }

      if let idleCategory {
        CategoryChip(category: idleCategory, isIdle: true)
      }
    }
    .padding(.leading, 2)
  }

  private var editButton: some View {
    CategoryEditCircleButton(
      action: onManageCategories,
      diameter: editButtonSize
    )
  }

  private var overflowGradient: some View {
    LinearGradient(
      gradient: Gradient(colors: [Color.clear, Color(hex: "FFF8F1")]),
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
