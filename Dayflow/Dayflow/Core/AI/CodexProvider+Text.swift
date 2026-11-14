import Foundation

extension CodexProvider {
  func generateChatStreaming(prompt: String, sessionId: String? = nil) -> AsyncThrowingStream<
    ChatStreamEvent, Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        var model = "gpt-6-luna"
        while true {
          let fallback = await self.forwardChatEvents(
            model: model, prompt: prompt, sessionId: sessionId, continuation: continuation)
          guard let fallback else { return }
          Self.recordModelFallback(from: model, to: fallback, operation: "chat")
          model = fallback
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Runs one chat attempt and forwards its events. Returns the older model to retry with when
  /// the account can't use `model` and nothing has been shown yet; otherwise finishes the stream.
  private func forwardChatEvents(
    model: String, prompt: String, sessionId: String?,
    continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
  ) async -> String? {
    let stream = runner.runStreaming(
      tool: .codex,
      prompt: prompt,
      workingDirectory: config.workingDirectory,
      model: model,
      reasoningEffort: "low",
      sessionId: sessionId
    )
    var hasShownText = false
    do {
      for try await event in stream {
        switch event {
        case .error(let message):
          let error = NSError(
            domain: "CodexProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
          if !hasShownText, let fallback = Self.availabilityFallback(for: model, error: error) {
            return fallback
          }
        case .textDelta, .complete:
          hasShownText = true
        default:
          break
        }
        continuation.yield(event)
      }
      continuation.finish()
    } catch {
      if !hasShownText, let fallback = Self.availabilityFallback(for: model, error: error) {
        return fallback
      }
      continuation.finish(throwing: error)
    }
    return nil
  }

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
                  domain: "CodexProvider",
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

  func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
    try await generateText(
      prompt: prompt,
      model: "gpt-5.2",
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
    let ctx = makeCtx(
      batchId: nil, operation: "generateText", model: model, startedAt: callStart)

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
      let errorMessage = run.failureMessage(toolName: "Codex CLI")
      let error = NSError(
        domain: "CodexProvider", code: Int(run.exitCode),
        userInfo: [NSLocalizedDescriptionKey: errorMessage])
      logFailure(
        ctx: ctx, finishedAt: run.finishedAt, error: error, stdout: run.stdout, stderr: run.stderr,
        run: run)
      throw error
    }

    logSuccess(
      ctx: ctx, finishedAt: run.finishedAt, stdout: run.stdout, stderr: run.stderr,
      responseHeaders: tokenHeaders(from: run.usage))

    let thinking = runner.parseThinkingFromOutput(run.rawStdout)
    let log = makeLLMCall(start: callStart, end: run.finishedAt, input: prompt, output: run.stdout)
    let text = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if let thinking, !thinking.isEmpty {
      return ("---THINKING---\n\(thinking)\n---END_THINKING---\n\(text)", log)
    }
    return (text, log)
  }
}
