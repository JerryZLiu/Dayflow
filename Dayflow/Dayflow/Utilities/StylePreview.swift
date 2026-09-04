//
//  StylePreview.swift
//  Dayflow
//
//  The refreshed styling shipped as the only mode; `showAfter` is now a
//  constant so the many views branching on `\.stylePreviewAfter` (or
//  `StylePreview.shared.showAfter` outside the view hierarchy) always get
//  the refreshed look.
//

import SwiftUI

@MainActor
final class StylePreview: ObservableObject {
  static let shared = StylePreview()

  let showAfter = true

  private init() {}
}

// MARK: - Standup style tweaks (light mode)

/// Dev-only knobs for iterating on the standup card's light-mode styling.
/// Values persist across launches so tweaks survive a rebuild.
@MainActor
final class StandupStyleTweaks: ObservableObject {
  static let shared = StandupStyleTweaks()

  // Storage keys are versioned; bump one when its default changes so the new
  // default wins over a previously persisted value.
  @Published var strokeHex: String { didSet { save(strokeHex, "standupTweakStrokeHexV2") } }
  @Published var headingHex: String { didSet { save(headingHex, "standupTweakHeadingHexV2") } }
  @Published var shadowColorHex: String { didSet { save(shadowColorHex, "standupTweakShadowHex") } }
  @Published var shadowBlur: Double { didSet { save(shadowBlur, "standupTweakShadowBlur") } }
  @Published var shadowDistance: Double { didSet { save(shadowDistance, "standupTweakShadowDistance") } }
  @Published var shadowOpacity: Double { didSet { save(shadowOpacity, "standupTweakShadowOpacity") } }
  @Published var bottomSpace: Double { didSet { save(bottomSpace, "standupTweakBottomSpaceV2") } }
  @Published var horizontalMargin: Double { didSet { save(horizontalMargin, "standupTweakHorizontalMarginV2") } }
  @Published var todayPadding: Double { didSet { save(todayPadding, "standupTweakTodayPadding") } }
  @Published var sectionGap: Double { didSet { save(sectionGap, "standupTweakSectionGapV2") } }

  static let defaultStrokeHex = "DADADA"
  static let defaultHeadingHex = "90837A"
  static let defaultShadowColorHex = "000000"
  static let defaultShadowBlur: Double = 8
  static let defaultShadowDistance: Double = 4
  static let defaultShadowOpacity: Double = 0.1
  static let defaultBottomSpace: Double = 52
  static let defaultHorizontalMargin: Double = 52
  // Extra inset applied to the "today so far" grid within the content column.
  static let defaultTodayPadding: Double = 0
  // Total gap between the "today so far" grid and the standup section.
  static let defaultSectionGap: Double = 60

  var strokeColor: Color { Color(hex: sanitized(strokeHex, fallback: Self.defaultStrokeHex)) }
  var headingColor: Color { Color(hex: sanitized(headingHex, fallback: Self.defaultHeadingHex)) }
  var shadowColor: Color {
    Color(hex: sanitized(shadowColorHex, fallback: Self.defaultShadowColorHex))
      .opacity(shadowOpacity)
  }

  func reset() {
    strokeHex = Self.defaultStrokeHex
    headingHex = Self.defaultHeadingHex
    shadowColorHex = Self.defaultShadowColorHex
    shadowBlur = Self.defaultShadowBlur
    shadowDistance = Self.defaultShadowDistance
    shadowOpacity = Self.defaultShadowOpacity
    bottomSpace = Self.defaultBottomSpace
    horizontalMargin = Self.defaultHorizontalMargin
    todayPadding = Self.defaultTodayPadding
    sectionGap = Self.defaultSectionGap
  }

  private init() {
    let defaults = UserDefaults.standard
    strokeHex = defaults.string(forKey: "standupTweakStrokeHexV2") ?? Self.defaultStrokeHex
    headingHex = defaults.string(forKey: "standupTweakHeadingHexV2") ?? Self.defaultHeadingHex
    shadowColorHex = defaults.string(forKey: "standupTweakShadowHex") ?? Self.defaultShadowColorHex
    shadowBlur =
      defaults.object(forKey: "standupTweakShadowBlur") as? Double ?? Self.defaultShadowBlur
    shadowDistance =
      defaults.object(forKey: "standupTweakShadowDistance") as? Double ?? Self.defaultShadowDistance
    shadowOpacity =
      defaults.object(forKey: "standupTweakShadowOpacity") as? Double ?? Self.defaultShadowOpacity
    bottomSpace =
      defaults.object(forKey: "standupTweakBottomSpaceV2") as? Double ?? Self.defaultBottomSpace
    horizontalMargin =
      defaults.object(forKey: "standupTweakHorizontalMarginV2") as? Double
      ?? Self.defaultHorizontalMargin
    todayPadding =
      defaults.object(forKey: "standupTweakTodayPadding") as? Double ?? Self.defaultTodayPadding
    sectionGap =
      defaults.object(forKey: "standupTweakSectionGapV2") as? Double ?? Self.defaultSectionGap
  }

  private func save(_ value: Any, _ key: String) {
    UserDefaults.standard.set(value, forKey: key)
  }

  private func sanitized(_ hex: String, fallback: String) -> String {
    let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
    let isValid = cleaned.count == 6 && cleaned.allSatisfy { $0.isHexDigit }
    return isValid ? cleaned : fallback
  }
}

// MARK: - Environment plumbing

private struct StylePreviewAfterKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  /// Always true now that the refreshed styling shipped.
  var stylePreviewAfter: Bool {
    get { self[StylePreviewAfterKey.self] }
    set { self[StylePreviewAfterKey.self] = newValue }
  }
}

extension View {
  /// Attach once at the window root; descendants read `\.stylePreviewAfter`.
  func resolveStylePreview() -> some View {
    modifier(StylePreviewResolver())
  }
}

private struct StylePreviewResolver: ViewModifier {
  @ObservedObject private var preview = StylePreview.shared

  func body(content: Content) -> some View {
    content.environment(\.stylePreviewAfter, preview.showAfter)
  }
}

// MARK: - Tweaks button

/// Floating tuner-style button that opens the standup style tweaks panel.
/// Lives in the dev controls cluster alongside the other tuner buttons.
struct StandupTweaksButton: View {
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "slider.horizontal.3")
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
      StandupStyleTweaksPanel()
    }
    .accessibilityLabel("Standup style tweaks")
  }
}

// MARK: - Tweaks panel

/// Popover with light-mode styling knobs for the standup card.
struct StandupStyleTweaksPanel: View {
  @ObservedObject private var tweaks = StandupStyleTweaks.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Standup card — light mode")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Button("Reset") { tweaks.reset() }
          .font(.system(size: 11))
      }

      hexRow(label: "Stroke color", hex: $tweaks.strokeHex, swatch: tweaks.strokeColor)
      hexRow(label: "Heading text", hex: $tweaks.headingHex, swatch: tweaks.headingColor)

      Divider()

      Text("Drop shadow")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.secondary)

      hexRow(
        label: "Color",
        hex: $tweaks.shadowColorHex,
        swatch: Color(hex: tweaks.shadowColorHex.count == 6 ? tweaks.shadowColorHex : "000000")
      )
      sliderRow(label: "Blur", value: $tweaks.shadowBlur, range: 0...40, format: "%.0f")
      sliderRow(label: "Distance", value: $tweaks.shadowDistance, range: 0...30, format: "%.0f")
      sliderRow(label: "Opacity", value: $tweaks.shadowOpacity, range: 0...1, format: "%.2f")

      Divider()

      Text("Layout (light + dark)")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.secondary)

      sliderRow(label: "Space below", value: $tweaks.bottomSpace, range: 0...120, format: "%.0f")
      sliderRow(label: "Side margin", value: $tweaks.horizontalMargin, range: 0...120, format: "%.0f")
      sliderRow(label: "Today pad", value: $tweaks.todayPadding, range: 0...120, format: "%.0f")
      sliderRow(label: "Section gap", value: $tweaks.sectionGap, range: 0...120, format: "%.0f")
    }
    .padding(16)
    .frame(width: 280)
  }

  private func hexRow(label: String, hex: Binding<String>, swatch: Color) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 11))
        .frame(width: 76, alignment: .leading)
      RoundedRectangle(cornerRadius: 3)
        .fill(swatch)
        .frame(width: 16, height: 16)
        .overlay(
          RoundedRectangle(cornerRadius: 3)
            .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
        )
      TextField("Hex", text: hex)
        .font(.system(size: 11, design: .monospaced))
        .textFieldStyle(.roundedBorder)
    }
  }

  private func sliderRow(
    label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String
  ) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 11))
        .frame(width: 76, alignment: .leading)
      Slider(value: value, in: range)
      Text(String(format: format, value.wrappedValue))
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.secondary)
        .frame(width: 34, alignment: .trailing)
    }
  }
}
