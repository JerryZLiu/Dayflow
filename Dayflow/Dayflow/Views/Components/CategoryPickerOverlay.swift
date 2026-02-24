import AppKit
import SwiftUI

struct CategoryPickerOverlay: View {
  let categories: [TimelineCategory]
  let currentCategoryName: String
  var onSelect: (TimelineCategory) -> Void
  var onNavigateToEditor: () -> Void

  private var orderedCategories: [TimelineCategory] {
    let trimmedCurrent = currentCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let sorted = categories.sorted { lhs, rhs in
      lhs.order < rhs.order
    }

    guard
      let index = sorted.firstIndex(where: {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmedCurrent
      })
    else {
      return sorted
    }

    var reordered = sorted
    let selected = reordered.remove(at: index)
    reordered.insert(selected, at: 0)
    return reordered
  }

  var body: some View {
    VStack(spacing: 12) {
      FlowLayout(spacing: 6, rowSpacing: 8) {
        ForEach(orderedCategories) { category in
          Button {
            onSelect(category)
          } label: {
            CategoryPickerPill(
              category: category,
              isSelected: isSelected(category)
            )
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Rectangle()
        .fill(Color(red: 0.91, green: 0.89, blue: 0.86))
        .frame(height: 1)

      helperContent
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundView)
    .clipShape(
      UnevenRoundedRectangle(
        cornerRadii: .init(
          topLeading: 0,
          bottomLeading: 0,
          bottomTrailing: 0,
          topTrailing: 6
        )
      )
    )
    .overlay(
      UnevenRoundedRectangle(
        cornerRadii: .init(
          topLeading: 0,
          bottomLeading: 0,
          bottomTrailing: 0,
          topTrailing: 6
        )
      )
      .stroke(Color(red: 0.91, green: 0.88, blue: 0.87), lineWidth: 1)
    )
  }

  private var backgroundView: some View {
    Color(red: 0.98, green: 0.96, blue: 0.95).opacity(0.86)
      .background(.ultraThinMaterial)
  }

  private var helperContent: some View {
    let baseFont = Font.custom("Nunito", size: 12)
    let baseColor = Color(red: 0.39, green: 0.35, blue: 0.33)
    let linkColor = Color(red: 1.0, green: 0.4, blue: 0.0)
    let linkURL = URL(string: "dayflow://category-editor")!

    var intro = AttributedString(
      "To help Dayflow organize your activities more accurately, try adding more details to the descriptions in your categories "
    )
    intro.font = baseFont
    intro.foregroundColor = baseColor

    var link = AttributedString("here")
    link.font = baseFont
    link.foregroundColor = linkColor
    link.underlineStyle = .single
    link.link = linkURL

    var period = AttributedString(".")
    period.font = baseFont
    period.foregroundColor = baseColor

    let attributed = intro + link + period

    return Text(attributed)
      .fixedSize(horizontal: false, vertical: true)
      .environment(
        \.openURL,
        OpenURLAction { url in
          guard url == linkURL else { return .systemAction }
          onNavigateToEditor()
          return .handled
        })
  }

  private func isSelected(_ category: TimelineCategory) -> Bool {
    let trimmedCurrent = currentCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      == trimmedCurrent
  }
}

private struct CategoryPickerPill: View {
  let category: TimelineCategory
  let isSelected: Bool

  private var categoryColor: Color {
    if let nsColor = NSColor(hex: category.colorHex) {
      return Color(nsColor: nsColor)
    }
    return Color.gray
  }

  private var background: some View {
    Group {
      if isSelected {
        LinearGradient(
          colors: [
            Color(red: 1.0, green: 0.99, blue: 0.97),
            Color(red: 1.0, green: 0.91, blue: 0.83),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      } else {
        Color.white.opacity(0.76)
      }
    }
  }

  private var borderColor: Color {
    if isSelected {
      return Color(red: 0.98, green: 0.73, blue: 0.50)
    }
    return Color(red: 0.88, green: 0.88, blue: 0.88)
  }

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(categoryColor)
        .frame(width: 10, height: 10)

      Text(category.name)
        .font(
          Font.custom("Nunito", size: 13)
            .weight(.medium)
        )
        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
        .lineLimit(1)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
    .background(background)
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .inset(by: 0.25)
        .stroke(style: strokeStyle)
        .foregroundColor(borderColor)
    )
    .cornerRadius(6)
  }

  private var strokeStyle: StrokeStyle {
    if category.isIdle && !isSelected {
      return StrokeStyle(lineWidth: 0.75, dash: [2, 2])
    }
    return StrokeStyle(lineWidth: 0.5)
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  var rowSpacing: CGFloat = 6

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
