//
//  WhatsNewView.swift
//  Dayflow
//
//  Displays release highlights after app updates
//

import AppKit
import SwiftUI
import WebKit

// MARK: - Release Notes Data Structure

struct ReleaseNoteCTA {
  let title: String
  let description: String
  let buttonTitle: String
  let url: String
}

struct ReleaseNoteSocialPreview {
  let authorName: String
  let authorHandle: String
  let dateText: String
  let body: String
  let url: String
}

struct ReleaseNoteBetaSignup {
  let title: String
  let description: String
  let followUp: String
}

struct ReleaseNote: Identifiable {
  let id = UUID()
  let version: String  // e.g. "2.0.1"
  let title: String  // e.g. "Timeline Improvements"
  let highlights: [String]  // Array of bullet points
  let socialPreview: ReleaseNoteSocialPreview?
  let previewIntro: String?
  let previewImageNames: [String]
  let betaSignup: ReleaseNoteBetaSignup?
  let cta: ReleaseNoteCTA?
  let showsWeeklyFeedbackSurvey: Bool

  // Helper to compare semantic versions
  var semanticVersion: [Int] {
    version.split(separator: ".").compactMap { Int($0) }
  }
}

enum AgentsPerDayOption: String, CaseIterable, Identifiable {
  case oneToTwo = "1-2"
  case threeToFive = "3-5"
  case sixToTen = "6-10"
  case elevenToTwenty = "11-20"
  case moreThanTwenty = "20+"

  var id: String { rawValue }

  var title: String {
    rawValue.replacingOccurrences(of: "-", with: "–")
  }
}

enum WhatsNewWeeklyFeedback: String, CaseIterable, Identifiable {
  case valuable = "valuable"
  case usefulNeedsWork = "useful_needs_work"
  case notUsefulYet = "not_useful_yet"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .valuable:
      return "It feels valuable"
    case .usefulNeedsWork:
      return "Useful, but needs work"
    case .notUsefulYet:
      return "Not useful yet"
    }
  }
}

// MARK: - What's New Configuration

enum WhatsNewConfiguration {
  private static let seenKey = "lastSeenWhatsNewVersion"

  /// Override with the specific release number you want to show.
  private static let versionOverride: String? = "2.0.1"

  /// Update this content before shipping each release. Return nil to disable the modal entirely.
  static var configuredRelease: ReleaseNote? {
    ReleaseNote(
      version: targetVersion,
      title: "Smarter, more efficient AI",
      highlights: [
        "Claude now uses around 80% fewer tokens while producing higher-quality results.",
        "Upgraded to GPT-5.6 Luna and Sol for better timeline quality.",
        "A bunch of small bug and performance fixes. Thank you to everyone who's been reporting issues. Please keep them coming!",
      ],
      socialPreview: nil,
      previewIntro:
        "A lot of work now happens behind the scenes in coding agents, where Dayflow can't capture the decisions, parallel threads, and finished outcomes. Dayflow Agents will help you understand what your agents worked on and how you're juggling them throughout the day.",
      previewImageNames: ["AgentsPreview"],
      betaSignup: ReleaseNoteBetaSignup(
        title: "Want to try Dayflow Agents?",
        description:
          "We're opening a small beta for people who regularly work with coding agents.",
        followUp:
          "Coming next: track Dayflow's token usage and choose which models it uses."
      ),
      cta: nil,
      showsWeeklyFeedbackSurvey: false
    )
  }

  /// Returns the configured release when it matches the app version and hasn't been shown yet.
  static func pendingReleaseForCurrentBuild() -> ReleaseNote? {
    guard let release = configuredRelease else { return nil }
    guard isVersion(release.version, lessThanOrEqualTo: currentAppVersion) else { return nil }
    let defaults = UserDefaults.standard
    let lastSeen = defaults.string(forKey: seenKey)

    // First run: seed seen version so new installs skip the modal until next upgrade.
    if lastSeen == nil || lastSeen?.isEmpty == true {
      defaults.set(release.version, forKey: seenKey)
      return nil
    }

    return lastSeen == release.version ? nil : release
  }

  /// Returns the latest configured release, regardless of the running app version.
  static func latestRelease() -> ReleaseNote? {
    configuredRelease
  }

  static func markReleaseAsSeen(version: String) {
    UserDefaults.standard.set(version, forKey: seenKey)
  }

  private static var targetVersion: String {
    versionOverride ?? currentAppVersion
  }

  private static var currentAppVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }

  /// Compare two semantic version strings. Returns true if lhs <= rhs.
  private static func isVersion(_ lhs: String, lessThanOrEqualTo rhs: String) -> Bool {
    let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
    let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }

    for i in 0..<max(lhsParts.count, rhsParts.count) {
      let lhsVal = i < lhsParts.count ? lhsParts[i] : 0
      let rhsVal = i < rhsParts.count ? rhsParts[i] : 0
      if lhsVal < rhsVal { return true }
      if lhsVal > rhsVal { return false }
    }
    return true  // equal
  }
}

// MARK: - What's New View

struct WhatsNewView: View {
  let releaseNote: ReleaseNote
  let onDismiss: () -> Void

  @Environment(\.openURL) private var openURL
  @AppStorage("whatsNewWeeklyFeedbackSubmittedVersion") private var submittedWeeklyFeedbackVersion =
    ""
  @State private var selectedWeeklyFeedback: WhatsNewWeeklyFeedback?
  @State private var weeklyImprovementText = ""
  @State private var releaseSurveyResponseID = ""
  @State private var isSubmittingWeeklyFeedback = false
  @State private var surveyErrorText: String?
  @State private var didHydrateSurveyState = false
  @AppStorage("whatsNewAgentsBetaSubmittedVersion") private var submittedAgentsBetaVersion = ""
  @State private var selectedAgentsPerDay: AgentsPerDayOption?
  @State private var agentsBetaEmail = ""
  @State private var agentsBetaCompany = ""
  @State private var agentsBetaResponseID = ""
  @State private var isSubmittingAgentsBeta = false
  @State private var agentsBetaErrorText: String?
  @State private var tweetEmbedState: TweetEmbedState = .loading
  @State private var tweetEmbedHeight: CGFloat = 0

  private enum TweetEmbedState {
    case loading
    case ready
    case failed
  }

  private let bottomAnchorID = "whats_new_bottom_anchor"
  private let releaseSurveyKey = "weekly_feedback"
  private let agentsBetaSurveyKey = "agents_beta"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 6) {
            Text("What's New in \(releaseNote.version) 🎉")
              .font(.custom("InstrumentSerif-Regular", size: 32))
              .foregroundColor(.black.opacity(0.9))

            Text(releaseNote.title)
              .font(.custom("Figtree", size: 17))
              .fontWeight(.semibold)
              .foregroundColor(.black.opacity(0.78))
              .fixedSize(horizontal: false, vertical: true)
          }

          Spacer()

          Button(action: dismiss) {
            Image(systemName: "xmark")
              .font(.system(size: 13, weight: .semibold))
              .padding(8)
              .background(Color.black.opacity(0.05))
              .clipShape(Circle())
          }
          .buttonStyle(PlainButtonStyle())
          .pointingHandCursor()
          .accessibilityLabel("Close")
          .keyboardShortcut(.cancelAction)
        }

        if !releaseNote.highlights.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(releaseNote.highlights.enumerated()), id: \.offset) { _, highlight in
              HStack(alignment: .top, spacing: 12) {
                Circle()
                  .fill(Color(red: 0.25, green: 0.17, blue: 0).opacity(0.6))
                  .frame(width: 6, height: 6)
                  .padding(.top, 7)

                Text(highlight)
                  .font(.custom("Figtree", size: 15))
                  .foregroundColor(.black.opacity(0.75))
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }

        if let betaSignup = releaseNote.betaSignup {
          Label(betaSignup.followUp, systemImage: "chart.bar.xaxis")
            .font(.custom("Figtree", size: 13))
            .foregroundColor(.black.opacity(0.58))
        }

        if releaseNote.showsWeeklyFeedbackSurvey {
          surveySection
        }

        if let socialPreview = releaseNote.socialPreview {
          socialPreviewSection(socialPreview)
        }

        if let previewIntro = releaseNote.previewIntro,
          previewIntro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
          Text(previewIntro)
            .font(.custom("Figtree", size: 14))
            .foregroundColor(.black.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }

        if !releaseNote.previewImageNames.isEmpty {
          VStack(spacing: 16) {
            ForEach(releaseNote.previewImageNames, id: \.self) { imageName in
              Image(imageName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.985, green: 0.985, blue: 0.985))
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
            }
          }
          // Let previews use more horizontal space than text for better readability.
          .padding(.top, 6)
          .padding(.horizontal, -36)
        }

        if let betaSignup = releaseNote.betaSignup {
          agentsBetaSignupSection(betaSignup)
        }

        if let cta = releaseNote.cta {
          ctaSection(cta)
        }

        Color.clear
          .frame(height: 1)
          .id(bottomAnchorID)
      }
      .padding(.horizontal, 44)
      .padding(.vertical, 36)
    }
    .frame(maxHeight: 760)
    .frame(width: 780)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white)
        .shadow(color: Color.black.opacity(0.25), radius: 40, x: 0, y: 20)
    )
    .onAppear {
      AnalyticsService.shared.screen("whats_new")
      if releaseNote.showsWeeklyFeedbackSurvey && didHydrateSurveyState == false {
        hydrateSurveyStateIfNeeded()
        didHydrateSurveyState = true
      }
      if releaseNote.betaSignup != nil && agentsBetaResponseID.isEmpty {
        agentsBetaResponseID = loadResponseID(for: agentsBetaSurveyKey)
      }
    }
    .environment(\.colorScheme, .light)
    .preferredColorScheme(.light)
  }

  private func dismiss() {
    AnalyticsService.shared.capture(
      "whats_new_dismissed",
      [
        "version": releaseNote.version,
        "provider_label": currentProviderLabel,
      ])

    onDismiss()
  }

  private var surveySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("How do you feel about Weekly so far?")
        .font(.custom("Figtree", size: 15))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)

      Text(
        "A quick answer helps shape where Weekly goes next."
      )
      .font(.custom("Figtree", size: 13))
      .foregroundColor(.black.opacity(0.62))
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        ForEach(WhatsNewWeeklyFeedback.allCases) { option in
          weeklyFeedbackButton(option)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("How can we improve Weekly?")
          .font(.custom("Figtree", size: 15))
          .fontWeight(.semibold)
          .foregroundColor(.black.opacity(0.85))

        WhatsNewSurveyTextEditor(
          text: $weeklyImprovementText,
          placeholder: "New visualizations, data, comparisons, breakdowns, anything missing..."
        )
        .frame(minHeight: 78)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
      }
      .padding(.top, 4)

      if let surveyErrorText {
        Text(surveyErrorText)
          .font(.custom("Figtree", size: 13))
          .foregroundColor(Color.red.opacity(0.75))
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 12) {
        DayflowSurfaceButton(
          action: submitWeeklyFeedbackFromButton,
          content: {
            HStack(spacing: 8) {
              Image(systemName: "paperplane.fill")
                .font(.system(size: 12, weight: .semibold))
              Text(isSubmittingWeeklyFeedback ? "Saving..." : "Send feedback")
                .font(.custom("Figtree", size: 14))
                .fontWeight(.semibold)
            }
          },
          background: Color(red: 0.25, green: 0.17, blue: 0),
          foreground: .white,
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 14,
          verticalPadding: 9,
          showOverlayStroke: true
        )
        .disabled(isSubmittingWeeklyFeedback)
        .opacity(isSubmittingWeeklyFeedback ? 0.72 : 1)
        .pointingHandCursor()

        if hasSubmittedWeeklyFeedback {
          Label("Saved.", systemImage: "checkmark.circle.fill")
            .font(.custom("Figtree", size: 14))
            .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
        }
      }
    }
    .padding(.top, 10)
    .environment(\.colorScheme, .light)
    .preferredColorScheme(.light)
  }

  private func weeklyFeedbackButton(_ option: WhatsNewWeeklyFeedback) -> some View {
    let isSelected = selectedWeeklyFeedback == option

    return Button(action: {
      selectWeeklyFeedback(option)
    }) {
      HStack(spacing: 8) {
        Text(option.title)
          .font(.custom("Figtree", size: 14))
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundColor(.black.opacity(0.82))
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(
            isSelected
              ? Color(red: 0.25, green: 0.17, blue: 0).opacity(0.06)
              : Color.white
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(
            isSelected
              ? Color(red: 0.25, green: 0.17, blue: 0).opacity(0.28)
              : Color.black.opacity(0.1),
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
    .disabled(isSubmittingWeeklyFeedback)
    .pointingHandCursor()
  }

  private func agentsBetaSignupSection(_ signup: ReleaseNoteBetaSignup) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text(signup.title)
          .font(.custom("Figtree", size: 17))
          .fontWeight(.bold)
          .foregroundColor(.black.opacity(0.86))

        Text(signup.description)
          .font(.custom("Figtree", size: 14))
          .foregroundColor(.black.opacity(0.68))
      }

      if hasSubmittedAgentsBeta {
        Label("You're on the beta list.", systemImage: "checkmark.circle.fill")
          .font(.custom("Figtree", size: 14))
          .fontWeight(.semibold)
          .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
          .padding(.vertical, 6)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("How many agents do you launch per day?")
            .font(.custom("Figtree", size: 14))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.82))

          HStack(spacing: 8) {
            ForEach(AgentsPerDayOption.allCases) { option in
              agentsPerDayButton(option)
            }
          }
        }

        HStack(alignment: .top, spacing: 10) {
          agentsBetaTextField(
            title: "Email",
            placeholder: "you@company.com",
            text: $agentsBetaEmail,
            isRequired: true
          )

          agentsBetaTextField(
            title: "Company",
            placeholder: "Optional",
            text: $agentsBetaCompany,
            isRequired: false
          )
        }

        if let agentsBetaErrorText {
          Text(agentsBetaErrorText)
            .font(.custom("Figtree", size: 13))
            .foregroundColor(Color.red.opacity(0.75))
        }

        DayflowSurfaceButton(
          action: submitAgentsBeta,
          content: {
            HStack(spacing: 8) {
              if isSubmittingAgentsBeta {
                ProgressView()
                  .controlSize(.small)
                  .tint(.white)
              }

              Text(isSubmittingAgentsBeta ? "Joining..." : "Join the beta")
                .font(.custom("Figtree", size: 14))
                .fontWeight(.semibold)
            }
          },
          background: Color(red: 0.25, green: 0.17, blue: 0),
          foreground: .white,
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 16,
          verticalPadding: 10,
          showOverlayStroke: true
        )
        .disabled(isSubmittingAgentsBeta)
        .opacity(isSubmittingAgentsBeta ? 0.72 : 1)
        .pointingHandCursor()
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(red: 0.985, green: 0.975, blue: 0.955))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color(red: 0.25, green: 0.17, blue: 0).opacity(0.1), lineWidth: 1)
    )
    .padding(.top, 4)
  }

  private func agentsPerDayButton(_ option: AgentsPerDayOption) -> some View {
    let isSelected = selectedAgentsPerDay == option

    return Button {
      selectedAgentsPerDay = option
      agentsBetaErrorText = nil
    } label: {
      Text(option.title)
        .font(.custom("Figtree", size: 13))
        .fontWeight(isSelected ? .semibold : .regular)
        .foregroundColor(.black.opacity(0.8))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.white : Color.white.opacity(0.55))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
              isSelected
                ? Color(red: 0.25, green: 0.17, blue: 0).opacity(0.35)
                : Color.black.opacity(0.09),
              lineWidth: 1
            )
        )
    }
    .buttonStyle(.plain)
    .disabled(isSubmittingAgentsBeta)
    .pointingHandCursor()
  }

  private func agentsBetaTextField(
    title: String,
    placeholder: String,
    text: Binding<String>,
    isRequired: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 3) {
        Text(title)
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
          .foregroundColor(.black.opacity(0.78))

        if isRequired {
          Text("*")
            .font(.custom("Figtree", size: 13))
            .foregroundColor(.black.opacity(0.42))
        }
      }

      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black.opacity(0.84))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
        .disabled(isSubmittingAgentsBeta)
    }
    .frame(maxWidth: .infinity)
  }

  private func ctaSection(_ cta: ReleaseNoteCTA) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(cta.title)
        .font(.custom("Figtree", size: 16))
        .fontWeight(.bold)
        .foregroundColor(.black.opacity(0.86))

      Text(cta.description)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black.opacity(0.75))
        .fixedSize(horizontal: false, vertical: true)

      DayflowSurfaceButton(
        action: { openCTA(cta) },
        content: {
          HStack(spacing: 8) {
            Image(systemName: "calendar")
              .font(.system(size: 12, weight: .semibold))
            Text(cta.buttonTitle)
              .font(.custom("Figtree", size: 14))
              .fontWeight(.semibold)
          }
        },
        background: Color(red: 0.25, green: 0.17, blue: 0),
        foreground: .white,
        borderColor: .clear,
        cornerRadius: 8,
        horizontalPadding: 16,
        verticalPadding: 10,
        showOverlayStroke: true
      )
      .pointingHandCursor()
    }
    .padding(.top, 6)
  }

  /// Shows the live X embed, with the hand-drawn card as a fallback if the
  /// widget can't load (offline, script blocked, or 10s timeout).
  @ViewBuilder
  private func socialPreviewSection(_ preview: ReleaseNoteSocialPreview) -> some View {
    if tweetEmbedState == .failed {
      socialPreviewCard(preview)
    } else {
      ZStack(alignment: .topLeading) {
        TweetEmbedWebView(
          tweetURL: preview.url,
          onEvent: handleTweetEmbedEvent
        )
        .frame(height: tweetEmbedState == .ready ? tweetEmbedHeight : 220)
        .opacity(tweetEmbedState == .ready ? 1 : 0)

        if tweetEmbedState == .loading {
          tweetEmbedPlaceholder
        }
      }
      .animation(.easeInOut(duration: 0.25), value: tweetEmbedHeight)
      .animation(.easeInOut(duration: 0.25), value: tweetEmbedState == .ready)
      .task {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        if tweetEmbedState == .loading {
          tweetEmbedState = .failed
        }
      }
    }
  }

  private var tweetEmbedPlaceholder: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(Color(red: 0.985, green: 0.982, blue: 0.972))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.black.opacity(0.08), lineWidth: 1)
      )
      .overlay(
        ProgressView()
          .controlSize(.small)
      )
      .frame(height: 220)
  }

  private func handleTweetEmbedEvent(_ event: TweetEmbedWebView.Event) {
    switch event {
    case .rendered(let height):
      if height > 0 {
        tweetEmbedHeight = height
      }
      tweetEmbedState = .ready
    case .heightChanged(let height):
      if tweetEmbedState == .ready && height > 0 {
        tweetEmbedHeight = height
      }
    case .failed:
      if tweetEmbedState != .ready {
        tweetEmbedState = .failed
      }
    case .openLink(let url):
      AnalyticsService.shared.capture(
        "whats_new_social_preview_opened",
        [
          "version": releaseNote.version,
          "preview_url": url.absoluteString,
          "provider_label": currentProviderLabel,
        ])
      openURL(url)
    }
  }

  private func socialPreviewCard(_ preview: ReleaseNoteSocialPreview) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 10) {
        Text("J")
          .font(.custom("Figtree", size: 16))
          .fontWeight(.bold)
          .foregroundColor(.white)
          .frame(width: 36, height: 36)
          .background(
            Circle()
              .fill(Color(red: 0.25, green: 0.17, blue: 0))
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(preview.authorName)
            .font(.custom("Figtree", size: 14))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.86))

          Text("\(preview.authorHandle) - \(preview.dateText)")
            .font(.custom("Figtree", size: 13))
            .foregroundColor(.black.opacity(0.48))
        }

        Spacer()
      }

      Text(preview.body)
        .font(.custom("Figtree", size: 15))
        .foregroundColor(.black.opacity(0.78))
        .fixedSize(horizontal: false, vertical: true)

      Button(action: { openSocialPreview(preview) }) {
        HStack(spacing: 6) {
          Text("View on X")
            .font(.custom("Figtree", size: 14))
            .fontWeight(.semibold)
          Image(systemName: "arrow.up.right")
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(red: 0.985, green: 0.982, blue: 0.972))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.black.opacity(0.08), lineWidth: 1)
    )
    .padding(.top, 2)
  }

  private func openSocialPreview(_ preview: ReleaseNoteSocialPreview) {
    guard let url = URL(string: preview.url) else { return }
    AnalyticsService.shared.capture(
      "whats_new_social_preview_opened",
      [
        "version": releaseNote.version,
        "preview_url": preview.url,
        "provider_label": currentProviderLabel,
      ])
    openURL(url)
  }

  private func openCTA(_ cta: ReleaseNoteCTA) {
    guard let url = URL(string: cta.url) else { return }
    AnalyticsService.shared.capture(
      "whats_new_cta_opened",
      [
        "version": releaseNote.version,
        "cta_title": cta.title,
        "cta_url": cta.url,
        "provider_label": currentProviderLabel,
      ])
    openURL(url)
  }

  private var hasSubmittedWeeklyFeedback: Bool {
    submittedWeeklyFeedbackVersion == releaseNote.version
  }

  private var hasSubmittedAgentsBeta: Bool {
    submittedAgentsBetaVersion == releaseNote.version
  }

  private func selectWeeklyFeedback(_ option: WhatsNewWeeklyFeedback) {
    let previousSelection = selectedWeeklyFeedback
    selectedWeeklyFeedback = option
    persistWeeklyFeedbackState()
    surveyErrorText = nil

    Task {
      if await submitReleaseSurvey() {
        submittedWeeklyFeedbackVersion = releaseNote.version
      } else {
        selectedWeeklyFeedback = previousSelection
        persistWeeklyFeedbackState()
      }
    }
  }

  private func submitWeeklyFeedbackFromButton() {
    persistWeeklyFeedbackState()
    surveyErrorText = nil

    Task {
      if await submitReleaseSurvey() {
        submittedWeeklyFeedbackVersion = releaseNote.version
      }
    }
  }

  private func persistWeeklyFeedbackState() {
    if let selectedWeeklyFeedback {
      UserDefaults.standard.set(
        selectedWeeklyFeedback.rawValue, forKey: selectedFeedbackStorageKey)
    } else {
      UserDefaults.standard.removeObject(forKey: selectedFeedbackStorageKey)
    }

    UserDefaults.standard.set(weeklyImprovementText, forKey: improvementStorageKey)
  }

  private func hydrateSurveyStateIfNeeded() {
    if let storedFeedback = UserDefaults.standard.string(forKey: selectedFeedbackStorageKey) {
      selectedWeeklyFeedback = WhatsNewWeeklyFeedback(rawValue: storedFeedback)
    }
    weeklyImprovementText = UserDefaults.standard.string(forKey: improvementStorageKey) ?? ""
    releaseSurveyResponseID = loadResponseID(for: releaseSurveyKey)
  }

  private var selectedFeedbackStorageKey: String {
    "whatsNewWeeklyFeedback_\(releaseSurveyKey)_\(releaseNote.version)"
  }

  private var improvementStorageKey: String {
    "whatsNewWeeklyImprovement_\(releaseSurveyKey)_\(releaseNote.version)"
  }

  private func responseIDStorageKey(for surveyKey: String) -> String {
    "whatsNewReleaseSurveyResponseID_\(surveyKey)_\(releaseNote.version)"
  }

  private func loadResponseID(for surveyKey: String) -> String {
    let defaults = UserDefaults.standard
    let storageKey = responseIDStorageKey(for: surveyKey)
    if let existing = defaults.string(forKey: storageKey),
      !existing.isEmpty
    {
      return existing
    }

    let generated = UUID().uuidString.lowercased()
    defaults.set(generated, forKey: storageKey)
    return generated
  }

  private func submitReleaseSurvey() async -> Bool {
    isSubmittingWeeklyFeedback = true

    defer {
      isSubmittingWeeklyFeedback = false
    }

    do {
      let responseID =
        releaseSurveyResponseID.isEmpty
        ? loadResponseID(for: releaseSurveyKey) : releaseSurveyResponseID
      releaseSurveyResponseID = responseID
      let trimmedImprovement = weeklyImprovementText.trimmingCharacters(
        in: .whitespacesAndNewlines)
      try await ReleaseSurveyClient.submit(
        ReleaseSurveyPayload(
          responseID: responseID,
          surveyKey: releaseSurveyKey,
          version: releaseNote.version,
          selectedOption: selectedWeeklyFeedback?.rawValue,
          improvementText: trimmedImprovement.isEmpty ? nil : trimmedImprovement,
          appVersion: appVersion,
          analyticsOptIn: AnalyticsService.shared.isOptedIn,
          providerLabel: currentProviderLabel
        )
      )
      surveyErrorText = nil
      return true
    } catch {
      surveyErrorText = "Could not submit. Please try again."
      return false
    }
  }

  private func submitAgentsBeta() {
    agentsBetaErrorText = nil

    guard let selectedAgentsPerDay else {
      agentsBetaErrorText = "Choose how many agents you launch per day."
      return
    }

    let email = agentsBetaEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard isLikelyValidEmail(email) else {
      agentsBetaErrorText = "Enter a valid email address."
      return
    }

    let company = agentsBetaCompany.trimmingCharacters(in: .whitespacesAndNewlines)
    let contact = company.isEmpty ? email : "\(email) | \(company)"
    guard contact.count <= 200 else {
      agentsBetaErrorText = "Email and company must be under 200 characters combined."
      return
    }

    isSubmittingAgentsBeta = true

    Task {
      defer { isSubmittingAgentsBeta = false }

      do {
        let responseID =
          agentsBetaResponseID.isEmpty
          ? loadResponseID(for: agentsBetaSurveyKey) : agentsBetaResponseID
        agentsBetaResponseID = responseID

        try await ReleaseSurveyClient.submit(
          ReleaseSurveyPayload(
            responseID: responseID,
            surveyKey: agentsBetaSurveyKey,
            version: releaseNote.version,
            selectedOption: selectedAgentsPerDay.rawValue,
            improvementText: contact,
            appVersion: appVersion,
            analyticsOptIn: AnalyticsService.shared.isOptedIn,
            providerLabel: currentProviderLabel
          )
        )

        submittedAgentsBetaVersion = releaseNote.version
        agentsBetaEmail = ""
        agentsBetaCompany = ""
        agentsBetaErrorText = nil
      } catch {
        agentsBetaErrorText = "Could not join the beta. Please try again."
      }
    }
  }

  private func isLikelyValidEmail(_ email: String) -> Bool {
    guard email.count <= 254, !email.contains(where: \.isWhitespace) else {
      return false
    }

    let parts = email.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty else { return false }
    return parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? releaseNote.version
  }

  private var currentProviderLabel: String {
    (try? LLMProviderRoutingStore.load())?.primary.providerLabel ?? "unknown"
  }
}

private struct ReleaseSurveyPayload: Encodable {
  let responseID: String
  let surveyKey: String
  let version: String
  let selectedOption: String?
  let improvementText: String?
  let appVersion: String
  let analyticsOptIn: Bool
  let providerLabel: String

  enum CodingKeys: String, CodingKey {
    case responseID = "response_id"
    case surveyKey = "survey_key"
    case version
    case selectedOption = "pro_interest"
    case improvementText = "pro_price"
    case appVersion = "app_version"
    case analyticsOptIn = "analytics_opt_in"
    case providerLabel = "provider_label"
  }
}

private enum ReleaseSurveyClient {
  static func submit(_ payload: ReleaseSurveyPayload) async throws {
    guard let url = releaseSurveyURL() else {
      throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw URLError(.badServerResponse)
    }
  }

  private static func releaseSurveyURL() -> URL? {
    guard let endpoint = resolvedEndpoint() else { return nil }
    return URL(string: "\(endpoint)/v1/release-survey")
  }

  private static func resolvedEndpoint() -> String? {
    DayflowBackendConfiguration.endpoint()
  }
}

private struct WhatsNewSurveyTextEditor: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  var isEditable: Bool = true

  private let fontSize: CGFloat = 14
  private let textInsets = NSSize(width: 14, height: 12)

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.focusRingType = .none
    scrollView.appearance = NSAppearance(named: .aqua)

    let textView = PlaceholderTextView()
    textView.delegate = context.coordinator
    textView.placeholder = placeholder
    textView.font = NSFont(name: "Figtree", size: fontSize) ?? .systemFont(ofSize: fontSize)
    textView.textColor = NSColor.black.withAlphaComponent(0.82)
    textView.insertionPointColor = .systemBlue
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.focusRingType = .none
    textView.appearance = NSAppearance(named: .aqua)
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.autoresizingMask = [.width]
    textView.textContainerInset = textInsets
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.string = text

    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    nsView.appearance = NSAppearance(named: .aqua)

    guard let textView = nsView.documentView as? PlaceholderTextView else { return }

    if textView.string != text {
      textView.string = text
    }

    textView.placeholder = placeholder
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.appearance = NSAppearance(named: .aqua)
    textView.needsDisplay = true
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding private var text: String

    init(text: Binding<String>) {
      _text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
      textView.needsDisplay = true
    }
  }
}

private final class PlaceholderTextView: NSTextView {
  var placeholder = "" {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard string.isEmpty, let font else { return }

    let placeholderRect = NSRect(
      x: textContainerInset.width,
      y: textContainerInset.height,
      width: bounds.width - (textContainerInset.width * 2),
      height: (font.ascender - font.descender + font.leading) * 2
    )

    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.black.withAlphaComponent(0.35),
    ]

    (placeholder as NSString).draw(
      with: placeholderRect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes
    )
  }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }
}

// MARK: - Tweet Embed

/// Renders X's official embed widget for a single tweet and reports lifecycle
/// events (rendered, height changes, failures, link clicks) back to SwiftUI.
private struct TweetEmbedWebView: NSViewRepresentable {
  enum Event {
    case rendered(CGFloat)
    case heightChanged(CGFloat)
    case failed
    case openLink(URL)
  }

  let tweetURL: String
  let onEvent: (Event) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onEvent: onEvent)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "embed")

    let webView = WheelPassthroughWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.loadHTMLString(
      Self.embedHTML(tweetURL: tweetURL),
      baseURL: URL(string: "https://twitter.com")
    )
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    nsView.configuration.userContentController.removeScriptMessageHandler(forName: "embed")
    nsView.navigationDelegate = nil
    nsView.uiDelegate = nil
  }

  private static func embedHTML(tweetURL: String) -> String {
    // widgets.js only reliably recognizes twitter.com URLs in the blockquote.
    let normalizedURL = tweetURL.replacingOccurrences(
      of: "://x.com/", with: "://twitter.com/")
    return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body { margin: 0; padding: 0; background: #FFFFFF; overflow: hidden; }
        .twitter-tweet { margin: 0 !important; }
      </style>
      </head>
      <body>
      <blockquote class="twitter-tweet" data-dnt="true" data-theme="light">
        <a href="\(normalizedURL)"></a>
      </blockquote>
      <script>
        function post(message) {
          window.webkit.messageHandlers.embed.postMessage(message);
        }
        function reportFailure() {
          post({ event: "failed" });
        }
        function onWidgetsLoaded() {
          twttr.ready(function (twitter) {
            twitter.events.bind("rendered", function () {
              post({ event: "rendered", height: document.body.scrollHeight });
            });
          });
        }
        new ResizeObserver(function () {
          post({ event: "height", height: document.body.scrollHeight });
        }).observe(document.body);
      </script>
      <script src="https://platform.twitter.com/widgets.js"
              onload="onWidgetsLoaded()" onerror="reportFailure()"></script>
      </body>
      </html>
      """
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private let onEvent: (Event) -> Void

    init(onEvent: @escaping (Event) -> Void) {
      self.onEvent = onEvent
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == "embed",
        let body = message.body as? [String: Any],
        let event = body["event"] as? String
      else { return }

      let height = (body["height"] as? Double).map { CGFloat($0) } ?? 0

      switch event {
      case "rendered":
        onEvent(.rendered(height))
      case "height":
        onEvent(.heightChanged(height))
      case "failed":
        onEvent(.failed)
      default:
        break
      }
    }

    // Any link the user clicks inside the embed opens in the real browser.
    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url
      {
        decisionHandler(.cancel)
        onEvent(.openLink(url))
        return
      }
      decisionHandler(.allow)
    }

    // The widget's action buttons (like, repost) open popups — send those to
    // the browser too instead of spawning a webview window.
    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if let url = navigationAction.request.url {
        onEvent(.openLink(url))
      }
      return nil
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      onEvent(.failed)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      onEvent(.failed)
    }
  }
}

/// The embed never scrolls internally (its height always matches its content),
/// so forward wheel events to the modal's ScrollView instead of swallowing them.
private final class WheelPassthroughWebView: WKWebView {
  override func scrollWheel(with event: NSEvent) {
    nextResponder?.scrollWheel(with: event)
  }
}

// MARK: - Preview

struct WhatsNewView_Previews: PreviewProvider {
  static var previews: some View {
    Group {
      if let note = WhatsNewConfiguration.configuredRelease {
        WhatsNewView(
          releaseNote: note,
          onDismiss: { print("Dismissed") }
        )
        .frame(width: 1200, height: 800)
      } else {
        Text("Configure WhatsNewConfiguration.configuredRelease to preview.")
          .frame(width: 780, height: 400)
      }
    }
  }
}
