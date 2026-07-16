import Foundation

private enum ClaudeCardGenerationError: LocalizedError {
  case empty

  var errorDescription: String? {
    "No cards returned."
  }
}

extension ClaudeProvider {
  // MARK: - Claude activity cards

  static func activityCardModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    (model: "claude-sonnet-5", reasoningEffort: "low")
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

    do {
      let profile = Self.optimizedCardGenerationCLIProfile()
      let sessionID = UUID().uuidString
      let sessionCleanup = ClaudeSessionCleanup(sessionID: sessionID)
      defer { sessionCleanup.cleanup() }
      let initialRun = try await runOptimizedClaudeTurn(
        prompt: prompt,
        model: model,
        reasoningEffort: effort,
        profile: profile,
        sessionMode: .start(id: sessionID)
      )
      run = initialRun
      accumulatedUsage = initialRun.usage

      try validateSuccessfulClaudeProcess(initialRun)

      let cards: [ActivityCardData]
      let finalRun: ChatCLIRunResult
      let totalUsage: TokenUsage?
      do {
        cards = try validatedClaudeCards(
          from: initialRun,
          observations: observations,
          context: context
        )
        finalRun = initialRun
        totalUsage = accumulatedUsage
      } catch {
        attempt = 2
        let correctionPrompt = buildCardsCorrectionPrompt(
          validationError: error.localizedDescription
        )
        print(
          "[ClaudeProvider] Card output failed strict validation; continuing the same session once"
        )
        let correctionRun = try await runOptimizedClaudeTurn(
          prompt: correctionPrompt,
          model: model,
          reasoningEffort: effort,
          profile: profile,
          sessionMode: .resume(id: sessionID)
        )
        run = correctionRun
        accumulatedUsage = Self.combinedTokenUsage(accumulatedUsage, correctionRun.usage)
        try validateSuccessfulClaudeProcess(correctionRun)
        cards = try validatedClaudeCards(
          from: correctionRun,
          observations: observations,
          context: context
        )
        finalRun = correctionRun
        totalUsage = accumulatedUsage
      }

      logSuccess(
        ctx: makeCtx(
          batchId: batchId,
          operation: "generate_cards",
          model: model,
          startedAt: callStart,
          attempt: attempt
        ),
        finishedAt: finalRun.finishedAt,
        stdout: finalRun.stdout,
        stderr: finalRun.stderr,
        responseHeaders: tokenHeaders(from: totalUsage)
      )
      let llmCall = makeLLMCall(
        start: callStart,
        end: finalRun.finishedAt,
        input: prompt,
        output: finalRun.stdout
      )
      return (cards, llmCall)
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
    observations: [Observation],
    context: ActivityGenerationContext
  ) throws -> [ActivityCardData] {
    let parsedCards = try parseClaudeCardsStrict(from: run.stdout, stderr: run.stderr)
    guard !parsedCards.isEmpty else { throw ClaudeCardGenerationError.empty }

    try validateClaudeCardCategories(parsedCards, descriptors: context.categories)
    try ClaudeOutputValidator.validateActivityCards(
      parsedCards,
      existingCards: context.existingCards,
      observations: observations
    )
    return parsedCards
  }

  private func validateClaudeCardCategories(
    _ cards: [ActivityCardData],
    descriptors: [LLMCategoryDescriptor]
  ) throws {
    guard !descriptors.isEmpty else { return }
    let allowed = Set(descriptors.map(\.name))
    if let card = cards.first(where: { !allowed.contains($0.category) }) {
      throw NSError(
        domain: "ClaudeProvider",
        code: -97,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Card '\(card.title)' must use one configured category exactly as written. Got '\(card.category)'."
        ]
      )
    }
  }

}
