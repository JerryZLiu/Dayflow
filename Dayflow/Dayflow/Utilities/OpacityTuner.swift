//
//  OpacityTuner.swift
//  Dayflow
//
//  Dev tool for iterating on surface transparency. A floating button
//  (bottom-left, above the background tuner) opens a popover with three
//  sliders: the overall window background, the timeline's right panel,
//  and the white body of activity cards. 0% is fully transparent, 100%
//  fully opaque. Unset sliders fall back to the theme's shipped values.
//

import SwiftUI

// MARK: - Model

struct OpacityOverrides: Codable, Equatable {
  /// Each value is an absolute alpha in 0...1; nil keeps the theme default.
  var background: Double?
  var rightPanel: Double?
  var card: Double?

  static let none = OpacityOverrides()
}

@MainActor
final class OpacityTuner: ObservableObject {
  static let shared = OpacityTuner()

  @Published var overrides: OpacityOverrides {
    didSet { persist() }
  }

  private static let storageKey = "opacityTunerOverrides"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(OpacityOverrides.self, from: data)
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

private struct OpacityOverridesKey: EnvironmentKey {
  static let defaultValue = OpacityOverrides.none
}

extension EnvironmentValues {
  var opacityOverrides: OpacityOverrides {
    get { self[OpacityOverridesKey.self] }
    set { self[OpacityOverridesKey.self] = newValue }
  }
}

extension View {
  /// Attach once at the window root; descendants read `\.opacityOverrides`.
  func resolveOpacityOverrides() -> some View {
    modifier(OpacityOverridesResolver())
  }
}

private struct OpacityOverridesResolver: ViewModifier {
  @ObservedObject private var tuner = OpacityTuner.shared
  @ObservedObject private var preview = StylePreview.shared
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    // Tuned opacities are a light-mode adjustment on the "After" styling;
    // dark mode and the "Before" preview keep the theme's shipped values.
    content.environment(
      \.opacityOverrides,
      colorScheme == .dark || !preview.showAfter ? .none : tuner.overrides)
  }
}

// MARK: - Color helpers

extension Color {
  /// Replaces this color's alpha with `value` (absolute, not multiplied);
  /// nil returns the color unchanged.
  func opacityOverride(_ value: Double?) -> Color {
    guard let value else { return self }
    let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
    return Color(
      .sRGB,
      red: ns.redComponent,
      green: ns.greenComponent,
      blue: ns.blueComponent,
      opacity: value
    )
  }

  /// The color's current alpha, used to seed sliders with the theme default.
  var alphaValue: Double {
    Double((NSColor(self).usingColorSpace(.sRGB) ?? .white).alphaComponent)
  }
}

// MARK: - Floating button + popover

struct OpacityTunerButton: View {
  @ObservedObject private var tuner = OpacityTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "circle.lefthalf.filled")
        .font(.system(size: 13, weight: .medium))
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
      OpacityTunerPanel()
    }
    .accessibilityLabel("Adjust surface opacity")
  }
}

private struct OpacityTunerPanel: View {
  @ObservedObject private var tuner = OpacityTuner.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Opacity")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") { tuner.reset() }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }

      opacitySlider(
        "Background",
        value: binding(\.background, default: 1.0)
      )
      opacitySlider(
        "Right panel",
        value: binding(\.rightPanel, default: theme.rightPanelFill.alphaValue)
      )
      opacitySlider(
        "Card white",
        value: binding(\.card, default: theme.cardFill.alphaValue)
      )

      if theme.isDark {
        Text("Overrides apply in light mode only.")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
      }
    }
    .padding(16)
    .frame(width: 260)
  }

  private func binding(
    _ keyPath: WritableKeyPath<OpacityOverrides, Double?>, default defaultValue: Double
  ) -> Binding<Double> {
    Binding(
      get: { tuner.overrides[keyPath: keyPath] ?? defaultValue },
      set: { tuner.overrides[keyPath: keyPath] = $0 }
    )
  }

  @ViewBuilder
  private func opacitySlider(_ title: String, value: Binding<Double>) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .frame(width: 72, alignment: .leading)
      Slider(value: value, in: 0...1)
      Text(String(format: "%.0f%%", value.wrappedValue * 100))
        .font(.system(size: 10).monospacedDigit())
        .foregroundColor(.secondary)
        .frame(width: 34, alignment: .trailing)
    }
  }
}
