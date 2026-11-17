import AppKit
import Foundation
import SwiftUI

struct CLIDetectionReport {
  let state: CLIDetectionState
  let resolvedPath: String?
  let stdout: String?
  let stderr: String?
}

struct CLIDetector {
  /// Detect if a CLI tool is installed by running `tool --version` via login shell.
  /// This replicates exactly what happens when user types in Terminal.app.
  static func detect(tool: CLITool) async -> CLIDetectionReport {
    // Pick up a CLI installed, or a shell file edited, since the environment was last read.
    // Both tools are checked back to back, so one read covers them.
    let previousRead = ShellEnvironment.shared.current().readAt
    if ShellEnvironment.shared.refreshIfOlder(than: 30, trigger: "cli_check").readAt
      != previousRead
    {
      CodexExecutableResolver.shared.invalidate()
    }

    if tool == .codex, let resolution = CodexExecutableResolver.shared.resolve() {
      return CLIDetectionReport(
        state: .installed(version: resolution.versionSummary),
        resolvedPath: resolution.executableURL.path,
        stdout: resolution.versionSummary,
        stderr: nil
      )
    }

    let result = LoginShellRunner.run("\(tool.executableName) --version", timeout: 10)

    if result.exitCode == 0 {
      let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
      let summary = firstLine.isEmpty ? "\(tool.shortName) detected" : firstLine
      return CLIDetectionReport(
        state: .installed(version: summary), resolvedPath: tool.executableName,
        stdout: result.stdout, stderr: result.stderr)
    }

    if result.exitCode == 127 || result.stderr.contains("command not found") {
      return CLIDetectionReport(
        state: .notFound, resolvedPath: nil, stdout: result.stdout, stderr: result.stderr)
    }

    let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedPath = tool == .codex ? nil : tool.executableName
    if message.isEmpty {
      return CLIDetectionReport(
        state: .failed(message: String(localized: "Exit code \(result.exitCode)")),
        resolvedPath: resolvedPath,
        stdout: result.stdout, stderr: result.stderr)
    }
    return CLIDetectionReport(
      state: .failed(message: message), resolvedPath: resolvedPath, stdout: result.stdout,
      stderr: result.stderr)
  }

  /// Check if a CLI tool is installed (simple boolean check)
  static func isInstalled(_ tool: CLITool) -> Bool {
    LoginShellRunner.isInstalled(tool.executableName)
  }

  /// Run an arbitrary debug command via login shell
  static func runDebugCommand(_ command: String) -> CLIResult {
    let result = LoginShellRunner.run(command, timeout: 30)
    return CLIResult(
      stdout: result.stdout,
      stderr: result.stderr,
      exitCode: result.exitCode,
      shellCommand: command,
      environmentOverrides: [:]
    )
  }
}

struct ChatCLIDetectionStepView: View {
  let codexStatus: CLIDetectionState
  let codexReport: CLIDetectionReport?
  let claudeStatus: CLIDetectionState
  let claudeReport: CLIDetectionReport?
  let isChecking: Bool
  let onRetry: () -> Void
  let onInstall: (CLITool) -> Void
  let selectedTool: CLITool?
  let onSelectTool: (CLITool) -> Void
  /// Shows the Claude card in one state without running anything, for screenshots.
  var forcedClaudePhase: ClaudeOneClickSetupCard.Phase? = nil

  let accentColor = Color(hex: "FF9F6F")

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(introText)
        .font(.custom("Figtree", size: 16))
        .foregroundColor(Color(hex: "333333"))

      HStack(alignment: .top, spacing: 18) {
        ChatCLIToolStatusRow(
          tool: .codex,
          status: codexStatus,
          onInstall: { onInstall(.codex) }
        )
        ChatCLIToolStatusRow(
          tool: .claude,
          status: claudeStatus,
          // The card below installs Claude, so a second Install button here would compete.
          showsInstallButton: selectedTool != .claude,
          onInstall: { onInstall(.claude) }
        )
      }

      if selectedTool == .claude {
        ClaudeOneClickSetupCard(
          claudeStatus: claudeStatus,
          onRecheck: onRetry,
          onInstallManually: { onInstall(.claude) },
          forcedPhase: forcedClaudePhase
        )
      }

      Text(
        "Tip: Once both are installed, you can choose which provider Dayflow uses from Settings → AI Provider."
      )
      .font(.custom("Figtree", size: 16))
      .foregroundColor(Color(hex: "333333"))

      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Choose which provider Dayflow should use")
            .font(.custom("Figtree", size: 14))
            .fontWeight(.medium)
            .foregroundColor(Color(hex: "333333"))
          HStack(spacing: 12) {
            ForEach(CLITool.allCases, id: \.self) { tool in
              selectionButton(for: tool)
            }
          }
        }
        .padding(16)
        .frame(maxWidth: 516)
        .background(Color.white.opacity(0.6))
        .cornerRadius(12)
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color(hex: "EDE5E1"), lineWidth: 1)
        )

        DayflowSurfaceButton(
          action: {
            if !isChecking {
              onRetry()
            }
          },
          content: {
            HStack(spacing: 4) {
              if isChecking {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
              } else {
                Image(systemName: "arrow.clockwise")
                  .font(.system(size: 13, weight: .semibold))
                  .frame(width: 16, height: 16)
              }
              Text(isChecking ? String(localized: "Checking…") : String(localized: "Check"))
                .font(.custom("Figtree", size: 14))
                .fontWeight(.medium)
            }
          },
          background: Color(hex: "FDCEA4"),
          foreground: Color(hex: "926244"),
          borderColor: Color(hex: "F1CEBC"),
          cornerRadius: 200,
          horizontalPadding: 24,
          verticalPadding: 8,
          fixedHeight: 41,
          showOverlayStroke: false,
          innerGlowColor: Color(hex: "FFECE6")
        )
        .disabled(isChecking)
      }
    }
  }

  private var introText: String {
    if selectedTool == .claude {
      return String(
        localized:
          "Dayflow uses Claude Code with your paid Claude plan. If it isn't on this Mac yet, Dayflow can install it and sign you in below."
      )
    }
    return String(
      localized:
        "Dayflow can talk to ChatGPT (via the Codex CLI) or Claude Code. You only need one installed and signed in on this Mac. After installing, run `codex login` or `claude login` in Terminal to connect it to your account."
    )
  }

  func isToolAvailable(_ tool: CLITool) -> Bool {
    switch tool {
    case .codex:
      if codexStatus.isInstalled { return true }
      return codexReport?.resolvedPath != nil
    case .claude:
      if claudeStatus.isInstalled { return true }
      return claudeReport?.resolvedPath != nil
    }
  }

  @ViewBuilder
  func selectionButton(for tool: CLITool) -> some View {
    let enabled = isToolAvailable(tool)
    Button(action: {
      onSelectTool(tool)
    }) {
      HStack(spacing: 12) {
        Image(systemName: selectedTool == tool ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 22, weight: .regular))
          .frame(width: 24, height: 24)
          .foregroundColor(selectedTool == tool ? accentColor : Color(hex: "D0C8C2"))
        VStack(alignment: .leading, spacing: 4) {
          Text(tool.shortName)
            .font(.custom("Figtree", size: 16))
            .fontWeight(.semibold)
            .foregroundColor(.black)
          Text(enabled ? String(localized: "Ready to use") : String(localized: "Install to enable"))
            .font(.custom("Figtree", size: 12))
            .foregroundColor(Color(hex: "727272"))
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.white.opacity(0.8))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color(hex: "EDE5E1"), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

struct ChatCLIToolStatusRow: View {
  let tool: CLITool
  let status: CLIDetectionState
  var showsInstallButton = true
  let onInstall: () -> Void

  let accentColor = Color(hex: "FF9F6F")

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Icon and title row
      HStack(spacing: 12) {
        Image(tool.logoAssetName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 32, height: 32)

        Text(tool.shortName)
          .font(.custom("Figtree", size: 16))
          .fontWeight(.semibold)
          .foregroundColor(.black)

        Spacer(minLength: 12)

        statusView
      }

      // Install button if needed
      if shouldShowInstallButton {
        DayflowSurfaceButton(
          action: onInstall,
          content: {
            HStack(spacing: 6) {
              Image(systemName: "arrow.down.circle.fill").font(.system(size: 11, weight: .semibold))
              Text(installLabel)
                .font(.custom("Figtree", size: 12))
                .fontWeight(.semibold)
            }
          },
          background: .white.opacity(0.85),
          foreground: accentColor,
          borderColor: accentColor.opacity(0.35),
          cornerRadius: 6,
          horizontalPadding: 12,
          verticalPadding: 6,
          showOverlayStroke: true
        )
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.9))
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(hex: "EDE5E1"), lineWidth: 1)
    )
  }

  @ViewBuilder
  var statusView: some View {
    switch status {
    case .checking, .unknown:
      HStack(spacing: 5) {
        ProgressView().scaleEffect(0.5)
        Text(status.statusLabel)
          .font(.custom("Figtree", size: 12))
          .fontWeight(.semibold)
          .foregroundColor(Color(hex: "634342"))
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color(hex: "634342").opacity(0.08))
      .cornerRadius(20)
    case .installed:
      Text(status.statusLabel)
        .font(.custom("Figtree", size: 12))
        .fontWeight(.semibold)
        .foregroundColor(Color(hex: "21A638"))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: "DEF3E0"))
        .cornerRadius(20)
    case .notFound:
      Text(status.statusLabel)
        .font(.custom("Figtree", size: 11))
        .fontWeight(.semibold)
        .foregroundColor(Color(hex: "E91515"))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(hex: "FFD1D1"))
        .cornerRadius(999)
    case .failed:
      Text(status.statusLabel)
        .font(.custom("Figtree", size: 11))
        .fontWeight(.semibold)
        .foregroundColor(Color(red: 0.91, green: 0.34, blue: 0.16))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(red: 0.91, green: 0.34, blue: 0.16).opacity(0.18))
        .cornerRadius(999)
    }
  }

  var shouldShowInstallButton: Bool {
    guard showsInstallButton else { return false }
    switch status {
    case .notFound, .failed:
      return tool.installURL != nil
    default:
      return false
    }
  }

  var installLabel: String {
    switch status {
    case .failed:
      return String(localized: "Setup guide")
    default:
      return String(localized: "Install")
    }
  }
}

/// Installs and signs in to Claude Code from inside onboarding, so people without it don't have
/// to leave for Terminal. Before this, they took a median of 44 minutes at this step and about a
/// third of them never came back.
struct ClaudeOneClickSetupCard: View {
  enum Phase: Equatable {
    case checking
    case needsInstall
    case installing
    case installFailed
    /// The installer finished, but Dayflow still can't find `claude`.
    case installedNotFound
    case needsSignIn
    case signingIn
    case signInFailed
    case ready
  }

  let claudeStatus: CLIDetectionState
  let onRecheck: () -> Void
  let onInstallManually: () -> Void
  /// Shows one phase without running anything, for screenshots of the flow.
  var forcedPhase: Phase? = nil

  @ObservedObject private var installer = ClaudeInstaller.shared
  @ObservedObject private var signIn = ProviderSignIn.shared
  @State private var isSignedIn: Bool?

  private let accentColor = Color(hex: "FF9F6F")

  var body: some View {
    let phase = forcedPhase ?? currentPhase
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image("ClaudeLogo")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 22, height: 22)
        Text(title(for: phase))
          .font(.custom("Figtree", size: 16))
          .fontWeight(.semibold)
          .foregroundColor(.black)
      }

      Text(detail(for: phase))
        .font(.custom("Figtree", size: 14))
        .foregroundColor(Color(hex: "555555"))
        .fixedSize(horizontal: false, vertical: true)

      action(for: phase)
    }
    .padding(16)
    .frame(maxWidth: 516, alignment: .leading)
    .background(Color.white.opacity(0.85))
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(phase == .ready ? Color(hex: "BFE6C6") : accentColor.opacity(0.45), lineWidth: 1)
    )
    .animation(.easeInOut(duration: 0.2), value: phase)
    .task(id: claudeStatus) { await refreshSignedIn() }
    .onChange(of: installer.state) { _, state in
      if state == .installed { onRecheck() }
    }
    .onChange(of: signIn.state) { old, new in
      if case .waiting(.claude) = old, new == .idle {
        Task { await refreshSignedIn() }
      }
    }
  }

  private var currentPhase: Phase {
    if installer.state == .installing { return .installing }
    switch claudeStatus {
    case .unknown, .checking:
      return .checking
    case .notFound, .failed:
      switch installer.state {
      case .failed: return .installFailed
      case .installed: return .installedNotFound
      default: return .needsInstall
      }
    case .installed:
      if case .waiting(.claude) = signIn.state { return .signingIn }
      if case .failed(.claude) = signIn.state { return .signInFailed }
      switch isSignedIn {
      case .some(true): return .ready
      case .some(false): return .needsSignIn
      case .none: return .checking
      }
    }
  }

  private func title(for phase: Phase) -> String {
    switch phase {
    case .checking: return String(localized: "Checking Claude Code…")
    case .needsInstall, .installFailed: return String(localized: "Install Claude Code for me")
    case .installedNotFound: return String(localized: "Claude Code is installed")
    case .installing: return String(localized: "Installing Claude Code…")
    case .needsSignIn, .signInFailed: return String(localized: "Sign in to Claude")
    case .signingIn: return String(localized: "Finish signing in in your browser")
    case .ready: return String(localized: "Claude is ready")
    }
  }

  private func detail(for phase: Phase) -> String {
    switch phase {
    case .checking:
      return String(localized: "Looking for Claude Code on this Mac.")
    case .needsInstall:
      return String(
        localized:
          "Dayflow can install Claude Code for you. It takes about a minute and doesn't need your Mac password. You'll need a paid Claude plan, like Pro or Max, to use it."
      )
    case .installFailed:
      return String(
        localized:
          "The install didn't finish. Check your internet connection and try again, or install it yourself from Claude's website."
      )
    case .installedNotFound:
      return String(
        localized:
          "Dayflow can't find it yet. Click Check below. If that doesn't work, quit and reopen Dayflow."
      )
    case .installing:
      return String(
        localized: "Downloading and setting up Claude Code. This usually takes under a minute.")
    case .needsSignIn:
      return String(
        localized:
          "Claude Code is installed. Sign in with the Claude account that has your paid plan, and Dayflow will continue on its own."
      )
    case .signingIn:
      return String(
        localized:
          "A Claude sign-in page opened in your browser. Approve it there, then come back here.")
    case .signInFailed:
      return String(
        localized:
          "Sign-in didn't finish. Try again, or run `claude auth login` in Terminal.")
    case .ready:
      return String(
        localized: "Claude Code is installed and signed in. Continue to test the connection.")
    }
  }

  @ViewBuilder
  private func action(for phase: Phase) -> some View {
    switch phase {
    case .needsInstall, .installFailed:
      primaryButton(
        phase == .installFailed
          ? String(localized: "Try again") : String(localized: "Install Claude Code"),
        systemImage: "arrow.down.circle.fill"
      ) {
        installer.install(source: "onboarding_setup")
      }
      if phase == .installFailed {
        Button(String(localized: "Install it myself")) { onInstallManually() }
          .buttonStyle(.plain)
          .font(.custom("Figtree", size: 13))
          .foregroundColor(accentColor)
          .pointingHandCursor()
      }
    case .installedNotFound:
      primaryButton(String(localized: "Check again"), systemImage: "arrow.clockwise") {
        onRecheck()
      }
    case .needsSignIn, .signInFailed:
      primaryButton(
        phase == .signInFailed
          ? String(localized: "Try again") : String(localized: "Sign in with Claude"),
        systemImage: "person.crop.circle.fill"
      ) {
        signIn.start(.claude, source: "onboarding_setup")
      }
    case .installing, .checking:
      ProgressView()
        .scaleEffect(0.7)
        .frame(height: 24)
    case .signingIn:
      HStack(spacing: 12) {
        ProgressView().scaleEffect(0.7).frame(width: 20, height: 20)
        Button(String(localized: "Browser didn't open? Try again")) {
          signIn.start(.claude, source: "onboarding_setup_retry")
        }
        .buttonStyle(.plain)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(accentColor)
        .pointingHandCursor()
      }
    case .ready:
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
        Text("Installed and signed in")
      }
      .font(.custom("Figtree", size: 14))
      .fontWeight(.semibold)
      .foregroundColor(Color(hex: "21A638"))
    }
  }

  private func primaryButton(
    _ title: String, systemImage: String, action: @escaping () -> Void
  ) -> some View {
    DayflowSurfaceButton(
      action: action,
      content: {
        HStack(spacing: 6) {
          Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
          Text(title)
            .font(.custom("Figtree", size: 14))
            .fontWeight(.semibold)
        }
      },
      background: accentColor,
      foreground: .white,
      borderColor: Color(hex: "F4C8B1"),
      cornerRadius: 200,
      horizontalPadding: 20,
      verticalPadding: 8,
      showOverlayStroke: false,
      innerGlowColor: Color(hex: "FFDCCB").opacity(0.9)
    )
  }

  private func refreshSignedIn() async {
    guard forcedPhase == nil, claudeStatus.isInstalled else {
      isSignedIn = nil
      return
    }
    let signedIn = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: ProviderHealthCheck.isSignedIn(.claude))
      }
    }
    // A Claude too old to report its sign-in state gets the connection test to find out.
    isSignedIn = signedIn ?? true
  }
}
