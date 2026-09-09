//
//  WrappingHStack.swift
//  Dayflow
//
//  Simple wrapping HStack layout
//

import SwiftUI

struct WrappingHStack<Content: View>: View {
  let items: [TimelineCategory]
  let spacing: CGFloat
  let width: CGFloat
  let content: (TimelineCategory) -> Content

  @State private var rows: [[TimelineCategory]] = []

  init(
    _ items: [TimelineCategory], spacing: CGFloat = 4, width: CGFloat,
    @ViewBuilder content: @escaping (TimelineCategory) -> Content
  ) {
    self.items = items
    self.spacing = spacing
    self.width = width
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(rows.indices, id: \.self) { rowIndex in
        HStack(spacing: spacing) {
          ForEach(rows[rowIndex], id: \.id) { item in
            content(item)
          }
          Spacer()
        }
      }
    }
    .onAppear {
      calculateRows()
    }
    .onChange(of: width) {
      calculateRows()
    }
    .onChange(of: items.count) {
      calculateRows()
    }
  }

  private func calculateRows() {
    var currentRows: [[TimelineCategory]] = []
    var currentRow: [TimelineCategory] = []
    var currentRowWidth: CGFloat = 0

    for item in items {
      // Estimate width of the pill (rough estimate based on text length)
      let estimatedWidth = estimatePillWidth(for: item)

      if currentRowWidth + estimatedWidth + spacing > width && !currentRow.isEmpty {
        // Start new row
        currentRows.append(currentRow)
        currentRow = [item]
        currentRowWidth = estimatedWidth
      } else {
        currentRow.append(item)
        currentRowWidth += estimatedWidth + spacing
      }
    }

    if !currentRow.isEmpty {
      currentRows.append(currentRow)
    }

    rows = currentRows
  }

  private func estimatePillWidth(for category: TimelineCategory) -> CGFloat {
    // Rough estimate: category name + dot + padding
    // This is approximate - actual rendering may vary
    let textWidth = CGFloat(category.name.count) * 6.0  // Approximate char width
    return textWidth + 8 + 12 + 12  // dot width + horizontal padding
  }
}
