//
//  CardColorTuner.swift
//  Dayflow
//
//  Dev tool for iterating on the dark-mode activity card background. A
//  floating button (bottom-left, with the other tuners) opens a popover with
//  a color picker plus a hex field for the card fill. The override applies
//  in dark mode only; unset keeps the theme's shipped value.
//

import SwiftUI

// MARK: - Model

struct CardColorOverrides: Codable, Equatable {
  /// 6-digit sRGB hex (no '#') replacing the dark theme's card fill.
  /// nil keeps the theme's shipped value.
  var cardFillHex: String?

  static let none = CardColorOverrides()
}

@MainActor
final class CardColorTuner: ObservableObject {
  static let shared = CardColorTuner()

  @Published var overrides: CardColorOverrides {
    didSet { persist() }
  }

  private static let storageKey = "cardColorTunerOverrides"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(CardColorOverrides.self, from: data)
    {
      overrides = decoded
    } else {
      overrides = .none
    }
  }

  func reset() {
    overrides = .none
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(overrides) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}

// MARK: - Environment plumbing

private struct CardColorOverridesKey: EnvironmentKey {
  static let defaultValue = CardColorOverrides.none
}

extension EnvironmentValues {
  var cardColorOverrides: CardColorOverrides {
    get { self[CardColorOverridesKey.self] }
    set { self[CardColorOverridesKey.self] = newValue }
  }
}

extension View {
  /// Attach once at the window root; descendants read `\.cardColorOverrides`.
  func resolveCardColorOverrides() -> some View {
    modifier(CardColorOverridesResolver())
  }
}

private struct CardColorOverridesResolver: ViewModifier {
  @ObservedObject private var tuner = CardColorTuner.shared
  @ObservedObject private var preview = StylePreview.shared
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    // The tuned fill is a dark-mode adjustment on the "After" styling;
    // light mode and the "Before" preview keep the theme's shipped values.
    content.environment(
      \.cardColorOverrides,
      colorScheme == .dark && preview.showAfter ? tuner.overrides : .none)
  }
}

extension Color {
  /// The tuned card fill when set, otherwise this color.
  func cardFillOverride(_ hex: String?) -> Color {
    guard let hex else { return self }
    return Color(hex: hex)
  }
}

// MARK: - Floating button + popover

struct CardColorTunerButton: View {
  @ObservedObject private var tuner = CardColorTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "rectangle.fill.on.rectangle.fill")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(theme.isDark ? .white : Color(hex: "2B2B2B"))
        .frame(width: 30, height: 30)
        .background(
          Circle()
            .fill(theme.isDark ? Color(hex: "1C1E2A").opacity(0.92) : Color.white.opacity(0.92))
            .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.18), radius: 10, y: 3)
        )
        .overlay(
          Circle()
            .stroke(
              theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.1), lineWidth: 1)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .opacity(isHovering || isPresenting ? 1.0 : 0.55)
    .scaleEffect(isHovering || isPresenting ? 1.0 : 0.96, anchor: .bottomLeading)
    .animation(.easeOut(duration: 0.15), value: isHovering)
    .onHover { isHovering = $0 }
    .popover(isPresented: $isPresenting, arrowEdge: .trailing) {
      CardColorTunerPanel()
    }
    .accessibilityLabel("Adjust dark-mode card background")
  }
}

private struct CardColorTunerPanel: View {
  @ObservedObject private var tuner = CardColorTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var hexText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Dark card background")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") {
          tuner.reset()
          hexText = currentHex
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
      }

      if !theme.isDark {
        Text("Switch to dark mode to see changes.")
          .font(.system(size: 11))
          .foregroundColor(.orange)
      }

      HStack(spacing: 8) {
        ColorPicker(
          "",
          selection: Binding(
            get: { Color(hex: currentHex) },
            set: {
              tuner.overrides.cardFillHex = $0.tunerHexString
              hexText = $0.tunerHexString
            }
          ),
          supportsOpacity: false
        )
        .labelsHidden()
        .frame(width: 34)

        Text("#")
          .font(.system(size: 12).monospaced())
          .foregroundColor(.secondary)

        TextField("Hex", text: $hexText)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12).monospaced())
          .frame(width: 84)
          .onSubmit { commitHex() }

        RoundedRectangle(cornerRadius: 6)
          .fill(Color(hex: currentHex))
          .frame(width: 34, height: 24)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color.primary.opacity(0.15), lineWidth: 1)
          )
      }

      if !hexIsValid {
        Text("Enter a 6-digit hex color (e.g. 383951).")
          .font(.system(size: 10))
          .foregroundColor(.orange)
      }

      Text("Applies to the timeline activity cards. Press return to apply a typed hex.")
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(width: 260)
    .onAppear { hexText = currentHex }
  }

  /// The shipped dark "After" card fill is opaque, so its hex round-trips
  /// cleanly through tunerHexString as the picker's starting point.
  private var currentHex: String {
    tuner.overrides.cardFillHex ?? theme.cardFill.tunerHexString
  }

  private var hexIsValid: Bool {
    sanitizedHex(hexText) != nil
  }

  private func commitHex() {
    guard let hex = sanitizedHex(hexText) else { return }
    tuner.overrides.cardFillHex = hex
    hexText = hex
  }

  private func sanitizedHex(_ raw: String) -> String? {
    let trimmed = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
      .uppercased()
    guard trimmed.count == 6, trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
    return trimmed
  }
}
