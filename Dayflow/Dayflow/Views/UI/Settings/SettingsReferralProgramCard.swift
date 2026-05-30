import SwiftUI

struct ReferralPassCard: View {
  let message: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false
  @State private var tiltX = 0.0
  @State private var tiltY = 0.0
  @State private var glareCenter = UnitPoint(x: 0.5, y: 0.5)

  private let cardSize = CGSize(width: 283, height: 161)

  init(message: String = "Enjoy a free month of Dayflow Pro on us.") {
    self.message = message
  }

  var body: some View {
    ZStack {
      Image("ReferralCardBackground")
        .resizable()
        .scaledToFill()

      shineOverlay

      VStack(spacing: 8) {
        HStack(alignment: .center, spacing: 4) {
          Image("DayflowLogo")
            .resizable()
            .renderingMode(.template)
            .foregroundColor(.white)
            .scaledToFit()
            .frame(width: 24, height: 24)

          Text("Dayflow")
            .font(.custom("InstrumentSerif-Regular", size: 28))
            .foregroundColor(.white)
            .lineLimit(1)

          Text("Pro")
            .font(.custom("InstrumentSerif-Regular", size: 12))
            .foregroundColor(Color(hex: "FF790C"))
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.9))
            )
        }

        Text(message)
          .font(.custom("Figtree", size: 10))
          .foregroundColor(.white)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      .frame(width: 158)
      .offset(y: 2)
    }
    .frame(width: 283, height: 161)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.78), lineWidth: 1)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.3), lineWidth: 1)
        .shadow(color: Color.white.opacity(0.18), radius: 10, x: 0, y: 6)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    )
    .rotation3DEffect(.degrees(effectiveTiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.65)
    .rotation3DEffect(.degrees(effectiveTiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
    .offset(y: isHovering && !reduceMotion ? -3 : 0)
    .shadow(
      color: Color(hex: "744D33").opacity(isHovering ? 0.22 : 0.18),
      radius: isHovering ? 17 : 13,
      x: 0,
      y: isHovering ? 24 : 18
    )
    .shadow(
      color: Color(hex: "744D33").opacity(isHovering ? 0.14 : 0.12),
      radius: isHovering ? 7 : 5,
      x: 0,
      y: isHovering ? 8 : 6
    )
    .onContinuousHover { phase in
      handleHover(phase)
    }
  }

  private var effectiveTiltX: Double {
    reduceMotion ? 0 : tiltX
  }

  private var effectiveTiltY: Double {
    reduceMotion ? 0 : tiltY
  }

  private var shineOverlay: some View {
    ZStack {
      LinearGradient(
        stops: [
          .init(color: Color.white.opacity(0.45), location: 0),
          .init(color: Color.white.opacity(0.02), location: 0.36),
          .init(color: Color(hex: "FF7531").opacity(0.13), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      RadialGradient(
        colors: [
          Color.white.opacity(isHovering ? 0.5 : 0.28),
          Color.white.opacity(isHovering ? 0.14 : 0.08),
          Color.white.opacity(0),
        ],
        center: glareCenter,
        startRadius: 0,
        endRadius: 78
      )
    }
    .blendMode(.softLight)
  }

  private func handleHover(_ phase: HoverPhase) {
    switch phase {
    case .active(let location):
      guard !reduceMotion else { return }
      let x = clampedUnit(location.x / cardSize.width)
      let y = clampedUnit(location.y / cardSize.height)

      if !isHovering {
        withAnimation(.easeOut(duration: 0.14)) {
          isHovering = true
        }
      }

      tiltY = Double((x - 0.5) * 12)
      tiltX = Double((0.5 - y) * 10)
      glareCenter = UnitPoint(x: x, y: y)
    case .ended:
      resetHover()
    }
  }

  private func resetHover() {
    withAnimation(.easeOut(duration: 0.18)) {
      isHovering = false
      tiltX = 0
      tiltY = 0
      glareCenter = UnitPoint(x: 0.5, y: 0.5)
    }
  }

  private func clampedUnit(_ value: CGFloat) -> CGFloat {
    min(max(value, 0), 1)
  }
}

enum ReferralStepIcon {
  case system(String)
  case menuBarMark
}

struct ReferralStepRow: View {
  let icon: ReferralStepIcon
  let content: Text

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      iconView
      content
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color(hex: "333333"))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var iconView: some View {
    switch icon {
    case .menuBarMark:
      Image("MenuBarOffIcon")
        .resizable()
        .renderingMode(.template)
        .foregroundColor(Color(hex: "B8AA9E"))
        .scaledToFit()
        .frame(width: 16, height: 13)
        .frame(width: 16, height: 14)
    case .system(let name):
      Image(systemName: name)
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(Color(hex: "B8AA9E"))
        .frame(width: 16, height: 12)
    }
  }
}

enum ReferralMiniButtonStyle {
  case copy
  case send

  var foreground: Color {
    switch self {
    case .copy: return Color(hex: "D7A585")
    case .send: return .white
    }
  }

  var background: Color {
    switch self {
    case .copy: return Color(hex: "FFF5EA")
    case .send: return Color(hex: "402C00")
    }
  }

  var border: Color {
    switch self {
    case .copy: return Color(hex: "F7E4CE")
    case .send: return Color.clear
    }
  }
}

struct ReferralMiniButton: View {
  let title: String
  let style: ReferralMiniButtonStyle
  var isDisabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Nunito", size: 12))
        .foregroundColor(style.foreground.opacity(isDisabled ? 0.45 : 1))
        .frame(minWidth: 64, minHeight: 28)
        .padding(.horizontal, 18)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(style.background.opacity(isDisabled ? 0.45 : 1))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(style.border.opacity(isDisabled ? 0.45 : 1), lineWidth: style == .copy ? 1 : 0)
        )
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .pointingHandCursor()
  }
}

struct ReferralFieldText: View {
  let icon: String
  let text: String
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(Color(hex: "AFA8A0"))
        .frame(width: 16)

      Text(text)
        .font(.custom("Figtree", size: 12))
        .foregroundColor(color)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.white)
    )
    .textSelection(.enabled)
  }
}

struct ReferralEmailField: View {
  @Binding var email: String
  let isDisabled: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "envelope.fill")
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(Color(hex: "AFA8A0"))
        .frame(width: 16)

      TextField("email@example.com", text: $email)
        .textFieldStyle(.plain)
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color(hex: "333333"))
        .disabled(isDisabled)
    }
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.white)
    )
  }
}

struct ReferralCodeField: View {
  @Binding var code: String
  let isDisabled: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "number")
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(Color(hex: "AFA8A0"))
        .frame(width: 16)

      TextField("ABC123", text: $code)
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundColor(Color(hex: "333333"))
        .disabled(isDisabled)
        .onChange(of: code) { _, newValue in
          let normalized = String(
            newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6)
          )
          if normalized != newValue {
            code = normalized
          }
        }
    }
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.white)
    )
  }
}

struct EmptyReferralState: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.custom("Figtree", size: 12))
      .foregroundColor(Color(hex: "72706D"))
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 24)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.white.opacity(0.6))
      )
  }
}
