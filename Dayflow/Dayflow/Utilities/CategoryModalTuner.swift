//
//  CategoryModalTuner.swift
//  Dayflow
//
//  Dev tool for iterating on the "Customize your categories" modal: title
//  size, the gap above the bottom buttons, and the card's inner margins.
//  Lives in the bottom-left dev cluster with the other tuners. Overrides are
//  pure layout, so they apply identically in light and dark mode; unset
//  values fall back to the shipped defaults.
//

import SwiftUI

// MARK: - Model

struct CategoryModalOverrides: Codable, Equatable {
  /// Points; nil keeps the layout default.
  var titleSize: Double?
  var subtitleSize: Double?
  var buttonGap: Double?
  var topMargin: Double?
  var bottomMargin: Double?
  var horizontalMargin: Double?
  var sectionXOffset: Double?

  static let none = CategoryModalOverrides()
}

@MainActor
final class CategoryModalTuner: ObservableObject {
  static let shared = CategoryModalTuner()

  @Published var overrides: CategoryModalOverrides {
    didSet { persist() }
  }

  private static let storageKey = "categoryModalTunerOverrides"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(CategoryModalOverrides.self, from: data)
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

struct CategoryModalTunerButton: View {
  @ObservedObject private var tuner = CategoryModalTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "rectangle.and.pencil.and.ellipsis")
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
      CategoryModalTunerPanel()
    }
    .accessibilityLabel("Adjust the customize-categories modal layout")
  }
}

private struct CategoryModalTunerPanel: View {
  @ObservedObject private var tuner = CategoryModalTuner.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Category modal")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") { tuner.reset() }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }

      sliderRow(
        "Title size",
        binding(\.titleSize, default: 36), in: 20...72)
      sliderRow(
        "Subtitle size",
        binding(\.subtitleSize, default: 30), in: 16...48)
      sliderRow(
        "Button gap",
        binding(\.buttonGap, default: 70), in: 0...120)
      sliderRow(
        "Top margin",
        binding(\.topMargin, default: 58), in: 0...120)
      sliderRow(
        "Bottom margin",
        binding(\.bottomMargin, default: 48), in: 0...120)
      sliderRow(
        "Side margins",
        binding(\.horizontalMargin, default: 62), in: 0...160)
      sliderRow(
        "Section X",
        binding(\.sectionXOffset, default: 4), in: -200...200)
    }
    .padding(16)
    .frame(width: 300)
  }

  private func binding(
    _ keyPath: WritableKeyPath<CategoryModalOverrides, Double?>, default defaultValue: Double
  ) -> Binding<Double> {
    Binding(
      get: { tuner.overrides[keyPath: keyPath] ?? defaultValue },
      set: { tuner.overrides[keyPath: keyPath] = $0 }
    )
  }

  private func sliderRow(_ label: String, _ value: Binding<Double>, in range: ClosedRange<Double>)
    -> some View
  {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .frame(width: 92, alignment: .leading)
      Slider(value: value, in: range)
      Text(String(format: "%.0fpt", value.wrappedValue))
        .font(.system(size: 10).monospacedDigit())
        .foregroundColor(.secondary)
        .frame(width: 34, alignment: .trailing)
    }
  }
}
