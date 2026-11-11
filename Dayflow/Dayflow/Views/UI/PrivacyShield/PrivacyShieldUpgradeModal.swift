import SwiftUI

/// Shown when someone without Dayflow Pro or Plus turns on the Privacy shield (Figma node 2:4271).
/// The list says only what the model actually hides, and the demo masks only the card number.
struct PrivacyShieldUpgradeModal: View {
  @ObservedObject private var shield = PrivacyShield.shared

  private let accent = Color(hex: "F3854B")
  private let ink = Color(hex: "1F1B18")
  private let body2 = Color(hex: "4A4440")

  var body: some View {
    ZStack {
      // The window behind is blurred by MainView; this only dims it a little and closes on click.
      Color.black.opacity(0.08)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { close(method: "backdrop") }

      // Sized to the text, with the demo half stretched to the same height.
      HStack(spacing: 0) {
        details
          .frame(width: 366)
        demo
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: 720)
      .fixedSize(horizontal: false, vertical: true)
      .background(Color.white)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(alignment: .topTrailing) {
        Button(action: { close(method: "close_button") }) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursorOnHover()
        .padding(8)
        .accessibilityLabel(Text("Close"))
      }
      .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
    }
    .onExitCommand { close(method: "escape") }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Dayflow Privacy Shield")
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundColor(ink)
        .padding(.bottom, 16)

      Text(
        "This is a custom trained machine learning model that hides sensitive information in your screen data before it is shared with your selected LLM."
      )
      .font(.custom("Figtree", size: 13))
      .foregroundColor(body2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 10)

      Text(
        "Our privacy model runs entirely on your machine, so these details stay only with you, including:"
      )
      .font(.custom("Figtree", size: 13))
      .foregroundColor(body2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 14)

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
        GridRow {
          checkItem("Bank accounts")
          checkItem("Credit cards")
        }
        GridRow {
          checkItem("Passwords")
          checkItem("API keys")
        }
      }

      Button(action: upgrade) {
        Text("Upgrade to Dayflow Pro or Plus")
          .font(.custom("Figtree", size: 13).weight(.medium))
          .foregroundColor(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 34)
          .background(Capsule().fill(accent))
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .hoverScaleEffect(scale: 1.01)
      .pointingHandCursorOnHover()
      .padding(.top, 32)
      .padding(.bottom, 12)

      privacyFootnote
    }
    .padding(.horizontal, 30)
    .padding(.top, 36)
    .padding(.bottom, 26)
  }

  private func checkItem(_ title: LocalizedStringKey) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(accent)
      Text(title)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(body2)
    }
  }

  private var privacyFootnote: some View {
    (Text("We are committed to protecting your privacy. Learn more through our ")
      + Text("[Privacy Policy](https://dayflow.so/privacy)").foregroundColor(accent)
      + Text("."))
      .font(.custom("Figtree", size: 10.5))
      .foregroundColor(Color(hex: "7A736E"))
      .tint(accent)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// The right half: a soft gradient behind a sample form whose secrets get pixelated one by one.
  private var demo: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(hex: "F8C9A0"), Color(hex: "F3854B"), Color(hex: "E8475A"), Color(hex: "B9B4F5"),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      RadialGradient(
        colors: [Color.white.opacity(0.55), .clear], center: .init(x: 0.45, y: 0.3), startRadius: 0,
        endRadius: 220)

      PrivacyShieldMaskingDemo()
    }
  }

  /// Opens Settings › Account, where the plans (and sign in) live.
  private func upgrade() {
    shield.upgradeRequested()
    NotificationCenter.default.post(name: .navigateToAccountSettings, object: nil)
  }

  private func close(method: String) {
    shield.upgradeDismissed(method: method)
  }
}

/// A sample form with a credit card number, an API key and a password. On a loop, each value is pixelated in
/// turn, left to right behind a bright sweep line, the way the Privacy Shield hides them before a screenshot
/// is stored.
private struct PrivacyShieldMaskingDemo: View {
  private struct Secret {
    let label: LocalizedStringKey
    let value: String
  }

  /// Made-up values that look like the real thing.
  private let secrets = [
    Secret(label: "Card number", value: "4821 7730 1956 2284"),
    Secret(label: "API key", value: "sk-proj-7Fq2xL9mWc4RbT"),
    Secret(label: "Password", value: "Blue-Harbor-2291!"),
  ]

  // One loop: everything readable, then each value masked in turn, a hold, then the masks fade away.
  private let readableHold = 1.0
  private let maskDuration = 0.7
  private let maskedHold = 1.8
  private let fadeDuration = 0.4

  private var loopDuration: Double {
    readableHold + maskDuration * Double(secrets.count) + maskedHold + fadeDuration
  }

  private let ink = Color(hex: "1F1B18")
  private let label = Color(hex: "7A736E")

  var body: some View {
    TimelineView(.animation) { context in
      let time = loopTime(context.date)
      VStack(alignment: .leading, spacing: 12) {
        ForEach(secrets.indices, id: \.self) { index in
          field(
            secrets[index], progress: maskProgress(of: index, at: time),
            opacity: maskOpacity(at: time))
        }
      }
      .padding(16)
      .frame(width: 300, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.92)))
      .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("A credit card number, an API key and a password being hidden"))
  }

  private func field(_ secret: Secret, progress: Double, opacity: Double) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(secret.label)
        .font(.custom("Figtree", size: 10.5).weight(.medium))
        .foregroundColor(label)
      Text(secret.value)
        .font(.system(size: 12.5, design: .monospaced))
        .foregroundColor(ink)
        .lineLimit(1)
        .overlay {
          GeometryReader { geo in
            let maskedWidth = geo.size.width * progress
            ZStack(alignment: .topLeading) {
              PixelatedBlock(width: geo.size.width + 4, height: geo.size.height + 4)
                .offset(x: -2, y: -2)
                .mask(alignment: .leading) {
                  Rectangle().frame(width: maskedWidth + 2)
                }
              // The sweep line at the edge of the mask while it moves.
              if progress > 0 && progress < 1 {
                LinearGradient(
                  colors: [.white.opacity(0), .white, .white.opacity(0)], startPoint: .top,
                  endPoint: .bottom
                )
                .frame(width: 2, height: geo.size.height + 10)
                .offset(x: maskedWidth - 1, y: -5)
                .shadow(color: .white, radius: 3)
              }
            }
            .opacity(opacity)
          }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "F7F5F3")))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: "E6E1DC"), lineWidth: 1))
    }
  }

  private func loopTime(_ date: Date) -> Double {
    date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loopDuration)
  }

  /// How much of a value is hidden, 0 to 1. The values are masked one after another.
  private func maskProgress(of index: Int, at time: Double) -> Double {
    let start = readableHold + maskDuration * Double(index)
    let linear = min(max((time - start) / maskDuration, 0), 1)
    return linear * linear * (3 - 2 * linear)  // ease in and out
  }

  /// The masks fade out at the end of each loop, so the values reappear instead of popping back.
  private func maskOpacity(at time: Double) -> Double {
    let fadeStart = loopDuration - fadeDuration
    return 1 - min(max((time - fadeStart) / fadeDuration, 0), 1)
  }
}

/// Blue-gray squares standing in for a pixelated value, like the Privacy Shield leaves on a screenshot.
private struct PixelatedBlock: View {
  let width: CGFloat
  let height: CGFloat

  private let cell: CGFloat = 6
  private let shades = ["9DB4F5", "B7C7F7", "8FA7EE", "C8D4F9", "A6BBF3", "D3DCFA"]

  var body: some View {
    let columns = Int((width / cell).rounded(.up))
    let rows = Int((height / cell).rounded(.up))
    VStack(spacing: 0) {
      ForEach(0..<rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<columns, id: \.self) { column in
            Rectangle()
              .fill(Color(hex: shades[(row * 7 + column * 3) % shades.count]))
              .frame(width: cell, height: cell)
          }
        }
      }
    }
    .frame(width: width, height: height, alignment: .topLeading)
    .clipped()
  }
}
