//
//  OnboardingPrototypeChooseProviderStep.swift
//  Dayflow
//

import SwiftUI

// MARK: - Provider Comparison Data

private enum ComparisonRating {
  case best, medium, basic

  var dotGradient: LinearGradient {
    switch self {
    case .best:
      return LinearGradient(
        colors: [Color(hex: "10F06D"), Color(hex: "08E8E4")],
        startPoint: .top, endPoint: .bottom
      )
    case .medium:
      return LinearGradient(
        colors: [Color(hex: "FFD560"), Color(hex: "FCAE6A")],
        startPoint: .top, endPoint: .bottom
      )
    case .basic:
      return LinearGradient(
        colors: [Color(hex: "EDD9CF"), Color(hex: "B6AAA4")],
        startPoint: .top, endPoint: .bottom
      )
    }
  }
}

private struct RatedValue {
  let text: String
  let rating: ComparisonRating
}

private struct ComparisonProvider: Identifiable {
  let providerID: LLMProviderID
  let title: String
  let accuracy: RatedValue
  let subscription: String
  let ease: RatedValue
  let notes: String

  var id: String { providerID.rawValue }
}

// MARK: - Choose Provider Step

struct OnboardingPrototypeChooseProviderStep: View {
  let hasPaidAI: Bool
  let flowID: String
  let flowVariant: String
  let onSelect: (LLMProviderID) -> Void

  @ObservedObject private var authManager = DayflowAuthManager.shared
  @State private var isShowingDayflowProSignIn = false
  @State private var dayflowProInitialReferralCode = ""
  @State private var isCodexCLIInstalled = false
  @State private var isClaudeCLIInstalled = false

  private static let providers: [ComparisonProvider] = [
    ComparisonProvider(
      providerID: .dayflow,
      title: "Dayflow Pro",
      accuracy: RatedValue(text: "Best", rating: .best),
      subscription: "30 day free trial",
      ease: RatedValue(text: "Sign in and go", rating: .best),
      notes: "Sync across devices"
    ),
    ComparisonProvider(
      providerID: .chatGPT,
      title: "ChatGPT",
      accuracy: RatedValue(text: "Best", rating: .best),
      subscription: "ChatGPT paid subscription",
      ease: RatedValue(text: "Install Codex CLI", rating: .medium),
      notes: "Uses your ChatGPT subscription and less than 1% of your daily limit."
    ),
    ComparisonProvider(
      providerID: .claude,
      title: "Claude",
      accuracy: RatedValue(text: "Best", rating: .best),
      subscription: "Claude paid subscription",
      ease: RatedValue(text: "Install Claude CLI", rating: .medium),
      notes: "Uses your Claude subscription and less than 1% of your daily limit."
    ),
    ComparisonProvider(
      providerID: .gemini,
      title: "Gemini",
      accuracy: RatedValue(text: "Medium", rating: .medium),
      subscription: "Free",
      ease: RatedValue(text: "API key", rating: .medium),
      notes: "Uses Gemini free tier."
    ),
    ComparisonProvider(
      providerID: .openAICompatible,
      title: "OpenRouter / Custom",
      accuracy: RatedValue(text: "Varies", rating: .medium),
      subscription: "API credits",
      ease: RatedValue(text: "API key and model", rating: .medium),
      notes: "Uses OpenRouter or any OpenAI-compatible endpoint."
    ),
    ComparisonProvider(
      providerID: .minimax,
      title: "MiniMax M3",
      accuracy: RatedValue(text: "Best", rating: .best),
      subscription: "MiniMax Token Plan",
      ease: RatedValue(text: "API key", rating: .medium),
      notes: "Frontier multimodal model • 1M-token context window • native image & video understanding."
    ),
    ComparisonProvider(
      providerID: .local,
      title: "Local AI",
      accuracy: RatedValue(text: "Decent", rating: .basic),
      subscription: "Free",
      ease: RatedValue(text: "Extensive setup", rating: .basic),
      notes: "Requires 16GB+ RAM, 4GB free disk space, M1 or later chip preferred"
    ),
  ]

  var body: some View {
    VStack(spacing: 0) {
      Text("Choose a way to run Dayflow")
        .font(.custom("InstrumentSerif-Regular", size: 40))
        .tracking(-1.2)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(hex: "492304"))
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 24)

      if isShowingDayflowProSignIn {
        DayflowProOnboardingSignInPanel(
          hasPaidAI: hasPaidAI,
          flowID: flowID,
          flowVariant: flowVariant,
          layoutScale: 0.8,
          textScale: 1.1,
          initialReferralCode: dayflowProInitialReferralCode,
          onBack: {
            withAnimation(.easeInOut(duration: 0.25)) {
              isShowingDayflowProSignIn = false
            }
          },
          onComplete: {
            onSelect(.dayflow)
          }
        )
        .padding(.horizontal, 112)
        .transition(.opacity)
      } else {
        comparisonTable
          .padding(.horizontal, 40)
          .transition(.opacity)
      }

      Spacer(minLength: 20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      let installed = await Task.detached(priority: .utility) {
        (
          codex: CLIDetector.isInstalled(.codex),
          claude: CLIDetector.isInstalled(.claude)
        )
      }.value
      guard !Task.isCancelled else { return }
      isCodexCLIInstalled = installed.codex
      isClaudeCLIInstalled = installed.claude
    }
  }

  private func startDayflowProSignIn() {
    OnboardingPrototypeAnalytics.trackDayflowProSelected(
      flowID: flowID,
      flowVariant: flowVariant,
      hasPaidAI: hasPaidAI,
      selectionStage: "started_sign_in"
    )
    dayflowProInitialReferralCode = authManager.pendingReferralCode ?? ""

    withAnimation(.easeInOut(duration: 0.25)) {
      isShowingDayflowProSignIn = true
    }

    Task {
      await authManager.signOut()
    }
  }

  // MARK: - Comparison Table

  private var comparisonTable: some View {
    Grid(horizontalSpacing: 8, verticalSpacing: 16) {
      GridRow(alignment: .top) {
        emptyLabelCell
        ForEach(Self.providers) { provider in
          providerHeader(provider)
        }
      }

      GridRow {
        rowLabel("Model accuracy")
        ForEach(Self.providers) { provider in
          ratedCell(provider.accuracy)
        }
      }

      rowSeparator

      GridRow {
        rowLabel("Subscription requirements")
        ForEach(Self.providers) { provider in
          subscriptionCell(provider.subscription)
        }
      }

      rowSeparator

      GridRow {
        rowLabel("Ease of set up")
        ForEach(Self.providers) { provider in
          ratedCell(easeValue(for: provider))
        }
      }

      rowSeparator

      GridRow(alignment: .top) {
        rowLabel("Additional notes")
        ForEach(Self.providers) { provider in
          notesCell(provider.notes)
        }
      }

      GridRow {
        emptyLabelCell
        ForEach(Self.providers) { provider in
          selectButton(for: provider)
            .padding(.top, 8)
        }
      }
    }
    .frame(maxWidth: 1120)
  }

  private var emptyLabelCell: some View {
    Color.clear
      .gridCellUnsizedAxes([.horizontal, .vertical])
  }

  private var rowSeparator: some View {
    Rectangle()
      .fill(Color.black.opacity(0.15))
      .frame(height: 0.75)
  }

  private func rowLabel(_ text: String) -> some View {
    Text(text)
      .font(.custom("Figtree", size: 14))
      .fontWeight(.semibold)
      .foregroundColor(.black)
      .fixedSize(horizontal: false, vertical: true)
      .gridColumnAlignment(.leading)
  }

  private func providerHeader(_ provider: ComparisonProvider) -> some View {
    VStack(spacing: 7) {
      headerIcon(for: provider.providerID)
      Text(provider.title)
        .font(.custom("Figtree", size: 16))
        .fontWeight(.semibold)
        .foregroundColor(.black)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 8)
  }

  @ViewBuilder
  private func headerIcon(for providerID: LLMProviderID) -> some View {
    switch providerID {
    case .dayflow:
      Image("DayflowLogo")
        .resizable()
        .renderingMode(.original)
        .interpolation(.high)
        .antialiased(true)
        .scaledToFit()
        .frame(width: 36, height: 36)
    case .chatGPT:
      iconCircle(imageName: "ChatGPTLogo")
    case .claude:
      iconCircle(imageName: "ClaudeLogo")
    case .gemini:
      iconCircle(imageName: "GeminiLogo")
    case .openAICompatible:
      iconCircle(systemName: "network")
    case .minimax:
      iconCircle(systemName: "sparkles")
    case .local:
      iconCircle(systemName: "laptopcomputer")
    }
  }

  private func iconCircle(imageName: String) -> some View {
    Image(imageName)
      .resizable()
      .renderingMode(.original)
      .interpolation(.high)
      .antialiased(true)
      .scaledToFit()
      .frame(width: 20, height: 20)
      .frame(width: 36, height: 36)
      .background(Color.white.opacity(0.3))
      .clipShape(Circle())
      .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
  }

  private func iconCircle(systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 14, weight: .medium))
      .foregroundColor(.black.opacity(0.8))
      .frame(width: 36, height: 36)
      .background(Color.white.opacity(0.3))
      .clipShape(Circle())
      .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
  }

  private func easeValue(for provider: ComparisonProvider) -> RatedValue {
    if provider.providerID == .chatGPT, isCodexCLIInstalled {
      return RatedValue(text: "CLI installed", rating: .best)
    }
    if provider.providerID == .claude, isClaudeCLIInstalled {
      return RatedValue(text: "CLI installed", rating: .best)
    }
    return provider.ease
  }

  private func ratedCell(_ value: RatedValue) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(value.rating.dotGradient)
        .frame(width: 10, height: 10)
      Text(value.text)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func subscriptionCell(_ text: String) -> some View {
    Text(text)
      .font(.custom("Figtree", size: 14))
      .foregroundColor(.black)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 170)
  }

  private func notesCell(_ text: String) -> some View {
    Text(text)
      .font(.custom("Figtree", size: 12))
      .foregroundColor(.black)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 180)
  }

  private func selectButton(for provider: ComparisonProvider) -> some View {
    DayflowSurfaceButton(
      action: {
        if provider.providerID == .dayflow {
          startDayflowProSignIn()
        } else {
          onSelect(provider.providerID)
        }
      },
      content: {
        Text("Select")
          .font(.custom("Nunito", size: 14))
          .fontWeight(.semibold)
          .tracking(-0.14)
      },
      background: Color(hex: "402C00"),
      foreground: .white,
      borderColor: .clear,
      cornerRadius: 8,
      horizontalPadding: 40,
      verticalPadding: 8,
      showOverlayStroke: true
    )
  }
}
