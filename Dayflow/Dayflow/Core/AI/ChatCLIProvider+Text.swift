import AppKit
import Foundation

extension ChatCLIProvider {
  // MARK: - Text Generation (Streaming)

  /// Stream chat responses with real-time thinking and tool execution events
  /// - Parameter sessionId: Optional session ID to resume a previous conversation
  func generateChatStreaming(prompt: String, sessionId: String? = nil) -> AsyncThrowingStream<
    ChatStreamEvent, Error
  > {
    let model: String
    let effort: String?
    switch tool {
    case .claude:
      model = "sonnet"
      effort = nil
    case .codex:
      model = "gpt-5.4"
      effort = "low"
    }

    return runner.runStreaming(
      tool: tool,
      prompt: prompt,
      workingDirectory: config.workingDirectory,
      model: model,
      reasoningEffort: effort,
      sessionId: sessionId
    )
  }

  /// Stream text-only output for protocol conformance
  func generateTextStreaming(prompt: String) -> AsyncThrowingStream<String, Error> {
    let stream = generateChatStreaming(prompt: prompt)
    return AsyncThrowingStream { continuation in
      Task {
        do {
          for try await event in stream {
            switch event {
            case .textDelta(let chunk):
              continuation.yield(chunk)
            case .error(let message):
              continuation.finish(
                throwing: NSError(
                  domain: "ChatCLI",
                  code: -1,
                  userInfo: [NSLocalizedDescriptionKey: message]
                ))
              return
            default:
              break
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  // MARK: - Text Generation (Non-Streaming)

  func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
    let model: String
    switch tool {
    case .claude:
      model = "sonnet"
    case .codex:
      model = "gpt-5.2"
    }

    return try await generateText(
      prompt: prompt,
      model: model,
      reasoningEffort: "high",
      disableTools: false
    )
  }

  func generateText(
    prompt: String,
    model: String,
    reasoningEffort: String? = nil,
    disableTools: Bool = true
  ) async throws -> (text: String, log: LLMCall) {
    let callStart = Date()
    let ctx = makeCtx(batchId: nil, operation: "generateText", startedAt: callStart)

    let run: ChatCLIRunResult
    do {
      run = try await Task.detached {
        try self.runAndScrub(
          prompt: prompt,
          model: model,
          reasoningEffort: reasoningEffort,
          disableTools: disableTools
        )
      }.value
    } catch {
      let nsErr = error as NSError
      let partialOut = nsErr.userInfo["partialStdout"] as? String
      let partialErr = nsErr.userInfo["partialStderr"] as? String
      logFailure(
        ctx: ctx, finishedAt: Date(), error: error, stdout: partialOut, stderr: partialErr)
      throw error
    }

    guard run.exitCode == 0 else {
      let errorMessage = run.stderr.isEmpty ? "CLI exited with code \(run.exitCode)" : run.stderr
      let error = NSError(
        domain: "ChatCLI", code: Int(run.exitCode),
        userInfo: [NSLocalizedDescriptionKey: errorMessage])
      logFailure(
        ctx: ctx, finishedAt: run.finishedAt, error: error, stdout: run.stdout, stderr: run.stderr,
        run: run)
      throw error
    }

    logSuccess(
      ctx: ctx, finishedAt: run.finishedAt, stdout: run.stdout, stderr: run.stderr,
      responseHeaders: tokenHeaders(from: run.usage))

    // Parse thinking - Codex puts it in stdout, Claude in stderr
    let thinking: String?
    if tool == .codex {
      thinking = runner.parseThinkingFromOutput(run.rawStdout)
    } else {
      thinking = parseThinkingFromStderr(run.stderr)
    }

    let log = makeLLMCall(start: callStart, end: run.finishedAt, input: prompt, output: run.stdout)

    // Return text with thinking prefix if present (ChatService will split on marker)
    let text = run.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    if let thinking = thinking, !thinking.isEmpty {
      return ("---THINKING---\n\(thinking)\n---END_THINKING---\n\(text)", log)
    }
    return (text, log)
  }

  func parseVideoTimestamp(_ timestamp: String) -> Int {
    let components = timestamp.components(separatedBy: ":")

    if components.count == 3 {
      guard let hours = Int(components[0]),
        let minutes = Int(components[1]),
        let seconds = Int(components[2])
      else {
        return 0
      }
      return hours * 3600 + minutes * 60 + seconds
    } else if components.count == 2 {
      guard let minutes = Int(components[0]),
        let seconds = Int(components[1])
      else {
        return 0
      }
      return minutes * 60 + seconds
    }

    return 0
  }

  func formatTimestampForPrompt(_ unixTime: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }
}
