import SwiftUI

enum GitHubStarPromptState {
  static let repositoryURL = URL(string: "https://github.com/jerryzliu/Dayflow")!

  /// How long to wait between asks (and between gh checks for people we can't ask).
  static let reminderInterval: TimeInterval = 3 * 24 * 60 * 60

  /// Set once the person clicks any star button or gh reports Dayflow as starred.
  /// After that we never ask again, even if the browser star can't be verified.
  private static let isDoneKey = "gitHubStarPromptDone"
  private static let lastAttemptAtKey = "gitHubStarPromptLastAttemptAt"
  private static let lastShownAtKey = "gitHubStarPromptLastShownAt"
  private static let shownCountKey = "gitHubStarPromptShownCount"
  /// The one-time prompt for people without gh. Reuses the original first-card key so
  /// anyone who already saw the old prompt isn't asked again.
  private static let hasShownBrowserPromptKey = "hasShownGitHubStarPrompt"

  static var isDone: Bool {
    UserDefaults.standard.bool(forKey: isDoneKey)
  }

  static var hasShownBrowserPrompt: Bool {
    UserDefaults.standard.bool(forKey: hasShownBrowserPromptKey)
  }

  /// When either version of the card last appeared. Surveys use it to stay off the same day.
  static var lastShownAt: Date? {
    UserDefaults.standard.object(forKey: lastShownAtKey) as? Date
  }

  static var shownCount: Int {
    UserDefaults.standard.integer(forKey: shownCountKey)
  }

  /// True when it's been at least `reminderInterval` since the last gh check.
  static var isDue: Bool {
    guard !isDone else { return false }
    guard let lastAttemptAt = UserDefaults.standard.object(forKey: lastAttemptAtKey) as? Date else {
      return true
    }
    return Date().timeIntervalSince(lastAttemptAt) >= reminderInterval
  }

  static func markDone() {
    UserDefaults.standard.set(true, forKey: isDoneKey)
  }

  /// Starts the 3-day wait, whether or not the check ended in showing the prompt.
  static func markAttempted() {
    UserDefaults.standard.set(Date(), forKey: lastAttemptAtKey)
  }

  static func markShown() {
    markAttempted()
    UserDefaults.standard.set(shownCount + 1, forKey: shownCountKey)
    UserDefaults.standard.set(Date(), forKey: lastShownAtKey)
  }

  static func markBrowserPromptShown() {
    UserDefaults.standard.set(true, forKey: hasShownBrowserPromptKey)
    UserDefaults.standard.set(Date(), forKey: lastShownAtKey)
  }
}

enum GitHubStarService {
  static func starDayflow() async -> Bool {
    await Task.detached(priority: .userInitiated) {
      guard !GitHubStarPrompt.shouldUseBrowser else { return false }
      let result = LoginShellRunner.run(
        "gh api -X PUT user/starred/JerryZLiu/Dayflow",
        timeout: 15
      )
      return result.exitCode == 0
    }.value
  }
}

struct GitHubStarPromptCard: View {
  @Environment(\.dayflowTheme) private var theme

  /// Current stargazer count from gh, used for social proof. Nil if the lookup failed.
  let starCount: Int?
  /// True for people without gh: the button opens GitHub in the browser instead.
  let usesBrowser: Bool
  /// Returns true when gh starred the repo, so the card can say thanks before closing.
  let onStar: () async -> Bool
  let onDismiss: () -> Void
  @State private var isStarring = false
  @State private var didStar = false

  private var bodyText: String {
    if usesBrowser {
      return String(
        localized:
          "Dayflow is free and open source, and GitHub stars are how other people find it. If you’re enjoying it, a star would mean a lot."
      )
    }
    if let starCount {
      let formattedCount = starCount.formatted(.number)
      return String(
        localized:
          "Dayflow is free and open source, and GitHub stars are how other people find it. Join \(formattedCount) people who’ve starred it. It’s one click, no browser needed."
      )
    }
    return String(
      localized:
        "Dayflow is free and open source, and GitHub stars are how other people find it. It’s one click, no browser needed."
    )
  }

  private var buttonTitle: String {
    if didStar { return String(localized: "Starred. Thank you!") }
    if isStarring { return String(localized: "Starring…") }
    return String(localized: "Give a star on GitHub")
  }

  var body: some View {
    VStack(spacing: 40) {
      VStack(spacing: 12) {
        Text("Enjoying Dayflow?")
          .font(.custom("Figtree", size: 16).weight(.semibold))
          .foregroundStyle(theme.textPrimary)
          .frame(maxWidth: .infinity)

        Text(bodyText)
          .font(.custom("Figtree", size: 14))
          .foregroundStyle(theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text("— Jerry, who makes Dayflow")
          .font(.custom("Figtree", size: 13))
          .foregroundStyle(theme.textPrimary.opacity(0.6))
          .frame(maxWidth: .infinity, alignment: .trailing)
      }

      VStack(spacing: 11) {
        Button {
          guard !isStarring, !didStar else { return }
          isStarring = true
          Task {
            didStar = await onStar()
            isStarring = false
          }
        } label: {
          HStack(spacing: 4) {
            if isStarring {
              ProgressView()
                .controlSize(.small)
                .tint(theme.primaryButtonText)
            } else {
              Image(systemName: didStar ? "star.fill" : "star")
                .font(.system(size: 14, weight: .medium))
            }
            Text(buttonTitle)
              .font(.custom("Figtree", size: 14).weight(.medium))
          }
          .foregroundStyle(theme.primaryButtonText)
          .frame(maxWidth: .infinity)
          .frame(height: 40)
          .background(Capsule().fill(theme.primaryButtonFill))
          .overlay(InnerGlow(shape: Capsule(), color: theme.primaryButtonInnerGlow, radius: 3))
          .overlay(
            Capsule().strokeBorder(theme.primaryButtonBorder, lineWidth: theme.isDark ? 0.5 : 0.75))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .allowsHitTesting(!isStarring && !didStar)

        Button(action: onDismiss) {
          Text("Later")
            .font(.custom("Figtree", size: 14).weight(theme.isDark ? .medium : .regular))
            .foregroundStyle(theme.secondaryButtonText)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 20).fill(theme.secondaryButtonFill))
            .overlay(
              RoundedRectangle(cornerRadius: 20)
                .strokeBorder(theme.secondaryButtonBorder, lineWidth: theme.isDark ? 1 : 0.75)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
    .promptCardStyle(width: 339)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Star Dayflow on GitHub")
  }
}

/// The floating bottom-right card look shared by the star prompt and surveys.
struct PromptCardStyle: ViewModifier {
  @Environment(\.dayflowTheme) private var theme
  let width: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(20)
      .frame(width: width)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.ultraThinMaterial)
      )
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(theme.isDark ? Color(hex: "272F43") : Color(hex: "FFFBF9").opacity(0.9))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(theme.isDark ? Color(hex: "5B5B5B") : Color(hex: "E3DAD1"), lineWidth: 1)
      )
      .shadow(
        color: theme.isDark ? Color(hex: "463B54") : Color(hex: "E5DDD5"),
        radius: theme.isDark ? 16 : 12, x: 0, y: 4
      )
  }
}

extension View {
  func promptCardStyle(width: CGFloat) -> some View {
    modifier(PromptCardStyle(width: width))
  }
}
