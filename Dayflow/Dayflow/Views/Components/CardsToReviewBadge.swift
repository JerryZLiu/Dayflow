//
//  CardsToReviewBadge.swift
//  Dayflow
//
//  Pill badge showing number of cards to review with stacked cards icon
//

import SwiftUI

struct CardsToReviewBadge: View {
    let count: Int

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // Stacked cards icon with number
            stackedCardsIcon

            // Label text
            Text(count == 1 ? "card to review" : "cards to review")
                .font(.custom("Nunito", size: 10).weight(.medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                stops: [
                    Gradient.Stop(color: Color(red: 1, green: 0.6, blue: 0.44), location: 0.00),
                    Gradient.Stop(color: Color(red: 0.74, green: 0.67, blue: 1), location: 1.00),
                ],
                startPoint: UnitPoint(x: 0.05, y: 0),
                endPoint: UnitPoint(x: 0.95, y: 1)
            )
        )
        .cornerRadius(20)
        .shadow(color: Color(red: 0.91, green: 0.79, blue: 0.7), radius: 1.5, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .inset(by: 0.75)
                .stroke(Color(red: 1, green: 0.85, blue: 0.83), lineWidth: 1.5)
        )
    }

    private var stackedCardsIcon: some View {
        ZStack(alignment: .bottom) {
            // Back card (rotated, behind) - 15.75 x 14 (h x w)
            // Positioned so leftmost point pokes out only 3px
            RoundedRectangle(cornerRadius: 3.5)
                .fill(Color.white)
                .frame(width: 14, height: 15.75)
                .rotationEffect(.degrees(-11.64))
                .offset(x: -3, y: 0)

            // Front card with number - 18 x 14 (h x w)
            ZStack {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(Color.white)
            }
            .frame(width: 14, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5)
                    .inset(by: -0.63)
                    .stroke(Color(red: 0.97, green: 0.61, blue: 0.51), lineWidth: 1.25)
            )
            .overlay(
                Text("\(count)")
                    .font(.custom("Nunito", size: 9).weight(.heavy))
                    .foregroundColor(Color(red: 0.98, green: 0.6, blue: 0.49))
            )
            .offset(x: 4, y: 0)
        }
        .frame(width: 21, height: 20)
    }
}

// MARK: - Preview

#Preview("Cards to Review Badge") {
    CardsToReviewBadgePreview()
}

private struct CardsToReviewBadgePreview: View {
    @State private var count: Int = 10

    var body: some View {
        VStack(spacing: 40) {
            // The badge
            CardsToReviewBadge(count: count)

            // Controls
            VStack(spacing: 16) {
                Text("Count: \(count)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button("1") { count = 1 }
                    Button("5") { count = 5 }
                    Button("10") { count = 10 }
                    Button("99") { count = 99 }
                }
                .buttonStyle(.bordered)

                Slider(value: Binding(
                    get: { Double(count) },
                    set: { count = Int($0) }
                ), in: 1...99, step: 1)
                .frame(width: 200)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
        .padding(60)
        .background(Color(red: 0.98, green: 0.96, blue: 0.94))
    }
}
