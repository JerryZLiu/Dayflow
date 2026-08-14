import AppKit
import Foundation

extension CodexProvider {
  // MARK: - Codex activity cards

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    enum CardParseError: LocalizedError {
      case empty
      case decodeFailure
      case validationFailed(details: String)

      var errorDescription: String? {
        switch self {
        case .empty:
          return "No cards returned."
        case .decodeFailure:
          return "Failed to decode cards."
        case .validationFailed(let details):
          return details
        }
      }
    }

    let callStart = Date()
    let basePrompt = buildCardsPrompt(observations: observations, context: context)
    var actualPromptUsed = basePrompt

    let modelConfiguration = Self.activityCardModelConfiguration()
    let legacyModelConfiguration = Self.legacyActivityCardModelConfiguration()
    var model = modelConfiguration.model
    var effort = modelConfiguration.reasoningEffort

    var lastError: Error?
    var lastRun: ChatCLIRunResult?
    var lastRawOutput: String = ""
    var parsedCards: [ActivityCardData] = []
    var sessionId: String? = nil

    for attempt in 1...3 {
      do {
        let runResult = try await runStreamingAndCollect(
          prompt: actualPromptUsed, model: model, reasoningEffort: effort, sessionId: sessionId)
        let run = runResult.run
        sessionId = runResult.sessionId
        lastRun = run
        lastRawOutput = run.stdout
        let cards = try parseCards(from: run.stdout, stderr: run.stderr)
        guard !cards.isEmpty else { throw CardParseError.empty }

        let normalizedCards = normalizeCards(cards, descriptors: context.categories)
        let (coverageValid, coverageError) = validateTimeCoverage(
          existingCards: context.existingCards, newCards: normalizedCards)
        let (durationValid, durationError) = validateTimeline(normalizedCards)

        if coverageValid && durationValid {
          parsedCards = normalizedCards
          let finishedAt = run.finishedAt
          logSuccess(
            ctx: makeCtx(
              batchId: batchId, operation: "generate_cards", model: model,
              startedAt: callStart, attempt: attempt),
            finishedAt: finishedAt, stdout: run.stdout, stderr: run.stderr,
            responseHeaders: tokenHeaders(from: run.usage))
          let llmCall = makeLLMCall(
            start: callStart, end: finishedAt, input: actualPromptUsed, output: run.stdout)
          return (parsedCards, llmCall)
        }

        // Validation failed - prepare retry with error feedback
        var errorMessages: [String] = []
        if !coverageValid, let coverageError {
          AnalyticsService.shared.captureValidationFailure(
            provider: "chat_cli",
            providerID: providerID,
            operation: "generate_activity_cards",
            validationType: "time_coverage",
            attempt: attempt,
            model: model,
            batchId: batchId,
            errorDetail: coverageError
          )
          errorMessages.append(coverageError)
        }
        if !durationValid, let durationError {
          AnalyticsService.shared.captureValidationFailure(
            provider: "chat_cli",
            providerID: providerID,
            operation: "generate_activity_cards",
            validationType: "duration",
            attempt: attempt,
            model: model,
            batchId: batchId,
            errorDetail: durationError
          )
          errorMessages.append(durationError)
        }
        let combinedError = errorMessages.joined(separator: "\n\n")
        lastError = CardParseError.validationFailed(details: combinedError)
        if sessionId == nil {
          actualPromptUsed =
            basePrompt + "\n\nPREVIOUS ATTEMPT FAILED - CRITICAL REQUIREMENTS NOT MET:\n\n"
            + combinedError
            + "\n\nPlease fix these issues and ensure your output meets all requirements."
        } else {
          actualPromptUsed = buildCardsCorrectionPrompt(validationError: combinedError)
        }
        print(
          "[ChatCLI] generate_cards validation failed (attempt " + String(attempt) + "): "
            + combinedError)
      } catch {
        lastError = error
        // Capture partial output from timeout errors for logging
        if let partialOut = (error as NSError).userInfo["partialStdout"] as? String,
          !partialOut.isEmpty
        {
          lastRawOutput = partialOut
        }
        print(
          "[ChatCLI] generate_cards attempt " + String(attempt) + " failed: "
            + error.localizedDescription + " — retrying")
        actualPromptUsed = basePrompt
        sessionId = nil
        if attempt < 3,
          Self.shouldUseLegacyModel(
            after: error,
            currentModel: model,
            fallbackModel: legacyModelConfiguration.model
          )
        {
          captureLegacyModelFallback(
            operation: "generate_activity_cards",
            fromModel: model,
            toModel: legacyModelConfiguration.model,
            batchId: batchId
          )
          model = legacyModelConfiguration.model
          effort = legacyModelConfiguration.reasoningEffort
          print("[ChatCLI] Codex is outdated; retrying card generation with \(model)")
        }
      }
    }

    let finishedAt = lastRun?.finishedAt ?? Date()
    let finalError = lastError ?? CardParseError.decodeFailure
    let finalStderr =
      lastRun?.stderr
      ?? (lastError as NSError?)?.userInfo["partialStderr"] as? String
    let finalRun =
      lastRun
      ?? codexRunResultFromStreamingError(
        finalError,
        stdout: lastRawOutput,
        stderr: finalStderr ?? "",
        startedAt: callStart,
        finishedAt: finishedAt)
    logFailure(
      ctx: makeCtx(
        batchId: batchId, operation: "generate_cards", model: model,
        startedAt: callStart, attempt: 3),
      finishedAt: finishedAt, error: finalError, stdout: lastRawOutput, stderr: finalStderr,
      run: finalRun)
    throw finalError
  }

  static func activityCardModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    // Mirrors `transcriptionModelConfiguration` — picks up the
    // user's selection from `CodexModelPreference` rather than
    // hard-coding a model name.
    return (model: CodexModelPreference.load().primary.rawValue, reasoningEffort: "low")
  }

  static func legacyActivityCardModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    return (model: CodexModel.gpt54.rawValue, reasoningEffort: "low")
  }

  private func codexRunResultFromStreamingError(
    _ error: Error,
    stdout: String,
    stderr: String,
    startedAt: Date,
    finishedAt: Date
  ) -> ChatCLIRunResult? {
    let userInfo = (error as NSError).userInfo
    guard
      let shellCommand = userInfo["shellCommand"] as? String
    else {
      return nil
    }

    let environmentOverrides =
      userInfo["environmentOverrides"] as? [String: String]
      ?? [:]
    return ChatCLIRunResult(
      exitCode: -1,
      stdout: stdout,
      rawStdout: stdout,
      stderr: stderr,
      shellCommand: shellCommand,
      environmentOverrides: environmentOverrides,
      startedAt: startedAt,
      finishedAt: finishedAt,
      usage: nil
    )
  }

}
