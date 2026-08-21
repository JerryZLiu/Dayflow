//
//  MiniTimerView.swift
//  Dayflow
//
//  The floating focus pill: today's focused time, counting up live.
//
//  NOTE: the view declares a FIXED outer frame. The hosting window is sized to
//  match and does not auto-resize — earlier the dynamic/auto-sizing path drove
//  AppKit's constraint engine into infinite recursion (stack-overflow crash).
//

import SwiftUI

struct MiniTimerView: View {
  static let windowSize = CGSize(width: 196, height: 52)

  @ObservedObject private var stats = ProductivityStats.shared
  var onClose: () -> Void

  @State private var hovering = false

  var body: some View {
    // TimelineView ticks every second so the live-optimistic extension counts
    // up smoothly between the once-a-minute processed refreshes.
    TimelineView(.periodic(from: .now, by: 1)) { context in
      pill(
        focused: stats.liveFocusedSeconds(asOf: context.date),
        counting: stats.isActivelyCounting(asOf: context.date))
    }
    .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    .onHover { isHovering in
      withAnimation(.easeInOut(duration: 0.15)) { hovering = isHovering }
    }
  }

  private func pill(focused: Double, counting: Bool) -> some View {
    HStack(spacing: 8) {
      Circle()
        .fill(counting ? Color.green : Color.secondary.opacity(0.5))
        .frame(width: 7, height: 7)

      Text(Self.format(seconds: focused))
        .font(.system(size: 14, weight: .semibold).monospacedDigit())
        .foregroundStyle(.primary)

      Spacer(minLength: 4)

      if hovering {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Hide the focus timer")
      } else {
        Text("focused")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .frame(width: 172, height: 38)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
  }

  static func format(seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
      return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
  }
}
