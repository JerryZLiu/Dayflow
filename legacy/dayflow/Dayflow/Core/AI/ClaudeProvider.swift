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
      let message = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw NSError(
        domain: "ClaudeProvider",
        code: Int(run.exitCode),
        userInfo: [
          NSLocalizedDescriptionKey: message.isEmpty
            ? "Claude CLI exited with code \(run.exitCode)"
            : message
        ]
      )
    }
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
