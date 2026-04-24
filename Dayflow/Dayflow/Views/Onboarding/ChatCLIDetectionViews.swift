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
    if message.isEmpty {
      return CLIDetectionReport(
        state: .failed(message: "Exit code \(result.exitCode)"), resolvedPath: tool.executableName,
        stdout: result.stdout, stderr: result.stderr)
    }
    return CLIDetectionReport(
      state: .failed(message: message), resolvedPath: tool.executableName, stdout: result.stdout,
      stderr: result.stderr)
  }

  /// Check if a CLI tool is installed (simple boolean check)
  static func isInstalled(_ tool: CLITool) -> Bool {
    LoginShellRunner.isInstalled(tool.executableName)
  }

  /// Run an arbitrary debug command via login shell
  static func runDebugCommand(_ command: String) -> CLIResult {
    let result = LoginShellRunner.run(command, timeout: 30)
    return CLIResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
  }
}

struct ChatCLIDetectionStepView<NextButton: View>: View {
  let codexStatus: CLIDetectionState
  let codexReport: CLIDetectionReport?
  let claudeStatus: CLIDetectionState
  let claudeReport: CLIDetectionReport?
  let isChecking: Bool
  let onRetry: () -> Void
  let onInstall: (CLITool) -> Void
  let selectedTool: CLITool?
  let onSelectTool: (CLITool) -> Void
  @ViewBuilder let nextButton: () -> NextButton

  let accentColor = Color(red: 0.25, green: 0.17, blue: 0)

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(
        "Dayflow can talk to ChatGPT (via the Codex CLI) or Claude Code. You only need one installed and signed in on this Mac. After installing, run `codex auth` or `claude login` in Terminal to connect it to your account."
      )
      .font(.custom("Nunito", size: 14))
      .foregroundColor(.black.opacity(0.6))

      HStack(alignment: .top, spacing: 14) {
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
      .font(.custom("Nunito", size: 12))
      .foregroundColor(.black.opacity(0.5))

      VStack(alignment: .leading, spacing: 10) {
        Text("Choose which provider Dayflow should use")
          .font(.custom("Nunito", size: 13))
          .fontWeight(.semibold)
          .foregroundColor(.black.opacity(0.65))
        HStack(spacing: 12) {
          ForEach(CLITool.allCases, id: \.self) { tool in
            selectionButton(for: tool)
          }
        }
      }
      .padding(16)
      .background(Color.white.opacity(0.5))
      .cornerRadius(12)
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.black.opacity(0.05), lineWidth: 1)
      )

      HStack {
        DayflowSurfaceButton(
          action: {
            if !isChecking {
              onRetry()
            }
          },
          content: {
            HStack(spacing: 8) {
              if isChecking {
                ProgressView().scaleEffect(0.7)
              } else {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
              }
              Text(isChecking ? "Checking…" : "Re-check")
                .font(.custom("Nunito", size: 14))
                .fontWeight(.semibold)
            }
          },
          background: accentColor,
          foreground: .white,
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 20,
          verticalPadding: 10,
          showOverlayStroke: true
        )
        .disabled(isChecking)

        Spacer()

        nextButton()
          .opacity(canContinue ? 1.0 : 0.5)
          .allowsHitTesting(canContinue)
      }
    }
  }

  var canContinue: Bool {
    guard let selectedTool else { return false }
    return isToolAvailable(selectedTool)
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
      if enabled {
        onSelectTool(tool)
      }
    }) {
      HStack(spacing: 6) {
        Image(systemName: selectedTool == tool ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(enabled ? accentColor : Color.gray.opacity(0.6))
        VStack(alignment: .leading, spacing: 2) {
          Text(tool.shortName)
            .font(.custom("Nunito", size: 13))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(enabled ? 0.85 : 0.4))
          Text(enabled ? "Ready to use" : "Install to enable")
            .font(.custom("Nunito", size: 11))
            .foregroundColor(.black.opacity(enabled ? 0.5 : 0.35))
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(selectedTool == tool ? Color.white.opacity(0.9) : Color.white.opacity(0.5))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            selectedTool == tool ? accentColor.opacity(0.4) : Color.black.opacity(0.05),
            lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1.0 : 0.5)
    .pointingHandCursor(enabled: enabled)
  }
}

struct ChatCLIToolStatusRow: View {
  let tool: CLITool
  let status: CLIDetectionState
  let onInstall: () -> Void

  let accentColor = Color(red: 0.25, green: 0.17, blue: 0)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Icon and title row
      HStack(spacing: 10) {
        Image(tool.logoAssetName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 30, height: 30)

        Text(tool.shortName)
          .font(.custom("Nunito", size: 15))
          .fontWeight(.semibold)
          .foregroundColor(.black.opacity(0.9))

        Spacer()

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
                .font(.custom("Nunito", size: 12))
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
    .background(Color.white.opacity(0.6))
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.black.opacity(0.05), lineWidth: 1)
    )
  }

  @ViewBuilder
  var statusView: some View {
    switch status {
    case .checking, .unknown:
      HStack(spacing: 5) {
        ProgressView().scaleEffect(0.5)
        Text(status.statusLabel)
          .font(.custom("Nunito", size: 11))
          .foregroundColor(accentColor)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(accentColor.opacity(0.12))
      .cornerRadius(999)
    case .installed:
      Text(status.statusLabel)
        .font(.custom("Nunito", size: 11))
        .fontWeight(.semibold)
        .foregroundColor(Color(red: 0.13, green: 0.7, blue: 0.23))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(red: 0.13, green: 0.7, blue: 0.23).opacity(0.17))
        .cornerRadius(999)
    case .notFound:
      Text(status.statusLabel)
        .font(.custom("Nunito", size: 11))
        .fontWeight(.semibold)
        .foregroundColor(Color(hex: "E91515"))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(hex: "FFD1D1"))
        .cornerRadius(999)
    case .failed:
      Text(status.statusLabel)
        .font(.custom("Nunito", size: 11))
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
