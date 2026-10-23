import AppKit
import Foundation

extension ClaudeProvider {
  // MARK: - Claude one-step timeline

  static func timelineModelConfiguration() -> (model: String, reasoningEffort: String?) {
    (model: "haiku", reasoningEffort: "medium")
  }

  private static var timelineFrameMaxHeight: Int { 1080 }
  private static var timelineMaxAttempts: Int { 3 }

  /// One call that reads the batch's screenshots as separate images and writes the timeline
  /// cards, with no transcript in between. Observations are rebuilt from the cards' detail
  /// lines so recaps and chat keep their per-batch record.
  func generateTimeline(
    screenshots: [Screenshot], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (
    cards: [ActivityCardData], observations: [Observation], rewriteSpan: Range<Int>?, log: LLMCall
  ) {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "ClaudeProvider", code: -96,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to generate a timeline from"])
    }

    let callStart = Date()
    let modelConfiguration = Self.timelineModelConfiguration()
    let model = modelConfiguration.model
    let effort = modelConfiguration.reasoningEffort
    var run: ChatCLIRunResult?
    var accumulatedUsage: TokenUsage?
    var attempt = 1

    do {
      let frames = try await OneStepTimelineFrames.write(
        screenshots, maxHeight: Self.timelineFrameMaxHeight,
        directoryPrefix: "Dayflow-claude-timeline")
      defer { frames.cleanup() }

      // The window stands in for the observations the two-step path would have, so the same
      // rules decide which previous cards connect to this batch and what the cards must cover.
      let window = Observation(
        id: nil,
        batchId: batchId ?? -1,
        startTs: frames.windowStart,
        endTs: frames.windowEnd,
        observation: "",
        metadata: nil,
        llmModel: model,
        createdAt: Date()
      )
      let plan = makeClaudeCardGenerationPlan(
        observations: [window],
        context: ActivityGenerationContext(
          batchObservations: [window],
          existingCards: context.existingCards,
          currentTime: context.currentTime,
          categories: context.categories,
          hasPreviousCardWithinFiveMinutes: context.hasPreviousCardWithinFiveMinutes
        )
      )
      let previousCards = plan.context.existingCards
      let prompt = buildTimelinePrompt(
        frames: frames,
        previousCards: previousCards,
        categories: context.categories
      )

      let inlineImages = timelineInlineImages(frames: frames)
      let profile = ClaudeCLIExecutionProfile.oneStepTimeline
      let sessionID = UUID().uuidString
      let sessionCleanup = ClaudeSessionCleanup(sessionID: sessionID)
      defer { sessionCleanup.cleanup() }
      var currentPrompt = prompt

      for currentAttempt in 1...Self.timelineMaxAttempts {
        attempt = currentAttempt
        let sessionMode: ClaudeCLISessionMode =
          currentAttempt == 1 ? .start(id: sessionID) : .resume(id: sessionID)
        // The frames go in the first message only; a correction turn resumes the session,
        // which already holds them.
        let currentRun = try await runOptimizedClaudeTurn(
          prompt: currentPrompt,
          model: model,
          reasoningEffort: effort,
          profile: profile,
          sessionMode: sessionMode,
          inlineImages: currentAttempt == 1 ? inlineImages : []
        )
        run = currentRun
        accumulatedUsage = Self.combinedTokenUsage(accumulatedUsage, currentRun.usage)
        try validateSuccessfulClaudeProcess(currentRun)

        let cards: [ActivityCardData]
        do {
          cards = try validatedTimelineCards(
            from: currentRun,
            previousCards: previousCards,
            window: window,
            categories: context.categories,
            batchId: batchId,
            model: model,
            attempt: attempt
          )
        } catch {
          guard currentAttempt < Self.timelineMaxAttempts else { throw error }
          currentPrompt = buildTimelineCorrectionPrompt(
            validationError: error.localizedDescription,
            windowStart: formatTimestampForPrompt(frames.windowStart),
            windowEnd: formatTimestampForPrompt(frames.windowEnd)
          )
          print("[ClaudeProvider] Timeline output failed validation; continuing the same session")
          continue
        }

        let observations = OneStepTimelineObservations.make(
          from: cards,
          windowStart: frames.windowStart,
          windowEnd: frames.windowEnd,
          batchId: batchId,
          model: model
        )
        logSuccess(
          ctx: makeCtx(
            batchId: batchId,
            operation: "generate_timeline",
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
        return (cards, observations, plan.rewriteSpan, llmCall)
      }

      throw NSError(
        domain: "ClaudeProvider", code: -95,
        userInfo: [NSLocalizedDescriptionKey: "No timeline cards returned."])
    } catch {
      let nsError = error as NSError
      logFailure(
        ctx: makeCtx(
          batchId: batchId,
          operation: "generate_timeline",
          model: model,
          startedAt: callStart,
          attempt: attempt
        ),
        finishedAt: run?.finishedAt ?? Date(),
        error: error,
        stdout: run?.stdout ?? nsError.userInfo["partialStdout"] as? String,
        stderr: run?.stderr ?? nsError.userInfo["partialStderr"] as? String,
        run: run,
        usage: accumulatedUsage
      )
      throw error
    }
  }

  // MARK: Prompt

  private func buildTimelinePrompt(
    frames: OneStepTimelineFrames,
    previousCards: [ActivityCardData],
    categories: [LLMCategoryDescriptor]
  ) -> String {
    let userName = NSFullUserName()
      .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let perMinute = frames.isOneFramePerMinute

    var prompt = ClaudeTimelinePrompt.template
      .replacingOccurrences(
        of: ClaudeTimelinePrompt.categoriesPlaceholder, with: categoriesSection(from: categories)
      )
      .replacingOccurrences(
        of: ClaudeTimelinePrompt.languagePlaceholder,
        with: LLMOutputLanguagePreferences.languageInstruction(forJSON: true) ?? ""
      )
    if userName.isEmpty {
      prompt = prompt.replacingOccurrences(
        of: ClaudeTimelinePrompt.nameGiven, with: ClaudeTimelinePrompt.nameMissing)
    }
    if !perMinute {
      prompt = prompt.replacingOccurrences(
        of: ClaudeTimelinePrompt.perMinuteFrames, with: ClaudeTimelinePrompt.irregularFrames)
    }

    let previousCardsData = try? JSONEncoder().encode(previousCards)
    let previousCardsJSON = previousCardsData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

    // Explicit concatenation keeps screen-derived text in previous cards from being interpolated.
    var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nINPUTS:\n"
    if !userName.isEmpty {
      text += "User: " + userName + "\n"
    }
    text += "Previous cards: " + previousCardsJSON + "\n"
    text +=
      "New screenshots: " + String(frames.frames.count) + " frames, covering "
      + formatTimestampForPrompt(frames.windowStart) + " to "
      + formatTimestampForPrompt(frames.windowEnd)
      + ". Each is attached below, labeled with its time.\n\n"
    text += "Do not narrate or summarize individual frames before the answer.\n\n"
    text += ClaudeTimelinePrompt.outputBlock
    return text
  }

  /// Each frame labeled with its capture time, to send inside the first message.
  private func timelineInlineImages(frames: OneStepTimelineFrames) -> [ClaudeInlineImage] {
    let labelFormatter = DateFormatter()
    labelFormatter.dateFormat = frames.isOneFramePerMinute ? "h:mm a" : "h:mm:ss a"
    labelFormatter.locale = Locale(identifier: "en_US_POSIX")
    labelFormatter.timeZone = TimeZone.current
    return frames.frames.map { frame in
      let label = labelFormatter.string(
        from: Date(timeIntervalSince1970: TimeInterval(frame.capturedAt)))
      return ClaudeInlineImage(label: "Frame at " + label, path: frame.url.path)
    }
  }

  private func buildTimelineCorrectionPrompt(
    validationError: String, windowStart: String, windowEnd: String
  ) -> String {
    """
    The previous JSON output has validation errors. Fix it using the screenshots and context already in this conversation.

    Issues:
    \(validationError)

    Requirements:
    - Return the FULL corrected JSON array, not a diff.
    - The cards together must cover the previous cards' time and the new window, \(windowStart) to \(windowEnd), with no gaps and no overlaps, and must not extend past \(windowEnd).
    - Every card except the last must be 10 to 60 minutes long. Fold a shorter stretch into the neighbouring card and keep its detail lines.
    - Keep the detailedSummary lines that were correct; only change what the issues require.
    - Do not use tools. Output JSON only, with no code fences or extra text.
    """
  }

  // MARK: Validation

  private func validatedTimelineCards(
    from run: ChatCLIRunResult,
    previousCards: [ActivityCardData],
    window: Observation,
    categories: [LLMCategoryDescriptor],
    batchId: Int64?,
    model: String,
    attempt: Int
  ) throws -> [ActivityCardData] {
    let parsedCards = try parseCards(from: run.stdout, stderr: run.stderr)
    let normalizedCards = normalizeCards(parsedCards, descriptors: categories)
    let (isValid, validationError) = validateClaudeTimeCoverage(
      existingCards: previousCards,
      requiredObservations: [window],
      newCards: normalizedCards
    )
    guard isValid else {
      let detail = validationError ?? "Timeline cards failed validation."
      AnalyticsService.shared.captureValidationFailure(
        provider: "chat_cli",
        providerID: providerID,
        operation: "generate_timeline",
        validationType: "time_coverage",
        attempt: attempt,
        model: model,
        batchId: batchId,
        errorDetail: detail
      )
      throw NSError(
        domain: "ClaudeProvider", code: -93,
        userInfo: [NSLocalizedDescriptionKey: detail])
    }
    return normalizedCards
  }
}
