import Foundation

final class ClaudeProvider: AgentCLISupporting {
  let providerID: LLMProviderID = .claude
  var cliTool: ChatCLITool { .claude }
  let runner = ChatCLIProcessRunner()
  let config = ChatCLIConfigManager.shared

  init() {
    config.ensureWorkingDirectory()
  }

  static func optimizedTranscriptionCLIProfile() -> ClaudeCLIExecutionProfile {
    .optimizedTranscription
  }

  static func optimizedCardGenerationCLIProfile() -> ClaudeCLIExecutionProfile {
    .optimizedCardGeneration
  }

  static func optimizedTranscriptionCorrectionCLIProfile() -> ClaudeCLIExecutionProfile {
    .optimizedTranscriptionCorrection
  }

  func runOptimizedClaudeTurn(
    prompt: String,
    model: String,
    reasoningEffort: String?,
    profile: ClaudeCLIExecutionProfile,
    sessionMode: ClaudeCLISessionMode,
    environmentOverrides: [String: String] = [:]
  ) async throws -> ChatCLIRunResult {
    let runner = runner
    let workingDirectory = config.workingDirectory
    return try await Task.detached(priority: .utility) {
      try runner.run(
        tool: .claude,
        prompt: prompt,
        workingDirectory: workingDirectory,
        imagePaths: [],
        model: model,
        reasoningEffort: reasoningEffort,
        disableTools: false,
        claudeProfile: profile,
        claudeSessionMode: sessionMode,
        environmentOverrides: environmentOverrides
      )
    }.value
  }

  static func combinedTokenUsage(_ first: TokenUsage?, _ second: TokenUsage?) -> TokenUsage? {
    guard let first else { return second }
    return first.adding(second)
  }

  func validateSuccessfulClaudeProcess(_ run: ChatCLIRunResult) throws {
    guard run.exitCode == 0 else {
      // Claude CLI surfaces API errors as JSON events on stdout (`--output-format json`), not
      // on stderr — so a `claude -p` that exits non-zero with empty stderr is almost always
      // a transient API failure (529 overloaded, 5xx, network). Without a richer message the
      // recording panel just says "Claude CLI exited with code 1" and the user has no idea
      // it's a server-side issue they can wait out. Surface the underlying signal when we
      // can detect it.
      let stderrMessage = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      let detected = Self.detectTransientClaudeFailure(in: run.stdout)
      let message: String
      if !stderrMessage.isEmpty {
        message = stderrMessage
      } else if let detected = detected {
        message = detected
      } else {
        message = "Claude CLI exited with code \(run.exitCode)"
      }
      throw NSError(
        domain: "ClaudeProvider",
        code: Int(run.exitCode),
        userInfo: [
          NSLocalizedDescriptionKey: message
        ]
      )
    }
  }

  /// Scan Claude's JSON-streamed stdout for a transient API failure shape (529 overloaded,
  /// 5xx, rate limit) and return a human-readable hint pointing at status.claude.com. We
  /// only flag the patterns we know are server-side so the user doesn't waste time
  /// re-trying a binary that broke locally.
  private static func detectTransientClaudeFailure(in stdout: String) -> String? {
    let lower = stdout.lowercased()
    // The Claude CLI emits these as JSON-stringified `error.type` / `error.message` values
    // inside the stream, so a substring match is reliable.
    if lower.contains("overloaded") || lower.contains(" 529") {
      return
        "Claude API is temporarily overloaded (529). This is a server-side issue — try again in a few minutes. If it persists, check https://status.claude.com."
    }
    if lower.contains("rate_limit") || lower.contains("rate limit") {
      return
        "Claude API rate limit hit. Wait a few minutes and retry from Settings."
    }
    if lower.contains(" 5") && (lower.contains("internal_server_error") || lower.contains("service_unavailable"))
    {
      return
        "Claude API server error. This is a server-side issue — try again in a few minutes. If it persists, check https://status.claude.com."
    }
    return nil
  }

}

/// Deletes Dayflow's short resumable Claude conversation after its optional correction turn.
/// The normal Claude config remains in place so `claude -p` uses the user's current auth setup.
struct ClaudeSessionCleanup {
  private let sessionID: String
  private let claudeConfigDirectory: URL

  init(
    sessionID: String,
    claudeConfigDirectory: URL? = nil
  ) {
    self.sessionID = sessionID
    self.claudeConfigDirectory =
      claudeConfigDirectory ?? ClaudeConfigDirectory.currentInLoginShell
  }

  func cleanup(fileManager: FileManager = .default) {
    removeSessionTranscript(from: claudeConfigDirectory, fileManager: fileManager)
  }

  private func removeSessionTranscript(
    from configDirectory: URL,
    fileManager: FileManager
  ) {
    let projectsDirectory = configDirectory.appendingPathComponent("projects", isDirectory: true)
    guard
      let enumerator = fileManager.enumerator(
        at: projectsDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return }

    let expectedFilename = "\(sessionID).jsonl"
    for case let candidate as URL in enumerator
    where candidate.lastPathComponent == expectedFilename {
      do {
        try fileManager.removeItem(at: candidate)
      } catch {
        print(
          "[ClaudeProvider] Failed to remove temporary Claude session transcript: \(error.localizedDescription)"
        )
      }
    }
  }
}

private enum ClaudeConfigDirectory {
  static let currentInLoginShell: URL = {
    let result = LoginShellRunner.run("printenv CLAUDE_CONFIG_DIR", timeout: 5)
    let configuredPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.exitCode == 0, !configuredPath.isEmpty {
      return URL(fileURLWithPath: NSString(string: configuredPath).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude", isDirectory: true)
  }()
}
