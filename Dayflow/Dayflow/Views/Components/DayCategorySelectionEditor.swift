//
//  DayCategorySelectionEditor.swift
//  Dayflow
//
//  Compact category chooser used by the Day Summary right rail.
//

import SwiftUI

struct DayCategorySelectionEditor: View {
  @Environment(\.dayflowTheme) private var theme

  let categories: [TimelineCategory]
  let selectedCategoryIDs: Set<UUID>
  let helperText: String
  var onToggle: (TimelineCategory) -> Void
  var onDone: () -> Void

  private enum Design {
    static let pillSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 10
    static let helperTextSize: CGFloat = 11
    static let cornerRadius: CGFloat = 6
  }

  var body: some View {
    VStack(spacing: 12) {
      DayCategoryFlowLayout(spacing: Design.pillSpacing, rowSpacing: Design.rowSpacing) {
        ForEach(categories) { category in
          CategoryPill(
            category: category,
            isSelected: selectedCategoryIDs.contains(category.id)
          ) {
            onToggle(category)
          }
        }
      }
      .padding(.trailing, 32)
      .frame(maxWidth: .infinity, alignment: .leading)

      Rectangle()
        .fill(theme.rightPanelDivider)
        .frame(height: 1)

      helperRow
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, Design.horizontalPadding)
    .padding(.vertical, Design.verticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundView)
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius)
        .stroke(theme.popoverBorder, lineWidth: 1)
    )
    .overlay(alignment: .topTrailing) {
      Button(action: onDone) {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(theme.textPrimary)
          .frame(width: 26, height: 26)
          .background(theme.chipFill)
          .clipShape(
            UnevenRoundedRectangle(
              cornerRadii: .init(
                topLeading: 0,
                bottomLeading: 8,
                bottomTrailing: 0,
                topTrailing: Design.cornerRadius
              )
            )
          )
      }
      .buttonStyle(.plain)
      .pointingHandCursorOnHover(reassertOnPressEnd: true)
    }
    .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 10)
  }

  private var helperRow: some View {
    HStack(alignment: .center, spacing: 6) {
      Image(systemName: "lightbulb")
        .font(.system(size: 11))
        .foregroundColor(theme.textSecondary.opacity(0.7))

      Text(helperText)
        .font(.custom("Figtree", size: Design.helperTextSize))
        .foregroundColor(theme.textSecondary)
    }
  }

  private var backgroundView: some View {
    theme.popoverFill
      .background(.ultraThinMaterial)
  }
}

private struct DayCategoryFlowLayout: Layout {
  var spacing: CGFloat = 4
  var rowSpacing: CGFloat = 4

  func makeCache(subviews: Subviews) {
    ()
  }

  func updateCache(_ cache: inout (), subviews: Subviews) {}

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maxRowWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let proposedWidth = size.width

      if rowWidth > 0 && rowWidth + spacing + proposedWidth > maxWidth {
        totalHeight += rowHeight + rowSpacing
        maxRowWidth = max(maxRowWidth, rowWidth)
        rowWidth = proposedWidth
        rowHeight = size.height
      } else {
        rowWidth = rowWidth == 0 ? proposedWidth : rowWidth + spacing + proposedWidth
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
    var currentRowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += currentRowHeight + rowSpacing
        currentRowHeight = 0
      }

      subview.place(
        at: CGPoint(x: origin.x, y: origin.y),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )

      origin.x += size.width + spacing
      currentRowHeight = max(currentRowHeight, size.height)
    }
  }
}
