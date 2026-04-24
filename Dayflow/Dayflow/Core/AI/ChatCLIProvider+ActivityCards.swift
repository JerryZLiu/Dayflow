import AppKit
import Foundation

extension ChatCLIProvider {
  // MARK: - Activity Cards

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    enum CardParseError: LocalizedError {
      case empty(rawOutput: String)
      case decodeFailure(rawOutput: String)
      case validationFailed(details: String, rawOutput: String)

      var errorDescription: String? {
        switch self {
        case .empty(let rawOutput):
          return "No cards returned.\n\n📄 RAW OUTPUT:\n" + rawOutput
        case .decodeFailure(let rawOutput):
          return "Failed to decode cards.\n\n📄 RAW OUTPUT:\n" + rawOutput
        case .validationFailed(let details, let rawOutput):
          return details + "\n\n📄 RAW OUTPUT:\n" + rawOutput
        }
      }
    }

    let callStart = Date()
    let basePrompt = buildCardsPrompt(observations: observations, context: context)
    var actualPromptUsed = basePrompt

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
        guard !cards.isEmpty else { throw CardParseError.empty(rawOutput: run.stdout) }

        let normalizedCards = normalizeCards(cards, descriptors: context.categories)
        let (coverageValid, coverageError) = validateTimeCoverage(
          existingCards: context.existingCards, newCards: normalizedCards)
        let (durationValid, durationError) = validateTimeline(normalizedCards)

        if coverageValid && durationValid {
          parsedCards = normalizedCards
          let finishedAt = run.finishedAt
          logSuccess(
            ctx: makeCtx(
              batchId: batchId, operation: "generate_cards", startedAt: callStart, attempt: attempt),
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
        lastError = CardParseError.validationFailed(details: combinedError, rawOutput: run.stdout)
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
      }
    }

    let finishedAt = lastRun?.finishedAt ?? Date()
    let finalError = lastError ?? CardParseError.decodeFailure(rawOutput: lastRawOutput)
    let finalStderr =
      lastRun?.stderr
      ?? (lastError as NSError?)?.userInfo["partialStderr"] as? String
    logFailure(
      ctx: makeCtx(batchId: batchId, operation: "generate_cards", startedAt: callStart, attempt: 3),
      finishedAt: finishedAt, error: finalError, stdout: lastRawOutput, stderr: finalStderr)
    throw finalError
  }

}
