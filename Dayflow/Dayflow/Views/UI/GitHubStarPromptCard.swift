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
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 14) {
        Image(systemName: "checkmark")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(theme.controlText)
          .frame(width: 42, height: 42)
          .background(Circle().fill(theme.controlFill))
          .overlay(InnerGlow(shape: Circle(), color: theme.controlInnerGlow, radius: 3))
          .overlay(Circle().strokeBorder(theme.controlBorder, lineWidth: 0.75))

        Text("Your first card is ready!")
          .font(.custom("Figtree", size: 20).weight(.semibold))
          .foregroundStyle(theme.textPrimary)

        Spacer()

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel("Dismiss")
      }

      Text("If you’re enjoying Dayflow so far, a GitHub star helps other people discover it.")
        .font(.custom("Figtree", size: 17))
        .foregroundStyle(theme.textSecondary)
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        Button {
          guard !isStarring else { return }
          isStarring = true
          Task {
            await onStar()
            isStarring = false
          }
        } label: {
          HStack(spacing: 8) {
            if isStarring {
              ProgressView()
                .controlSize(.small)
                .tint(theme.primaryButtonText)
            } else {
              Image(systemName: "star")
                .font(.system(size: 17, weight: .semibold))
            }
            Text(isStarring ? "Starring…" : "Star Dayflow on GitHub")
              .font(.custom("Figtree", size: 17).weight(.semibold))
          }
          .foregroundStyle(theme.primaryButtonText)
          .frame(maxWidth: .infinity)
          .frame(height: 54)
          .background(RoundedRectangle(cornerRadius: 12).fill(theme.primaryButtonFill))
          .overlay(
            InnerGlow(
              shape: RoundedRectangle(cornerRadius: 12),
              color: theme.primaryButtonInnerGlow,
              radius: 3
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(theme.primaryButtonBorder, lineWidth: 0.75)
          )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .allowsHitTesting(!isStarring)

        Button(action: onDismiss) {
          Text("Later")
            .font(.custom("Figtree", size: 17).weight(.semibold))
            .foregroundStyle(theme.secondaryButtonText)
            .frame(width: 126, height: 54)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.secondaryButtonFill))
            .overlay(
              RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.secondaryButtonBorder, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
    .padding(24)
    .frame(width: 510)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(theme.popoverFill)
    )
    .overlay(
      InnerGlow(
        shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
        color: theme.summaryCardInnerGlow,
        radius: 4
      )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(theme.popoverBorder, lineWidth: 0.75)
    )
    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.11), radius: 18, x: 0, y: 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Star Dayflow on GitHub")
  }
}
