import Foundation

final class CodexProvider: AgentCLISupporting {
  let providerID: LLMProviderID = .chatGPT
  var cliTool: ChatCLITool { .codex }
  let runner = ChatCLIProcessRunner()
  let config = ChatCLIConfigManager.shared

  init() {
    config.ensureWorkingDirectory()
  }

  static func availabilityFallback(for model: String, error: Error, stderr: String? = nil)
    -> String?
  {
    let nsError = error as NSError
    let text = [
      error.localizedDescription, stderr ?? "",
      nsError.userInfo["partialStderr"] as? String ?? "",
    ].joined(separator: "\n").lowercased()
    guard
      ![
        "invalid_api_key", "insufficient_quota", "usage limit", "country, region",
        "failed to refresh token",
      ].contains(where: { text.contains($0) })
    else { return nil }
    let pattern =
      #"model_not_found|unsupported_model|unknown model|model not found|\bmodel\b[^\r\n]{0,160}(?:does not exist|not available|not supported|(?:do not|don't|not) have access)"#
    guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
    switch model {
    case "gpt-6.1-sol": return "gpt-5.6-sol"
    case "gpt-6-luna": return "gpt-5.6-luna"
    default: return nil
    }
  }

  static func recordModelFallback(from: String, to: String, operation: String) {
    AnalyticsService.shared.capture(
      "llm_model_fallback",
      [
        "provider": "chat_cli", "provider_id": LLMProviderID.chatGPT.rawValue,
        "operation": operation, "from_model": from, "to_model": to,
        "reason": "model_unavailable",
      ])
  }
}

/// Deletes a saved Codex session once nothing will resume it.
///
/// Codex keeps every session it runs in its sessions folder forever, with attached screenshots
/// stored inline as base64. One-off runs avoid that with `--ephemeral` (see
/// `ChatCLIProcessRunner.run`), but a conversation Dayflow resumes has to be saved, so one
/// that sends screenshots (Flow) removes its file when it ends. Codex names the file
/// `sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl`.
struct CodexSessionCleanup {
  private let threadID: String
  private let sessionsDirectory: URL

  init(threadID: String, sessionsDirectory: URL? = nil) {
    self.threadID = threadID
    self.sessionsDirectory = sessionsDirectory ?? Self.defaultSessionsDirectory()
  }

  func cleanup(fileManager: FileManager = .default) {
    // Thread ids are UUIDs. Anything else could match other sessions' files.
    guard UUID(uuidString: threadID) != nil else { return }
    guard
      let enumerator = fileManager.enumerator(
        at: sessionsDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return }

    let expectedSuffix = "-\(threadID).jsonl"
    for case let candidate as URL in enumerator
    where candidate.lastPathComponent.hasSuffix(expectedSuffix) {
      do {
        try fileManager.removeItem(at: candidate)
      } catch {
        print("[CodexProvider] Failed to remove Codex session file: \(error.localizedDescription)")
      }
    }
  }

  /// `$CODEX_HOME/sessions` when the user's shell sets CODEX_HOME, otherwise `~/.codex/sessions`.
  private static func defaultSessionsDirectory() -> URL {
    let codexHome =
      ShellEnvironment.shared.current().launchEnvironment["CODEX_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let homeDirectory =
      codexHome.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".codex", isDirectory: true)
      : URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath, isDirectory: true)
    return homeDirectory.appendingPathComponent("sessions", isDirectory: true)
  }
}
