//
//  HowItWorksView.swift
//  Dayflow
//
//  Re-responsive + scroll-safe rewrite, August 2025
//

import SwiftUI

struct HowItWorksView: View {
  @State private var titleOpacity: Double = 0
  @State private var cardOffsets: [CGFloat] = [50, 50, 50]
  @State private var cardOpacities: [Double] = [0, 0, 0]
  @State private var buttonsOpacity: Double = 0

  private let fullText = "How Dayflow Works"

  // Navigation callbacks
  var onBack: () -> Void
  var onNext: () -> Void

  private let cards: [(icon: String, title: String, body: String)] = [
    (
      "OnboardingHow",
      "Install and Forget",
      "Dayflow takes periodic screen captures to understand what you're working on, all stored privately on your device. You can toggle this whenever you like."
    ),
    (
      "OnboardingSecurity",
      "Privacy by Default",
      "Dayflow can run entirely on local AI models, which means your data never leaves your computer. You can also find the source code below - please consider giving it a star on Github!"
    ),
    (
      "OnboardingUnderstanding",
      "Understand your Day",
      "Knows the difference between YouTube tutorials and YouTube rabbit holes. Dayflow actually gets what you're working on."
    ),
  ]

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(spacing: 40) {
        Text(fullText)
          .font(.custom("InstrumentSerif-Regular", size: 48))
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, minHeight: 60)
          .foregroundColor(.black)
          .opacity(titleOpacity)
          .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
              titleOpacity = 1
            }
            // Animate cards after title appears
            animateCards()
          }

        VStack(spacing: 16) {
          ForEach(cards.indices, id: \.self) { idx in
            HowItWorksCard(
              iconImage: cards[idx].icon,
              title: cards[idx].title,
              description: cards[idx].body
            )
            .offset(y: cardOffsets[idx])
            .opacity(cardOpacities[idx])
          }
        }

      }
      .frame(maxWidth: 600)  // Match card width

      // Navigation section - all buttons on same line
      HStack {
        DayflowSurfaceButton(
          action: onBack,
          content: { Text("Back").font(.custom("Nunito", size: 14)).fontWeight(.semibold) },
          background: .white,
          foreground: Color(red: 0.25, green: 0.17, blue: 0),
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 20,
          verticalPadding: 12,
          minWidth: 120,
          isSecondaryStyle: true
        )

        Spacer()

        DayflowSurfaceButton(
          action: {
            if let url = URL(string: "https://github.com/jerryzliu/Dayflow") {
              NSWorkspace.shared.open(url)
            }
          },
          content: {
            HStack(spacing: 12) {
              Image("GithubIcon").resizable().aspectRatio(contentMode: .fit).frame(
                width: 20, height: 20
              ).colorInvert()
              Text("Star Dayflow on GitHub").font(.custom("Nunito", size: 14)).fontWeight(.medium)
            }
          },
          background: Color(red: 0.25, green: 0.17, blue: 0),
          foreground: .white,
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 24,
          verticalPadding: 12,
          showOverlayStroke: true
        )

        Spacer()

        DayflowSurfaceButton(
          action: onNext,
          content: { Text("Next").font(.custom("Nunito", size: 14)).fontWeight(.semibold) },
          background: Color(red: 0.25, green: 0.17, blue: 0),
          foreground: .white,
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 20,
          verticalPadding: 12,
          minWidth: 120,
          showOverlayStroke: true
        )
      }
      .frame(maxWidth: 600)  // Match card width
      .padding(.top, 40)
      .opacity(buttonsOpacity)  // Use separate opacity for buttons

      // Overall breathing room
      .padding(.horizontal, 40)
      .padding(.bottom, 40)
    }
    .preferredColorScheme(.light)
  }
}

extension HowItWorksView {
  fileprivate func animateCards() {
    for idx in cards.indices {
      // Each card appears 1 second after the previous one
      // First card appears after 1 second, then 1 second between each
      let delay = 1.0 + Double(idx) * 1.0

      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        withAnimation(
          .spring(
            response: 0.8,
            dampingFraction: 0.75,
            blendDuration: 0)
        ) {
          cardOffsets[idx] = 0
          cardOpacities[idx] = 1
        }
      }
    }

    // Animate buttons 1 second after the last card
    let buttonsDelay = 1.0 + Double(cards.count) * 1.0
    DispatchQueue.main.asyncAfter(deadline: .now() + buttonsDelay) {
      withAnimation(.easeInOut(duration: 0.6)) {
        buttonsOpacity = 1
      }
    }
  }
}
