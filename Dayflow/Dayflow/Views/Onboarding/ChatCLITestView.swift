import AppKit
import Foundation
import SwiftUI

struct ChatCLITestView: View {
  let selectedTool: CLITool?
  let onTestComplete: (Bool) -> Void

  let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
  let successAccentColor = Color(red: 0.34, green: 1, blue: 0.45)

  @State var isTesting = false
  @State var success = false
  @State var resultMessage: String?
  @State var debugOutput: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("We'll ask your CLI a simple question to verify it's working and signed in.")
        .font(.custom("Nunito", size: 12))
        .foregroundColor(SettingsStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)

      SettingsPrimaryButton(
        title: isTesting ? "Testing…" : "Test CLI",
        systemImage: "bolt.fill",
        isLoading: isTesting,
        isDisabled: selectedTool == nil,
        action: runTest
      )

      if selectedTool == nil {
        Text("Select ChatGPT or Claude above before running the test.")
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.secondary)
      }

      if success {
        SettingsStatusDot(state: .good, label: "Test successful.")
      } else if let msg = resultMessage {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 10) {
            SettingsStatusDot(state: .bad, label: msg)
            if debugOutput != nil {
              SettingsLinkButton(
                title: "Copy logs",
                systemImage: nil,
                action: copyDebugLogs
              )
            }
          }

          if let debug = debugOutput {
            ScrollView {
              Text(debug)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(SettingsStyle.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.03))
            )
          }
        }
      }
    }
  }

  func runTest() {
    guard !isTesting else { return }
    guard let tool = selectedTool else {
      resultMessage = "Pick ChatGPT or Claude first."
      return
    }

    isTesting = true
    success = false
    resultMessage = nil
    debugOutput = nil
    let testStartedAt = Date()

    captureChatCLITestStarted(for: tool)

    Task.detached {
      let outcome: Result<CLIResult, Error> = {
        do {
          return .success(try performTest(for: tool))
        } catch {
          return .failure(error)
        }
      }()

      await MainActor.run {
        let durationMs = Int(Date().timeIntervalSince(testStartedAt) * 1000)
        isTesting = false
        switch outcome {
        case .success(let cliResult):
          // Build debug output for troubleshooting
          var debugParts: [String] = []
          debugParts.append("Tool: \(tool.shortName)")
          debugParts.append("Exit code: \(cliResult.exitCode)")
          debugParts.append("Shell: \(LoginShellRunner.userLoginShell.path)")

          // Show all installations found (helps debug multi-install issues)
          let cmdName = tool == .codex ? "codex" : "claude"
          let whichResult = LoginShellRunner.run("which -a \(cmdName)", timeout: 5)
          if whichResult.exitCode == 0 {
            let paths = whichResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !paths.isEmpty {
              debugParts.append("Installations found:\n\(paths)")
            }
          }

          if !cliResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debugParts.append("stdout:\n\(cliResult.stdout)")
          }
          if !cliResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debugParts.append("stderr:\n\(cliResult.stderr)")
          }
          debugOutput = debugParts.joined(separator: "\n\n")

          // Check exit code FIRST - non-zero means failure
          if cliResult.exitCode != 0 {
            success = false
            let stderrTrimmed = cliResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let authError = detectAuthError(cliResult, for: tool) {
              resultMessage = authError
              captureChatCLITestFailed(
                for: tool,
                durationMs: durationMs,
                failureReason: "auth_error",
                exitCode: Int(cliResult.exitCode)
              )
            } else {
              if stderrTrimmed.isEmpty {
                if tool == .claude {
                  resultMessage =
                    "Claude CLI returned an error. You may need to sign in — run 'claude login' in Terminal."
                } else {
                  resultMessage =
                    "Codex CLI returned an error. You may need to sign in — run 'codex auth' in Terminal."
                }
              } else {
                resultMessage = "CLI error: \(stderrTrimmed.prefix(150))"
              }
              captureChatCLITestFailed(
                for: tool,
                durationMs: durationMs,
                failureReason: stderrTrimmed.isEmpty
                  ? "nonzero_exit_no_stderr" : "nonzero_exit_with_stderr",
                exitCode: Int(cliResult.exitCode)
              )
            }
            onTestComplete(false)
            return
          }

          // Exit code is 0, now check for expected response
          let passed = parseForSuccess(cliResult, for: tool)
          success = passed
          if passed {
            resultMessage = "CLI is working!"
            captureChatCLITestSucceeded(
              for: tool,
              durationMs: durationMs,
              exitCode: Int(cliResult.exitCode)
            )
          } else if cliResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resultMessage = "CLI returned empty response. Make sure you're signed in."
            captureChatCLITestFailed(
              for: tool,
              durationMs: durationMs,
              failureReason: "empty_response",
              exitCode: Int(cliResult.exitCode)
            )
          } else {
            let preview = cliResult.stdout.prefix(100)
            resultMessage = "Got: \"\(preview)\" — expected '4'"
            captureChatCLITestFailed(
              for: tool,
              durationMs: durationMs,
              failureReason: "unexpected_output",
              exitCode: Int(cliResult.exitCode)
            )
          }
          onTestComplete(passed)
        case .failure(let error):
          success = false
          resultMessage = error.localizedDescription
          let nsError = error as NSError

          // Build debug output even for errors
          var debugParts: [String] = []
          debugParts.append("Tool: \(tool.shortName)")
          debugParts.append("Error: \(error.localizedDescription)")
          debugParts.append("Shell: \(LoginShellRunner.userLoginShell.path)")

          let cmdName = tool == .codex ? "codex" : "claude"
          let whichResult = LoginShellRunner.run("which -a \(cmdName)", timeout: 5)
          if whichResult.exitCode == 0 {
            let paths = whichResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !paths.isEmpty {
              debugParts.append("Installations found:\n\(paths)")
            }
          } else {
            debugParts.append("Installations found: none")
          }

          debugOutput = debugParts.joined(separator: "\n\n")
          captureChatCLITestFailed(
            for: tool,
            durationMs: durationMs,
            failureReason: analyticsFailureReason(for: nsError),
            errorCode: nsError.code,
            errorDomain: nsError.domain
          )
          onTestComplete(false)
        }
      }
    }
  }

  func captureChatCLITestStarted(for tool: CLITool) {
    AnalyticsService.shared.capture(
      "chat_cli_test_started",
      chatCLITestAnalyticsProperties(for: tool)
    )
  }

  func captureChatCLITestSucceeded(
    for tool: CLITool,
    durationMs: Int,
    exitCode: Int
  ) {
    var props = chatCLITestAnalyticsProperties(for: tool)
    props["duration_ms"] = durationMs
    props["exit_code"] = exitCode
    AnalyticsService.shared.capture("chat_cli_test_succeeded", props)
  }

  func captureChatCLITestFailed(
    for tool: CLITool,
    durationMs: Int,
    failureReason: String,
    exitCode: Int? = nil,
    errorCode: Int? = nil,
    errorDomain: String? = nil
  ) {
    var props = chatCLITestAnalyticsProperties(for: tool)
    props["duration_ms"] = durationMs
    props["failure_reason"] = failureReason
    if let exitCode {
      props["exit_code"] = exitCode
    }
    if let errorCode {
      props["error_code"] = errorCode
    }
    if let errorDomain {
      props["error_domain"] = errorDomain
    }
    AnalyticsService.shared.capture("chat_cli_test_failed", props)
  }

  func chatCLITestAnalyticsProperties(for tool: CLITool) -> [String: Any] {
    [
      "provider": "chatgpt_claude",
      "tool": tool.rawValue,
      "setup_step": "test",
    ]
  }

  func analyticsFailureReason(for error: NSError) -> String {
    if error.domain == "ChatCLITest" && error.code == 1 {
      return "cli_not_found"
    }
    return "execution_error"
  }

  func copyDebugLogs() {
    guard let debug = debugOutput else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(debug, forType: .string)
  }

  func performTest(for tool: CLITool) throws -> CLIResult {
    guard CLIDetector.isInstalled(tool) else {
      throw NSError(
        domain: "ChatCLITest", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(tool.shortName) CLI not found. Install it and run '\(tool == .codex ? "codex auth" : "claude login")' in Terminal."
        ])
    }

    // Use a sandboxed directory to avoid permission prompts for Downloads/Desktop
    let safeWorkingDir = FileManager.default.temporaryDirectory

    // Simple math test - deterministic and doesn't require image handling
    let prompt = "What is 2+2? Answer with just the number."

    switch tool {
    case .codex:
      // --skip-git-repo-check needed because app runs from sandboxed directory
      // Disable MCP servers dynamically to avoid connecting to user's configured servers during test
      // -- separator ensures prompt isn't parsed as an option
      var codexArgs = [
        "exec",
        "--skip-git-repo-check",
        "-c", "model_reasoning_effort=low",
      ]
      // Dynamically disable each MCP server by name
      let mcpServers = LoginShellRunner.getCodexMCPServerNames()
      for serverName in mcpServers {
        codexArgs.append(contentsOf: ["--config", "mcp_servers.\(serverName).enabled=false"])
      }
      codexArgs.append(contentsOf: [
        "-c", "rmcp_client=false",
        "-c", "web_search=disabled",
        "--",
        prompt,
      ])
      return try runCLI(
        "codex",
        args: codexArgs,
        cwd: safeWorkingDir
      )
    case .claude:
      let runner = ChatCLIProcessRunner()
      let run = try runner.run(
        tool: .claude,
        prompt: prompt,
        workingDirectory: safeWorkingDir,
        disableTools: true
      )
      return CLIResult(stdout: run.stdout, stderr: run.stderr, exitCode: run.exitCode)
    }
  }

  func parseForSuccess(_ result: CLIResult, for tool: CLITool) -> Bool {
    let combined = (result.stdout + " " + result.stderr)
    // Simple math test - check for "4" in the response
    return combined.contains("4")
  }

  func detectAuthError(_ result: CLIResult, for tool: CLITool) -> String? {
    let combined = (result.stdout + " " + result.stderr).lowercased()

    // Check for common auth failure patterns
    let isAuthError =
      combined.contains("invalid api key")
      || combined.contains("please run /login")
      || combined.contains("401 unauthorized")
      || combined.contains("not logged in")
      || combined.contains("codex auth")
      || combined.contains("claude login")
      || combined.contains("authentication required")
      || combined.contains("unauthorized")

    guard isAuthError else { return nil }

    // Return the correct message based on which tool we're actually testing
    switch tool {
    case .claude:
      return "Claude CLI is not signed in. Run 'claude login' in Terminal to authenticate."
    case .codex:
      return "Codex CLI is not signed in. Run 'codex auth' in Terminal to authenticate."
    }
  }
}

enum CLITool: String, CaseIterable {
  case codex
  case claude

  var displayName: String {
    switch self {
    case .codex: return "ChatGPT (Codex CLI)"
    case .claude: return "Claude Code"
    }
  }

  var shortName: String {
    switch self {
    case .codex: return "ChatGPT"
    case .claude: return "Claude"
    }
  }

  var subtitle: String {
    switch self {
    case .codex:
      return "OpenAI's ChatGPT desktop tooling with codex CLI"
    case .claude:
      return "Anthropic's Claude Code command-line helper"
    }
  }

  var executableName: String {
    switch self {
    case .codex: return "codex"
    case .claude: return "claude"
    }
  }

  var versionCommand: String {
    "\(executableName) --version"
  }

  var installURL: URL? {
    switch self {
    case .codex:
      return URL(string: "https://developers.openai.com/codex/cli/")
    case .claude:
      return URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")
    }
  }

  var iconName: String {
    switch self {
    case .codex: return "terminal"
    case .claude: return "bolt.horizontal.circle"
    }
  }

  var logoAssetName: String {
    switch self {
    case .codex: return "ChatGPTLogo"
    case .claude: return "ClaudeLogo"
    }
  }
}

enum CLIDetectionState: Equatable {
  case unknown
  case checking
  case installed(version: String)
  case notFound
  case failed(message: String)

  var isInstalled: Bool {
    if case .installed = self { return true }
    return false
  }

  var statusLabel: String {
    switch self {
    case .unknown:
      return "Not checked"
    case .checking:
      return "Checking…"
    case .installed:
      return "Installed"
    case .notFound:
      return "Not installed"
    case .failed:
      return "Error"
    }
  }

  var detailMessage: String? {
    switch self {
    case .installed(let version):
      return version.trimmingCharacters(in: .whitespacesAndNewlines)
    case .failed(let message):
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    default:
      return nil
    }
  }
}
