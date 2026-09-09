//
//  LightWindowGradient.swift
//  Dayflow
//
//  The light-mode window background. Matches the Figma "Light - timeline"
//  mock (Interface refresh / Final): a radial peach→pink→blue gradient
//  anchored at the bottom. These are the mock's raw gradient stops; the veil
//  above them is the main panel's own fill (theme.panelFill), so the gradient
//  renders unwashed here.
//

import SwiftUI

struct LightWindowGradient: View {
  private static let stops: [Gradient.Stop] = [
    .init(color: Color(hex: "FFE6CF"), location: 0.17),
    .init(color: Color(hex: "FFE6E0"), location: 0.33),
    .init(color: Color(hex: "D6E8FF"), location: 1),
  ]
  private static let center = UnitPoint(x: 0.64, y: 1.0)
  /// End radius as a multiple of the window's larger dimension.
  private static let radiusScale: CGFloat = 0.92

  var body: some View {
    GeometryReader { proxy in
      RadialGradient(
        gradient: Gradient(stops: Self.stops),
        center: Self.center,
        startRadius: 0,
        endRadius: max(proxy.size.width, proxy.size.height) * Self.radiusScale
      )
    }
  }
}
