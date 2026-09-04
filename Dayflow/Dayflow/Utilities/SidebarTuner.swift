//
//  SidebarTuner.swift
//  Dayflow
//
//  Dev tool for iterating on the left sidebar gutter. A floating button
//  (bottom-left, alongside the other tuners) opens a popover with two sliders:
//  one for the vertical placement of the icon stack and one for the gutter
//  width. Width writes through the same UserDefaults key the Settings slider
//  uses; the y offset is an additive override on top of the centered layout.
//

import SwiftUI

// MARK: - Model

struct SidebarOverrides: Codable, Equatable {
  /// Points added to the icon stack's centered y position; nil keeps center.
  var iconYOffset: Double?

  static let none = SidebarOverrides()
}

@MainActor
final class SidebarTuner: ObservableObject {
  static let shared = SidebarTuner()

  @Published var overrides: SidebarOverrides {
    didSet { persist() }
  }

  var iconYOffset: CGFloat {
    CGFloat(overrides.iconYOffset ?? 0)
  }

  private static let storageKey = "sidebarTunerOverrides"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(SidebarOverrides.self, from: data)
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

struct SidebarTunerButton: View {
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "sidebar.left")
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
      SidebarTunerPanel()
    }
    .accessibilityLabel("Adjust sidebar icon placement and gutter width")
  }
}

private struct SidebarTunerPanel: View {
  @ObservedObject private var tuner = SidebarTuner.shared
  @AppStorage(SidebarGutter.storageKey) private var gutterWidth: Double = SidebarGutter
    .defaultWidth

  private var yOffsetBinding: Binding<Double> {
    Binding(
      get: { tuner.overrides.iconYOffset ?? 0 },
      set: { tuner.overrides.iconYOffset = $0 }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Sidebar")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") {
          tuner.reset()
          gutterWidth = SidebarGutter.defaultWidth
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
      }

      row(label: "Icon Y", value: yOffsetBinding, range: -300...300, format: "%+.0fpt")
      row(label: "Gutter width", value: $gutterWidth, range: 48...220, format: "%.0fpt")
    }
    .padding(16)
    .frame(width: 300)
  }

  private func row(
    label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String
  ) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .frame(width: 72, alignment: .leading)
      Slider(value: value, in: range)
      Text(String(format: format, value.wrappedValue))
        .font(.system(size: 10).monospacedDigit())
        .foregroundColor(.secondary)
        .frame(width: 44, alignment: .trailing)
    }
  }
}
