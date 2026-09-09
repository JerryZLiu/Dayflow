import SwiftUI

enum GitHubStarPromptState {
  static let hasShownKey = "hasShownGitHubStarPrompt"
  static let repositoryURL = URL(string: "https://github.com/jerryzliu/Dayflow")!

  static var hasShown: Bool {
    UserDefaults.standard.bool(forKey: hasShownKey)
  }

  static func markShown() {
    UserDefaults.standard.set(true, forKey: hasShownKey)
  }
}

enum GitHubStarService {
  static func starDayflow() async -> Bool {
    await Task.detached(priority: .userInitiated) {
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

  let onStar: () async -> Void
  let onDismiss: () -> Void
  @State private var isStarring = false

  var body: some View {
    VStack(spacing: 40) {
      VStack(spacing: 12) {
        Text("Your first card is ready!")
          .font(.custom("Figtree", size: 16).weight(.semibold))
          .foregroundStyle(theme.textPrimary)
          .frame(maxWidth: .infinity)

        Text("If you’re enjoying Dayflow so far, a GitHub star helps other people discover it.")
          .font(.custom("Figtree", size: 14))
          .foregroundStyle(theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(spacing: 11) {
        Button {
          guard !isStarring else { return }
          isStarring = true
          Task {
            await onStar()
            isStarring = false
          }
        } label: {
          HStack(spacing: 4) {
            if isStarring {
              ProgressView()
                .controlSize(.small)
                .tint(theme.primaryButtonText)
            } else {
              Image(systemName: "star")
                .font(.system(size: 14, weight: .medium))
            }
            Text(isStarring ? "Starring…" : "Give a star on GitHub")
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
        .allowsHitTesting(!isStarring)

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
    .padding(20)
    .frame(width: 339)
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
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Star Dayflow on GitHub")
  }
}
