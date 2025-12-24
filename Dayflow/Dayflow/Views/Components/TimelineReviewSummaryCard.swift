//
//  TimelineReviewSummaryCard.swift
//  Dayflow
//
//  Review summary card that links to timeline swiping.
//

import SwiftUI

struct TimelineReviewSummarySnapshot {
    let hasData: Bool
    let lastReviewedAt: Date?
    let distractedRatio: Double
    let neutralRatio: Double
    let productiveRatio: Double
    let distractedDuration: TimeInterval
    let neutralDuration: TimeInterval
    let productiveDuration: TimeInterval

    static let placeholder = TimelineReviewSummarySnapshot(
        hasData: false,
        lastReviewedAt: nil,
        distractedRatio: 1.0 / 3.0,
        neutralRatio: 1.0 / 3.0,
        productiveRatio: 1.0 / 3.0,
        distractedDuration: 0,
        neutralDuration: 0,
        productiveDuration: 0
    )
}

struct TimelineReviewSummaryCard: View {
    let summary: TimelineReviewSummarySnapshot
    let cardsToReviewCount: Int
    var onReviewTap: (() -> Void)? = nil

    private enum Design {
        static let sectionSpacing: CGFloat = 12
        static let headerSpacing: CGFloat = 2
        static let contentSpacing: CGFloat = 16

        static let titleColor = Color(hex: "333333")
        static let subtitleColor = Color(hex: "707070")
        static let linkColor = Color(hex: "F96E00")

        static let barHeight: CGFloat = 39
        static let barCornerRadius: CGFloat = 4
        static let barStrokeWidth: CGFloat = 1
        static let barSpacing: CGFloat = 4
        static let barShadowRadius: CGFloat = 4
        static let barShadowY: CGFloat = 2

        static let legendSpacing: CGFloat = 28
        static let legendRowSpacing: CGFloat = 2
        static let legendIconWidth: CGFloat = 10.667
        static let legendIconHeight: CGFloat = 8
        static let legendIconCornerRadius: CGFloat = 3
        static let legendStrokeWidth: CGFloat = 1.25
    }

    private struct ReviewMetric: Identifiable {
        let id: String
        let label: String
        let ratio: CGFloat
        let durationText: String
        let style: ReviewMetricStyle
    }

    private struct ReviewMetricStyle {
        let barGradient: LinearGradient
        let barStroke: Color
        let barShadow: Color
        let legendFill: Color
        let legendStroke: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionSpacing) {
            header

            VStack(alignment: .leading, spacing: Design.contentSpacing) {
                barRow
                legendRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.headerSpacing) {
            Text("Your review")
                .font(.custom("InstrumentSerif-Regular", size: 20))
                .foregroundColor(Design.titleColor)

            subtitle
                .font(.custom("Nunito", size: 11))
                .lineSpacing(2)
                .onTapGesture {
                    guard cardsToReviewCount > 0 else { return }
                    onReviewTap?()
                }
                .opacity(cardsToReviewCount > 0 ? 1 : 0.9)
        }
    }

    private var subtitle: Text {
        let baseText = summary.hasData
            ? "Last reviewed at \(formattedLastReviewedAt)."
            : "No reviews yet."
        var composed = Text(baseText)
            .foregroundColor(Design.subtitleColor)

        guard cardsToReviewCount > 0 else {
            return composed
        }

        let reviewText = "Review \(reviewCountText)"
        composed = composed
            + Text(" \(reviewText)")
                .foregroundColor(Design.linkColor)
            + Text(" to update your data.")
                .foregroundColor(Design.subtitleColor)

        return composed
    }

    private var barRow: some View {
        GeometryReader { proxy in
            let metrics = reviewMetrics
            let spacing = Design.barSpacing
            let totalSpacing = spacing * CGFloat(max(metrics.count - 1, 0))
            let availableWidth = max(proxy.size.width - totalSpacing, 0)

            HStack(spacing: spacing) {
                ForEach(metrics) { metric in
                    RoundedRectangle(cornerRadius: Design.barCornerRadius, style: .continuous)
                        .fill(metric.style.barGradient)
                        .frame(width: availableWidth * metric.ratio, height: Design.barHeight)
                        .overlay(
                            RoundedRectangle(cornerRadius: Design.barCornerRadius, style: .continuous)
                                .stroke(metric.style.barStroke, lineWidth: Design.barStrokeWidth)
                        )
                        .shadow(color: metric.style.barShadow, radius: Design.barShadowRadius, x: 0, y: Design.barShadowY)
                }
            }
            .frame(width: proxy.size.width, height: Design.barHeight, alignment: .leading)
        }
        .frame(height: Design.barHeight)
    }

    private var legendRow: some View {
        let metrics = reviewMetrics
        return HStack(spacing: Design.legendSpacing) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: Design.legendRowSpacing) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: Design.legendIconCornerRadius, style: .continuous)
                            .fill(metric.style.legendFill)
                            .frame(width: Design.legendIconWidth, height: Design.legendIconHeight)
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.legendIconCornerRadius, style: .continuous)
                                    .stroke(metric.style.legendStroke, lineWidth: Design.legendStrokeWidth)
                            )

                        Text(metric.label)
                            .font(.custom("Nunito", size: 10))
                            .foregroundColor(Design.subtitleColor)
                    }

                    if summary.hasData {
                        Text(metric.durationText)
                            .font(.custom("Nunito", size: 12).weight(.semibold))
                            .foregroundColor(Design.titleColor)
                            .padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var reviewMetrics: [ReviewMetric] {
        let placeholder = summary.hasData == false
        let distracted = ReviewMetric(
            id: "distracted",
            label: "Distracted",
            ratio: max(CGFloat(summary.distractedRatio), 0),
            durationText: durationText(summary.distractedDuration),
            style: metricStyle(
                baseColor: Color(hex: "FF8772"),
                shadow: Color(red: 148 / 255, green: 87 / 255, blue: 77 / 255).opacity(0.25),
                legendFill: Color(hex: "FF8772").opacity(0.4),
                legendStroke: Color(hex: "FF8772"),
                placeholder: placeholder
            )
        )

        let neutral = ReviewMetric(
            id: "neutral",
            label: "Neutral",
            ratio: max(CGFloat(summary.neutralRatio), 0),
            durationText: durationText(summary.neutralDuration),
            style: metricStyle(
                baseColor: Color(hex: "EAE0DB"),
                shadow: Color(red: 225 / 255, green: 210 / 255, blue: 203 / 255).opacity(0.25),
                legendFill: Color(hex: "DDDBDA").opacity(0.4),
                legendStroke: Color(hex: "DDDBDA"),
                placeholder: placeholder
            )
        )

        let productive = ReviewMetric(
            id: "productive",
            label: "Focused",
            ratio: max(CGFloat(summary.productiveRatio), 0),
            durationText: durationText(summary.productiveDuration),
            style: metricStyle(
                baseColor: Color(hex: "42D0BB"),
                shadow: Color(red: 77 / 255, green: 156 / 255, blue: 145 / 255).opacity(0.25),
                legendFill: Color(hex: "42D0BB").opacity(0.4),
                legendStroke: Color(hex: "42D0BB"),
                placeholder: placeholder
            )
        )

        return [distracted, neutral, productive]
    }

    private func metricStyle(
        baseColor: Color,
        shadow: Color,
        legendFill: Color,
        legendStroke: Color,
        placeholder: Bool
    ) -> ReviewMetricStyle {
        let barColor = placeholder ? Color(hex: "EAE0DB") : baseColor
        let barShadow = placeholder
            ? Color(red: 225 / 255, green: 210 / 255, blue: 203 / 255).opacity(0.25)
            : shadow
        let gradient = LinearGradient(
            colors: [barColor.opacity(0.5), barColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ReviewMetricStyle(
            barGradient: gradient,
            barStroke: barColor,
            barShadow: barShadow,
            legendFill: legendFill,
            legendStroke: legendStroke
        )
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(minutes)m"
        }
    }

    private var formattedLastReviewedAt: String {
        guard let last = summary.lastReviewedAt else { return "—" }
        return Self.timeFormatter.string(from: last)
    }

    private var reviewCountText: String {
        cardsToReviewCount == 1 ? "1 card" : "\(cardsToReviewCount) cards"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

#Preview("Timeline Review Summary Card") {
    VStack(spacing: 24) {
        TimelineReviewSummaryCard(
            summary: TimelineReviewSummarySnapshot(
                hasData: true,
                lastReviewedAt: Date(),
                distractedRatio: 0.22,
                neutralRatio: 0.4,
                productiveRatio: 0.38,
                distractedDuration: 4200,
                neutralDuration: 3000,
                productiveDuration: 7200
            ),
            cardsToReviewCount: 4
        )
        .frame(width: 322)

        TimelineReviewSummaryCard(
            summary: .placeholder,
            cardsToReviewCount: 0
        )
        .frame(width: 322)
    }
    .padding(24)
    .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
