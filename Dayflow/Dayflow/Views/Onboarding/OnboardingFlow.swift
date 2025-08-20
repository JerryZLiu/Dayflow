//
//  OnboardingFlow.swift
//  Dayflow
//
//  Created by Jerry Liu on 4/26/25.
//

import SwiftUI
import ScreenCaptureKit

struct OnboardingFlow: View {
    // MARK: – State
    @AppStorage("onboardingStep") private var savedStepRawValue = 0
    @State private var step: Step = .welcome
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var timelineOffset: CGFloat = 300 // Start below screen
    @State private var textOpacity: Double = 0
    private let fullText = "Stop wondering where your day went.\nStart understanding it."
    
    var body: some View {
        ZStack {
            // Background image
            Image("OnboardingBackgroundv2")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
            
            GeometryReader { geometry in
                
                if step == .welcome {
                    ZStack {
                        // Text and button container - positioned from top
                        VStack {
                            VStack(spacing: 40) {
                                Text(fullText)
                                    .font(.custom("InstrumentSerif-Regular", size: min(36, geometry.size.width / 20)))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.black.opacity(0.8))
                                    .padding(.horizontal, 20)
                                    .minimumScaleFactor(0.5)
                                    .lineLimit(3)
                                    .frame(minHeight: 100) // Min height to prevent jumping
                                    .opacity(textOpacity)
                                    .onAppear {
                                        withAnimation(.easeOut(duration: 0.6)) {
                                            textOpacity = 1
                                        }
                                    }
                                
                                // Custom Start button right below text
                                DayflowButton(title: "Start", action: advance)
                                    .opacity(textOpacity)
                                    .animation(.easeIn(duration: 0.3).delay(0.4), value: textOpacity)
                            }
                            .padding(.top, 80) // Move text higher up
                            
                            Spacer()
                        }
                        .zIndex(1) // Ensure text and button are always on top
                        
                        // Timeline image - anchored to bottom
                        VStack {
                            Spacer()
                            Image("OnboardingTimeline")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: min(geometry.size.width * 0.9, 800))
                                .offset(y: timelineOffset)
                                .opacity(timelineOffset > 0 ? 0 : 1)
                                .onAppear {
                                    // Emil Kowalski principles:
                                    // - Use spring for natural movement
                                    // - Keep it fast (under 1s)
                                    // - Ease out for responsiveness
                                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0).delay(0.3)) {
                                        timelineOffset = 0
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if step == .howItWorks {
                    // How It Works page with custom layout
                    VStack {
                        HowItWorksView(
                            onBack: { step.prev() },
                            onNext: { advance() }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if step == .screen {
                    // Screen recording permission with visual guide
                    ScreenRecordingPermissionView(
                        onBack: { step.prev() },
                        onNext: { advance() }
                    )
                } else if step == .llmSelection {
                    // LLM Selection view
                    OnboardingLLMSelectionView(
                        onBack: { step.prev() },
                        onNext: { advance() }
                    )
                } else {
                    // Other onboarding steps
                    VStack(spacing: 24) {
                        switch step {
                        case .screen:
                            Heading("Give screen-recording permission",
                                    "macOS will open System Settings → Screen Recording. Please enable Dayflow.")
                        case .llmSelection:
                            EmptyView() // Handled by custom view
                        case .done:
                            Heading("Setup Complete",
                                    "You can now close this window; Dayflow will keep running in the menu-bar.")
                        default:
                            EmptyView()
                        }
                    }
                    .padding(geometry.size.width < 600 ? 20 : 40)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                            .shadow(radius: 20)
                    )
                }
                
                // Navigation buttons (hidden on custom layout pages)
                if step != .welcome && step != .howItWorks && step != .llmSelection && step != .screen {
                    VStack {
                        Spacer()
                        HStack {
                            Button("Back") { 
                                timelineOffset = 300 // Reset for animation
                                step.prev() 
                            }
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.secondary)
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            DayflowButton(
                                title: step == .done ? "Finish" : "Next",
                                action: advance,
                                width: 120,
                                fontSize: 14
                            )
                        }
                        .padding(geometry.size.width < 600 ? 20 : 40)
                    }
                }
            }
        }
        .onAppear {
            // Restore saved step if app was restarted
            if let savedStep = Step(rawValue: savedStepRawValue) {
                step = savedStep
            }
        }
    }
    
    // MARK: – Flow control
    private func advance() {
        switch step {
        case .welcome:      
            step.next()
            savedStepRawValue = step.rawValue
        case .howItWorks:   
            step.next()
            savedStepRawValue = step.rawValue
        case .screen:
            Task { try? await requestScreenPerm() }
            step.next()
            savedStepRawValue = step.rawValue
        case .llmSelection:
            step.next()
            savedStepRawValue = step.rawValue
        case .done:         
            didOnboard = true
            savedStepRawValue = 0  // Reset for next time
        }
    }
    
    private func requestScreenPerm() async throws {
        _ = try await SCShareableContent.current                 // triggers prompt
    }
}

// MARK: – Helpers

/// Wizard step order
private enum Step: Int, CaseIterable { case welcome, howItWorks, screen, llmSelection, done
    mutating func next() { self = Step(rawValue: rawValue + 1)! }
    mutating func prev() { self = Step(rawValue: rawValue - 1)! }
}

@ViewBuilder private func Heading(_ title: String, _ sub: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title)
            .font(.custom("InstrumentSerif-Regular", size: 28))
            .fontWeight(.medium)
        Text(sub)
            .font(.system(size: 14))
            .foregroundColor(.secondary)
    }
}

// MARK: - Preview
struct OnboardingFlow_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingFlow()
            .environmentObject(AppState.shared)
            .frame(width: 1200, height: 800)
    }
}
