import SwiftUI

struct WeeklyHeader: View {
  let title: String
  let canNavigateForward: Bool
  let onPrevious: () -> Void
  let onNext: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Button(action: onPrevious) {
        Image("CalendarLeftButton")
          .resizable()
          .scaledToFit()
          .frame(width: 26, height: 26)
      }
      .buttonStyle(.plain)
      .hoverScaleEffect(scale: 1.02)
      .pointingHandCursorOnHover(reassertOnPressEnd: true)

      Text(title)
        .font(.custom("InstrumentSerif-Regular", size: 24))
        .foregroundStyle(Color.black)
        .multilineTextAlignment(.center)

      Button(action: onNext) {
        Image("CalendarRightButton")
          .resizable()
          .scaledToFit()
          .frame(width: 26, height: 26)
      }
      .buttonStyle(.plain)
      .disabled(!canNavigateForward)
      .hoverScaleEffect(enabled: canNavigateForward, scale: 1.02)
      .pointingHandCursorOnHover(enabled: canNavigateForward, reassertOnPressEnd: true)
    }
    .frame(maxWidth: .infinity)
  }
}
