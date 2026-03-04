//
//  CategoryPickerView.swift
//  Dayflow
//

import SwiftUI

struct CategoryPickerView: View {
  let currentCategory: String
  let categories: [TimelineCategory]
  var onCategorySelected: (TimelineCategory) -> Void
  var onNavigateToEditor: () -> Void

  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 0) {
        // Category pills section - wrap to as many rows as needed
        WrappingHStack(categories, spacing: 4, width: geometry.size.width - 16) { category in
          CategoryPill(
            category: category,
            isSelected: isCategorySelected(category),
            onTap: { onCategorySelected(category) }
          )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)

        // Divider - using a custom line with specific styling
        Rectangle()
          .fill(Color.clear)
          .frame(height: 0)
          .overlay(
            Rectangle()
              .fill(Color(red: 0.91, green: 0.89, blue: 0.86))
              .frame(height: 1)
          )
          .padding(.horizontal, 0)

        // Helper text section
        VStack(alignment: .leading, spacing: 10) {
          ZStack(alignment: .topLeading) {
            // Main text
            HStack(alignment: .top, spacing: 0) {
              Text(
                "To help Dayflow organize your activities more accurately, try adding more details to the descriptions in your categories "
              )
              .font(Font.custom("Nunito", size: 10).weight(.medium))
              .foregroundColor(Color(red: 0.39, green: 0.35, blue: 0.33))  // #635953

              Button(action: onNavigateToEditor) {
                Text("here")
                  .font(Font.custom("Nunito", size: 10).weight(.medium))
                  .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.0))  // #ff6600
                  .underline()
              }
              .buttonStyle(.plain)
              .pointingHandCursor()

              Text(".")
                .font(Font.custom("Nunito", size: 10).weight(.medium))
                .foregroundColor(Color(red: 0.39, green: 0.35, blue: 0.33))
            }
            .padding(.leading, 2.188)

            // Lightbulb icon overlaid
            Image(systemName: "lightbulb.fill")
              .font(.system(size: 7))
              .foregroundColor(Color(red: 0.49, green: 0.47, blue: 0.46))  // #7c7875
              .offset(x: 0, y: 2)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      ZStack {
        // Backdrop blur effect - rgba(250,244,241,0.86) with blur
        Color(red: 0.98, green: 0.96, blue: 0.95).opacity(0.86)
          .background(.ultraThinMaterial)
      }
      .overlay(
        // Border - #e9e1de
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
    )
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
    .overlay(alignment: .topTrailing) {
      // Edit/Check button in top right corner
      Button(action: {}) {
        Image(systemName: "checkmark")
          .font(.system(size: 8))
          .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
          .frame(width: 8, height: 8)
      }
      .buttonStyle(.plain)
      .padding(6)
      .background(
        Color(red: 0.98, green: 0.98, blue: 0.98).opacity(0.8)
          .background(.ultraThinMaterial)
      )
      .clipShape(
        UnevenRoundedRectangle(
          cornerRadii: .init(
            topLeading: 0,
            bottomLeading: 6,
            bottomTrailing: 0,
            topTrailing: 6
          )
        )
      )
      .overlay(
        UnevenRoundedRectangle(
          cornerRadii: .init(
            topLeading: 0,
            bottomLeading: 6,
            bottomTrailing: 0,
            topTrailing: 6
          )
        )
        .stroke(Color(red: 0.89, green: 0.89, blue: 0.89), lineWidth: 1)
      )
      .offset(x: -8, y: 8)
    }
  }

  private func isCategorySelected(_ category: TimelineCategory) -> Bool {
    let currentNormalized = currentCategory.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let categoryNormalized = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return currentNormalized == categoryNormalized
  }
}

struct CategoryPill: View {
  let category: TimelineCategory
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 4) {
        // Colored dot
        Circle()
          .fill(categoryColor)
          .frame(width: 8, height: 8)

        // Category name - no line limit, text can wrap if needed
        Text(category.name)
          .font(Font.custom("Nunito", size: 10).weight(.medium))
          .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
          .fixedSize(horizontal: false, vertical: true)
          .lineLimit(nil)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(pillBackground)
      .cornerRadius(6)
      .overlay(
        Group {
          if category.isIdle && !isSelected {
            // Dotted border for Idle category
            RoundedRectangle(cornerRadius: 6)
              .inset(by: 0.375)
              .stroke(style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
              .foregroundColor(pillBorder)
          } else {
            RoundedRectangle(cornerRadius: 6)
              .inset(by: 0.375)
              .stroke(pillBorder, lineWidth: 0.75)
          }
        }
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  private var categoryColor: Color {
    if let nsColor = NSColor(hex: category.colorHex) {
      return Color(nsColor: nsColor)
    }
    return Color.gray
  }

  private var pillBackground: some View {
    Group {
      if isSelected {
        // Gradient for selected state
        LinearGradient(
          colors: [
            Color(red: 1.0, green: 0.99, blue: 0.97),  // #fffdf8
            Color(red: 1.0, green: 0.91, blue: 0.83),  // #ffe8d3
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      } else {
        Color(red: 0.996, green: 0.996, blue: 0.996)  // #fefefe
      }
    }
  }

  private var pillBorder: Color {
    if isSelected {
      return Color(red: 0.98, green: 0.73, blue: 0.50)  // #fbbb80
    } else if category.isIdle {
      // Dotted border for Idle category
      return Color(red: 0.88, green: 0.88, blue: 0.88)  // Will be styled differently
    } else {
      return Color(red: 0.88, green: 0.88, blue: 0.88)  // #e1e1e1
    }
  }
}
