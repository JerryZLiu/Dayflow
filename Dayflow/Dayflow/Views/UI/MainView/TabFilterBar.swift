import SwiftUI

struct TabFilterBar: View {
    let categories: [TimelineCategory]
    let idleCategory: TimelineCategory?
    let onManageCategories: () -> Void

    @State private var chipRowWidth: CGFloat = 0

    private let editButtonSize: CGFloat = 26
    private let chipButtonSpacing: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let inlineContentLimit = max(0, availableWidth - (editButtonSize + chipButtonSpacing))
            let fitsInline = chipRowWidth == 0 ? true : chipRowWidth <= inlineContentLimit

            Group {
                if fitsInline {
                    HStack(spacing: chipButtonSpacing) {
                        scrollableChipRow(maxWidth: chipRowWidth == 0 ? inlineContentLimit : chipRowWidth)
                        editButton
                    }
                } else {
                    ZStack(alignment: .trailing) {
                        scrollableChipRow(maxWidth: nil)
                            .padding(.trailing, editButtonSize + chipButtonSpacing)

                        overflowGradient
                        editButton
                    }
                }
            }
            .frame(width: geometry.size.width, height: 26, alignment: .leading)
        }
        .frame(height: 26)
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
                        Font.custom("Nunito", size: 13)
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

    private func scrollableChipRow(maxWidth: CGFloat?) -> some View {
        let row = ScrollView(.horizontal, showsIndicators: false) {
            measuredChipRow
        }
        .frame(height: 26)
        .clipped()

        return Group {
            if let maxWidth {
                row.frame(width: max(0, maxWidth), alignment: .leading)
            } else {
                row
            }
        }
    }

    private var measuredChipRow: some View {
        HStack(spacing: 5) {
            ForEach(categories) { category in
                CategoryChip(category: category, isIdle: false)
            }

            if let idleCategory {
                CategoryChip(category: idleCategory, isIdle: true)
            }
        }
        .padding(.leading, 1)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ChipRowWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
    }

    private var editButton: some View {
        Button(action: onManageCategories) {
            Image("CategoryEditButton")
                .resizable()
                .scaledToFit()
                .frame(width: editButtonSize, height: editButtonSize)
        }
        .buttonStyle(PlainButtonStyle())
        .hoverScaleEffect(scale: 1.02)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
    }

    private var overflowGradient: some View {
        HStack(spacing: 0) {
            Spacer()
            LinearGradient(
                gradient: Gradient(colors: [Color.clear, Color(hex: "FFF8F1")]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 40)
            .allowsHitTesting(false)

            Color(hex: "FFF8F1")
                .frame(width: editButtonSize)
                .allowsHitTesting(false)
        }
    }

    private struct ChipRowWidthPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }
}
