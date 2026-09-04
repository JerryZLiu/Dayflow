//
//  WeeklyCardTuner.swift
//  Dayflow
//
//  Dev tool for iterating on the weekly view's light-mode card surfaces. A
//  floating button (bottom-left, with the other tuners) opens a popover with
//  color pickers, hex fields, and opacity sliders for two groups: the card
//  backgrounds, and the footer strips inside cards ("Week total", the insight
//  row). Overrides apply in light mode only; unset keeps the shipped values.
//

import SwiftUI

// MARK: - Model

struct WeeklyCardOverrides: Codable, Equatable {
  /// 6-digit sRGB hex (no '#') for the light-mode card fill; nil keeps white.
  var cardColorHex: String?
  /// 0...1; nil keeps the shipped card fill opacity.
  var cardOpacity: Double?
  /// 6-digit sRGB hex (no '#') for the footer strips; nil keeps white.
  var sectionColorHex: String?
  /// 0...1; nil keeps the shipped footer fill (clear in the refreshed style).
  var sectionOpacity: Double?

  static let none = WeeklyCardOverrides()
}

@MainActor
final class WeeklyCardTuner: ObservableObject {
  static let shared = WeeklyCardTuner()

  @Published var overrides: WeeklyCardOverrides {
    didSet { persist() }
  }

  private static let storageKey = "weeklyCardTunerOverrides"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(WeeklyCardOverrides.self, from: data)
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

struct WeeklyCardTunerButton: View {
  @ObservedObject private var tuner = WeeklyCardTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "square.on.square.dashed")
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
      WeeklyCardTunerPanel()
    }
    .accessibilityLabel("Adjust weekly card backgrounds")
  }
}

private struct WeeklyCardTunerPanel: View {
  @ObservedObject private var tuner = WeeklyCardTuner.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var cardHexText: String = ""
  @State private var sectionHexText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Weekly cards")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") {
          tuner.reset()
          cardHexText = currentCardHex
          sectionHexText = currentSectionHex
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
      }

      if theme.isDark {
        Text("Switch to light mode to see changes.")
          .font(.system(size: 11))
          .foregroundColor(.orange)
      }

      group(
        title: "Card background",
        hexText: $cardHexText,
        currentHex: currentCardHex,
        opacity: Binding(
          get: { tuner.overrides.cardOpacity ?? 0.46 },
          set: { tuner.overrides.cardOpacity = $0 }
        ),
        setHex: { tuner.overrides.cardColorHex = $0 }
      )

      Divider()

      group(
        title: "Footer strips (Week total / insight)",
        hexText: $sectionHexText,
        currentHex: currentSectionHex,
        opacity: Binding(
          get: { tuner.overrides.sectionOpacity ?? 1 },
          set: { tuner.overrides.sectionOpacity = $0 }
        ),
        setHex: { tuner.overrides.sectionColorHex = $0 }
      )

      Text("Applies to the weekly view in light mode. Press return to apply a typed hex.")
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(width: 300)
    .onAppear {
      cardHexText = currentCardHex
      sectionHexText = currentSectionHex
    }
  }

  private var currentCardHex: String {
    tuner.overrides.cardColorHex ?? "FFFFFF"
  }

  private var currentSectionHex: String {
    tuner.overrides.sectionColorHex ?? "FAF7F5"
  }

  @ViewBuilder
  private func group(
    title: String,
    hexText: Binding<String>,
    currentHex: String,
    opacity: Binding<Double>,
    setHex: @escaping (String) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)

      HStack(spacing: 8) {
        ColorPicker(
          "",
          selection: Binding(
            get: { Color(hex: currentHex) },
            set: {
              setHex($0.tunerHexString)
              hexText.wrappedValue = $0.tunerHexString
            }
          ),
          supportsOpacity: false
        )
        .labelsHidden()
        .frame(width: 34)

        Text("#")
          .font(.system(size: 12).monospaced())
          .foregroundColor(.secondary)

        TextField("Hex", text: hexText)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12).monospaced())
          .frame(width: 84)
          .onSubmit {
            guard let hex = sanitizedHex(hexText.wrappedValue) else { return }
            setHex(hex)
            hexText.wrappedValue = hex
          }

        RoundedRectangle(cornerRadius: 6)
          .fill(Color(hex: currentHex))
          .frame(width: 34, height: 24)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color.primary.opacity(0.15), lineWidth: 1)
          )
      }

      if sanitizedHex(hexText.wrappedValue) == nil {
        Text("Enter a 6-digit hex color (e.g. FFFFFF).")
          .font(.system(size: 10))
          .foregroundColor(.orange)
      }

      HStack(spacing: 8) {
        Text("Opacity")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .frame(width: 52, alignment: .leading)
        Slider(value: opacity, in: 0...1)
        Text(String(format: "%.0f%%", opacity.wrappedValue * 100))
          .font(.system(size: 10).monospacedDigit())
          .foregroundColor(.secondary)
          .frame(width: 38, alignment: .trailing)
      }
    }
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
