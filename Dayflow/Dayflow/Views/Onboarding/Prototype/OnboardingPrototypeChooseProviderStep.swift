//
//  OnboardingPrototypeChooseProviderStep.swift
//  Dayflow
//

import SwiftUI

// MARK: - Choose Provider Step

enum DayflowProOnboardingStep {
  case email
  case code
  case referralCode
  case freeMonthActive
  case trialOffer
  case trialActive

  var analyticsName: String {
    switch self {
    case .email:
      return "email"
    case .code:
      return "code"
    case .referralCode:
      return "referral_code"
    case .freeMonthActive:
      return "free_month_active"
    case .trialOffer:
      return "trial_offer"
    case .trialActive:
      return "trial_active"
    }
  }
}

private struct DayflowProReferralFieldShake: GeometryEffect {
  var travelDistance: CGFloat
  var shakes: CGFloat
  var animatableData: CGFloat

  func effectValue(size: CGSize) -> ProjectionTransform {
    let xOffset = travelDistance * sin(animatableData * .pi * shakes)
    return ProjectionTransform(CGAffineTransform(translationX: xOffset, y: 0))
  }
}

struct OnboardingPrototypeChooseProviderStep: View {
  let hasPaidAI: Bool
  let flowID: String
  let flowVariant: String
  let onSelect: (String) -> Void

  @ObservedObject private var authManager = DayflowAuthManager.shared
  @State private var showAllOptions = false
  @State private var isShowingDayflowProSignIn = false
  @State private var dayflowProStep: DayflowProOnboardingStep = .email
  @State private var dayflowProEmail = ""
  @State private var dayflowProCode = ""
  @State private var dayflowProReferralCode = ""
  @State private var dayflowProReferralShakeTrigger: CGFloat = 0
  @State private var dayflowProVerificationEmail = ""

  private let layoutScale: CGFloat = 0.8
  private let textScale: CGFloat = 1.1

  private func scaled(_ value: CGFloat) -> CGFloat {
    value * layoutScale
  }

  private func scaledText(_ value: CGFloat) -> CGFloat {
    scaled(value) * textScale
  }

  private var recommendedProviders: (first: String, second: String) {
    hasPaidAI ? ("dayflow", "chatgpt_claude") : ("dayflow", "gemini")
  }

  private func providerInfo(for id: String) -> (
    icon: String, title: String, pros: [String], caveats: [String]
  ) {
    switch id {
    case "dayflow":
      return (
        "dayflow_asset",
        "Dayflow Pro",
        [
          "Zero setup - just sign in and go",
          "Try it for free - no credit card necessary.",
          "Sync across devices",
          "Uses models with maximum intelligence for the best experience",
        ],
        []
      )
    case "chatgpt_claude":
      return (
        "chatgpt_claude_asset",
        "ChatGPT or Claude",
        [
          "Superior intelligence and reliability",
          "Uses less than 1% of your daily limit",
          "Perfect for ChatGPT Plus or Claude Pro paid subscribers",
        ],
        ["Requires installing Codex or Claude CLI"]
      )
    case "gemini":
      return (
        "gemini_asset",
        "Google Gemini",
        [
          "Uses Gemini's free tier (no subscription needed)",
          "Faster and more accurate than local models",
          "Much easier setup compared to local models",
        ],
        ["Less advanced compared to ChatGPT and Claude"]
      )
    case "local":
      return (
        "desktopcomputer",
        "Local AI",
        [
          "100% private - nothing leaves your computer"
        ],
        [
          "Significantly less intelligence",
          "Not recommended for those new to running local LLMs",
          "Requires 16GB+ of RAM, 4GB free disk space, M1 or later chip preferred",
        ]
      )
    default:
      return ("", "", [], [])
    }
  }

  private func secondaryBadgeText(for providerID: String) -> String {
    switch providerID {
    case "chatgpt_claude":
      return "USE EXISTING ACCOUNT"
    case "gemini":
      return "FREE SETUP"
    case "local":
      return "MOST PRIVATE"
    default:
      return "OPTION"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Title
      Text("Choose a way to run Dayflow")
        .font(.custom("InstrumentSerif-Regular", size: scaledText(40)))
        .tracking(-1.2 * layoutScale)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(hex: "492304"))
        .frame(maxWidth: .infinity)
        .padding(.top, scaled(25))
        .padding(.bottom, scaled(30))

      // Cards area
      if isShowingDayflowProSignIn {
        dayflowProSignInPanel
          .padding(.horizontal, scaled(140))
          .transition(.opacity)
      } else if showAllOptions {
        VStack(spacing: scaled(12)) {
          HStack(spacing: scaled(12)) {
            compactCard(for: "dayflow")
            compactCard(for: "chatgpt_claude")
          }
          HStack(spacing: scaled(12)) {
            compactCard(for: "gemini")
            compactCard(for: "local")
          }
        }
        .padding(.horizontal, scaled(40))
        .transition(.opacity)
      } else {
        let recs = recommendedProviders
        let first = providerInfo(for: recs.first)
        let second = providerInfo(for: recs.second)

        HStack(spacing: scaled(20)) {
          tallCard(
            icon: first.icon, title: first.title,
            badgeText: "RECOMMENDED", badgeType: .orange,
            pros: first.pros, caveats: first.caveats,
            isHighlighted: true
          )
          tallCard(
            icon: second.icon, title: second.title,
            badgeText: secondaryBadgeText(for: recs.second),
            badgeType: .green,
            pros: second.pros, caveats: second.caveats,
            isHighlighted: false
          )
        }
        .padding(.horizontal, scaled(40))
        .transition(.opacity)
      }

      Spacer()

      if isShowingDayflowProSignIn {
        Color.clear
          .frame(height: scaled(44))
          .padding(.bottom, scaled(30))
      } else {
        // Toggle pill
        Button {
          withAnimation(.easeInOut(duration: 0.3)) {
            showAllOptions.toggle()
          }
        } label: {
          Text(showAllOptions ? "See recommendations only" : "See all options")
            .font(.custom("Figtree", size: scaledText(16)))
            .foregroundColor(Color(hex: "492304"))
            .padding(.horizontal, scaled(20))
            .padding(.vertical, scaled(8))
            .background(Color.white.opacity(0.4))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E4D3C2"), lineWidth: 1))
            .shadow(
              color: Color(hex: "AF7246").opacity(0.15),
              radius: scaled(2),
              x: 0,
              y: 0
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .padding(.bottom, scaled(30))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Dayflow Pro sign-in

  private var dayflowProSignInPanel: some View {
    VStack(alignment: .leading, spacing: scaled(18)) {
      HStack(alignment: .center, spacing: scaled(14)) {
        ProviderIconView(icon: "dayflow_asset", scale: layoutScale)

        VStack(alignment: .leading, spacing: scaled(4)) {
          Text("Sign up / Sign in to Dayflow")
            .font(.custom("Figtree", size: scaledText(20)))
            .fontWeight(.semibold)
            .foregroundColor(Color(hex: "492304"))

          if let subtitle = dayflowProSubtitle {
            Text(subtitle)
              .font(.custom("Figtree", size: scaledText(13)))
              .foregroundColor(Color(hex: "89380E").opacity(0.75))
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Spacer()

        Button {
          withAnimation(.easeInOut(duration: 0.25)) {
            isShowingDayflowProSignIn = false
            dayflowProStep = .email
          }
        } label: {
          Text("Back")
            .font(.custom("Figtree", size: scaledText(13)))
            .fontWeight(.semibold)
            .foregroundColor(Color(hex: "492304"))
            .padding(.horizontal, scaled(14))
            .padding(.vertical, scaled(8))
            .background(Color.white.opacity(0.45))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E4D3C2"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }

      switch dayflowProStep {
      case .email:
        dayflowProEmailForm
      case .code:
        dayflowProCodeForm
      case .referralCode:
        dayflowProReferralCodeForm
      case .freeMonthActive:
        dayflowProRewardActiveForm
      case .trialOffer:
        dayflowProTrialOfferForm
      case .trialActive:
        dayflowProTrialActiveForm
      }

      if let statusMessage = dayflowProStatusMessage {
        Text(statusMessage.text)
          .font(.custom("Figtree", size: scaledText(13)))
          .foregroundColor(statusMessage.isError ? Color(hex: "B42318") : Color(hex: "89380E"))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, scaled(28))
    .padding(.vertical, scaled(24))
    .frame(maxWidth: scaled(620))
    .background(Color.white.opacity(0.42))
    .cornerRadius(6)
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(hex: "E4D3C2"), lineWidth: 1)
    )
    .shadow(color: Color(hex: "AF7246").opacity(0.15), radius: 8, x: 0, y: 2)
    .onAppear {
      trackDayflowProStepViewed(dayflowProStep)
    }
    .onChange(of: dayflowProStep) { oldStep, newStep in
      guard oldStep != newStep else { return }
      trackDayflowProStepViewed(newStep)
    }
  }

  private var dayflowProEmailForm: some View {
    VStack(alignment: .leading, spacing: scaled(14)) {
      VStack(alignment: .leading, spacing: scaled(6)) {
        Text("Email")
          .font(.custom("Figtree", size: scaledText(13)))
          .fontWeight(.semibold)
          .foregroundColor(Color(hex: "492304"))

        dayflowProTextField("you@example.com", text: $dayflowProEmail)
          .onSubmit(sendDayflowProCode)
      }

      HStack {
        Spacer()
        dayflowProPrimaryButton(
          title: authManager.isBusy ? "Sending..." : "Send sign-in code",
          enabled: canSendDayflowProCode,
          action: sendDayflowProCode
        )
      }
    }
  }

  private var dayflowProCodeForm: some View {
    VStack(alignment: .leading, spacing: scaled(14)) {
      VStack(alignment: .leading, spacing: scaled(6)) {
        Text("Code sent to \(dayflowProVerificationTarget)")
          .font(.custom("Figtree", size: scaledText(13)))
          .fontWeight(.semibold)
          .foregroundColor(Color(hex: "492304"))

        dayflowProTextField("123456", text: $dayflowProCode)
          .onChange(of: dayflowProCode) { _, newValue in
            let normalized = String(newValue.filter(\.isNumber).prefix(6))
            if normalized != newValue {
              dayflowProCode = normalized
            }
          }
          .onSubmit(verifyDayflowProCode)
      }

      HStack(spacing: scaled(10)) {
        dayflowProSecondaryButton(
          title: "Different email",
          action: showDayflowProEmailStep
        )

        dayflowProSecondaryButton(
          title: authManager.isBusy ? "Sending..." : "Resend code",
          enabled: !authManager.isBusy,
          action: resendDayflowProCode
        )

        Spacer()

        dayflowProPrimaryButton(
          title: authManager.isBusy ? "Checking..." : "Continue",
          enabled: canVerifyDayflowProCode,
          action: verifyDayflowProCode
        )
      }
    }
  }

  private var dayflowProReferralCodeForm: some View {
    VStack(alignment: .leading, spacing: scaled(14)) {
      VStack(alignment: .leading, spacing: scaled(6)) {
        Text("Do you have a referral code?")
          .font(.custom("Figtree", size: scaledText(13)))
          .fontWeight(.semibold)
          .foregroundColor(Color(hex: "492304"))

        Text(
          "If someone gave you a code, enter it here. Don't worry if you don't have a code, we'll gift you a free week of Dayflow Pro!"
        )
        .font(.custom("Figtree", size: scaledText(13)))
        .foregroundColor(Color(hex: "89380E").opacity(0.75))
        .fixedSize(horizontal: false, vertical: true)
      }

      dayflowProReferralField

      HStack(spacing: scaled(10)) {
        dayflowProPrimaryButton(
          title: authManager.isBusy ? "Applying..." : "Apply code",
          enabled: canApplyDayflowProReferralCode,
          action: applyDayflowProReferralCode
        )

        dayflowProSecondaryButton(
          title: "I don't have a code",
          enabled: !authManager.isBusy,
          action: showDayflowProTrialOffer
        )
      }
    }
  }

  private var dayflowProRewardActiveForm: some View {
    VStack(alignment: .center, spacing: scaled(16)) {
      ReferralPassCard(message: "Your free month of Dayflow Pro is ready.")

      VStack(spacing: scaled(6)) {
        Text("Congrats, enjoy a free month of Dayflow Pro on us!")
          .font(.custom("Figtree", size: scaledText(16)))
          .fontWeight(.semibold)
          .foregroundColor(Color(hex: "492304"))
          .multilineTextAlignment(.center)

        Text("Your referral reward is active on this account.")
          .font(.custom("Figtree", size: scaledText(13)))
          .foregroundColor(Color(hex: "89380E").opacity(0.75))
          .multilineTextAlignment(.center)
      }

      dayflowProPrimaryButton(
        title: "Continue with Dayflow Pro",
        enabled: !authManager.isBusy,
        action: continueWithDayflowPro
      )
    }
    .frame(maxWidth: .infinity)
  }

  private var dayflowProTrialOfferForm: some View {
    VStack(alignment: .center, spacing: scaled(16)) {
      ReferralPassCard(message: "7 days free. No credit card required.")

      VStack(spacing: scaled(6)) {
        Text("Try Dayflow Pro free for 7 days.")
          .font(.custom("Figtree", size: scaledText(16)))
          .fontWeight(.semibold)
          .foregroundColor(Color(hex: "492304"))
          .multilineTextAlignment(.center)

        Text(
          "We want you to be able to try Dayflow for free, no credit card and no strings attached!"
        )
        .font(.custom("Figtree", size: scaledText(13)))
        .foregroundColor(Color(hex: "89380E").opacity(0.75))
        .multilineTextAlignment(.center)
      }

      HStack(spacing: scaled(10)) {
        dayflowProPrimaryButton(
          title: authManager.isBusy ? "Starting..." : "Start free trial",
          enabled: !authManager.isBusy,
          action: startDayflowProTrial
        )

        dayflowProSecondaryButton(
          title: "I have a code",
          enabled: !authManager.isBusy,
          action: showDayflowProReferralCodeStep
        )
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var dayflowProTrialActiveForm: some View {
    VStack(alignment: .center, spacing: scaled(16)) {
      ReferralPassCard(message: "7 days free. No credit card required.")

      VStack(spacing: scaled(6)) {
        Text("Your Dayflow Pro trial is active.")
          .font(.custom("Figtree", size: scaledText(16)))
          .fontWeight(.semibold)
          .foregroundColor(Color(hex: "492304"))
          .multilineTextAlignment(.center)

        Text("No credit card needed. You can set up billing later if Dayflow is useful.")
          .font(.custom("Figtree", size: scaledText(13)))
          .foregroundColor(Color(hex: "89380E").opacity(0.75))
          .multilineTextAlignment(.center)
      }

      dayflowProPrimaryButton(
        title: "Continue with Dayflow Pro",
        enabled: !authManager.isBusy,
        action: continueWithDayflowPro
      )
    }
    .frame(maxWidth: .infinity)
  }

  private var dayflowProReferralField: some View {
    VStack(alignment: .leading, spacing: scaled(6)) {
      HStack(spacing: scaled(8)) {
        Text("Referral code")
          .font(.custom("Figtree", size: scaledText(13)))
          .fontWeight(.semibold)
          .foregroundColor(Color(hex: "492304"))

        Text("Optional")
          .font(.custom("Figtree", size: scaledText(12)))
          .foregroundColor(Color(hex: "89380E").opacity(0.62))
      }

      dayflowProTextField("ABC123", text: $dayflowProReferralCode)
        .modifier(
          DayflowProReferralFieldShake(
            travelDistance: scaled(7),
            shakes: 5,
            animatableData: dayflowProReferralShakeTrigger
          )
        )
        .onChange(of: dayflowProReferralCode) { _, newValue in
          let normalized = normalizedReferralInput(newValue)
          if normalized != newValue {
            dayflowProReferralCode = normalized
          }
        }

      if !dayflowProReferralCode.isEmpty && !isDayflowProReferralCodeValid {
        Text("Enter the 6-character code from your invite.")
          .font(.custom("Figtree", size: scaledText(12)))
          .foregroundColor(Color(hex: "B42318"))
      }
    }
  }

  private var dayflowProSubtitle: String? {
    switch dayflowProStep {
    case .email:
      return nil
    case .code:
      return "Enter the code we sent to finish signing up/in."
    case .referralCode:
      return nil
    case .freeMonthActive:
      return "Your referral reward is ready."
    case .trialOffer:
      return "No referral code? Start with a free trial."
    case .trialActive:
      return "Your trial is ready."
    }
  }

  private var dayflowProStatusMessage: (text: String, isError: Bool)? {
    if let errorText = authManager.errorText, !errorText.isEmpty {
      return (errorText, true)
    }

    let status = authManager.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedStatus = status.lowercased()
    guard !status.isEmpty, !normalizedStatus.hasPrefix("signed out") else {
      return nil
    }
    if shouldHideSignedInStatus, normalizedStatus.hasPrefix("signed in") {
      return nil
    }

    return (status, false)
  }

  private var shouldHideSignedInStatus: Bool {
    dayflowProStep == .referralCode || dayflowProStep == .trialOffer
  }

  private func trackDayflowProStepViewed(_ step: DayflowProOnboardingStep) {
    OnboardingPrototypeAnalytics.trackDayflowProStepViewed(
      step: step,
      flowID: flowID,
      flowVariant: flowVariant,
      hasPaidAI: hasPaidAI
    )
  }

  private func trackDayflowProAPIOutcome(
    _ eventName: String,
    action: String,
    result: DayflowAuthActionResult,
    step: DayflowProOnboardingStep? = nil
  ) {
    OnboardingPrototypeAnalytics.trackDayflowProAPIOutcome(
      eventName,
      action: action,
      result: result,
      step: step ?? dayflowProStep,
      flowID: flowID,
      flowVariant: flowVariant,
      hasPaidAI: hasPaidAI
    )
  }

  private var trimmedDayflowProEmail: String {
    dayflowProEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var dayflowProVerificationTarget: String {
    dayflowProVerificationEmail.isEmpty ? trimmedDayflowProEmail : dayflowProVerificationEmail
  }

  private var canSendDayflowProCode: Bool {
    trimmedDayflowProEmail.contains("@")
      && trimmedDayflowProEmail.contains(".")
      && !trimmedDayflowProEmail.contains(" ")
      && !authManager.isBusy
  }

  private var canVerifyDayflowProCode: Bool {
    dayflowProCode.filter(\.isNumber).count == 6
      && !authManager.isBusy
  }

  private var canApplyDayflowProReferralCode: Bool {
    dayflowProReferralCode.count == 6 && !authManager.isBusy
  }

  private var isDayflowProReferralCodeValid: Bool {
    dayflowProReferralCode.isEmpty || dayflowProReferralCode.count == 6
  }

  private var normalizedDayflowProReferralCode: String? {
    let normalized = normalizedReferralInput(dayflowProReferralCode)
    return normalized.isEmpty ? nil : normalized
  }

  private var isDayflowProActive: Bool {
    authManager.entitlements.plan == "pro" && authManager.entitlements.status == "active"
  }

  private var hasActiveReferralReward: Bool {
    hasActiveReward(matching: { $0.rewardType == "recipient_claim" })
  }

  private var hasActiveTrialReward: Bool {
    hasActiveReward(matching: { $0.rewardType == "onboarding_trial" })
  }

  private func dayflowProTextField(_ placeholder: String, text: Binding<String>) -> some View {
    TextField(placeholder, text: text)
      .font(.custom("Figtree", size: scaledText(14)))
      .foregroundColor(Color(hex: "492304"))
      .textFieldStyle(.plain)
      .padding(.horizontal, scaled(12))
      .frame(height: scaled(42))
      .background(Color.white.opacity(0.72))
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color(hex: "E4D3C2"), lineWidth: 1)
      )
  }

  private func dayflowProPrimaryButton(
    title: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    DayflowSurfaceButton(
      action: action,
      content: {
        Text(title)
          .font(.custom("Figtree", size: scaledText(13)))
          .fontWeight(.semibold)
      },
      background: enabled ? Color(hex: "402C00") : Color(hex: "D8CCBD"),
      foreground: .white,
      borderColor: .clear,
      cornerRadius: scaled(8),
      horizontalPadding: scaled(22),
      verticalPadding: scaled(11),
      minWidth: scaled(150),
      showOverlayStroke: true
    )
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.85)
  }

  private func dayflowProSecondaryButton(
    title: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    DayflowSurfaceButton(
      action: action,
      content: {
        Text(title)
          .font(.custom("Figtree", size: scaledText(13)))
          .fontWeight(.semibold)
      },
      background: Color.white.opacity(0.64),
      foreground: Color(hex: "492304"),
      borderColor: .clear,
      cornerRadius: scaled(8),
      horizontalPadding: scaled(16),
      verticalPadding: scaled(11),
      minWidth: scaled(116),
      isSecondaryStyle: true
    )
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.7)
  }

  private func startDayflowProSignIn() {
    OnboardingPrototypeAnalytics.trackDayflowProSelected(
      flowID: flowID,
      flowVariant: flowVariant,
      hasPaidAI: hasPaidAI,
      selectionStage: "started_sign_in"
    )
    dayflowProEmail = ""
    dayflowProCode = ""
    dayflowProReferralCode = authManager.pendingReferralCode ?? ""
    dayflowProVerificationEmail = ""
    dayflowProStep = .email

    withAnimation(.easeInOut(duration: 0.25)) {
      showAllOptions = false
      isShowingDayflowProSignIn = true
    }

    Task {
      await authManager.signOut()
    }
  }

  private func sendDayflowProCode() {
    guard canSendDayflowProCode else { return }

    Task {
      let result = await authManager.sendCode(to: trimmedDayflowProEmail)
      trackDayflowProAPIOutcome(
        "dayflow_pro_auth_code_requested",
        action: "auth_code_request",
        result: result,
        step: .email
      )
      guard result.succeeded, authManager.canVerifyCode else { return }

      dayflowProVerificationEmail = authManager.pendingEmail ?? trimmedDayflowProEmail
      dayflowProCode = ""
      withAnimation(.easeInOut(duration: 0.25)) {
        dayflowProStep = .code
      }
    }
  }

  private func verifyDayflowProCode() {
    guard canVerifyDayflowProCode else { return }

    Task {
      let result = await authManager.verifyCode(dayflowProCode, for: dayflowProVerificationTarget)
      trackDayflowProAPIOutcome(
        "dayflow_pro_auth_code_verified",
        action: "auth_code_verify",
        result: result,
        step: .code
      )
      guard result.succeeded else { return }

      await authManager.refreshAccount()
      guard authManager.isSignedIn else { return }

      routeAfterDayflowProSignIn()
    }
  }

  private func resendDayflowProCode() {
    Task {
      await authManager.resendCode()
    }
  }

  private func showDayflowProEmailStep() {
    authManager.useDifferentEmail()
    dayflowProCode = ""
    dayflowProVerificationEmail = ""
    withAnimation(.easeInOut(duration: 0.25)) {
      dayflowProStep = .email
    }
  }

  private func routeAfterDayflowProSignIn() {
    if isDayflowProActive && !hasActiveReferralReward && !hasActiveTrialReward {
      continueWithDayflowPro()
      return
    }

    withAnimation(.easeInOut(duration: 0.25)) {
      if hasActiveReferralReward {
        dayflowProStep = .freeMonthActive
      } else if hasActiveTrialReward {
        dayflowProStep = .trialActive
      } else {
        dayflowProStep = .referralCode
      }
    }
  }

  private func applyDayflowProReferralCode() {
    guard let referralCode = normalizedDayflowProReferralCode else {
      trackDayflowProAPIOutcome(
        "dayflow_pro_referral_code_submitted",
        action: "referral_code_submit",
        result: .localFailure(errorType: "missing_referral_code", endpoint: "/v1/referrals/claim"),
        step: .referralCode
      )
      shakeDayflowProReferralField()
      return
    }

    Task {
      let result = await authManager.claimReferralCode(referralCode)
      trackDayflowProAPIOutcome(
        "dayflow_pro_referral_code_submitted",
        action: "referral_code_submit",
        result: result,
        step: .referralCode
      )
      guard result.succeeded, authManager.errorText == nil else {
        shakeDayflowProReferralField()
        return
      }

      await authManager.refreshAccount()
      guard authManager.errorText == nil else { return }

      if hasActiveReferralReward || isDayflowProActive {
        withAnimation(.easeInOut(duration: 0.25)) {
          dayflowProStep = .freeMonthActive
        }
      }
    }
  }

  private func showDayflowProTrialOffer() {
    withAnimation(.easeInOut(duration: 0.25)) {
      dayflowProStep = .trialOffer
    }
  }

  private func showDayflowProReferralCodeStep() {
    withAnimation(.easeInOut(duration: 0.25)) {
      dayflowProStep = .referralCode
    }
  }

  private func shakeDayflowProReferralField() {
    withAnimation(.linear(duration: 0.32)) {
      dayflowProReferralShakeTrigger += 1
    }
  }

  private func startDayflowProTrial() {
    Task {
      let result = await authManager.startNoCardTrial()
      trackDayflowProAPIOutcome(
        "dayflow_pro_trial_started",
        action: "trial_start",
        result: result,
        step: .trialOffer
      )
      guard result.succeeded, authManager.errorText == nil else { return }

      if hasActiveTrialReward || isDayflowProActive {
        withAnimation(.easeInOut(duration: 0.25)) {
          dayflowProStep = .trialActive
        }
      }
    }
  }

  private func continueWithDayflowPro() {
    OnboardingPrototypeAnalytics.trackDayflowProSelected(
      flowID: flowID,
      flowVariant: flowVariant,
      hasPaidAI: hasPaidAI,
      selectionStage: "continued"
    )
    onSelect("Dayflow Pro")
  }

  private func hasActiveReward(matching predicate: (DayflowReferralReward) -> Bool) -> Bool {
    let activeStatuses = ["applied_internal", "pending_stripe", "applied_stripe"]
    return authManager.referralSummary?.rewards.contains { reward in
      predicate(reward) && activeStatuses.contains(reward.status)
    } ?? false
  }

  private func normalizedReferralInput(_ input: String) -> String {
    let allowed = CharacterSet.alphanumerics
    return
      input
      .uppercased()
      .unicodeScalars
      .filter { allowed.contains($0) }
      .prefix(6)
      .map(String.init)
      .joined()
  }

  // MARK: - Tall Card (recommended view)

  private func tallCard(
    icon: String, title: String,
    badgeText: String, badgeType: BadgeType,
    pros: [String], caveats: [String],
    isHighlighted: Bool
  ) -> some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Spacer()
          ProviderIconView(icon: icon, scale: layoutScale)
          Spacer()
        }
        .padding(.top, scaled(24))
        .padding(.bottom, scaled(16))

        HStack {
          Spacer()
          Text(title)
            .font(.custom("Figtree", size: scaledText(18)))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.9))
          Spacer()
        }
        .padding(.bottom, scaled(8))

        HStack {
          Spacer()
          BadgeView(text: badgeText, type: badgeType, scale: layoutScale, fontScale: textScale)
          Spacer()
        }
        .padding(.bottom, scaled(24))

        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: scaled(10)) {
            ForEach(pros, id: \.self) {
              FeatureRowView(feature: ($0, true), scale: layoutScale, fontScale: textScale)
            }
            ForEach(caveats, id: \.self) {
              FeatureRowView(feature: ($0, false), scale: layoutScale, fontScale: textScale)
            }
          }
          .padding(.horizontal, scaled(24))
        }
      }

      Spacer()

      selectButton(title: title)
        .padding(.horizontal, scaled(24))
        .padding(.bottom, scaled(24))
    }
    .frame(maxWidth: .infinity)
    .frame(maxHeight: scaled(432))
    .background(
      isHighlighted ? AnyView(SelectedCardBackground()) : AnyView(Color.white.opacity(0.3))
    )
    .cornerRadius(4)
    .overlay(
      isHighlighted
        ? AnyView(SelectedCardOverlay())
        : AnyView(
          RoundedRectangle(cornerRadius: 4).inset(by: 0.5).stroke(
            Color.black.opacity(0.06), lineWidth: 1)
        )
    )
    .modifier(CardShadowModifier(isSelected: isHighlighted))
  }

  // MARK: - Compact Card (all options view)

  private func compactCard(for id: String) -> some View {
    let info = providerInfo(for: id)

    return VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: scaled(8)) {
        HStack(spacing: scaled(12)) {
          ProviderIconView(icon: info.icon, scale: layoutScale)
          Text(info.title)
            .font(.custom("Figtree", size: scaledText(18)))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.9))
            .lineLimit(1)
        }

        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: scaled(2)) {
            ForEach(info.pros, id: \.self) {
              FeatureRowView(feature: ($0, true), scale: layoutScale, fontScale: textScale)
            }
            ForEach(info.caveats, id: \.self) {
              FeatureRowView(feature: ($0, false), scale: layoutScale, fontScale: textScale)
            }
          }
        }
      }

      Spacer()

      HStack {
        Spacer()
        selectButton(title: info.title)
      }
    }
    .padding(.horizontal, scaled(20))
    .padding(.vertical, scaled(18))
    .frame(maxWidth: .infinity)
    .frame(height: scaled(205))
    .background(Color.white.opacity(0.3))
    .cornerRadius(4)
    .overlay(
      RoundedRectangle(cornerRadius: 4).inset(by: 0.5).stroke(
        Color.black.opacity(0.06), lineWidth: 1)
    )
  }

  private func selectButton(title: String) -> some View {
    DayflowSurfaceButton(
      action: {
        if title == "Dayflow Pro" {
          startDayflowProSignIn()
        } else {
          onSelect(title)
        }
      },
      content: {
        Text("Select")
          .font(.custom("Figtree", size: scaledText(14)))
          .fontWeight(.semibold)
          .frame(maxWidth: .infinity)
      },
      background: Color(red: 0.25, green: 0.17, blue: 0),
      foreground: .white,
      borderColor: .clear,
      cornerRadius: scaled(8),
      horizontalPadding: scaled(24),
      verticalPadding: scaled(12),
      showOverlayStroke: true
    )
  }
}
