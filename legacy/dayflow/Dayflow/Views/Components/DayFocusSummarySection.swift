//
//  DayFocusSummarySection.swift
//  Dayflow
//
//  Focus section for the Day Summary right rail.
//

import SwiftUI

struct DayFocusSummarySection: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  let totalFocusText: String
  let focusBlocks: [FocusBlock]
  let isSelectionEmpty: Bool
  let categories: [TimelineCategory]
  let selectedCategoryIDs: Set<UUID>
  let isEditingCategories: Bool
  var onEditCategories: () -> Void
  var onToggleCategory: (TimelineCategory) -> Void
  var onDoneEditing: () -> Void

  private enum Design {
    static let sectionSpacing: CGFloat = 12
    static let cardsSpacing: CGFloat = 8
    static let editButtonSize: CGFloat = 20
    static let editorWidth: CGFloat = 358
    static let editorOffsetX: CGFloat = -18
    static let editorOffsetY: CGFloat = 28
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.sectionSpacing) {
      header

      if isSelectionEmpty {
        Text("Edit categories to calculate focus.")
          .font(.custom("Figtree", size: 11))
          .foregroundColor(theme.textSecondary)
      }

      VStack(spacing: Design.cardsSpacing) {
        TotalFocusCard(value: totalFocusText)

        LongestFocusCard(focusBlocks: focusBlocks)
      }
      .opacity(isSelectionEmpty ? 0.45 : 1)
    }
    .overlay(alignment: .topLeading) {
      if isEditingCategories {
        DayCategorySelectionEditor(
          categories: categories,
          selectedCategoryIDs: selectedCategoryIDs,
          helperText: "Pick the categories that count towards Focus",
          onToggle: onToggleCategory,
          onDone: onDoneEditing
        )
        .frame(width: Design.editorWidth, alignment: .leading)
        .offset(x: Design.editorOffsetX, y: Design.editorOffsetY)
        .onTapGesture {}
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 6) {
      Text("Your focus")
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundColor(theme.textPrimary)

      if !stylePreviewAfter {
        Image(systemName: "info.circle")
          .font(.system(size: 12))
          .foregroundColor(theme.textMuted)
      }

      Spacer()

      CategoryEditCircleButton(
        action: onEditCategories,
        diameter: Design.editButtonSize
      )
    }
  }
}

private struct TotalFocusCard: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("Total focus time")
          .font(.custom("InstrumentSerif-Regular", size: 16))
          .foregroundColor(theme.textPrimary)

        if !stylePreviewAfter {
          Image(systemName: "info.circle")
            .font(.system(size: 12))
            .foregroundColor(theme.textMuted)
        }

        Spacer()
      }

      Text(value)
        .font(.custom("InstrumentSerif-Regular", size: 34))
        .foregroundColor(theme.summaryValue)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .daySummaryCard()
  }
}

// Figma summary card: translucent fill, hairline border, soft inner glow
// (dark) or a faint drop shadow (light). Shared by the focus cards.
struct DaySummaryCardModifier: ViewModifier {
  @Environment(\.dayflowTheme) private var theme

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    content
      .background(theme.summaryCardFill)
      .clipShape(shape)
      .overlay(
        InnerGlow(
          shape: shape,
          color: theme.summaryCardInnerGlow,
          radius: 3,
          spread: 3,
          blur: 2.5
        )
      )
      .overlay(shape.strokeBorder(theme.summaryCardBorder, lineWidth: 0.5))
      .shadow(color: theme.summaryCardShadow, radius: 4, x: 0, y: 1)
  }
}

extension View {
  func daySummaryCard() -> some View {
    modifier(DaySummaryCardModifier())
  }
}
