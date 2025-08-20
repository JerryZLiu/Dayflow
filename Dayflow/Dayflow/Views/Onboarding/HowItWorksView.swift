//
//  HowItWorksView.swift
//  Dayflow
//
//  Re-responsive + scroll-safe rewrite, August 2025
//

import SwiftUI

struct HowItWorksView: View {
    // MARK: – Animation state
    @State private var titleOpacity: Double = 0
    @State private var cardOffsets: [CGFloat] = [50, 50, 50]
    @State private var cardOpacities: [Double] = [0, 0, 0]
    @State private var buttonsOpacity: Double = 0
    @State private var isHoveringGitHub: Bool = false

    private let fullText = "How Dayflow Works"
    
    // Navigation callbacks
    var onBack: () -> Void
    var onNext: () -> Void

    // MARK: – Card data model
    private let cards: [(icon: String, title: String, body: String)] = [
        ("OnboardingHow",
         "Install and Forget",
         "Dayflow takes periodic screen captures to understand what you're working on – all stored privately on your device. You can toggle this whenever you like."),
        ("OnboardingSecurity",
         "Privacy by Default",
         "Dayflow can run entirely on local AI models, which means your data never leaves your computer. And our code is public, so you don’t have to trust us – you can verify."),
        ("OnboardingUnderstanding",
         "Understand your Day",
         "Smart context detection turns raw data into meaningful insights—see the difference between deep work and distraction.")
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 40) {
                    // MARK: – Animated title
                    Text(fullText)
                        .font(.custom("InstrumentSerif-Regular", size: 48))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .opacity(titleOpacity)
                        .onAppear {
                            withAnimation(.easeOut(duration: 0.6)) {
                                titleOpacity = 1
                            }
                            // Animate cards after title appears
                            animateCards()
                        }

                    // MARK: – Cards
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
                .frame(maxWidth: 600) // Match card width
                
                // Navigation section - all buttons on same line
                HStack {
                    DayflowButton(
                        title: "Back",
                        action: onBack,
                        width: 120,
                        fontSize: 14,
                        isSubtle: true
                    )
                    
                    Spacer()
                    
                    // GitHub button centered with hover effect
                    Button {
                        if let url = URL(string: "https://github.com/teleportlabs/Dayflow") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image("GithubIcon")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)

                            Text("Read the code on GitHub")
                                .font(.custom("Nunito", size: 16))
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(isHoveringGitHub ? 1.0 : 0.9))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.black.opacity(isHoveringGitHub ? 0.3 : 0.1), lineWidth: isHoveringGitHub ? 2 : 1)
                                )
                                .shadow(color: Color.black.opacity(isHoveringGitHub ? 0.15 : 0), radius: 8, x: 0, y: 4)
                        )
                        .scaleEffect(isHoveringGitHub ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isHoveringGitHub)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringGitHub = hovering
                    }
                    
                    Spacer()
                    
                    DayflowButton(
                        title: "Next",
                        action: onNext,
                        width: 120,
                        fontSize: 14
                    )
                }
                .frame(maxWidth: 600) // Match card width
                .padding(.top, 40)
                .opacity(buttonsOpacity) // Use separate opacity for buttons
                
                // Overall breathing room
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
    }
}

// MARK: – Helper: value clamping
private func clamp<T: Comparable>(_ value: T, _ limits: ClosedRange<T>) -> T {
    min(max(value, limits.lowerBound), limits.upperBound)
}

// MARK: – Card animation
private extension HowItWorksView {
    func animateCards() {
        for idx in cards.indices {
            // Each card appears 2 seconds after the previous one
            // First card appears after 1 second, then 2 seconds between each
            let delay = 1.0 + Double(idx) * 2.0
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.8,
                                      dampingFraction: 0.75,
                                      blendDuration: 0)) {
                    cardOffsets[idx] = 0
                    cardOpacities[idx] = 1
                }
            }
        }
        
        // Animate buttons 2 seconds after the last card
        let buttonsDelay = 1.0 + Double(cards.count) * 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + buttonsDelay) {
            withAnimation(.easeInOut(duration: 0.6)) {
                buttonsOpacity = 1
            }
        }
    }
}
