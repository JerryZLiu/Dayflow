import SwiftUI

/// The "Privacy shield" pill in the timeline footer (Figma: Dayflow - minor adjustments, node 2:1508).
/// Without Dayflow Pro or Plus, tapping it opens the upgrade modal instead of turning it on.
struct PrivacyShieldToggle: View {
  @Environment(\.dayflowTheme) private var theme
  @ObservedObject private var shield = PrivacyShield.shared

  var body: some View {
    Button(action: { shield.toggleTapped() }) {
      HStack(spacing: 4) {
        icon
          .frame(width: 12, height: 12)
        Text("Privacy shield")
          .font(Font.custom("Figtree", size: 11.5).weight(.medium))
          .foregroundColor(theme.secondaryButtonText)
          .fixedSize()
        Spacer(minLength: 8)
        PrivacyShieldSwitch(isOn: shield.showsOn)
      }
      .padding(.leading, 6)
      .padding(.trailing, 6)
      .frame(width: 144, height: 28)
      .background(theme.secondaryButtonFill)
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7).strokeBorder(theme.secondaryButtonBorder, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .help(helpText)
    .accessibilityLabel(Text("Privacy shield"))
    .accessibilityValue(Text(shield.showsOn ? "On" : "Off"))
  }

  @ViewBuilder
  private var icon: some View {
    switch shield.status {
    case .preparing:
      ProgressView()
        .scaleEffect(0.4)
        .frame(width: 12, height: 12)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .resizable()
        .scaledToFit()
        .foregroundColor(theme.accent)
    case .on, .off:
      // Stand-in for the Figma shield icon (node 2:1510), which couldn't be exported.
      Image(systemName: "shield.lefthalf.filled")
        .resizable()
        .scaledToFit()
        .foregroundColor(theme.accent)
    }
  }

  private var helpText: String {
    switch shield.status {
    case .preparing:
      return String(
        localized: "Getting Privacy Shield ready. Screenshots are saved as usual until it's done.")
    case .failed:
      return String(
        localized: "Privacy Shield couldn't get its model. Turn it off and on again to retry.")
    case .on:
      return String(
        localized: "Hiding passwords, API keys, cards and bank details in your screenshots.")
    case .off:
      return String(
        localized: "Hide passwords, API keys, cards and bank details in your screenshots.")
    }
  }
}

/// The small 28 x 16 switch inside the pill.
private struct PrivacyShieldSwitch: View {
  @Environment(\.dayflowTheme) private var theme
  let isOn: Bool

  var body: some View {
    ZStack(alignment: isOn ? .trailing : .leading) {
      Capsule()
        .fill(isOn ? theme.accent : theme.secondaryButtonBorder.opacity(0.6))
      Circle()
        .fill(Color.white)
        .frame(width: 12, height: 12)
        .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
        .padding(2)
    }
    .frame(width: 28, height: 16)
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
  }
}

/// The "NEW" callout above the toggle (Figma node 2:2100). Shown until it's closed or the toggle is used.
struct PrivacyShieldCallout: View {
  @Environment(\.dayflowTheme) private var theme
  @ObservedObject private var shield = PrivacyShield.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("NEW")
          .font(Font.custom("Figtree", size: 9).weight(.bold))
          .foregroundColor(.white)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: "B9B4F5")))
        Text("Privacy shield for extra security")
          .font(Font.custom("Figtree", size: 12).weight(.semibold))
          .foregroundColor(theme.textPrimary)
        Spacer(minLength: 0)
        Button(action: { shield.dismissCallout() }) {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(theme.textTertiary)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursorOnHover()
        .accessibilityLabel(Text("Close"))
      }
      Text("Turn it on to hide passwords, API keys, and card and bank details in your screenshots.")
        .font(Font.custom("Figtree", size: 11))
        .foregroundColor(theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(9)
    .frame(width: 239, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardFill))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.cardBorder, lineWidth: 1))
    .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }
}

/// The footer item: the toggle, with the "NEW" callout floating above it until it's dismissed.
struct PrivacyShieldFooterItem: View {
  @ObservedObject private var shield = PrivacyShield.shared

  var body: some View {
    PrivacyShieldToggle()
      .overlay(alignment: .bottomTrailing) {
        if !shield.calloutDismissed && !shield.showsOn {
          PrivacyShieldCallout()
            .fixedSize()
            .offset(y: -38)
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.85), value: shield.calloutDismissed)
  }
}

/// Puts the upgrade modal over the main window while `PrivacyShield.showUpgrade` is set.
struct PrivacyShieldUpgradeHost: View {
  @ObservedObject private var shield = PrivacyShield.shared

  var body: some View {
    ZStack {
      if shield.showUpgrade {
        PrivacyShieldUpgradeModal()
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.2), value: shield.showUpgrade)
  }
}
