import Foundation

final class ClaudeProvider: AgentCLISupporting {
  let providerID: LLMProviderID = .claude
  var cliTool: ChatCLITool { .claude }
  let runner = ChatCLIProcessRunner()
  let config = ChatCLIConfigManager.shared
  /// When non-nil, this overrides whatever the static `*ModelConfiguration`
  /// methods would otherwise pick as the canonical Claude model. `LLMService`
  /// populates it from `UserDefaults` (key: `llmClaudeModel`) so the model
  /// the provider uses stays in sync with the user's Settings selection.
  /// When nil, providers fall back to the hardcoded default.
  let defaultModel: String?

  init(defaultModel: String? = nil) {
    self.defaultModel = defaultModel
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

  /// Resolved model for activity-card generation. Uses `defaultModel` when the
  /// user has configured one in Settings, otherwise falls back to the
  /// canonical Claude model returned by `activityCardModelConfiguration()`.
  /// Reasoning effort is always taken from the static default because the
  /// effort is a property of the Claude profile, not the model id.
  func resolvedActivityCardModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    let fallback = Self.activityCardModelConfiguration()
    return (model: defaultModel ?? fallback.model, reasoningEffort: fallback.reasoningEffort)
  }

  /// Resolved model for screenshot transcription. Same shape as
  /// `resolvedActivityCardModelConfiguration()`; kept distinct so future per-
  /// operation overrides (e.g. a faster transcription-only model) can be
  /// added without touching the activity-card path.
  func resolvedTranscriptionModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    let fallback = Self.transcriptionModelConfiguration()
    return (model: defaultModel ?? fallback.model, reasoningEffort: fallback.reasoningEffort)
  }

  /// Model used for one-off `generateChatStreaming` calls (dashboard chat,
  /// on-demand text). Falls back to a stable Claude default.
  var resolvedChatStreamingModel: String {
    defaultModel ?? Self.activityCardModelConfiguration().model
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
