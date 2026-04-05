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

  private var onboardingFilledSegments: Int {
    switch step {
    case .introVideo: return 0
    case .roleSelection: return 0
    case .referral: return 1
    case .preferences: return 2
    case .llmSelection: return 3
    case .llmSetup: return 4
    case .categories: return 5
    case .categoryColors: return 6
    case .screen: return 7
    case .completion: return 8
    }
  }

  private var showsProgressRing: Bool {
    step != .introVideo && step != .llmSelection && step != .categoryColors
  }

  @ViewBuilder
  var body: some View {
    ZStack(alignment: .bottomLeading) {
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
            categoryStore.setOnboardingRole(selectedRole)
            AnalyticsService.shared.capture("onboarding_role_selected", ["role": selectedRole])
            advance()
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_role_selection")
        }

      case .referral:
        OnboardingPrototypeReferralStep(
          onContinue: { option, detail in
            var payload: [String: String] = [
              "source": option.analyticsValue,
              "surface": "onboarding_referral",
            ]

            if let detail, !detail.isEmpty {
              payload["detail"] = detail
            }

            AnalyticsService.shared.capture("onboarding_referral", payload)
            advance()
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_referral")
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
        OnboardingCategoryStepView(
          onBack: {
            // Go back to llmSetup, or llmSelection if they picked dayflow
            let backStep: OnboardingStep =
              (selectedProvider == "dayflow") ? .llmSelection : .llmSetup
            setStep(backStep)
          },
          onNext: {
            advance()
          }
        )
        .environmentObject(categoryStore)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_categories")
        }

      case .categoryColors:
        OnboardingCategoryColorStepView(
          onBack: {
            setStep(.categories)
          },
          onNext: {
            advance()
          }
        )
        .environmentObject(categoryStore)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      case .screen:
        ScreenRecordingPermissionView(
          onBack: {
            setStep(.categoryColors)
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

            markStepCompleted(.completion)
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

      // Progress ring — bottom-left, always in tree (opacity toggle preserves @State)
      ProgressRingView(totalSegments: 8, filledSegments: onboardingFilledSegments)
        .opacity(showsProgressRing ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: showsProgressRing)
        .padding(.leading, 0)
        .padding(.bottom, 0)
        .allowsHitTesting(false)
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
      if savedStep == .categories {
        prepareCategoriesForOnboardingIfNeeded()
      }
      step = savedStep
    }
  }

  private var persistedHasPaidAISelection: Bool? {
    Self.decodeHasPaidAISelection(savedHasPaidAISelection)
  }

  private func setStep(_ newStep: OnboardingStep) {
    if newStep == .categories {
      prepareCategoriesForOnboardingIfNeeded()
    }
    step = newStep
    savedStepRawValue = newStep.rawValue
  }

  private func prepareCategoriesForOnboardingIfNeeded() {
    categoryStore.applyOnboardingPresetIfNeeded()
  }

  private func markStepCompleted(_ completedStep: OnboardingStep) {
    AnalyticsService.shared.capture(
      "onboarding_step_completed", ["step": completedStep.analyticsName])
  }

  private func advance() {
    switch step {
    case .introVideo:
      markStepCompleted(step)
      step.next()
      savedStepRawValue = step.rawValue
    case .roleSelection:
      markStepCompleted(step)
      step.next()
      savedStepRawValue = step.rawValue
    case .referral:
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
      setStep(.categories)
    case .categories:
      markStepCompleted(step)
      setStep(.categoryColors)
    case .categoryColors:
      markStepCompleted(step)
      setStep(.screen)
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
              AppState.shared.setRecording(true, analyticsReason: "onboarding")
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
  case introVideo, roleSelection, referral, preferences, llmSelection, llmSetup, categories,
    categoryColors, screen, completion

  var analyticsName: String {
    switch self {
    case .introVideo:
      return "intro_video"
    case .roleSelection:
      return "role_selection"
    case .referral:
      return "referral"
    case .preferences:
      return "preferences"
    case .llmSelection:
      return "llm_selection"
    case .llmSetup:
      return "llm_setup"
    case .categories:
      return "categories"
    case .categoryColors:
      return "category_colors"
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
  static let currentVersion = 4

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

    // v2 → v3: insert referral after role selection
    // Old v2: introVideo=0, roleSelection=1, preferences=2, llmSelection=3, llmSetup=4, categories=5, screen=6, completion=7
    // New v3: introVideo=0, roleSelection=1, referral=2, preferences=3, llmSelection=4, llmSetup=5, categories=6, screen=7, completion=8
    if storedVersion < 3 {
      migratedValue = migrateV2toV3(migratedValue)
    }

    // v3 → v4: insert categoryColors after categories
    // Old v3: introVideo=0, roleSelection=1, referral=2, preferences=3, llmSelection=4, llmSetup=5, categories=6, screen=7, completion=8
    // New v4: introVideo=0, roleSelection=1, referral=2, preferences=3, llmSelection=4, llmSetup=5, categories=6, categoryColors=7, screen=8, completion=9
    if storedVersion < 4 {
      migratedValue = migrateV3toV4(migratedValue)
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

  static func migrateV2toV3(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0: return 0  // introVideo → introVideo
    case 1: return 1  // roleSelection → roleSelection
    case 2: return 3  // preferences → preferences
    case 3: return 4  // llmSelection → llmSelection
    case 4: return 5  // llmSetup → llmSetup
    case 5: return 6  // categories → categories
    case 6: return 7  // screen → screen
    case 7: return 8  // completion → completion
    default: return 0
    }
  }

  static func migrateV3toV4(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0...6: return rawValue  // unchanged through categories
    case 7: return 8  // screen → screen
    case 8: return 9  // completion → completion
    default: return 0
    }
  }

  // Keep for testing compatibility
  static func migrateRawValue(_ rawValue: Int) -> Int {
    migrateV3toV4(migrateV2toV3(migrateV1toV2(migrateV0toV1(rawValue))))
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

struct OnboardingCategoryColorStepView: View {
  let onBack: () -> Void
  let onNext: () -> Void
  @EnvironmentObject private var categoryStore: CategoryStore

  var body: some View {
    VStack(spacing: 32) {
      ColorOrganizerRoot(
        presentationStyle: .embedded,
        flowMode: .colorsOnly,
        onBack: onBack,
        onDismiss: {
          onNext()
        },
        analyticsSurface: "onboarding"
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

struct OnboardingPrototypeReferralStep: View {
  let onContinue: (ReferralOption, String?) -> Void

  @State private var selectedReferral: ReferralOption? = nil
  @State private var referralDetail = ""

  private var trimmedDetail: String {
    referralDetail.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canContinue: Bool {
    guard let option = selectedReferral else { return false }
    if option.requiresDetail {
      return !trimmedDetail.isEmpty
    }
    return true
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 39)

      Text("One quick question")
        .font(.custom("InstrumentSerif-Regular", size: 40))
        .tracking(-1.2)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(hex: "492304"))
        .lineSpacing(40 * 0.2)
        .frame(maxWidth: 708)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()
        .frame(height: 48)

      VStack(spacing: 20) {
        ReferralSurveyView(
          prompt: "Where did you first hear about Dayflow?",
          showSubmitButton: false,
          selectedReferral: $selectedReferral,
          customReferral: $referralDetail
        )
      }
      .frame(maxWidth: 720)
      .padding(.horizontal, 24)

      Spacer()

      DayflowSurfaceButton(
        action: {
          guard let option = selectedReferral else { return }
          let detail = option.requiresDetail ? trimmedDetail : nil
          onContinue(option, detail)
        },
        content: {
          Text("Continue")
            .font(.custom("Nunito", size: 14))
            .fontWeight(.semibold)
        },
        background: Color(hex: "402C00"),
        foreground: .white,
        borderColor: .clear,
        cornerRadius: 8,
        horizontalPadding: 59,
        verticalPadding: 12,
        minWidth: 234,
        showOverlayStroke: true
      )
      .opacity(canContinue ? 1.0 : 0.4)
      .allowsHitTesting(canContinue)
      .animation(.easeInOut(duration: 0.2), value: canContinue)

      Spacer()
        .frame(height: 60)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct CompletionView: View {
  let onFinish: () -> Void

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

        Text(
          "To get useful insights, let Dayflow run in the background for an hour or two to gather enough context, then check back in."
        )
        .font(.custom("Nunito", size: 15))
        .foregroundColor(.black.opacity(0.6))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }

      DayflowSurfaceButton(
        action: {
          onFinish()
        },
        content: {
          Text("Launch Dayflow")
            .font(.custom("Nunito", size: 16))
            .fontWeight(.semibold)
        },
        background: Color(red: 0.25, green: 0.17, blue: 0),
        foreground: .white,
        borderColor: .clear,
        cornerRadius: 8,
        horizontalPadding: 40,
        verticalPadding: 14,
        minWidth: 200,
        showOverlayStroke: true
      )
      .padding(.top, 16)
    }
    .padding(.horizontal, 48)
    .padding(.vertical, 60)
    .frame(maxWidth: 720)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct OnboardingFlow_Previews: PreviewProvider {
  static var previews: some View {
    OnboardingFlow()
      .environmentObject(AppState.shared)
      .frame(width: 1200, height: 800)
  }
}
