import SwiftUI

// The "Next card... / Paused / Resume" pill shown in today's column of the
// Week view. The parent grid positions it; this view only renders the pill.
// Colors mirror the Day view's status cards so both views flip together.
struct WeekRecordingStatusCard: View {
  @Environment(\.dayflowTheme) private var theme

  let mode: RecordingControlMode
  let width: CGFloat
  let height: CGFloat

  private var compact: Bool {
    height < 24
  }

  private var isActive: Bool {
    if case .active = mode { return true }
    return false
  }

  var body: some View {
    HStack(spacing: 0) {
      label
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(
      width: width,
      height: height,
      alignment: .leading
    )
    .background(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(theme.panelSolid)
        .overlay(
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isActive ? theme.generatingGradient : theme.pausedCardGradient)
        )
    )
    .overlay {
      if !isActive {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .stroke(theme.cardBorder.opacity(0.6), lineWidth: 0.5)
      }
    }
  }

  @ViewBuilder
  private var label: some View {
    switch mode {
    case .active:
      HStack(spacing: 6) {
        TimelineThinkingSpinner(config: spinnerConfig, visualScale: 0.4)
        if !compact {
          Text("Next card...")
            .font(.custom("Figtree", size: 10).weight(.semibold))
            .foregroundColor(.white)
            .lineLimit(1)
        }
      }
    case .pausedTimed, .pausedIndefinite:
      Label("Paused", systemImage: "pause.fill")
        .font(.custom("Figtree", size: 10).weight(.medium))
        .foregroundColor(theme.pausedCardText)
    case .stopped:
      Label("Resume", systemImage: "play.fill")
        .font(.custom("Figtree", size: 10).weight(.medium))
        .foregroundColor(theme.pausedCardText)
    }
  }

  private var spinnerConfig: TimelineSpinnerConfig {
    var config = TimelineSpinnerConfig.reference
    config.gap = 1.0
    config.colorDim = .init(0.263, 0.365, 0.592)
    config.colorMid = .init(0.722, 0.518, 0.737)
    config.colorHot = .init(0.965, 0.745, 0.455)
    return config
  }
}
