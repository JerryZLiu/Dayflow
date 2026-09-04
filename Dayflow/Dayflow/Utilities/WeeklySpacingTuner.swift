//
//  WeeklySpacingTuner.swift
//  Dayflow
//
//  Dev tool for iterating on the weekly view's vertical rhythm. A floating
//  button (bottom-left, alongside the other tuners) opens a popover with two
//  sliders: the vertical spacing between weekly sections, and the gap between
//  the date header and the rest of the dashboard. Unset sliders fall back to
//  the shipped layout values.
//

import SwiftUI

// MARK: - Model

struct WeeklySpacingOverrides: Codable, Equatable {
  /// Points; nil keeps the layout default.
  var sectionSpacing: Double?
  var headerSpacing: Double?

  static let none = WeeklySpacingOverrides()
}

@MainActor
final class WeeklySpacingTuner: ObservableObject {
  static let shared = WeeklySpacingTuner()

  @Published var overrides: WeeklySpacingOverrides {
    didSet { persist() }
  }

  private static let storageKey = "weeklySpacingTunerOverrides"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(WeeklySpacingOverrides.self, from: data)
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

// MARK: - Floating button + popover

struct WeeklySpacingTunerButton: View {
  @ObservedObject private var tuner = WeeklySpacingTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "arrow.up.and.down.text.horizontal")
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
      WeeklySpacingTunerPanel()
    }
    .accessibilityLabel("Adjust weekly view spacing")
  }
}

private struct WeeklySpacingTunerPanel: View {
  @ObservedObject private var tuner = WeeklySpacingTuner.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Weekly spacing")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") { tuner.reset() }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }

      spacingSlider(
        "Sections",
        value: binding(\.sectionSpacing, default: 32),
        range: 0...80
      )
      spacingSlider(
        "Below date",
        value: binding(\.headerSpacing, default: 40),
        range: 0...80
      )
    }
    .padding(16)
    .frame(width: 260)
  }

  private func binding(
    _ keyPath: WritableKeyPath<WeeklySpacingOverrides, Double?>, default defaultValue: Double
  ) -> Binding<Double> {
    Binding(
      get: { tuner.overrides[keyPath: keyPath] ?? defaultValue },
      set: { tuner.overrides[keyPath: keyPath] = $0 }
    )
  }

  @ViewBuilder
  private func spacingSlider(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>
  ) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .frame(width: 72, alignment: .leading)
      Slider(value: value, in: range)
      Text(String(format: "%.0fpt", value.wrappedValue))
        .font(.system(size: 10).monospacedDigit())
        .foregroundColor(.secondary)
        .frame(width: 34, alignment: .trailing)
    }
  }
}
