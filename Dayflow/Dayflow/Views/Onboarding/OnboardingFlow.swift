//
//  OnboardingFlow.swift
//  Dayflow
//

import Foundation
import SwiftUI
import ScreenCaptureKit

// Window manager removed - no longer needed!

struct OnboardingFlow: View {
    @AppStorage("onboardingStep") private var savedStepRawValue = 0
    @State private var step: Step = .welcome
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var timelineOffset: CGFloat = 300 // Start below screen
    @State private var textOpacity: Double = 0
    @AppStorage("selectedLLMProvider") private var selectedProvider: String = "gemini" // Persist across sessions
    @EnvironmentObject private var categoryStore: CategoryStore
    private let fullText = "Your day has a story. Uncover it with Dayflow."
    
    @ViewBuilder
    var body: some View {
        ZStack {
            // NO NESTING! Just render the appropriate view directly - NO GROUP!
            switch step {
            case .welcome:
                WelcomeView(
                    fullText: fullText,
                    textOpacity: $textOpacity,
                    timelineOffset: $timelineOffset,
                    onStart: advance
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    restoreSavedStep()
                    // screen + start event
                    AnalyticsService.shared.screen("onboarding_welcome")
                    if !UserDefaults.standard.bool(forKey: "onboardingStarted") {
                        AnalyticsService.shared.capture("onboarding_started")
                        UserDefaults.standard.set(true, forKey: "onboardingStarted")
                        AnalyticsService.shared.setPersonProperties(["onboarding_status": "in_progress"]) 
                    }
                }
                
            case .howItWorks:
                HowItWorksView(
                    onBack: { 
                        setStep(.welcome)
                    },
                    onNext: { advance() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    restoreSavedStep()
                    AnalyticsService.shared.screen("onboarding_how_it_works")
                }
                
            case .llmSelection:
                OnboardingLLMSelectionView(
                    onBack: { 
                        setStep(.howItWorks)
                    },
                    onNext: { provider in
                        selectedProvider = provider
                        var props: [String: Any] = ["provider": provider]
                        // If ollama is selected, include the engine type that will be chosen
                        if provider == "ollama" {
                            let localEngine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
                            props["local_engine"] = localEngine
                        }
                        AnalyticsService.shared.capture("llm_provider_selected", props)
                        AnalyticsService.shared.setPersonProperties(["current_llm_provider": provider])
                        advance()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    restoreSavedStep()
                    AnalyticsService.shared.screen("onboarding_llm_selection")
                }
                
            case .llmSetup:
                // COMPLETELY STANDALONE - no parent constraints!
                LLMProviderSetupView(
                    providerType: selectedProvider,
                    onBack: {
                        setStep(.llmSelection)
                    },
                    onComplete: {
                        advance()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    restoreSavedStep()
                    AnalyticsService.shared.screen("onboarding_llm_setup")
                }
                
            case .categories:
                OnboardingCategorySetupView(
                    onNext: {
                        advance()
                    }
                )
                .environmentObject(categoryStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    restoreSavedStep()
                    AnalyticsService.shared.screen("onboarding_categories")
                }

            case .screen:
                ScreenRecordingPermissionView(
                    onBack: { 
                        setStep(.categories)
                    },
                    onNext: { advance() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    restoreSavedStep()
                    AnalyticsService.shared.screen("onboarding_screen_recording")
                }
                
            case .completion:
                CompletionView(
                    onFinish: {
                        // Create sample card BEFORE switching views (sync write)
                        StorageManager.shared.createOnboardingCard()

                        didOnboard = true
                        savedStepRawValue = 0
                        AnalyticsService.shared.capture("onboarding_completed")
                        AnalyticsService.shared.setPersonProperties(["onboarding_status": "completed"])
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    restoreSavedStep()
                    AnalyticsService.shared.screen("onboarding_completion")
                }
            }
        }
        .background {
            // Background at parent level - fills entire window!
            Image("OnboardingBackgroundv2")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.light)
    }

    private func restoreSavedStep() {
        let migratedValue = OnboardingStepMigration.migrateIfNeeded()
        if migratedValue != savedStepRawValue {
            savedStepRawValue = migratedValue
        }
        if let savedStep = Step(rawValue: migratedValue) {
            step = savedStep
        }
    }
    
    private func setStep(_ newStep: Step) {
        step = newStep
        savedStepRawValue = newStep.rawValue
    }

    private func advance() {
        // Mark current step completed before advancing
        func markStepCompleted(_ s: Step) {
            let name: String
            switch s {
            case .welcome: name = "welcome"
            case .howItWorks: name = "how_it_works"
            case .llmSelection: name = "llm_selection"
            case .llmSetup: name = "llm_setup"
            case .categories: name = "categories"
            case .screen: name = "screen_recording"
            case .completion: name = "completion"
            }
            AnalyticsService.shared.capture("onboarding_step_completed", ["step": name])
        }

        switch step {
        case .welcome:      
            markStepCompleted(step)
            step.next()
            savedStepRawValue = step.rawValue
        case .howItWorks:   
            markStepCompleted(step)
            step.next()
            savedStepRawValue = step.rawValue
        case .llmSelection:
            markStepCompleted(step)
            let nextStep: Step = (selectedProvider == "dayflow") ? .categories : .llmSetup
            setStep(nextStep)
        case .llmSetup:
            markStepCompleted(step)
            step.next()
            savedStepRawValue = step.rawValue
        case .categories:
            markStepCompleted(step)
            step.next()
            savedStepRawValue = step.rawValue
        case .screen:
            // Permission request is handled by ScreenRecordingPermissionView itself
            markStepCompleted(step)
            step.next()
            savedStepRawValue = step.rawValue
            
            // Try to start recording if we have permission
            Task {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    await MainActor.run {
                        AppState.shared.isRecording = true
                    }
                } catch {
                    // Permission not granted yet, will start after restart
                    print("Will start recording after restart")
                }
            }
        case .completion:         
            didOnboard = true
            savedStepRawValue = 0  // Reset for next time
        }
    }
    
}


/// Wizard step order
private enum Step: Int, CaseIterable {
    case welcome, howItWorks, llmSelection, llmSetup, categories, screen, completion

    mutating func next() { self = Step(rawValue: rawValue + 1)! }
}

enum OnboardingStepMigration {
    static let schemaVersionKey = "onboardingStepSchemaVersion"
    private static let onboardingStepKey = "onboardingStep"
    static let currentVersion = 1

    @discardableResult
    static func migrateIfNeeded(defaults: UserDefaults = .standard) -> Int {
        let storedVersion = defaults.integer(forKey: schemaVersionKey)
        let rawValue = defaults.integer(forKey: onboardingStepKey)
        guard storedVersion < currentVersion else {
            return rawValue
        }

        let migratedValue = migrateRawValue(rawValue)
        defaults.set(migratedValue, forKey: onboardingStepKey)
        defaults.set(currentVersion, forKey: schemaVersionKey)
        return migratedValue
    }

    static func migrateRawValue(_ rawValue: Int) -> Int {
        switch rawValue {
        case 0: return 0         // welcome
        case 1: return 1         // how it works
        case 2: return 5         // legacy screen step moves after categories
        case 3: return 2         // llm selection
        case 4: return 3         // llm setup
        case 5: return 4         // categories
        case 6: return 6         // completion
        default: return 0
        }
    }
}


struct WelcomeView: View {
    let fullText: String
    @Binding var textOpacity: Double
    @Binding var timelineOffset: CGFloat
    let onStart: () -> Void
    
    var body: some View {
        ZStack {
            // Text and button container
            VStack {
                    VStack(spacing: 20) {
                        Image("DayflowLogoMainApp")
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(height: 64)
                            .opacity(textOpacity)

                        Text(fullText)
                            .font(.custom("InstrumentSerif-Regular", size: 36))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.black.opacity(0.8))
                            .padding(.horizontal, 20)
                            .minimumScaleFactor(0.5)
                            .lineLimit(3)
                            .frame(minHeight: 100)
                            .opacity(textOpacity)
                            .onAppear {
                                withAnimation(.easeOut(duration: 0.6)) {
                                    textOpacity = 1
                                }
                            }
                        
                        DayflowSurfaceButton(
                            action: onStart,
                            content: { Text("Start").font(.custom("Nunito", size: 16)).fontWeight(.semibold) },
                            background: Color(red: 0.25, green: 0.17, blue: 0),
                            foreground: .white,
                            borderColor: .clear,
                            cornerRadius: 8,
                            horizontalPadding: 28,
                            verticalPadding: 14,
                            minWidth: 160,
                            showOverlayStroke: true
                        )
                            .opacity(textOpacity)
                            .animation(.easeIn(duration: 0.3).delay(0.4), value: textOpacity)
                    }
                    .padding(.top, 20)
                    
                    Spacer()
                }
                .zIndex(1)
                
                // Timeline image
                VStack {
                    Spacer()
                    Image("OnboardingTimeline")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 800)
                        .offset(y: timelineOffset)
                        .opacity(timelineOffset > 0 ? 0 : 1)
                        .onAppear {
                            withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0).delay(0.3)) {
                                timelineOffset = 0
                            }
                        }
                }
        }
    }
}

struct OnboardingCategorySetupView: View {
    let onNext: () -> Void
    @EnvironmentObject private var categoryStore: CategoryStore

    var body: some View {
        VStack(spacing: 32) {
            ColorOrganizerRoot(presentationStyle: .embedded, onDismiss: {
                onNext()
            })
            .environmentObject(categoryStore)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 600)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompletionView: View {
    let onFinish: () -> Void
    @State private var referralSelection: ReferralOption? = nil
    @State private var referralDetail: String = ""

    /// User must select a referral option (and provide detail if required) to proceed
    private var canProceed: Bool {
        guard let option = referralSelection else { return false }
        if option.requiresDetail {
            return !referralDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(spacing: 16) {
            Image("DayflowLogoMainApp")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(height: 64)

            // Title section
            VStack(spacing: 8) {
                Text("You are ready to go!")
                    .font(.custom("InstrumentSerif-Regular", size: 36))
                    .foregroundColor(.black.opacity(0.9))
                
                Text("Welcome to Dayflow! Let it run for about 30 minutes to gather enough data, then come back to explore your personalized timeline. If you have any issues, feature requests, or feedback please use the feedback tab. I would love to hear from you! ")
                    .font(.custom("Nunito", size: 15))
                    .foregroundColor(.black.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Referral survey replaces the static preview
            ReferralSurveyView(
                prompt: "I have a small favor to ask. I'd love to understand where you first heard about Dayflow.",
                showSubmitButton: false,
                selectedReferral: $referralSelection,
                customReferral: $referralDetail
            )

            // Proceed button (disabled until referral is selected)
            DayflowSurfaceButton(
                action: {
                    submitReferralIfNeeded()
                    onFinish()
                },
                content: {
                    Text("Start")
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                },
                background: canProceed
                    ? Color(red: 0.25, green: 0.17, blue: 0)
                    : Color(red: 0.88, green: 0.84, blue: 0.78),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 40,
                verticalPadding: 14,
                minWidth: 200,
                showOverlayStroke: true
            )
            .disabled(!canProceed)
            .padding(.top, 16)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 60)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitReferralIfNeeded() {
        guard let payload = referralPayload() else { return }
        AnalyticsService.shared.capture("onboarding_referral", payload)
    }

    private func referralPayload() -> [String: String]? {
        guard let option = referralSelection else { return nil }

        var payload: [String: String] = [
            "source": option.analyticsValue,
            "surface": "onboarding_completion"
        ]

        let trimmedDetail = referralDetail.trimmingCharacters(in: .whitespacesAndNewlines)

        if option.requiresDetail {
            guard !trimmedDetail.isEmpty else { return nil }
            payload["detail"] = trimmedDetail
        } else if !trimmedDetail.isEmpty {
            payload["detail"] = trimmedDetail
        }

        return payload
    }
}

struct OnboardingFlow_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingFlow()
            .environmentObject(AppState.shared)
            .frame(width: 1200, height: 800)
    }
}
