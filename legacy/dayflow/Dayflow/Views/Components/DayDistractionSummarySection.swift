//
//  DayDistractionSummarySection.swift
//  Dayflow
//
//  Distraction section for the Day Summary right rail.
//

import SwiftUI

struct DayDistractionSummarySection: View {
  @Environment(\.dayflowTheme) private var theme

  let totalCapturedText: String
  let totalDistractedText: String
  let distractedRatio: Double
  let patternTitle: String
  let patternDescription: String
  let isSelectionEmpty: Bool
  let categories: [TimelineCategory]
  let selectedCategoryIDs: Set<UUID>
  let isEditingCategories: Bool
  var onEditCategories: () -> Void
  var onToggleCategory: (TimelineCategory) -> Void
  var onDoneEditing: () -> Void

  private enum Design {
    static let sectionSpacing: CGFloat = 16
    static let editButtonSize: CGFloat = 20
    static let editorWidth: CGFloat = 358
    static let editorOffsetX: CGFloat = -18
    static let editorOffsetY: CGFloat = 28
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.sectionSpacing) {
      header

      if isSelectionEmpty {
        Text("Edit categories to calculate distractions.")
          .font(.custom("Figtree", size: 11))
          .foregroundColor(theme.textSecondary)
      }

      DistractionSummaryCard(
        totalCaptured: totalCapturedText,
        totalDistracted: totalDistractedText,
        distractedRatio: distractedRatio,
        patternTitle: patternTitle,
        patternDescription: patternDescription
      )
      .frame(maxWidth: .infinity)
      .opacity(isSelectionEmpty ? 0.45 : 1)
    }
    .overlay(alignment: .topLeading) {
      if isEditingCategories {
        DayCategorySelectionEditor(
          categories: categories,
          selectedCategoryIDs: selectedCategoryIDs,
          helperText: "Pick the categories that count towards Distractions",
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
      Text("Distractions so far")
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundColor(theme.textPrimary)

      Spacer()

      CategoryEditCircleButton(
        action: onEditCategories,
        diameter: Design.editButtonSize
      )
    }
  }
}
