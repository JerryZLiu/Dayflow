//
//  BackgroundTuner.swift
//  Dayflow
//
//  Dev tool for iterating on the light-mode window background. A floating
//  button (bottom-left, above the Before/After toggle) opens a popover with
//  controls for the background gradient: style (radial/linear), color stops,
//  and geometry. The tuned gradient renders only in light mode with the
//  style preview set to "After"; "Before" keeps the shipped image.
//

import SwiftUI

// MARK: - Model

struct BackgroundGradientSettings: Codable, Equatable {
  enum Kind: String, Codable, CaseIterable, Identifiable {
    case radial, linear
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
  }

  struct Stop: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var hex: String
    var location: Double

    private enum CodingKeys: String, CodingKey { case hex, location }
  }

  var kind: Kind
  var stops: [Stop]
  /// Linear only: direction in degrees (0 = left→right, 90 = top→bottom).
  var angle: Double
  /// Linear only: gradient span as a multiple of the window (1 = edge to edge;
  /// smaller compresses the transition, larger stretches it past the edges).
  var spanScale: Double
  /// Radial only: center as unit-space coordinates.
  var centerX: Double
  var centerY: Double
  /// Radial only: end radius as a multiple of the window's larger dimension.
  var radiusScale: Double
  /// Radial only: rotates the center around the window midpoint, in degrees.
  /// (A circular gradient centered at 0.5/0.5 looks the same at any rotation.)
  var rotation: Double

  /// Matches the Figma "Light - timeline" mock (Interface refresh / Final):
  /// radial peach→pink→blue anchored at the bottom. These are the mock's raw
  /// gradient stops; the veil above them is the main panel's own fill
  /// (theme.panelFill), so the gradient renders unwashed here.
  static let `default` = BackgroundGradientSettings(
    kind: .radial,
    stops: [
      Stop(hex: "FFE6CF", location: 0.17),
      Stop(hex: "FFE6E0", location: 0.33),
      Stop(hex: "D6E8FF", location: 1),
    ],
    angle: 90,
    spanScale: 1,
    centerX: 0.64,
    centerY: 1.0,
    radiusScale: 0.92,
    rotation: 0
  )
}

extension BackgroundGradientSettings {
  private enum CodingKeys: String, CodingKey {
    case kind, stops, angle, spanScale, centerX, centerY, radiusScale, rotation
  }

  // Custom decode so settings persisted before spanScale/rotation existed
  // still load instead of silently resetting to the default.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decode(Kind.self, forKey: .kind)
    stops = try c.decode([Stop].self, forKey: .stops)
    angle = try c.decode(Double.self, forKey: .angle)
    spanScale = try c.decodeIfPresent(Double.self, forKey: .spanScale) ?? 1
    centerX = try c.decode(Double.self, forKey: .centerX)
    centerY = try c.decode(Double.self, forKey: .centerY)
    radiusScale = try c.decode(Double.self, forKey: .radiusScale)
    rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
  }
}

@MainActor
final class BackgroundTuner: ObservableObject {
  static let shared = BackgroundTuner()

  @Published var settings: BackgroundGradientSettings {
    didSet { persist() }
  }

  // Bumped when the default changes so a stale tuned value doesn't hide it.
  private static let storageKey = "backgroundTunerSettings.v4"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode(BackgroundGradientSettings.self, from: data)
    {
      settings = decoded
    } else {
      settings = .default
    }
  }

  func reset() {
    settings = .default
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}

// MARK: - Gradient rendering

struct TunedGradientBackground: View {
  let settings: BackgroundGradientSettings

  var body: some View {
    GeometryReader { proxy in
      let gradient = Gradient(
        stops: settings.stops
          .sorted { $0.location < $1.location }
          .map { .init(color: Color(hex: $0.hex), location: $0.location) }
      )

      // Raw gradient only. The veil above it is the main panel's own fill
      // (theme.panelFill, #FBFBFB @ 55%) — adding one here doubles it up.
      baseGradient(gradient, in: proxy)
    }
  }

  @ViewBuilder
  private func baseGradient(_ gradient: Gradient, in proxy: GeometryProxy) -> some View {
    switch settings.kind {
      case .radial:
        // Rotation swings the center around the window midpoint, computed in
        // pixel space so the orbit stays circular in non-square windows.
        let rot: Double = settings.rotation * .pi / 180
        let ox: Double = (settings.centerX - 0.5) * Double(proxy.size.width)
        let oy: Double = (settings.centerY - 0.5) * Double(proxy.size.height)
        let rx: Double = ox * Foundation.cos(rot) - oy * Foundation.sin(rot)
        let ry: Double = ox * Foundation.sin(rot) + oy * Foundation.cos(rot)
        RadialGradient(
          gradient: gradient,
          center: UnitPoint(
            x: 0.5 + rx / max(proxy.size.width, 1),
            y: 0.5 + ry / max(proxy.size.height, 1)
          ),
          startRadius: 0,
          endRadius: max(proxy.size.width, proxy.size.height) * settings.radiusScale
        )
      case .linear:
        let rad = settings.angle * .pi / 180
        let dx = cos(rad) / 2 * settings.spanScale
        let dy = sin(rad) / 2 * settings.spanScale
        LinearGradient(
          gradient: gradient,
          startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
          endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }
  }
}

// MARK: - Floating button + popover

struct BackgroundTunerButton: View {
  @ObservedObject private var tuner = BackgroundTuner.shared
  @ObservedObject private var preview = StylePreview.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false
  @State private var isPresenting = false

  var body: some View {
    Button {
      isPresenting.toggle()
    } label: {
      Image(systemName: "paintpalette")
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
      BackgroundTunerPanel()
    }
    .accessibilityLabel("Adjust background colors")
  }
}

private struct BackgroundTunerPanel: View {
  @ObservedObject private var tuner = BackgroundTuner.shared
  @ObservedObject private var preview = StylePreview.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Light background")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Reset") { tuner.reset() }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }

      if !preview.showAfter {
        Text("Set the preview toggle to “After” to see changes.")
          .font(.system(size: 11))
          .foregroundColor(.orange)
      } else if theme.isDark {
        Text("Switch to light mode to see this background.")
          .font(.system(size: 11))
          .foregroundColor(.orange)
      }

      Picker("Style", selection: $tuner.settings.kind) {
        ForEach(BackgroundGradientSettings.Kind.allCases) { kind in
          Text(kind.label).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      // Live preview strip
      TunedGradientBackground(settings: tuner.settings)
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )

      VStack(alignment: .leading, spacing: 8) {
        Text("Colors")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.secondary)

        ForEach($tuner.settings.stops) { $stop in
          HStack(spacing: 8) {
            ColorPicker(
              "",
              selection: Binding(
                get: { Color(hex: stop.hex) },
                set: { stop.hex = $0.tunerHexString }
              ),
              supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 34)

            Slider(value: $stop.location, in: 0...1)

            Text(String(format: "%.0f%%", stop.location * 100))
              .font(.system(size: 10).monospacedDigit())
              .foregroundColor(.secondary)
              .frame(width: 34, alignment: .trailing)

            Button {
              tuner.settings.stops.removeAll { $0.id == stop.id }
            } label: {
              Image(systemName: "minus.circle")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(tuner.settings.stops.count <= 2)
            .opacity(tuner.settings.stops.count <= 2 ? 0.3 : 1)
          }
        }

        if tuner.settings.stops.count < 5 {
          Button {
            let last = tuner.settings.stops.last
            tuner.settings.stops.append(
              .init(hex: last?.hex ?? "FFFFFF", location: 1)
            )
          } label: {
            Label("Add color", systemImage: "plus.circle")
              .font(.system(size: 11))
          }
          .buttonStyle(.plain)
          .foregroundColor(.secondary)
        }
      }

      switch tuner.settings.kind {
      case .linear:
        labeledSlider(
          "Rotation", value: $tuner.settings.angle, range: 0...360,
          format: String(format: "%.0f°", tuner.settings.angle))
        labeledSlider(
          "Size", value: $tuner.settings.spanScale, range: 0.2...3,
          format: String(format: "%.2f×", tuner.settings.spanScale))
      case .radial:
        labeledSlider(
          "Center X", value: $tuner.settings.centerX, range: 0...1,
          format: String(format: "%.2f", tuner.settings.centerX))
        labeledSlider(
          "Center Y", value: $tuner.settings.centerY, range: -0.5...2,
          format: String(format: "%.2f", tuner.settings.centerY))
        labeledSlider(
          "Size", value: $tuner.settings.radiusScale, range: 0.3...2,
          format: String(format: "%.2f×", tuner.settings.radiusScale))
        labeledSlider(
          "Rotation", value: $tuner.settings.rotation, range: 0...360,
          format: String(format: "%.0f°", tuner.settings.rotation))
      }

      Text(exportSummary)
        .font(.system(size: 10).monospaced())
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .lineLimit(3)
    }
    .padding(16)
    .frame(width: 300)
  }

  @ViewBuilder
  private func labeledSlider(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String
  ) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .frame(width: 56, alignment: .leading)
      Slider(value: value, in: range)
      Text(format)
        .font(.system(size: 10).monospacedDigit())
        .foregroundColor(.secondary)
        .frame(width: 38, alignment: .trailing)
    }
  }

  private var exportSummary: String {
    let stops = tuner.settings.stops
      .sorted { $0.location < $1.location }
      .map { "#\($0.hex) @ \(String(format: "%.0f%%", $0.location * 100))" }
      .joined(separator: ", ")
    return "\(tuner.settings.kind.label): \(stops)"
  }
}

// MARK: - Color → hex

extension Color {
  /// sRGB hex (no alpha) for persisting tuner selections.
  var tunerHexString: String {
    let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
    return String(
      format: "%02X%02X%02X",
      Int(round(ns.redComponent * 255)),
      Int(round(ns.greenComponent * 255)),
      Int(round(ns.blueComponent * 255))
    )
  }
}
