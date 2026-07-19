import Foundation

private enum ClaudeCardGenerationError: LocalizedError {
  case empty
  case validationFailed(String)

  var errorDescription: String? {
    switch self {
    case .empty:
      return "No cards returned."
    case .validationFailed(let details):
      return details
    }
  }
}

extension ClaudeProvider {
  // MARK: - Claude activity cards

  static func activityCardModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    // Mirrors `transcriptionModelConfiguration` — we always pass
    // the user's selected alias to the CLI rather than a hard-coded
    // model name. The Settings → Providers tab is what writes this
    // preference; the catalog at `ChatCLIModelCatalog` powers the
    // picker with the live display names.
    (model: ClaudeModelPreference.load().primary.rawValue, reasoningEffort: "low")
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let callStart = Date()
    let prompt = buildCardsPrompt(observations: observations, context: context)
    let modelConfiguration = Self.activityCardModelConfiguration()
    let model = modelConfiguration.model
    let effort = modelConfiguration.reasoningEffort
    var run: ChatCLIRunResult?
    var accumulatedUsage: TokenUsage?
    var attempt = 1
    var currentPrompt = prompt

    do {
      let profile = Self.optimizedCardGenerationCLIProfile()
      let sessionID = UUID().uuidString
      let sessionCleanup = ClaudeSessionCleanup(sessionID: sessionID)
      defer { sessionCleanup.cleanup() }
      let maxAttempts = 3

      for currentAttempt in 1...maxAttempts {
        attempt = currentAttempt
        let sessionMode: ClaudeCLISessionMode =
          currentAttempt == 1 ? .start(id: sessionID) : .resume(id: sessionID)
        let currentRun = try await runOptimizedClaudeTurn(
          prompt: currentPrompt,
          model: model,
          reasoningEffort: effort,
          profile: profile,
          sessionMode: sessionMode
        )
        run = currentRun
        accumulatedUsage = Self.combinedTokenUsage(accumulatedUsage, currentRun.usage)
        try validateSuccessfulClaudeProcess(currentRun)

        let cards: [ActivityCardData]
        do {
          cards = try validatedClaudeCards(
            from: currentRun,
            context: context,
            batchId: batchId,
            model: model,
            attempt: attempt
          )
        } catch {
          guard currentAttempt < maxAttempts else { throw error }
          currentPrompt = buildCardsCorrectionPrompt(
            validationError: error.localizedDescription
          )
          print(
            "[ClaudeProvider] Card output failed validation; continuing the same session"
          )
          continue
        }

        logSuccess(
          ctx: makeCtx(
            batchId: batchId,
            operation: "generate_cards",
            model: model,
            startedAt: callStart,
            attempt: attempt
          ),
          finishedAt: currentRun.finishedAt,
          stdout: currentRun.stdout,
          stderr: currentRun.stderr,
          responseHeaders: tokenHeaders(from: accumulatedUsage)
        )
        let llmCall = makeLLMCall(
          start: callStart,
          end: currentRun.finishedAt,
          input: currentPrompt,
          output: currentRun.stdout
        )
        return (cards, llmCall)
      }

      throw ClaudeCardGenerationError.empty
    } catch {
      let nsError = error as NSError
      let partialStdout =
        run?.stdout
        ?? nsError.userInfo["partialStdout"] as? String
      let partialStderr =
        run?.stderr
        ?? nsError.userInfo["partialStderr"] as? String
      logFailure(
        ctx: makeCtx(
          batchId: batchId,
          operation: "generate_cards",
          model: model,
          startedAt: callStart,
          attempt: attempt
        ),
        finishedAt: run?.finishedAt ?? Date(),
        error: error,
        stdout: partialStdout,
        stderr: partialStderr,
        run: run,
        usage: accumulatedUsage
      )
      throw error
    }
  }

  private func validatedClaudeCards(
    from run: ChatCLIRunResult,
    context: ActivityGenerationContext,
    batchId: Int64?,
    model: String,
    attempt: Int
  ) throws -> [ActivityCardData] {
    let parsedCards = try parseCards(from: run.stdout, stderr: run.stderr)
    guard !parsedCards.isEmpty else { throw ClaudeCardGenerationError.empty }

    let normalizedCards = normalizeCards(parsedCards, descriptors: context.categories)
    let (coverageValid, coverageError) = validateTimeCoverage(
      existingCards: context.existingCards,
      newCards: normalizedCards
    )
    let (durationValid, durationError) = validateTimeline(normalizedCards)

    var validationErrors: [String] = []
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
      validationErrors.append(coverageError)
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
      validationErrors.append(durationError)
    }

    guard validationErrors.isEmpty else {
      throw ClaudeCardGenerationError.validationFailed(
        validationErrors.joined(separator: "\n\n")
      )
    }

    return normalizedCards
  }

}
