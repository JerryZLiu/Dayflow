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
        state: .failed(message: "Exit code \(result.exitCode)"), resolvedPath: resolvedPath,
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

  let accentColor = Color(hex: "FF9F6F")

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(
        "Dayflow can talk to ChatGPT (via the Codex CLI) or Claude Code. You only need one installed and signed in on this Mac. After installing, run `codex auth` or `claude login` in Terminal to connect it to your account."
      )
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
          onInstall: { onInstall(.claude) }
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
              Text(isChecking ? "Checking…" : "Check")
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
          Text(enabled ? "Ready to use" : "Install to enable")
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

        Spacer(minLength: 53)

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
      return "Setup guide"
    default:
      return "Install"
    }
  }
}
