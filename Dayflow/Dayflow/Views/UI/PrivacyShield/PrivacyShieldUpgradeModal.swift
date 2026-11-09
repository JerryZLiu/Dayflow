import SwiftUI

/// Shown when someone without Dayflow Pro or Plus turns on the Privacy shield (Figma node 2:4271).
/// The list says only what the model actually hides, and the demo masks only the card number.
struct PrivacyShieldUpgradeModal: View {
  @ObservedObject private var shield = PrivacyShield.shared
  @ObservedObject private var authManager = DayflowAuthManager.shared
  @State private var showSignIn = false

  private let accent = Color(hex: "F3854B")
  private let ink = Color(hex: "1F1B18")
  private let body2 = Color(hex: "4A4440")

  var body: some View {
    ZStack {
      Color.black.opacity(0.18)
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .onTapGesture { close() }

      HStack(spacing: 0) {
        details
          .frame(width: 366)
        demo
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: 720, height: 440)
      .background(Color.white)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(alignment: .topTrailing) {
        Button(action: close) {
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
    .sheet(isPresented: $showSignIn) {
      DayflowSignInSheet(onDismiss: { showSignIn = false })
    }
    .onChange(of: shield.isEntitled) { _, entitled in
      // Checkout finished (or the account already had a plan once signed in): turn the shield on.
      guard entitled else { return }
      shield.showUpgrade = false
      shield.setEnabled(true)
    }
    .onExitCommand { close() }
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
          checkItem("Cards")
        }
        GridRow {
          checkItem("Passwords")
          checkItem("API keys")
        }
      }

      Spacer(minLength: 20)

      Button(action: upgrade) {
        Text(authManager.isSignedIn ? "Upgrade to Dayflow Pro" : "Sign in to upgrade")
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
      .padding(.bottom, 12)

      privacyFootnote
    }
    .padding(.horizontal, 30)
    .padding(.top, 44)
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

  /// The right half: a soft gradient with a sample email where only the card number is pixelated.
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

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("MW")
            .font(.custom("Figtree", size: 9).weight(.semibold))
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(hex: "9DB4F5")))
          Text("Maya Williams <maya.williams@gmail.com>")
            .font(.custom("Figtree", size: 12).weight(.medium))
            .foregroundColor(ink)
            .lineLimit(1)
        }
        Text("Call me at (415) 555-0132 when you land.")
        Text("Ship the badges to 2207 Hayes St, SF")
        HStack(spacing: 4) {
          Text("Card on file")
          PixelatedBlock(width: 92)
          Text("4821")
        }
      }
      .font(.custom("Figtree", size: 12))
      .foregroundColor(body2)
      .padding(16)
      .frame(width: 316, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.92)))
      .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
  }

  private func upgrade() {
    guard authManager.isSignedIn else {
      showSignIn = true
      return
    }
    AnalyticsService.shared.capture("privacy_shield_upgrade_clicked")
    Task { await authManager.openBillingCheckout() }
  }

  private func close() {
    shield.showUpgrade = false
  }
}

/// Blue-gray squares standing in for a pixelated value, like the Privacy Shield leaves on a screenshot.
private struct PixelatedBlock: View {
  let width: CGFloat

  private let shades = ["9DB4F5", "B7C7F7", "8FA7EE", "C8D4F9", "A6BBF3", "D3DCFA"]

  var body: some View {
    let columns = Int(width / 7)
    VStack(spacing: 0) {
      ForEach(0..<2, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<columns, id: \.self) { column in
            Rectangle()
              .fill(Color(hex: shades[(row * 7 + column * 3) % shades.count]))
              .frame(width: 7, height: 7)
          }
        }
      }
    }
    .accessibilityLabel(Text("Hidden card number"))
  }
}
