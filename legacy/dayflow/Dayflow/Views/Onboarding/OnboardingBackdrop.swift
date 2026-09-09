//
//  OnboardingBackdrop.swift
//  Dayflow
//
//  Shared onboarding background from the Figma refresh: a warm radial
//  gradient with soft clouds along the bottom edge. Onboarding is light-only.
//

import SwiftUI

struct OnboardingBackdrop: View {
  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .bottom) {
        RadialGradient(
          stops: [
            .init(color: Color(hex: "FFE5CB"), location: 0),
            .init(color: Color(hex: "FFFBFA"), location: 0.49),
            .init(color: Color(hex: "F4F7FF"), location: 0.99),
          ],
          center: UnitPoint(x: 0.59, y: 1.0),
          startRadius: 0,
          endRadius: max(proxy.size.width, proxy.size.height) * 0.95
        )

        Image("OnboardingClouds")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: proxy.size.width)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
  }
}
