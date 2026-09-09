import SwiftUI

struct WeeklyHeader: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter
  let title: String
  let canNavigateForward: Bool
  let onPrevious: () -> Void
  let onNext: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      WeeklyNavigationButton(assetName: "LeftArrow") {
        onPrevious()
      }

      Text(title)
        .font(.custom("InstrumentSerif-Regular", size: stylePreviewAfter ? 26 : 20))
        .foregroundStyle(stylePreviewAfter && theme.isDark ? Color.white : Color.black)
        .multilineTextAlignment(.center)
        .frame(width: stylePreviewAfter ? 448 : 344)

      WeeklyNavigationButton(assetName: "RightArrow", isEnabled: canNavigateForward) {
        onNext()
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: stylePreviewAfter ? 34 : 29)
  }
}

private struct WeeklyNavigationButton: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter
  let assetName: String
  var isEnabled = true
  let action: () -> Void

  @State private var isHovering = false

  private let arrowSize: CGFloat = 24
  private let hoverCircleSize: CGFloat = 30

  var body: some View {
    Button {
      guard isEnabled else { return }
      action()
    } label: {
      ZStack {
        Circle()
          .fill(Color(hex: "FFEBD3").opacity(0.79))
          .frame(width: hoverCircleSize, height: hoverCircleSize)
          .opacity(isHovering && isEnabled ? 1 : 0)

        Image(assetName)
          .resizable()
          .renderingMode(stylePreviewAfter && theme.isDark ? .template : .original)
          .scaledToFit()
          .foregroundStyle(.white)
          .frame(width: arrowSize, height: arrowSize)
          .opacity(isEnabled ? 1 : 0.35)
      }
      .frame(width: hoverCircleSize, height: hoverCircleSize)
      .contentShape(Circle())
    }
    .buttonStyle(DayflowPressScaleButtonStyle(enabled: isEnabled))
    .disabled(!isEnabled)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = isEnabled && hovering
      }
    }
    .onChange(of: isEnabled) { _, enabled in
      if !enabled {
        isHovering = false
      }
    }
    .pointingHandCursorOnHover(enabled: isEnabled, reassertOnPressEnd: true)
  }
}
