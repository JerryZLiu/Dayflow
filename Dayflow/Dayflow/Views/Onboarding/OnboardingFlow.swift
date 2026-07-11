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
  @AppStorage("onboardingSelectedProviderID") private var selectedProviderIDRawValue =
    LLMProviderID.gemini.rawValue
  @AppStorage("onboardingHasPaidAI") private var savedHasPaidAISelection = ""
  @EnvironmentObject private var categoryStore: CategoryStore
  @State private var userHasPaidAI: Bool? = OnboardingFlow.loadSavedHasPaidAISelection()
  @State private var flowID = UUID().uuidString.lowercased()
  @State private var routingSaveErrorMessage: String?

  private var selectedProviderID: LLMProviderID {
    LLMProviderID(rawValue: selectedProviderIDRawValue) ?? .gemini
  }

  private var onboardingFilledSegments: Int {
    switch step {
    case .introVideo: return 0
    case .roleSelection: return 0
    case .downloadReason: return 1
    case .referral: return 2
    case .preferences: return 3
    case .llmSelection: return 4
    case .llmSetup: return 5
    case .categories: return 6
    case .categoryColors: return 7
    case .screen: return 8
    case .completion: return 9
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
            advance(selectedRole: selectedRole)
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_role_selection")
        }

      case .downloadReason:
        OnboardingPrototypeDownloadReasonStep(
          onContinue: { reasons, otherDetail in
            var payload: [String: Any] = [
              "reasons": reasons.map(\.analyticsValue),
              "surface": "onboarding_download_reason",
            ]

            if let otherDetail, !otherDetail.isEmpty {
              payload["other_detail"] = otherDetail
            }

            AnalyticsService.shared.capture("onboarding_download_reason", payload)
            advance(extraProps: payload)
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_download_reason")
        }

      case .referral:
        OnboardingPrototypeReferralStep(
          onContinue: { option, detail in
            var payload: [String: Any] = [
              "source": option.analyticsValue,
              "surface": "onboarding_referral",
            ]

            if let detail, !detail.isEmpty {
              payload["detail"] = detail
            }

            AnalyticsService.shared.capture("onboarding_referral", payload)
            advance(extraProps: payload)
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
            advance(extraProps: ["has_paid_ai": hasPaidAI])
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_preferences")
        }

      case .llmSelection:
        OnboardingPrototypeChooseProviderStep(
          hasPaidAI: userHasPaidAI ?? false,
          flowID: flowID,
          flowVariant: "production_onboarding",
          onSelect: { providerID in
            if providerID == .dayflow, !saveRouting(primary: providerID) {
              return
            }
            selectedProviderIDRawValue = providerID.rawValue

            var props: [String: Any] = [
              "provider": providerID.analyticsName,
              "provider_id": providerID.rawValue,
            ]
            if providerID == .local {
              let localEngine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
              props["local_engine"] = localEngine
            }
            AnalyticsService.shared.capture("llm_provider_selected", props)
            if providerID == .dayflow {
              recordCurrentProvider(providerID)
            }
            advance(extraProps: props)
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_llm_selection")
        }

      case .llmSetup:
        // COMPLETELY STANDALONE - no parent constraints!
        LLMProviderSetupView(
          providerType: selectedProviderID,
          onBack: {
            setStep(.llmSelection)
          },
          onComplete: {
            guard saveRouting(primary: selectedProviderID, presentsError: false) else {
              return false
            }
            recordCurrentProvider(selectedProviderID)
            advance()
            return true
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
              (selectedProviderID == .dayflow) ? .llmSelection : .llmSetup
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
            AnalyticsService.shared.flush()
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_completion")
        }
      }

      // Progress ring — bottom-left, always in tree (opacity toggle preserves @State)
      ProgressRingView(totalSegments: 9, filledSegments: onboardingFilledSegments)
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
    .alert(
      "Couldn't save your provider",
      isPresented: Binding(
        get: { routingSaveErrorMessage != nil },
        set: { isPresented in
          if !isPresented {
            routingSaveErrorMessage = nil
          }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        routingSaveErrorMessage = nil
      }
    } message: {
      Text(routingSaveErrorMessage ?? "Please try again.")
    }
  }

  private func saveRouting(
    primary providerID: LLMProviderID,
    presentsError: Bool = true
  ) -> Bool {
    do {
      try LLMProviderRoutingStore.save(LLMProviderRouting(primary: providerID))
      return true
    } catch {
      if presentsError {
        routingSaveErrorMessage = "Dayflow couldn't save this provider. Please try again."
      }
      AnalyticsService.shared.capture(
        "llm_provider_routing_save_failed",
        [
          "provider_id": providerID.rawValue,
          "surface": "onboarding",
        ]
      )
      return false
    }
  }

  private func recordCurrentProvider(_ providerID: LLMProviderID) {
    AnalyticsService.shared.setPersonProperties([
      "current_llm_provider": providerID.analyticsName,
      "current_llm_provider_id": providerID.rawValue,
    ])
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

  private func markStepCompleted(
    _ completedStep: OnboardingStep,
    extraProps: [String: Any] = [:]
  ) {
    var props: [String: Any] = ["step": completedStep.analyticsName]
    extraProps.forEach { key, value in
      props[key] = value
    }
    AnalyticsService.shared.capture("onboarding_step_completed", props)
  }

  private func advance(selectedRole: String? = nil, extraProps: [String: Any] = [:]) {
    switch step {
    case .introVideo:
      markStepCompleted(step)
      step.next()
      savedStepRawValue = step.rawValue
    case .roleSelection:
      let extraProps = selectedRole.map { ["role": $0] } ?? [:]
      markStepCompleted(step, extraProps: extraProps)
      step.next()
      savedStepRawValue = step.rawValue
    case .downloadReason:
      markStepCompleted(step, extraProps: extraProps)
      step.next()
      savedStepRawValue = step.rawValue
    case .referral:
      markStepCompleted(step, extraProps: extraProps)
      step.next()
      savedStepRawValue = step.rawValue
    case .preferences:
      markStepCompleted(step, extraProps: extraProps)
      step.next()
      savedStepRawValue = step.rawValue
    case .llmSelection:
      markStepCompleted(step, extraProps: extraProps)
      let nextStep: OnboardingStep =
        (selectedProviderID == .dayflow) ? .categories : .llmSetup
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
  case introVideo, roleSelection, downloadReason, referral, preferences, llmSelection, llmSetup,
    categories, categoryColors, screen, completion

  var analyticsName: String {
    switch self {
    case .introVideo:
      return "intro_video"
    case .roleSelection:
      return "role_selection"
    case .downloadReason:
      return "download_reason"
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
  static let currentVersion = 5

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

    // v4 → v5: insert downloadReason after roleSelection
    // Old v4: introVideo=0, roleSelection=1, referral=2, preferences=3, llmSelection=4, llmSetup=5, categories=6, categoryColors=7, screen=8, completion=9
    // New v5: introVideo=0, roleSelection=1, downloadReason=2, referral=3, preferences=4, llmSelection=5, llmSetup=6, categories=7, categoryColors=8, screen=9, completion=10
    if storedVersion < 5 {
      migratedValue = migrateV4toV5(migratedValue)
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

  static func migrateV4toV5(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0...1: return rawValue  // unchanged through roleSelection
    case 2...9: return rawValue + 1  // steps after roleSelection shift forward
    default: return 0
    }
  }

  // Keep for testing compatibility
  static func migrateRawValue(_ rawValue: Int) -> Int {
    migrateV4toV5(migrateV3toV4(migrateV2toV3(migrateV1toV2(migrateV0toV1(rawValue)))))
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
            content: { Text("Start").font(.custom("Figtree", size: 16)).fontWeight(.semibold) },
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

struct OnboardingPrototypeDownloadReasonStep: View {
  let onContinue: ([DownloadReasonOption], String?) -> Void

  @State private var shuffledReasons = DownloadReasonOption.randomizedConcreteOptions()
  @State private var selectedReasons: Set<DownloadReasonOption> = []
  @State private var otherText = ""

  private var options: [DownloadReasonOption] {
    shuffledReasons + [.other]
  }

  private var trimmedOtherText: String {
    otherText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canContinue: Bool {
    guard !selectedReasons.isEmpty else { return false }
    if selectedReasons.contains(.other) {
      return !trimmedOtherText.isEmpty
    }
    return true
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 48)

      VStack(spacing: 22) {
        VStack(spacing: 4) {
          Text("What are you hoping to get out of Dayflow?")
            .font(.custom("Figtree", size: 20))
            .foregroundColor(Color(hex: "89380E"))

          Text("This helps personalize the experience for you.")
            .font(.custom("Figtree", size: 16))
            .foregroundColor(Color(hex: "89380E").opacity(0.78))
        }
        .multilineTextAlignment(.center)

        VStack(spacing: 8) {
          ForEach(options) { option in
            downloadReasonRow(option)
          }
        }

        otherField
      }
      .frame(maxWidth: 760)
      .padding(.horizontal, 24)

      Spacer()

      DayflowSurfaceButton(
        action: {
          let selectedInDisplayOrder = options.filter { selectedReasons.contains($0) }
          let detail = selectedReasons.contains(.other) ? trimmedOtherText : nil
          onContinue(selectedInDisplayOrder, detail)
        },
        content: {
          Text("Continue")
            .font(.custom("Figtree", size: 14))
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
        .frame(height: 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.easeInOut(duration: 0.2), value: selectedReasons)
  }

  private func downloadReasonRow(_ option: DownloadReasonOption) -> some View {
    let isSelected = selectedReasons.contains(option)

    return Button {
      toggle(option)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(Color(hex: "402C00"))

        Text(option.displayName)
          .font(.custom("Figtree", size: 15))
          .foregroundColor(Color(hex: "492304"))
          .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? Color(hex: "FFE5CF").opacity(0.48) : Color.white.opacity(0.42))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(isSelected ? Color(hex: "FFCCA7") : Color(hex: "E4D3C2"), lineWidth: 1)
      )
      .shadow(
        color: isSelected
          ? Color(red: 1, green: 0.416, blue: 0).opacity(0.22)
          : Color(hex: "AF7246").opacity(0.12),
        radius: isSelected ? 3 : 2,
        x: 0,
        y: 0
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  private var otherField: some View {
    TextField("Tell me more", text: $otherText)
      .font(.custom("Figtree", size: 16))
      .foregroundColor(Color(hex: "492304"))
      .textFieldStyle(.plain)
      .padding(.horizontal, 12)
      .frame(height: 36)
      .background(Color.white.opacity(0.42))
      .cornerRadius(5)
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .stroke(Color(hex: "E4D3C2"), lineWidth: 1)
      )
      .shadow(
        color: Color(hex: "AF7246").opacity(0.15),
        radius: 2, x: 0, y: 0
      )
      .opacity(selectedReasons.contains(.other) ? 1 : 0)
      .disabled(!selectedReasons.contains(.other))
      .allowsHitTesting(selectedReasons.contains(.other))
      .frame(maxWidth: .infinity)
  }

  private func toggle(_ option: DownloadReasonOption) {
    if selectedReasons.contains(option) {
      selectedReasons.remove(option)
      if option == .other {
        otherText = ""
      }
    } else {
      selectedReasons.insert(option)
    }
  }
}

enum DownloadReasonOption: CaseIterable, Identifiable, Hashable {
  case automaticLog
  case proofOfWork
  case cutDistractions
  case productiveFocused
  case openSourcePrivate
  case other

  var id: String { analyticsValue }

  static func randomizedConcreteOptions() -> [DownloadReasonOption] {
    allCases.filter { $0 != .other }.shuffled()
  }

  var displayName: String {
    switch self {
    case .automaticLog:
      return "To keep an automatic log of what I worked on"
    case .proofOfWork:
      return "To make my work more visible for standups, reviews, or promotions"
    case .cutDistractions:
      return "To find and cut distractions"
    case .productiveFocused:
      return "To be more productive or focused"
    case .openSourcePrivate:
      return "I wanted a tracker that's open source and keeps my data private"
    case .other:
      return "Other"
    }
  }

  var analyticsValue: String {
    switch self {
    case .automaticLog:
      return "automatic_log"
    case .proofOfWork:
      return "proof_of_work"
    case .cutDistractions:
      return "cut_distractions"
    case .productiveFocused:
      return "productive_focused"
    case .openSourcePrivate:
      return "open_source_private"
    case .other:
      return "other"
    }
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
            .font(.custom("Figtree", size: 14))
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
        .font(.custom("Figtree", size: 15))
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
            .font(.custom("Figtree", size: 16))
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
