//
//  OnboardingFlow.swift
//  Dayflow
//

import Foundation
import ScreenCaptureKit
import SwiftUI

// Window manager removed - no longer needed!

struct OnboardingFlow: View {
  @AppStorage("onboardingStep") private var savedStepRawValue = 0
  @State private var step: OnboardingStep = OnboardingStepMigration.restoredStep()
  @AppStorage("didOnboard") private var didOnboard = false
  @AppStorage("selectedLLMProvider") private var selectedProvider: String = "gemini"
  @AppStorage("onboardingHasPaidAI") private var savedHasPaidAISelection = ""
  @EnvironmentObject private var categoryStore: CategoryStore
  @State private var userHasPaidAI: Bool? = OnboardingFlow.loadSavedHasPaidAISelection()

  @ViewBuilder
  var body: some View {
    ZStack {
      // NO NESTING! Just render the appropriate view directly - NO GROUP!
      switch step {
      case .introVideo:
        OnboardingPrototypeVideoIntroStep(
          videoName: "DayflowOnboarding",
          onPlaybackStarted: {
            AnalyticsService.shared.capture(
              "onboarding_video_started", ["asset": "DayflowOnboarding.mp4"])
          },
          onPlaybackCompleted: { reason in
            AnalyticsService.shared.capture("onboarding_video_completed", ["reason": reason])
            advance()
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_intro_video")
          if !UserDefaults.standard.bool(forKey: "onboardingStarted") {
            AnalyticsService.shared.capture("onboarding_started")
            UserDefaults.standard.set(true, forKey: "onboardingStarted")
            AnalyticsService.shared.setPersonProperties(["onboarding_status": "in_progress"])
          }
        }

      case .roleSelection:
        OnboardingPrototypeRoleSelectionStep(
          onContinue: { selectedRole in
            AnalyticsService.shared.capture("onboarding_role_selected", ["role": selectedRole])
            advance()
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_role_selection")
        }

      case .preferences:
        OnboardingPrototypePreferencesStep(
          onContinue: { hasPaidAI in
            userHasPaidAI = hasPaidAI
            savedHasPaidAISelection = hasPaidAI ? "yes" : "no"
            AnalyticsService.shared.capture("onboarding_preferences", ["has_paid_ai": hasPaidAI])
            advance()
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_preferences")
        }

      case .llmSelection:
        OnboardingPrototypeChooseProviderStep(
          hasPaidAI: userHasPaidAI ?? false,
          onSelect: { providerTitle in
            // Map display title → internal provider ID
            let providerID: String
            switch providerTitle {
            case "ChatGPT or Claude": providerID = "chatgpt_claude"
            case "Google Gemini": providerID = "gemini"
            case "Local AI": providerID = "ollama"
            default: providerID = "gemini"
            }
            selectedProvider = providerID

            var props: [String: Any] = ["provider": providerID]
            if providerID == "ollama" {
              let localEngine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
              props["local_engine"] = localEngine
            }
            AnalyticsService.shared.capture("llm_provider_selected", props)
            AnalyticsService.shared.setPersonProperties(["current_llm_provider": providerID])
            advance()
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
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
          AnalyticsService.shared.screen("onboarding_screen_recording")
        }

      case .completion:
        CompletionView(
          onFinish: {
            // Create sample card BEFORE switching views (sync write)
            StorageManager.shared.createOnboardingCard()

            didOnboard = true
            savedStepRawValue = 0
            savedHasPaidAISelection = ""
            AnalyticsService.shared.capture("onboarding_completed")
            AnalyticsService.shared.setPersonProperties(["onboarding_status": "completed"])
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_completion")
        }
      }
    }
    .animation(.easeInOut(duration: 0.5), value: step)
    .onAppear {
      restoreSavedStep()
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
    userHasPaidAI = persistedHasPaidAISelection
    if let savedStep = OnboardingStep(rawValue: migratedValue) {
      step = savedStep
    }
  }

  private var persistedHasPaidAISelection: Bool? {
    Self.decodeHasPaidAISelection(savedHasPaidAISelection)
  }

  private func setStep(_ newStep: OnboardingStep) {
    step = newStep
    savedStepRawValue = newStep.rawValue
  }

  private func advance() {
    func markStepCompleted(_ s: OnboardingStep) {
      AnalyticsService.shared.capture("onboarding_step_completed", ["step": s.analyticsName])
    }

    switch step {
    case .introVideo:
      markStepCompleted(step)
      step.next()
      savedStepRawValue = step.rawValue
    case .roleSelection:
      markStepCompleted(step)
      step.next()
      savedStepRawValue = step.rawValue
    case .preferences:
      markStepCompleted(step)
      step.next()
      savedStepRawValue = step.rawValue
    case .llmSelection:
      markStepCompleted(step)
      let nextStep: OnboardingStep = (selectedProvider == "dayflow") ? .categories : .llmSetup
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

      // Only try to start recording if we already have permission
      if CGPreflightScreenCaptureAccess() {
        Task {
          do {
            // Verify we have permission
            _ = try await SCShareableContent.excludingDesktopWindows(
              false, onScreenWindowsOnly: true)
            // Start recording
            await MainActor.run {
              AppState.shared.isRecording = true
            }
          } catch {
            // Permission not granted yet, that's ok
            // It will start after restart
            print("Will start recording after restart")
          }
        }
      }
    case .completion:
      didOnboard = true
      savedStepRawValue = 0  // Reset for next time
    }
  }

  private static func loadSavedHasPaidAISelection(defaults: UserDefaults = .standard) -> Bool? {
    decodeHasPaidAISelection(defaults.string(forKey: "onboardingHasPaidAI") ?? "")
  }

  private static func decodeHasPaidAISelection(_ value: String) -> Bool? {
    switch value {
    case "yes":
      return true
    case "no":
      return false
    default:
      return nil
    }
  }

}

/// Wizard step order
enum OnboardingStep: Int, CaseIterable {
  case introVideo, roleSelection, preferences, llmSelection, llmSetup, categories, screen,
    completion

  var analyticsName: String {
    switch self {
    case .introVideo:
      return "intro_video"
    case .roleSelection:
      return "role_selection"
    case .preferences:
      return "preferences"
    case .llmSelection:
      return "llm_selection"
    case .llmSetup:
      return "llm_setup"
    case .categories:
      return "categories"
    case .screen:
      return "screen_recording"
    case .completion:
      return "completion"
    }
  }

  static func hasPassedScreenRecordingStep(rawValue: Int) -> Bool {
    guard let step = OnboardingStep(rawValue: rawValue) else { return false }
    return step.rawValue > OnboardingStep.screen.rawValue
  }

  mutating func next() { self = OnboardingStep(rawValue: rawValue + 1)! }
}

enum OnboardingStepMigration {
  static let schemaVersionKey = "onboardingStepSchemaVersion"
  private static let onboardingStepKey = "onboardingStep"
  static let currentVersion = 2

  @discardableResult
  static func migrateIfNeeded(defaults: UserDefaults = .standard) -> Int {
    let storedVersion = defaults.integer(forKey: schemaVersionKey)
    let rawValue = defaults.integer(forKey: onboardingStepKey)
    guard storedVersion < currentVersion else {
      return rawValue
    }

    var migratedValue = rawValue

    // v0 → v1: reorder steps
    if storedVersion < 1 {
      migratedValue = migrateV0toV1(migratedValue)
    }

    // v1 → v2: welcome/howItWorks replaced by introVideo/roleSelection/preferences
    // Old v1: welcome=0, howItWorks=1, llmSelection=2, llmSetup=3, categories=4, screen=5, completion=6
    // New v2: introVideo=0, roleSelection=1, preferences=2, llmSelection=3, llmSetup=4, categories=5, screen=6, completion=7
    if storedVersion < 2 {
      migratedValue = migrateV1toV2(migratedValue)
    }

    defaults.set(migratedValue, forKey: onboardingStepKey)
    defaults.set(currentVersion, forKey: schemaVersionKey)
    return migratedValue
  }

  static func restoredStep(defaults: UserDefaults = .standard) -> OnboardingStep {
    OnboardingStep(rawValue: migrateIfNeeded(defaults: defaults)) ?? .introVideo
  }

  static func migrateV0toV1(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0: return 0  // welcome
    case 1: return 1  // how it works
    case 2: return 5  // legacy screen step moves after categories
    case 3: return 2  // llm selection
    case 4: return 3  // llm setup
    case 5: return 4  // categories
    case 6: return 6  // completion
    default: return 0
    }
  }

  static func migrateV1toV2(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0: return 0  // welcome → introVideo (restart from beginning)
    case 1: return 0  // howItWorks → introVideo (restart from beginning)
    case 2: return 3  // llmSelection → llmSelection
    case 3: return 4  // llmSetup → llmSetup
    case 4: return 5  // categories → categories
    case 5: return 6  // screen → screen
    case 6: return 7  // completion → completion
    default: return 0
    }
  }

  // Keep for testing compatibility
  static func migrateRawValue(_ rawValue: Int) -> Int {
    migrateV1toV2(migrateV0toV1(rawValue))
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
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0).delay(0.3))
            {
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
      ColorOrganizerRoot(
        presentationStyle: .embedded,
        onDismiss: {
          onNext()
        }
      )
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

      }

      // Referral survey replaces the static preview
      ReferralSurveyView(
        prompt:
          "I have a small favor to ask. I'd love to understand where you first heard about Dayflow.",
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
      "surface": "onboarding_completion",
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
