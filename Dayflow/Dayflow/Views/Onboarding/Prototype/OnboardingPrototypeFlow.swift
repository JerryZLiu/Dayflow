//
//  OnboardingPrototypeFlow.swift
//  Dayflow
//

import AVFoundation
import SwiftUI

enum OnboardingPrototypeStep: Int, CaseIterable, Identifiable {
  case introVideo
  case roleSelection
  case preferences
  case chooseProvider
  case placeholder

  var id: Int { rawValue }

  var analyticsName: String {
    switch self {
    case .introVideo:
      return "intro_video"
    case .roleSelection:
      return "role_selection"
    case .preferences:
      return "preferences"
    case .chooseProvider:
      return "choose_provider"
    case .placeholder:
      return "placeholder"
    }
  }

  var screenName: String {
    "onboarding_\(analyticsName)"
  }

  var next: OnboardingPrototypeStep? {
    OnboardingPrototypeStep(rawValue: rawValue + 1)
  }
}

struct OnboardingPrototypeFlow: View {
  private let flowVariant: String
  private let entryPoint: String

  @State private var currentStep: OnboardingPrototypeStep
  @State private var flowID = UUID().uuidString.lowercased()
  @State private var hasTrackedStart = false
  @State private var hasTrackedCompletion = false
  @State private var userHasPaidAI: Bool?

  init(
    initialStep: OnboardingPrototypeStep = .introVideo,
    flowVariant: String = "prototype_v1",
    entryPoint: String = "preview"
  ) {
    _currentStep = State(initialValue: initialStep)
    self.flowVariant = flowVariant
    self.entryPoint = entryPoint
  }

  var body: some View {
    ZStack {
      Color(red: 0.12, green: 0.12, blue: 0.12)
        .ignoresSafeArea()

      switch currentStep {
      case .introVideo:
        OnboardingPrototypeVideoIntroStep(
          videoName: "DayflowOnboarding",
          onPlaybackStarted: {
            OnboardingPrototypeAnalytics.trackVideoStarted(
              step: .introVideo,
              flowID: flowID,
              flowVariant: flowVariant,
              assetName: "DayflowOnboarding.mp4"
            )
          },
          onPlaybackCompleted: { reason in
            OnboardingPrototypeAnalytics.trackVideoCompleted(
              step: .introVideo,
              flowID: flowID,
              flowVariant: flowVariant,
              assetName: "DayflowOnboarding.mp4",
              completionReason: reason
            )
            advance(from: .introVideo, method: "video_\(reason)")
          }
        )

      case .roleSelection:
        OnboardingPrototypeRoleSelectionStep(
          onContinue: { selectedRole in
            OnboardingPrototypeAnalytics.trackStepCompleted(
              step: .roleSelection,
              flowID: flowID,
              flowVariant: flowVariant,
              advanceMethod: "continue_button",
              extraProps: ["selected_role": selectedRole]
            )
            if let nextStep = OnboardingPrototypeStep.roleSelection.next {
              currentStep = nextStep
            }
          }
        )

      case .preferences:
        OnboardingPrototypePreferencesStep(
          onContinue: { hasPaidAI in
            userHasPaidAI = hasPaidAI
            OnboardingPrototypeAnalytics.trackStepCompleted(
              step: .preferences,
              flowID: flowID,
              flowVariant: flowVariant,
              advanceMethod: hasPaidAI ? "yes_button" : "no_button",
              extraProps: ["has_paid_ai": hasPaidAI]
            )
            if let nextStep = OnboardingPrototypeStep.preferences.next {
              currentStep = nextStep
            }
          }
        )

      case .chooseProvider:
        OnboardingPrototypeChooseProviderStep(
          hasPaidAI: userHasPaidAI ?? false,
          onSelect: { provider in
            OnboardingPrototypeAnalytics.trackStepCompleted(
              step: .chooseProvider,
              flowID: flowID,
              flowVariant: flowVariant,
              advanceMethod: "select_button",
              extraProps: ["selected_provider": provider]
            )
            if let nextStep = OnboardingPrototypeStep.chooseProvider.next {
              currentStep = nextStep
            }
          }
        )

      case .placeholder:
        OnboardingPrototypePlaceholderStep(
          onReplayVideo: {
            currentStep = .introVideo
          },
          onFinish: {
            advance(from: .placeholder, method: "finish_button")
          }
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      Image("OnboardingBackgroundv2")
        .resizable()
        .aspectRatio(contentMode: .fill)
        .ignoresSafeArea()
    }
    .preferredColorScheme(.light)
    .onAppear {
      guard !hasTrackedStart else { return }
      hasTrackedStart = true
      OnboardingPrototypeAnalytics.trackFlowStarted(
        flowID: flowID,
        flowVariant: flowVariant,
        entryPoint: entryPoint,
        stepCount: OnboardingPrototypeStep.allCases.count
      )
      trackStepViewed(currentStep)
    }
    .onChange(of: currentStep) { oldStep, newStep in
      guard oldStep != newStep else { return }
      trackStepViewed(newStep)
    }
  }

  private func trackStepViewed(_ step: OnboardingPrototypeStep) {
    OnboardingPrototypeAnalytics.trackStepViewed(
      step: step,
      flowID: flowID,
      flowVariant: flowVariant
    )
  }

  private func advance(from step: OnboardingPrototypeStep, method: String) {
    OnboardingPrototypeAnalytics.trackStepCompleted(
      step: step,
      flowID: flowID,
      flowVariant: flowVariant,
      advanceMethod: method
    )

    if let nextStep = step.next {
      currentStep = nextStep
      return
    }

    guard !hasTrackedCompletion else { return }
    hasTrackedCompletion = true
    OnboardingPrototypeAnalytics.trackFlowCompleted(
      flowID: flowID,
      flowVariant: flowVariant,
      stepCount: OnboardingPrototypeStep.allCases.count
    )
  }
}

struct OnboardingPrototypeVideoIntroStep: View {
  let videoName: String
  let onPlaybackStarted: () -> Void
  let onPlaybackCompleted: (String) -> Void

  @State private var player: AVPlayer?
  @State private var hasStartedPlayback = false
  @State private var hasCompletedPlayback = false
  @State private var playbackTimer: Timer?
  @State private var timeObserverToken: Any?
  @State private var endObserverToken: NSObjectProtocol?
  @State private var statusObservation: NSKeyValueObservation?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let player = player {
        AVPlayerControllerRepresented(player: player)
          .ignoresSafeArea()
      }
    }
    .onAppear {
      setupVideo()
    }
    .onDisappear {
      cleanup()
    }
  }

  private func setupVideo() {
    guard let videoURL = resolveVideoURL() else {
      finishPlayback(reason: "missing_asset")
      return
    }

    let playerItem = AVPlayerItem(url: videoURL)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = true
    player?.volume = 0
    player?.automaticallyWaitsToMinimizeStalling = false
    player?.actionAtItemEnd = .none

    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      time in
      guard let duration = self.player?.currentItem?.duration,
        duration.isValid && duration.isNumeric
      else { return }

      let currentSeconds = time.seconds
      let totalSeconds = duration.seconds

      guard totalSeconds > 0 else { return }

      if currentSeconds >= totalSeconds - 0.3 && currentSeconds < totalSeconds {
        self.finishPlayback(reason: "ended")
      }
    }

    endObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { _ in
      finishPlayback(reason: "ended")
    }

    statusObservation = playerItem.observe(\.status) { item, _ in
      guard item.status == .failed else { return }
      DispatchQueue.main.async {
        finishPlayback(reason: "playback_failed")
      }
    }

    player?.play()
    markPlaybackStartedIfNeeded()

    playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      guard !self.hasCompletedPlayback else { return }
      if self.player?.rate == 0 {
        self.player?.play()
      }
    }
  }

  private func resolveVideoURL() -> URL? {
    Bundle.main.url(forResource: videoName, withExtension: "mp4")
      ?? Bundle.main.url(forResource: videoName, withExtension: "mp4", subdirectory: "Videos")
      ?? Bundle.main.url(forResource: videoName, withExtension: "mov")
      ?? Bundle.main.url(forResource: videoName, withExtension: "mov", subdirectory: "Videos")
  }

  private func markPlaybackStartedIfNeeded() {
    guard !hasStartedPlayback else { return }
    hasStartedPlayback = true
    onPlaybackStarted()
  }

  private func finishPlayback(reason: String) {
    guard !hasCompletedPlayback else { return }
    hasCompletedPlayback = true

    playbackTimer?.invalidate()
    playbackTimer = nil

    player?.pause()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      onPlaybackCompleted(reason)
    }
  }

  private func cleanup() {
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
      timeObserverToken = nil
    }
    if let token = endObserverToken {
      NotificationCenter.default.removeObserver(token)
      endObserverToken = nil
    }
    statusObservation = nil
    playbackTimer?.invalidate()
    playbackTimer = nil
    player?.pause()
    player = nil
  }
}

struct OnboardingPrototypeRoleSelectionStep: View {
  let onContinue: (String) -> Void

  private let roles = [
    "Software Engineer", "Founder / Executive", "Designer", "Student", "Product Manager",
    "Data Scientist", "Other",
  ]
  @State private var selectedRole: String?
  @State private var otherText = ""

  private var resolvedRole: String? {
    guard let selectedRole else { return nil }
    if selectedRole == "Other" {
      return otherText.trimmingCharacters(in: .whitespaces).isEmpty
        ? nil : otherText.trimmingCharacters(in: .whitespaces)
    }
    return selectedRole
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 39)

      Text("Help Dayflow understand your work patterns better.")
        .font(.custom("InstrumentSerif-Regular", size: 40))
        .tracking(-1.2)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(hex: "492304"))
        .lineSpacing(40 * 0.2)
        .frame(maxWidth: 708)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()
        .frame(height: 60)

      VStack(spacing: 24) {
        VStack(spacing: 4) {
          Text("What do you do for work?")
            .font(.custom("Nunito", size: 20))
            .foregroundColor(Color(hex: "89380E"))

          Text("This will help Dayflow generate categories that are most helpful to you.")
            .font(.custom("Nunito", size: 20))
            .foregroundColor(Color(hex: "89380E"))
        }
        .multilineTextAlignment(.center)

        VStack(spacing: 8) {
          HStack(spacing: 8) {
            ForEach(roles.prefix(4), id: \.self) { role in
              roleChip(role)
            }
          }
          HStack(spacing: 8) {
            ForEach(roles.dropFirst(4), id: \.self) { role in
              roleChip(role)
            }
          }
        }
      }

      if selectedRole == "Other" {
        VStack(spacing: 16) {
          Text("Please specify")
            .font(.custom("Nunito", size: 20))
            .foregroundColor(Color(hex: "89380E"))

          TextField("", text: $otherText)
            .font(.custom("Nunito", size: 16))
            .foregroundColor(Color(hex: "492304"))
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(width: 353, height: 34)
            .background(Color.white.opacity(0.4))
            .cornerRadius(5)
            .overlay(
              RoundedRectangle(cornerRadius: 5)
                .stroke(Color(hex: "E4D3C2"), lineWidth: 1)
            )
            .shadow(
              color: Color(hex: "AF7246").opacity(0.15),
              radius: 2, x: 0, y: 0
            )
        }
        .padding(.top, 32)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      Spacer()

      DayflowSurfaceButton(
        action: {
          if let role = resolvedRole {
            onContinue(role)
          }
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
      .opacity(resolvedRole == nil ? 0.4 : 1.0)
      .allowsHitTesting(resolvedRole != nil)
      .animation(.easeInOut(duration: 0.2), value: resolvedRole)

      Spacer()
        .frame(height: 60)
    }
    .animation(.easeInOut(duration: 0.25), value: selectedRole == "Other")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func roleChip(_ role: String) -> some View {
    let isSelected = selectedRole == role
    return Button {
      selectedRole = role
    } label: {
      Text(role)
        .font(.custom("Nunito", size: 16))
        .foregroundColor(Color(hex: "492304"))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
          isSelected
            ? Color(red: 1, green: 0.898, blue: 0.812).opacity(0.4)
            : Color.white.opacity(0.4)
        )
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .stroke(
              isSelected ? Color(hex: "FFCCA7") : Color(hex: "E4D3C2"),
              lineWidth: 1
            )
        )
        .shadow(
          color: isSelected
            ? Color(red: 1, green: 0.416, blue: 0).opacity(0.5)
            : Color(hex: "AF7246").opacity(0.15),
          radius: isSelected ? 3 : 2, x: 0, y: 0
        )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

// MARK: - Preferences Step

struct OnboardingPrototypePreferencesStep: View {
  let onContinue: (Bool) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Spacer()

      VStack(spacing: 24) {
        Text("Do you have a paid ChatGPT or Claude account?")
          .font(.custom("Nunito", size: 20))
          .foregroundColor(Color(hex: "89380E"))
          .multilineTextAlignment(.center)

        HStack(spacing: 8) {
          ForEach(["Yes", "No"], id: \.self) { option in
            Button {
              onContinue(option == "Yes")
            } label: {
              Text(option)
                .font(.custom("Nunito", size: 16))
                .foregroundColor(Color(hex: "492304"))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.4))
                .clipShape(Capsule())
                .overlay(
                  Capsule()
                    .stroke(Color(hex: "E4D3C2"), lineWidth: 1)
                )
                .shadow(
                  color: Color(hex: "AF7246").opacity(0.15),
                  radius: 2, x: 0, y: 0
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
          }
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Choose Provider Step

struct OnboardingPrototypeChooseProviderStep: View {
  let hasPaidAI: Bool
  let onSelect: (String) -> Void

  @State private var showAllOptions = false

  private let layoutScale: CGFloat = 0.8
  private let textScale: CGFloat = 1.1

  private func scaled(_ value: CGFloat) -> CGFloat {
    value * layoutScale
  }

  private func scaledText(_ value: CGFloat) -> CGFloat {
    scaled(value) * textScale
  }

  private var recommendedProviders: (first: String, second: String) {
    hasPaidAI ? ("chatgpt_claude", "gemini") : ("gemini", "local")
  }

  private func providerInfo(for id: String) -> (
    icon: String, title: String, pros: [String], caveats: [String]
  ) {
    switch id {
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
      if showAllOptions {
        VStack(spacing: scaled(12)) {
          HStack(spacing: scaled(12)) {
            compactCard(for: "chatgpt_claude")
            compactCard(for: "gemini")
          }
          HStack(spacing: scaled(12)) {
            compactCard(for: "local")
            Color.clear.frame(maxWidth: .infinity, minHeight: 1)
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
            badgeText: recs.second == "local" ? "MOST PRIVATE" : "GENEROUS FREE TIER",
            badgeType: .green,
            pros: second.pros, caveats: second.caveats,
            isHighlighted: false
          )
        }
        .padding(.horizontal, scaled(40))
        .transition(.opacity)
      }

      Spacer()

      // Toggle pill
      Button {
        withAnimation(.easeInOut(duration: 0.3)) {
          showAllOptions.toggle()
        }
      } label: {
        Text(showAllOptions ? "See recommendations only" : "See all options")
          .font(.custom("Nunito", size: scaledText(16)))
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .font(.custom("Nunito", size: scaledText(18)))
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
            .font(.custom("Nunito", size: scaledText(18)))
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
      action: { onSelect(title) },
      content: {
        Text("Select")
          .font(.custom("Nunito", size: scaledText(14)))
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

// MARK: - Placeholder Step

private struct OnboardingPrototypePlaceholderStep: View {
  let onReplayVideo: () -> Void
  let onFinish: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      VStack(spacing: 10) {
        Text("Prototype checkpoint")
          .font(.custom("InstrumentSerif-Regular", size: 44))
          .foregroundColor(.black.opacity(0.9))

        Text(
          "The intro video, role-selection screen, and preferences screen are now wired up. We can keep replacing the remaining placeholders step by step without touching production onboarding yet."
        )
        .font(.custom("Nunito", size: 17))
        .foregroundColor(.black.opacity(0.65))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 620)
      }

      HStack(spacing: 16) {
        DayflowSurfaceButton(
          action: onReplayVideo,
          content: {
            Text("Replay video")
              .font(.custom("Nunito", size: 15))
              .fontWeight(.semibold)
          },
          background: .white,
          foreground: Color(red: 0.25, green: 0.17, blue: 0),
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 28,
          verticalPadding: 14,
          minWidth: 170,
          isSecondaryStyle: true
        )

        DayflowSurfaceButton(
          action: onFinish,
          content: {
            Text("Finish prototype")
              .font(.custom("Nunito", size: 15))
              .fontWeight(.semibold)
          },
          background: Color(red: 0.25, green: 0.17, blue: 0),
          foreground: .white,
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 28,
          verticalPadding: 14,
          minWidth: 170,
          showOverlayStroke: true
        )
      }
    }
    .padding(.horizontal, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private enum OnboardingPrototypeAnalytics {
  private static let isPreviewRuntime =
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

  static func trackFlowStarted(
    flowID: String,
    flowVariant: String,
    entryPoint: String,
    stepCount: Int
  ) {
    capture(
      "onboarding_started",
      [
        "flow_id": flowID,
        "flow_variant": flowVariant,
        "entry_point": entryPoint,
        "step_count": stepCount,
      ]
    )
  }

  static func trackStepViewed(
    step: OnboardingPrototypeStep,
    flowID: String,
    flowVariant: String
  ) {
    let props = stepProps(step: step, flowID: flowID, flowVariant: flowVariant)
    screen(step.screenName, props)
    capture("onboarding_step_viewed", props)
  }

  static func trackStepCompleted(
    step: OnboardingPrototypeStep,
    flowID: String,
    flowVariant: String,
    advanceMethod: String,
    extraProps: [String: Any] = [:]
  ) {
    var props = stepProps(step: step, flowID: flowID, flowVariant: flowVariant)
    props["advance_method"] = advanceMethod
    extraProps.forEach { props[$0.key] = $0.value }
    capture("onboarding_step_completed", props)
  }

  static func trackVideoStarted(
    step: OnboardingPrototypeStep,
    flowID: String,
    flowVariant: String,
    assetName: String
  ) {
    var props = stepProps(step: step, flowID: flowID, flowVariant: flowVariant)
    props["asset_name"] = assetName
    props["is_muted"] = true
    props["auto_advance"] = true
    capture("onboarding_video_started", props)
  }

  static func trackVideoCompleted(
    step: OnboardingPrototypeStep,
    flowID: String,
    flowVariant: String,
    assetName: String,
    completionReason: String
  ) {
    var props = stepProps(step: step, flowID: flowID, flowVariant: flowVariant)
    props["asset_name"] = assetName
    props["completion_reason"] = completionReason
    capture("onboarding_video_completed", props)
  }

  static func trackFlowCompleted(
    flowID: String,
    flowVariant: String,
    stepCount: Int
  ) {
    capture(
      "onboarding_completed",
      [
        "flow_id": flowID,
        "flow_variant": flowVariant,
        "step_count": stepCount,
      ]
    )
  }

  private static func stepProps(
    step: OnboardingPrototypeStep,
    flowID: String,
    flowVariant: String
  ) -> [String: Any] {
    [
      "flow_id": flowID,
      "flow_variant": flowVariant,
      "step": step.analyticsName,
      "step_index": step.rawValue + 1,
      "step_count": OnboardingPrototypeStep.allCases.count,
    ]
  }

  private static func capture(_ name: String, _ props: [String: Any]) {
    guard !isPreviewRuntime else { return }
    AnalyticsService.shared.capture(name, props)
  }

  private static func screen(_ name: String, _ props: [String: Any]) {
    guard !isPreviewRuntime else { return }
    AnalyticsService.shared.screen(name, props)
  }
}

#Preview("Onboarding Prototype") {
  OnboardingPrototypeFlow()
    .frame(
      width: 900, height: 600
    )
}

#Preview("Onboarding Prototype Role Selection") {
  OnboardingPrototypeFlow(initialStep: .roleSelection)
    .frame(width: 1200, height: 800)
}

#Preview("Onboarding Prototype Preferences") {
  OnboardingPrototypeFlow(initialStep: .preferences)
    .frame(width: 1200, height: 800)
}

#Preview("Onboarding Prototype Choose Provider") {
  OnboardingPrototypeFlow(initialStep: .chooseProvider)
    .frame(width: 1200, height: 800)
}

#Preview("Onboarding Prototype Placeholder") {
  OnboardingPrototypeFlow(initialStep: .placeholder)
    .frame(width: 600, height: 400)
}
