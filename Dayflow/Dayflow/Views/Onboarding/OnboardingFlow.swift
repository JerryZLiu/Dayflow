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
  @EnvironmentObject private var categoryStore: CategoryStore
  @State private var flowID = UUID().uuidString.lowercased()
  @State private var routingSaveErrorMessage: String?

  private var selectedProviderID: LLMProviderID {
    LLMProviderID(rawValue: selectedProviderIDRawValue) ?? .gemini
  }

  private var onboardingFilledSegments: Int {
    switch step {
    case .introVideo: return 0
    case .roleSelection: return 0
    case .referral: return 1
    case .llmSelection: return 2
    case .llmSetup: return 3
    case .screen: return 4
    case .personalGoal: return 5
    case .completion: return 6
    }
  }

  private var showsProgressRing: Bool {
    step != .introVideo && step != .llmSelection
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
            // Onboarding no longer has a category step, so apply the role's preset here.
            categoryStore.applyOnboardingPresetIfNeeded()
            AnalyticsService.shared.capture("onboarding_role_selected", ["role": selectedRole])
            advance(selectedRole: selectedRole)
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

      case .llmSelection:
        OnboardingPrototypeChooseProviderStep(
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
          onComplete: { configuredProviderID in
            guard saveRouting(primary: configuredProviderID, presentsError: false) else {
              return false
            }
            // Keep the stored selection in sync if the user switched CLI tools mid-setup
            selectedProviderIDRawValue = configuredProviderID.rawValue
            recordCurrentProvider(configuredProviderID)
            advance()
            return true
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_llm_setup")
        }

      case .screen:
        ScreenRecordingPermissionView(
          onBack: {
            // Go back to llmSetup, or llmSelection if they picked dayflow
            let backStep: OnboardingStep =
              (selectedProviderID == .dayflow) ? .llmSelection : .llmSetup
            setStep(backStep)
          },
          onNext: { advance() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_screen_recording")
        }

      case .personalGoal:
        OnboardingPersonalGoalStep(
          onContinue: { goal in
            let trimmedGoal = String(goal.prefix(OnboardingPersonalGoalStep.maxCharacters))
            let payload: [String: Any] = [
              "goal": trimmedGoal,
              "character_count": trimmedGoal.count,
              "skipped": trimmedGoal.isEmpty,
              "surface": "onboarding_personal_goal",
            ]
            AnalyticsService.shared.capture("onboarding_personal_goal", payload)
            advance(extraProps: ["skipped": trimmedGoal.isEmpty])
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          AnalyticsService.shared.screen("onboarding_personal_goal")
        }

      case .completion:
        CompletionView(
          onFinish: {
            // Create sample card BEFORE switching views (sync write)
            StorageManager.shared.createOnboardingCard()

            markStepCompleted(.completion)
            didOnboard = true
            savedStepRawValue = 0
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
      ProgressRingView(totalSegments: 6, filledSegments: onboardingFilledSegments)
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
      OnboardingBackdrop()
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
      Text(routingSaveErrorMessage ?? String(localized: "Please try again."))
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
        routingSaveErrorMessage = String(
          localized: "Dayflow couldn't save this provider. Please try again.")
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
    if let savedStep = OnboardingStep(rawValue: migratedValue) {
      step = savedStep
    }
  }

  private func setStep(_ newStep: OnboardingStep) {
    step = newStep
    savedStepRawValue = newStep.rawValue
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
    case .referral:
      markStepCompleted(step, extraProps: extraProps)
      step.next()
      savedStepRawValue = step.rawValue
    case .llmSelection:
      markStepCompleted(step, extraProps: extraProps)
      let nextStep: OnboardingStep =
        (selectedProviderID == .dayflow) ? .screen : .llmSetup
      setStep(nextStep)
    case .llmSetup:
      markStepCompleted(step)
      setStep(.screen)
    case .personalGoal:
      markStepCompleted(step, extraProps: extraProps)
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
}

/// Wizard step order
enum OnboardingStep: Int, CaseIterable {
  case introVideo, roleSelection, referral, llmSelection, llmSetup, screen, personalGoal, completion

  var analyticsName: String {
    switch self {
    case .introVideo:
      return "intro_video"
    case .roleSelection:
      return "role_selection"
    case .referral:
      return "referral"
    case .llmSelection:
      return "llm_selection"
    case .llmSetup:
      return "llm_setup"
    case .screen:
      return "screen_recording"
    case .personalGoal:
      return "personal_goal"
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
  static let currentVersion = 6

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

    // v5 → v6: remove downloadReason, preferences, categories and categoryColors; insert personalGoal after screen
    // Old v5: introVideo=0, roleSelection=1, downloadReason=2, referral=3, preferences=4, llmSelection=5, llmSetup=6, categories=7, categoryColors=8, screen=9, completion=10
    // New v6: introVideo=0, roleSelection=1, referral=2, llmSelection=3, llmSetup=4, screen=5, personalGoal=6, completion=7
    if storedVersion < 6 {
      migratedValue = migrateV5toV6(migratedValue)
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

  static func migrateV5toV6(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0...1: return rawValue  // introVideo, roleSelection unchanged
    case 2...3: return 2  // downloadReason, referral → referral
    case 4...5: return 3  // preferences, llmSelection → llmSelection
    case 6: return 4  // llmSetup → llmSetup
    case 7...9: return 5  // categories, categoryColors, screen → screen
    case 10: return 6  // completion → personalGoal (the new step right after screen)
    default: return 0
    }
  }

  // Keep for testing compatibility
  static func migrateRawValue(_ rawValue: Int) -> Int {
    migrateV5toV6(
      migrateV4toV5(migrateV3toV4(migrateV2toV3(migrateV1toV2(migrateV0toV1(rawValue))))))
  }
}

struct WelcomeView: View {
  let fullText: String
  @Binding var textOpacity: Double
  @Binding var timelineOffset: CGFloat
  let onStart: () -> Void

  // The splash artwork is authored at 1200×680. The flower button baked into
  // the art sits at this center; the hit target scales with the artwork.
  private let artworkSize = CGSize(width: 1200, height: 680)
  private let startButtonCenter = CGPoint(x: 600, y: 243)
  private let startButtonDiameter: CGFloat = 133

  @State private var isHoveringStart = false

  var body: some View {
    GeometryReader { proxy in
      let scale = max(
        proxy.size.width / artworkSize.width,
        proxy.size.height / artworkSize.height
      )
      let originX = (proxy.size.width - artworkSize.width * scale) / 2
      let originY = (proxy.size.height - artworkSize.height * scale) / 2

      ZStack(alignment: .topLeading) {
        Image("OnboardingSplash")
          .resizable()
          .frame(width: artworkSize.width * scale, height: artworkSize.height * scale)
          .offset(x: originX, y: originY)

        Button(action: onStart) {
          Circle()
            .fill(Color.white.opacity(isHoveringStart ? 0.18 : 0))
            .frame(
              width: startButtonDiameter * scale,
              height: startButtonDiameter * scale
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .scaleEffect(isHoveringStart ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isHoveringStart)
        .onHover { isHoveringStart = $0 }
        .position(
          x: originX + startButtonCenter.x * scale,
          y: originY + startButtonCenter.y * scale
        )
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .clipped()
    }
    .ignoresSafeArea()
    .opacity(textOpacity)
    .onAppear {
      withAnimation(.easeOut(duration: 0.6)) {
        textOpacity = 1
      }
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
          prompt: String(localized: "Where did you first hear about Dayflow?"),
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
            .font(.custom("Figtree", size: 16))
            .fontWeight(.medium)
        },
        background: Color(hex: "FF9F6F"),
        foreground: .white,
        borderColor: Color(hex: "F4C8B1"),
        cornerRadius: 200,
        horizontalPadding: 59,
        verticalPadding: 18,
        minWidth: 234,
        showOverlayStroke: false,
        innerGlowColor: Color(hex: "FFDCCB").opacity(0.9)
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

struct OnboardingPersonalGoalStep: View {
  static let maxCharacters = 2_000

  let onContinue: (String) -> Void

  @State private var goalText = ""

  private var trimmedGoal: String {
    goalText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 39)

      Text("Dayflow adapts to what you need")
        .font(.custom("InstrumentSerif-Regular", size: 40))
        .tracking(-1.2)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(hex: "492304"))
        .frame(maxWidth: 708)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()
        .frame(height: 12)

      Text("Tell Dayflow what you're hoping to get out of it.")
        .font(.custom("Figtree", size: 18))
        .foregroundColor(Color(hex: "89380E").opacity(0.78))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()
        .frame(height: 36)

      goalEditor
        .frame(maxWidth: 620)
        .padding(.horizontal, 24)

      Spacer()

      DayflowSurfaceButton(
        action: {
          onContinue(trimmedGoal)
        },
        content: {
          Text("Continue")
            .font(.custom("Figtree", size: 16))
            .fontWeight(.medium)
        },
        background: Color(hex: "FF9F6F"),
        foreground: .white,
        borderColor: Color(hex: "F4C8B1"),
        cornerRadius: 200,
        horizontalPadding: 59,
        verticalPadding: 18,
        minWidth: 234,
        showOverlayStroke: false,
        innerGlowColor: Color(hex: "FFDCCB").opacity(0.9)
      )
      .opacity(trimmedGoal.isEmpty ? 0.4 : 1.0)
      .allowsHitTesting(!trimmedGoal.isEmpty)
      .animation(.easeInOut(duration: 0.2), value: trimmedGoal.isEmpty)

      Button {
        onContinue("")
      } label: {
        Text("Skip")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(Color(hex: "89380E").opacity(0.7))
          .padding(.vertical, 8)
          .padding(.horizontal, 16)
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .padding(.top, 8)

      Spacer()
        .frame(height: 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var goalEditor: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $goalText)
        .font(.custom("Figtree", size: 16))
        .foregroundColor(Color(hex: "492304"))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .onChange(of: goalText) { _, newValue in
          if newValue.count > Self.maxCharacters {
            goalText = String(newValue.prefix(Self.maxCharacters))
          }
        }

      if goalText.isEmpty {
        Text(
          "e.g. See where my time actually goes, cut down on distractions, or have an automatic log of my work for standups and reviews."
        )
        .font(.custom("Figtree", size: 16))
        .foregroundColor(Color(hex: "492304").opacity(0.4))
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .allowsHitTesting(false)
      }
    }
    .frame(height: 160)
    .background(Color.white.opacity(0.42))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(hex: "E4D3C2"), lineWidth: 1)
    )
    .shadow(
      color: Color(hex: "AF7246").opacity(0.15),
      radius: 2, x: 0, y: 0
    )
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
        background: Color(hex: "FF9F6F"),
        foreground: .white,
        borderColor: Color(hex: "F4C8B1"),
        cornerRadius: 200,
        horizontalPadding: 40,
        verticalPadding: 14,
        minWidth: 200,
        showOverlayStroke: false,
        innerGlowColor: Color(hex: "FFDCCB").opacity(0.9)
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
