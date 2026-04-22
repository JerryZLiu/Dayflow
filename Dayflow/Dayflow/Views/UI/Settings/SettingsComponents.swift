import SwiftUI

// MARK: - Settings design system
//
// One visual language, enforced here. If you find yourself reaching outside
// these tokens / components while building a settings screen, stop and ask
// whether what you're about to build needs its own grammar or whether an
// existing primitive can carry the weight. Almost always the latter.
//
// Principles:
//   1. The warm paper background IS the surface. No cards on top.
//   2. Hierarchy from typography + opacity, not borders + backgrounds.
//   3. One accent color (ink brown) for everything that needs emphasis.
//   4. Exactly three button treatments. No one-offs.
//   5. Rows always read label-left, control-right. Always.

// MARK: - Tokens

enum SettingsStyle {
  // Spacing
  static let sectionSpacing: CGFloat = 44
  static let rowVerticalPadding: CGFloat = 14

  // Type colors
  static let text = Color.black.opacity(0.9)
  static let secondary = Color.black.opacity(0.55)
  static let meta = Color.black.opacity(0.4)

  // Structure
  static let divider = Color.black.opacity(0.08)

  // The one accent — used for primary buttons, active tab pill, progress
  // fills, inline links, focused states. Deliberately the only branded
  // color on this surface.
  static let ink = Color(red: 0.25, green: 0.17, blue: 0)

  // Destructive — only for red-stroked confirm buttons and error copy.
  static let destructive = Color(red: 0.76, green: 0.19, blue: 0.19)

  // Status dots (paired with 13pt labels — the dot carries the color, the
  // label carries the word).
  static let statusGood = Color(red: 0.25, green: 0.62, blue: 0.32)
  static let statusIdle = Color.black.opacity(0.3)
  static let statusWarn = Color(red: 0.86, green: 0.6, blue: 0.1)
  static let statusBad = Color(red: 0.76, green: 0.19, blue: 0.19)
}

// MARK: - SettingsSection
//
// A section is a title (with optional subtitle) and content beneath. No
// container chrome — the paper is the container. Optional right-rail
// trailing view for metadata ("Last updated 3m ago", totals, badges).

struct SettingsSection<Content: View, Trailing: View>: View {
  let title: String
  let subtitle: String?
  let trailing: () -> Trailing
  let content: () -> Content

  init(
    title: String,
    subtitle: String? = nil,
    @ViewBuilder trailing: @escaping () -> Trailing,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.custom("Nunito", size: 17))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          if let subtitle {
            Text(subtitle)
              .font(.custom("Nunito", size: 12))
              .foregroundColor(SettingsStyle.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 12)
        trailing()
      }
      .padding(.bottom, 14)

      content()
    }
  }
}

extension SettingsSection where Trailing == EmptyView {
  init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
  }
}

// MARK: - SettingsRow
//
// Label left, control right, optional subtitle under the label. If the row
// needs a full-width accessory (progress bar, expanded calendar), compose
// it manually — we intentionally keep this component minimal so every row
// on every tab has identical rhythm.

struct SettingsRow<Trailing: View>: View {
  let label: String
  let subtitle: String?
  let showsDivider: Bool
  let trailing: () -> Trailing

  init(
    label: String,
    subtitle: String? = nil,
    showsDivider: Bool = true,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.label = label
    self.subtitle = subtitle
    self.showsDivider = showsDivider
    self.trailing = trailing
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(label)
            .font(.custom("Nunito", size: 14))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
            .fixedSize(horizontal: false, vertical: true)
          if let subtitle {
            Text(subtitle)
              .font(.custom("Nunito", size: 12))
              .foregroundColor(SettingsStyle.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 12)
        trailing()
      }
      .padding(.vertical, SettingsStyle.rowVerticalPadding)

      if showsDivider {
        Rectangle()
          .fill(SettingsStyle.divider)
          .frame(height: 1)
      }
    }
  }
}

extension SettingsRow where Trailing == EmptyView {
  init(label: String, subtitle: String? = nil, showsDivider: Bool = true) {
    self.init(
      label: label, subtitle: subtitle, showsDivider: showsDivider, trailing: { EmptyView() })
  }
}

// MARK: - Buttons
//
// EXACTLY THREE BUTTON TREATMENTS. If you need a fourth, you're wrong.
//
//   SettingsPrimaryButton   — filled ink. One per section, for the action
//                             that defines the section.
//   SettingsSecondaryButton — subtle black.opacity(0.05) fill, ink text.
//                             For alternative actions next to or beneath
//                             a primary (Save/Reset, Open folder, Edit).
//   SettingsLinkButton      — plain ink text + optional arrow glyph. For
//                             navigation away from this surface (release
//                             notes, external docs).

struct SettingsPrimaryButton: View {
  let title: String
  var systemImage: String? = nil
  var isLoading: Bool = false
  var isDisabled: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(.white)
        } else if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
        }
        Text(title)
          .font(.custom("Nunito", size: 13))
          .fontWeight(.semibold)
      }
      .foregroundColor(.white)
      .padding(.horizontal, 18)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(SettingsStyle.ink.opacity(isDisabled ? 0.4 : 1))
      )
    }
    .buttonStyle(SettingsButtonPressStyle())
    .disabled(isDisabled || isLoading)
    .pointingHandCursor()
  }
}

struct SettingsSecondaryButton: View {
  let title: String
  var systemImage: String? = nil
  var isDisabled: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
        }
        Text(title)
          .font(.custom("Nunito", size: 13))
          .fontWeight(.semibold)
      }
      .foregroundColor(SettingsStyle.ink.opacity(isDisabled ? 0.4 : 1))
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color.black.opacity(isDisabled ? 0.02 : 0.05))
      )
    }
    .buttonStyle(SettingsButtonPressStyle())
    .disabled(isDisabled)
    .pointingHandCursor()
  }
}

struct SettingsLinkButton: View {
  let title: String
  var systemImage: String? = "arrow.up.right"
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title)
          .font(.custom("Nunito", size: 13))
          .fontWeight(.semibold)
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
        }
      }
      .foregroundColor(SettingsStyle.ink)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

private struct SettingsButtonPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.85 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

// MARK: - SettingsStatusDot
//
// A 6pt colored dot + 13pt label. Every status in settings reads through
// this component. If something needs a status indicator and can't fit one
// of these four states, the copy is wrong — not the component.

struct SettingsStatusDot: View {
  enum State {
    case good, idle, warn, bad
  }

  let state: State
  let label: String

  private var color: Color {
    switch state {
    case .good: return SettingsStyle.statusGood
    case .idle: return Color.black.opacity(0.5)
    case .warn: return SettingsStyle.statusWarn
    case .bad: return SettingsStyle.statusBad
    }
  }

  /// The dot color and the text color are the same. That redundancy is
  /// the point — color is what your eye reads first on this surface,
  /// not the word. Semibold weight ensures the colored text holds its
  /// ground against the warm paper background without needing a pill.
  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(label)
        .font(.custom("Nunito", size: 13))
        .fontWeight(.semibold)
        .foregroundColor(color)
    }
  }
}

// MARK: - SettingsToggle
//
// The standard on/off control for a settings row. Rendered at ~70% of
// native size so the switch reads as a control, not a billboard — on a
// row with a tight label + subtitle, the full-size NSSwitch visually
// outweighs its own label, which is backwards. Anchored to `.trailing`
// so the scaled switch hugs the right edge of the row cleanly.

struct SettingsToggle: View {
  @Binding var isOn: Bool

  var body: some View {
    Toggle("", isOn: $isOn)
      .toggleStyle(.switch)
      .labelsHidden()
      .scaleEffect(0.72, anchor: .trailing)
      .pointingHandCursor()
  }
}

// MARK: - SettingsBadge
//
// A flat, uppercase chip replacing the legacy `BadgeView` on settings
// surfaces. Deliberately has only two tones: accent (ink-brown fill) for
// the one-per-group "this is the active thing" signal, and neutral (gray
// fill) for everything else. Multiple colored variants were a legacy
// design choice that added noise without carrying semantic value — the
// text already says what the status is; the chip just holds it.

struct SettingsBadge: View {
  let text: String
  var isAccent: Bool = false

  var body: some View {
    Text(text)
      .font(.custom("Nunito", size: 10))
      .fontWeight(.bold)
      .kerning(0.6)
      .foregroundColor(isAccent ? SettingsStyle.ink : SettingsStyle.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(isAccent ? SettingsStyle.ink.opacity(0.1) : Color.black.opacity(0.05))
      )
  }
}

// MARK: - SettingsMetadata
//
// The standard right-rail text treatment. Use this anywhere the trailing
// view is informational text (counts, sizes, percentages, timestamps) so
// every bit of right-rail metadata reads the same.

struct SettingsMetadata: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.custom("Nunito", size: 13))
      .foregroundColor(SettingsStyle.secondary)
  }
}
