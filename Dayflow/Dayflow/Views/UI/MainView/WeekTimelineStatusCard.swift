import SwiftUI

private struct WeekStatusCardStyle {
  let gradient: LinearGradient
  let gradientOpacity: Double
  let baseColor: Color
  let strokeColor: Color
  let strokeWidth: CGFloat
  let shadowColor: Color
  let shadowRadius: CGFloat
}

// The "Next card... / Paused / Resume" pill shown in today's column of the
// Week view. The parent grid positions it; this view only renders the pill.
struct WeekRecordingStatusCard: View {
  let mode: RecordingControlMode
  let width: CGFloat
  let height: CGFloat

  private var compact: Bool {
    height < 24
  }

  var body: some View {
    let style = cardStyle

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
        .fill(style.baseColor)
        .overlay(
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(style.gradient)
            .opacity(style.gradientOpacity)
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .inset(by: 0.375)
        .stroke(style.strokeColor, lineWidth: style.strokeWidth)
    )
    .shadow(color: style.shadowColor, radius: style.shadowRadius, x: 0, y: 0)
  }

  private var cardStyle: WeekStatusCardStyle {
    switch mode {
    case .active:
      return WeekStatusCardStyle(
        gradient: LinearGradient(
          stops: [
            .init(color: Color(hex: "5E7FC0"), location: 0.00),
            .init(color: Color(hex: "D88ECE"), location: 0.35),
            .init(color: Color(hex: "FFC19E"), location: 0.68),
            .init(color: Color(hex: "FFEDE0"), location: 1.00),
          ],
          startPoint: .leading,
          endPoint: .trailing
        ),
        gradientOpacity: 0.70,
        baseColor: Color(hex: "D9C6BA"),
        strokeColor: Color.white.opacity(0.52),
        strokeWidth: 0.75,
        shadowColor: .black.opacity(0.10),
        shadowRadius: 4
      )

    case .pausedTimed, .pausedIndefinite, .stopped:
      return WeekStatusCardStyle(
        gradient: LinearGradient(
          stops: [
            .init(color: Color(hex: "F7E6D5"), location: 0.13),
            .init(color: Color(hex: "DADEE4"), location: 1.00),
          ],
          startPoint: .leading,
          endPoint: .trailing
        ),
        gradientOpacity: 1.0,
        baseColor: .clear,
        strokeColor: .white,
        strokeWidth: 1,
        shadowColor: .black.opacity(0.03),
        shadowRadius: 2
      )
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
        .foregroundColor(Color(hex: "888D95"))
    case .stopped:
      Label("Resume", systemImage: "play.fill")
        .font(.custom("Figtree", size: 10).weight(.medium))
        .foregroundColor(Color(hex: "888D95"))
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
