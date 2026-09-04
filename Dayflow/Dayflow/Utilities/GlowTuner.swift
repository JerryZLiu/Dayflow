//
//  GlowTuner.swift
//  Dayflow
//
//  Dev tool for iterating on dark-mode glows. A floating button
//  (bottom-left, with the other tuners) opens a popover with sliders for
//  the activity cards' inner glow and the focus summary boxes' border
//  glow: opacity, spread (stroke width), and blur for each. Overrides
//  apply in dark mode only; unset sliders keep the theme's shipped values.
//

import SwiftUI

// MARK: - Model

struct GlowOverrides: Codable, Equatable {
  /// Opacities are absolute alphas in 0...1; spread/blur are points.
  /// nil keeps the theme / call-site default.
  var cardOpacity: Double?
  var cardSpread: Double?
  var cardBlur: Double?
  var boxOpacity: Double?
  var boxSpread: Double?
  var boxBlur: Double?
  /// Alpha of the focus boxes' background fill itself, not just the glow.
  var boxFillOpacity: Double?

  static let none = GlowOverrides()
}

@MainActor
final class GlowTuner: ObservableObject {
  static let shared = GlowTuner()

  @Published var overrides: GlowOverrides {
    didSet { persist() }
  }

  private static let storageKey = "glowTunerOverrides"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(GlowOverrides.self, from: data)
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

private struct GlowOverridesKey: EnvironmentKey {
  static let defaultValue = GlowOverrides.none
}

extension EnvironmentValues {
  var glowOverrides: GlowOverrides {
    get { self[GlowOverridesKey.self] }
    set { self[GlowOverridesKey.self] = newValue }
  }
}

extension View {
  /// Attach once at the window root; descendants read `\.glowOverrides`.
  func resolveGlowOverrides() -> some View {
    modifier(GlowOverridesResolver())
  }
}

private struct GlowOverridesResolver: ViewModifier {
  @ObservedObject private var tuner = GlowTuner.shared
  @ObservedObject private var preview = StylePreview.shared
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    // Tuned glows are a dark-mode adjustment on the "After" styling;
    // light mode and the "Before" preview keep the theme's shipped values.
    content.environment(
      \.glowOverrides,
      colorScheme == .dark && preview.showAfter ? tuner.overrides : .none)
  }
}

// MARK: - Floating button + popover

struct GlowTunerButton: View {
  @ObservedObject private var tuner = GlowTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "sparkles")
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
      GlowTunerPanel()
    }
    .accessibilityLabel("Adjust dark-mode glows")
  }
}

private struct GlowTunerPanel: View {
  @ObservedObject private var tuner = GlowTuner.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Dark glows")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") { tuner.reset() }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }

      if !theme.isDark {
        Text("Switch to dark mode to see changes.")
          .font(.system(size: 11))
          .foregroundColor(.orange)
      }

      section("Card glow")
      labeledSlider(
        "Opacity", value: binding(\.cardOpacity, default: theme.cardInnerGlow.alphaValue),
        range: 0...1, percent: true)
      labeledSlider(
        "Spread", value: binding(\.cardSpread, default: 3), range: 0...12)
      labeledSlider(
        "Blur", value: binding(\.cardBlur, default: 3), range: 0...12)

      section("Focus box glow")
      labeledSlider(
        "Opacity", value: binding(\.boxOpacity, default: theme.summaryCardInnerGlow.alphaValue),
        range: 0...1, percent: true)
      labeledSlider(
        "Spread", value: binding(\.boxSpread, default: 3), range: 0...12)
      labeledSlider(
        "Blur", value: binding(\.boxBlur, default: 2.5), range: 0...12)

      section("Focus box background")
      labeledSlider(
        "Opacity", value: binding(\.boxFillOpacity, default: theme.summaryCardFill.alphaValue),
        range: 0...1, percent: true)
    }
    .padding(16)
    .frame(width: 270)
  }

  private func binding(
    _ keyPath: WritableKeyPath<GlowOverrides, Double?>, default defaultValue: Double
  ) -> Binding<Double> {
    Binding(
      get: { tuner.overrides[keyPath: keyPath] ?? defaultValue },
      set: { tuner.overrides[keyPath: keyPath] = $0 }
    )
  }

  @ViewBuilder
  private func section(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(.secondary)
  }

  @ViewBuilder
  private func labeledSlider(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool = false
  ) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .frame(width: 52, alignment: .leading)
      Slider(value: value, in: range)
      Text(
        percent
          ? String(format: "%.0f%%", value.wrappedValue * 100)
          : String(format: "%.1fpt", value.wrappedValue)
      )
      .font(.system(size: 10).monospacedDigit())
      .foregroundColor(.secondary)
      .frame(width: 40, alignment: .trailing)
    }
  }
}
