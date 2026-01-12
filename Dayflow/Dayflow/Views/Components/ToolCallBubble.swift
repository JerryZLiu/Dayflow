//
//  ToolCallBubble.swift
//  Dayflow
//
//  Animated tool call indicator showing when the AI is fetching data.
//  Features a shimmer effect while running and smooth state transitions.
//

import SwiftUI

struct ToolCallBubble: View {
    let message: ChatMessage
    @State private var shimmerOffset: CGFloat = -1.0
    @State private var spinnerRotation: Double = 0
    @State private var appearScale: CGFloat = 0.8
    @State private var appearOpacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            statusText
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(borderOverlay)
        .shadow(color: shadowColor, radius: 6, x: 0, y: 3)
        .scaleEffect(appearScale)
        .opacity(appearOpacity)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                appearScale = 1.0
                appearOpacity = 1.0
            }
            startAnimationsIfNeeded()
        }
        .onChange(of: message.toolStatus) {
            // Subtle bounce when status changes
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                appearScale = 1.03
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    appearScale = 1.0
                }
            }
        }
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch message.toolStatus {
        case .running:
            // Animated spinner
            Image(systemName: "circle.dotted")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "F96E00"))
                .rotationEffect(.degrees(spinnerRotation))

        case .completed:
            // Green checkmark
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "34C759"))

        case .failed:
            // Red X
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "FF3B30"))

        case nil:
            EmptyView()
        }
    }

    // MARK: - Status Text

    @ViewBuilder
    private var statusText: some View {
        switch message.toolStatus {
        case .running:
            Text(message.content)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "8B5E3C"))

        case .completed(let summary):
            Text(summary)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "2D7D46"))

        case .failed(let error):
            Text(error)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "C62828"))

        case nil:
            Text(message.content)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "8B5E3C"))
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        switch message.toolStatus {
        case .running:
            ZStack {
                // Base gradient
                LinearGradient(
                    colors: [
                        Color(hex: "FFF4E9"),
                        Color(hex: "FFECD8")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Shimmer overlay
                if !reduceMotion {
                    ShimmerOverlay(offset: shimmerOffset)
                        .blendMode(.softLight)
                }
            }

        case .completed:
            LinearGradient(
                colors: [
                    Color(hex: "E8F5E9"),
                    Color(hex: "C8E6C9")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

        case .failed:
            LinearGradient(
                colors: [
                    Color(hex: "FFEBEE"),
                    Color(hex: "FFCDD2")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

        case nil:
            Color(hex: "FFF4E9")
        }
    }

    // MARK: - Border

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(borderColor, lineWidth: 1.5)
    }

    private var borderColor: Color {
        switch message.toolStatus {
        case .running:
            return Color(hex: "F96E00").opacity(0.3)
        case .completed:
            return Color(hex: "34C759").opacity(0.3)
        case .failed:
            return Color(hex: "FF3B30").opacity(0.3)
        case nil:
            return Color(hex: "F96E00").opacity(0.3)
        }
    }

    private var shadowColor: Color {
        switch message.toolStatus {
        case .running:
            return Color(hex: "F96E00").opacity(0.1)
        case .completed:
            return Color(hex: "34C759").opacity(0.1)
        case .failed:
            return Color(hex: "FF3B30").opacity(0.1)
        case nil:
            return Color(hex: "F96E00").opacity(0.1)
        }
    }

    // MARK: - Animations

    private func startAnimationsIfNeeded() {
        guard message.isRunning, !reduceMotion else { return }

        // Continuous spinner rotation
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            spinnerRotation = 360
        }

        // Continuous shimmer animation
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
            shimmerOffset = 1.0
        }
    }
}

// MARK: - Shimmer Overlay

private struct ShimmerOverlay: View {
    let offset: CGFloat

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.5),
                    Color.white.opacity(0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.4)
            .offset(x: offset * geo.size.width * 1.4 - geo.size.width * 0.2)
        }
        .clipped()
    }
}

// MARK: - Preview

#Preview("Tool Call Bubble - Running") {
    VStack(spacing: 20) {
        ToolCallBubble(
            message: ChatMessage(
                role: .toolCall,
                content: "Fetching Tuesday's timeline...",
                toolStatus: .running
            )
        )

        ToolCallBubble(
            message: ChatMessage(
                role: .toolCall,
                content: "Fetching timeline...",
                toolStatus: .completed(summary: "Found 8 activities for Jan 7th")
            )
        )

        ToolCallBubble(
            message: ChatMessage(
                role: .toolCall,
                content: "Fetching timeline...",
                toolStatus: .failed(error: "No data found for this date")
            )
        )
    }
    .padding(40)
    .background(Color(hex: "FAF5F0"))
}
