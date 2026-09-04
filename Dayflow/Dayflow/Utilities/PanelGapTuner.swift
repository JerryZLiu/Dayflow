//
//  PanelGapTuner.swift
//  Dayflow
//
//  Dev tool for iterating on the horizontal gap between the timeline (left)
//  and the inspector/summary panel (right). A floating button (bottom-left,
//  alongside the other tuners) opens a popover with a slider. The override is
//  pure layout, so it applies identically in light and dark mode. Unset falls
//  back to the shipped divider width.
//

import SwiftUI

// MARK: - Model

struct PanelGapOverrides: Codable, Equatable {
  /// Points; nil keeps the layout default.
  var inspectorGap: Double?

  static let none = PanelGapOverrides()
}

@MainActor
final class PanelGapTuner: ObservableObject {
  static let shared = PanelGapTuner()

  @Published var overrides: PanelGapOverrides {
    didSet { persist() }
  }

  private static let storageKey = "panelGapTunerOverrides"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(PanelGapOverrides.self, from: data)
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

struct PanelGapTunerButton: View {
  @ObservedObject private var tuner = PanelGapTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "arrow.left.and.right.text.vertical")
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
      PanelGapTunerPanel()
    }
    .accessibilityLabel("Adjust gap between timeline and right panel")
  }
}

private struct PanelGapTunerPanel: View {
  @ObservedObject private var tuner = PanelGapTuner.shared

  private var gapBinding: Binding<Double> {
    Binding(
      get: { tuner.overrides.inspectorGap ?? 12 },
      set: { tuner.overrides.inspectorGap = $0 }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Panel gap")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") { tuner.reset() }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }

      HStack(spacing: 8) {
        Text("Gap")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .frame(width: 72, alignment: .leading)
        Slider(value: gapBinding, in: 0...60)
        Text(String(format: "%.0fpt", gapBinding.wrappedValue))
          .font(.system(size: 10).monospacedDigit())
          .foregroundColor(.secondary)
          .frame(width: 34, alignment: .trailing)
      }
    }
    .padding(16)
    .frame(width: 260)
  }
}
