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

struct ClaudeCardGenerationPlan {
  let observations: [Observation]
  let context: ActivityGenerationContext
  let requiresSingleCard: Bool
  let allowsSingleShortCard: Bool
  let expectedStartTime: String?
  let expectedEndTime: String?
}

extension ClaudeProvider {
  // MARK: - Claude activity cards

  static func activityCardModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    (model: "sonnet", reasoningEffort: "low")
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let callStart = Date()
    let generationPlan = makeClaudeCardGenerationPlan(
      observations: observations,
      context: context
    )
    let prompt = buildCardsPrompt(
      observations: generationPlan.observations,
      context: generationPlan.context
    )
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
            observations: generationPlan.observations,
            context: generationPlan.context,
            requiresSingleCard: generationPlan.requiresSingleCard,
            expectedStartTime: generationPlan.expectedStartTime,
            expectedEndTime: generationPlan.expectedEndTime,
            allowsSingleShortCard: generationPlan.allowsSingleShortCard,
            batchId: batchId,
            model: model,
            attempt: attempt
          )
        } catch {
          guard currentAttempt < maxAttempts else { throw error }
          currentPrompt = buildCardsCorrectionPrompt(
            validationError: error.localizedDescription,
            requiresSingleCard: generationPlan.requiresSingleCard
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
    observations: [Observation],
    context: ActivityGenerationContext,
    requiresSingleCard: Bool,
    expectedStartTime: String?,
    expectedEndTime: String?,
    allowsSingleShortCard: Bool,
    batchId: Int64?,
    model: String,
    attempt: Int
  ) throws -> [ActivityCardData] {
    let parsedCards = try parseCards(from: run.stdout, stderr: run.stderr)
    guard !parsedCards.isEmpty else { throw ClaudeCardGenerationError.empty }

    let normalizedCards = normalizeCards(parsedCards, descriptors: context.categories)
    let (coverageValid, coverageError) = validateClaudeTimeCoverage(
      existingCards: context.existingCards,
      requiredObservations: observations,
      newCards: normalizedCards
    )
    let (policyValid, policyError) = validateClaudeCardPolicy(
      normalizedCards,
      requiresSingleCard: requiresSingleCard,
      expectedStartTime: expectedStartTime,
      expectedEndTime: expectedEndTime,
      allowsSingleShortCard: allowsSingleShortCard
    )

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
    if !policyValid, let policyError {
      AnalyticsService.shared.captureValidationFailure(
        provider: "chat_cli",
        providerID: providerID,
        operation: "generate_activity_cards",
        validationType: requiresSingleCard ? "fresh_segment" : "duration",
        attempt: attempt,
        model: model,
        batchId: batchId,
        errorDetail: policyError
      )
      validationErrors.append(policyError)
    }

    guard validationErrors.isEmpty else {
      throw ClaudeCardGenerationError.validationFailed(
        validationErrors.joined(separator: "\n\n")
      )
    }

    return normalizedCards
  }

  func makeClaudeCardGenerationPlan(
    observations: [Observation],
    context: ActivityGenerationContext
  ) -> ClaudeCardGenerationPlan {
    let currentObservations = context.batchObservations.sorted { lhs, rhs in
      lhs.startTs < rhs.startTs
    }
    let firstStart = currentObservations.map(\.startTs).min()
    let lastEnd = currentObservations.map(\.endTs).max()
    let connectedCardsAndIntervals: [(card: ActivityCardData, interval: Range<Int>)]
    if context.hasPreviousCardWithinFiveMinutes,
      let firstStart
    {
      let resolvedCards = context.existingCards.compactMap { card in
        (try? ClaudeOutputValidator.resolveActivityCardInterval(
          card,
          nearest: firstStart
        )).map { (card, $0) }
      }.filter { pair in
        pair.1.lowerBound <= firstStart
      }.sorted { lhs, rhs in
        lhs.1.lowerBound < rhs.1.lowerBound
      }

      var boundary = firstStart
      var connected: [(card: ActivityCardData, interval: Range<Int>)] = []
      for candidate in resolvedCards.reversed()
      where candidate.1.upperBound >= boundary - ClaudeTimelineTolerance.sourceConnectionSeconds {
        connected.append(candidate)
        boundary = min(boundary, candidate.1.lowerBound)
      }
      connectedCardsAndIntervals = Array(connected.reversed())
    } else {
      connectedCardsAndIntervals = []
    }

    if !connectedCardsAndIntervals.isEmpty {
      let relevantStart = connectedCardsAndIntervals.map(\.interval.lowerBound).min() ?? firstStart!
      let relevantEnd = max(
        lastEnd ?? relevantStart,
        connectedCardsAndIntervals.map(\.interval.upperBound).max() ?? relevantStart
      )
      let relevantObservations = observations.filter { $0.startTs >= relevantStart }
      let ongoingContext = ActivityGenerationContext(
        batchObservations: currentObservations,
        existingCards: connectedCardsAndIntervals.map(\.card),
        currentTime: context.currentTime,
        categories: context.categories,
        hasPreviousCardWithinFiveMinutes: true
      )
      return ClaudeCardGenerationPlan(
        observations: relevantObservations,
        context: ongoingContext,
        requiresSingleCard: false,
        allowsSingleShortCard: false,
        expectedStartTime: formatTimestampForPrompt(relevantStart),
        expectedEndTime: formatTimestampForPrompt(relevantEnd)
      )
    }

    let allowsSingleShortCard: Bool
    if let firstStart, let lastEnd {
      allowsSingleShortCard = lastEnd - firstStart < 10 * 60
    } else {
      allowsSingleShortCard = false
    }
    let freshContext = ActivityGenerationContext(
      batchObservations: currentObservations,
      existingCards: [],
      currentTime: context.currentTime,
      categories: context.categories,
      hasPreviousCardWithinFiveMinutes: false
    )

    return ClaudeCardGenerationPlan(
      observations: currentObservations,
      context: freshContext,
      requiresSingleCard: true,
      allowsSingleShortCard: allowsSingleShortCard,
      expectedStartTime: firstStart.map { formatTimestampForPrompt($0) },
      expectedEndTime: lastEnd.map { formatTimestampForPrompt($0) }
    )
  }

  func validateClaudeCardPolicy(
    _ cards: [ActivityCardData],
    requiresSingleCard: Bool,
    expectedStartTime: String?,
    expectedEndTime: String?,
    allowsSingleShortCard: Bool
  ) -> (isValid: Bool, error: String?) {
    var issues: [String] = []

    if requiresSingleCard, let expectedStartTime, let expectedEndTime {
      if cards.count != 1 {
        issues.append(
          "Fresh segment must contain exactly one card; received \(cards.count)."
        )
      } else if let card = cards.first {
        if timeToMinutes(card.startTime) != timeToMinutes(expectedStartTime)
          || timeToMinutes(card.endTime) != timeToMinutes(expectedEndTime)
        {
          issues.append(
            "Fresh segment card must cover \(expectedStartTime) - \(expectedEndTime)."
          )
        }
      }
    } else if !requiresSingleCard {
      if let expectedStartTime, let firstCard = cards.first,
        timeToMinutes(firstCard.startTime) != timeToMinutes(expectedStartTime)
      {
        issues.append(
          "Cards must begin at the connected rewrite boundary, \(expectedStartTime)."
        )
      }
      if let expectedEndTime, let lastCard = cards.last,
        timeToMinutes(lastCard.endTime) != timeToMinutes(expectedEndTime)
      {
        issues.append(
          "Cards must cover new observations through \(expectedEndTime)."
        )
      }
    }

    var previousStartMinutes: Double?
    var previousEndMinutes: Double?
    for (index, card) in cards.enumerated() {
      var startMinutes = timeToMinutes(card.startTime)
      if let previousStartMinutes,
        startMinutes < previousStartMinutes,
        previousStartMinutes - startMinutes > 12 * 60
      {
        startMinutes += 24 * 60
      }
      var endMinutes = timeToMinutes(card.endTime)
      if endMinutes < startMinutes { endMinutes += 24 * 60 }
      let duration = endMinutes - startMinutes
      let isAllowedShortSpan = allowsSingleShortCard && cards.count == 1

      if let previousEndMinutes, startMinutes < previousEndMinutes {
        issues.append(
          "Card \(index + 1) overlaps the preceding card; card boundaries must not overlap."
        )
      }

      if duration < 10, !isAllowedShortSpan {
        issues.append(
          String(
            format:
              "Card %d '%@' is only %.1f minutes long; every card, including the final card, must be at least 10 minutes.",
            index + 1,
            card.title,
            duration
          )
        )
      } else if duration > 60 {
        issues.append(
          String(
            format: "Card %d '%@' is %.1f minutes long; cards may not exceed 60 minutes.",
            index + 1,
            card.title,
            duration
          )
        )
      }

      previousStartMinutes = startMinutes
      previousEndMinutes = endMinutes
    }

    return issues.isEmpty ? (true, nil) : (false, issues.joined(separator: "\n"))
  }

  func validateClaudeTimeCoverage(
    existingCards: [ActivityCardData],
    requiredObservations: [Observation] = [],
    newCards: [ActivityCardData]
  ) -> (isValid: Bool, error: String?) {
    do {
      try ClaudeOutputValidator.validateActivityCards(
        newCards,
        existingCards: existingCards,
        observations: requiredObservations
      )
      return (true, nil)
    } catch {
      return (false, error.localizedDescription)
    }
  }

}
