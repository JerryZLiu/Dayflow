//
//  TimelineRateSummaryView.swift
//  Dayflow
//
//  Lightweight footer for rating a generated summary.
//

import SwiftUI

enum TimelineRatingDirection: String, Codable, Sendable {
    case up
    case down
}

struct TimelineRateSummaryView: View {

    var title: String = "Rate this summary"
    var isEnabled: Bool = true
    var activityID: String? = nil
    var onRate: ((TimelineRatingDirection) -> Void)? = nil

    @State private var selectedDirection: TimelineRatingDirection? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(title)
                    .font(Font.custom("Nunito", size: 12).weight(.medium))
                    .foregroundColor(
                        Color(red: 0.49, green: 0.47, blue: 0.46)
                            .opacity(isEnabled ? 0.95 : 0.45)
                    )

                HStack(spacing: 0) {
                    rateButton(for: .up)
                    rateButton(for: .down)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.98, green: 0.98, blue: 0.98))
        .overlay(
            Rectangle()
                .inset(by: 0.5)
                .stroke(Color(red: 0.93, green: 0.93, blue: 0.93), lineWidth: 1)
        )
        .shadow(color: Color.white.opacity(1.0), radius: 9, x: 0, y: -4)
        .opacity(isEnabled ? 1 : 0.6)
        .onChange(of: activityID) { _ in
            selectedDirection = nil
        }
    }

    @ViewBuilder
    private func rateButton(for direction: TimelineRatingDirection) -> some View {
        let isSelected = selectedDirection == direction
        Button(action: {
            guard isEnabled else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedDirection = direction
            }
            onRate?(direction)
        }) {
            Image("ThumbsUp")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .scaleEffect(x: direction == .down ? -1 : 1, y: direction == .down ? -1 : 1)
                .padding(4)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(isSelected ? Color.white : Color.clear)
                        .shadow(color: isSelected ? Color.black.opacity(0.08) : Color.clear, radius: 6, x: 0, y: 3)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(direction == .up ? Text("Thumbs up") : Text("Thumbs down"))
    }
}

#Preview("TimelineRateSummaryView") {
    TimelineRateSummaryView()
        .padding()
        .previewLayout(.sizeThatFits)
}
