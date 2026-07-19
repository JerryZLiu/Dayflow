import Foundation

extension ClaudeProvider {
  func generateChatStreaming(prompt: String, sessionId: String? = nil) -> AsyncThrowingStream<
    ChatStreamEvent, Error
  > {
    runner.runStreaming(
      tool: .claude,
      prompt: prompt,
      workingDirectory: config.workingDirectory,
      model: resolvedChatStreamingModel,
      reasoningEffort: nil,
      sessionId: sessionId
    )
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
                  domain: "ClaudeProvider",
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
    // One-off text requests (dashboard chat, ad-hoc prompts) intentionally
    // ignore `defaultModel`: the user-selected Claude model is reserved for
    // timeline-bound operations (transcription + card generation) so we
    // don't accidentally let a "fast" model setting degrade richer reasoning
    // tasks. Fall back to the same stable default as generateChatStreaming.
    try await generateText(
      prompt: prompt,
      model: resolvedChatStreamingModel,
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
      let errorMessage = run.stderr.isEmpty ? "CLI exited with code \(run.exitCode)" : run.stderr
      let error = NSError(
        domain: "ClaudeProvider", code: Int(run.exitCode),
        userInfo: [NSLocalizedDescriptionKey: errorMessage])
      logFailure(
        ctx: ctx, finishedAt: run.finishedAt, error: error, stdout: run.stdout, stderr: run.stderr,
        run: run)
      throw error
    }

    logSuccess(
      ctx: ctx, finishedAt: run.finishedAt, stdout: run.stdout, stderr: run.stderr,
      responseHeaders: tokenHeaders(from: run.usage))

    let thinking = parseThinkingFromStderr(run.stderr)
    let log = makeLLMCall(start: callStart, end: run.finishedAt, input: prompt, output: run.stdout)
    let text = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if let thinking, !thinking.isEmpty {
      return ("---THINKING---\n\(thinking)\n---END_THINKING---\n\(text)", log)
    }
    return (text, log)
  }
}
