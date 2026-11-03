import AppKit
import Foundation

extension CodexProvider {
  // MARK: - Codex one-step timeline

  static func timelineModelConfiguration() -> (model: String, reasoningEffort: String?) {
    (model: "gpt-6-luna", reasoningEffort: "high")
  }

  private static var timelineFrameMaxHeight: Int { 1080 }
  private static var timelineMaxAttempts: Int { 3 }

  /// One call that takes the batch's screenshots as attached images and writes the timeline
  /// cards, with no transcript in between. Observations are rebuilt from the cards' detail
  /// lines so recaps and chat keep their per-batch record.
  func generateTimeline(
    screenshots: [Screenshot], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (
    cards: [ActivityCardData], observations: [Observation], rewriteSpan: Range<Int>?, log: LLMCall
  ) {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "ChatCLI", code: -96,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to generate a timeline from"])
    }

    let callStart = Date()
    let modelConfiguration = Self.timelineModelConfiguration()
    var model = modelConfiguration.model
    let effort = modelConfiguration.reasoningEffort
    var lastRun: ChatCLIRunResult?
    var attempt = 1

    do {
      let frames = try await OneStepTimelineFrames.write(
        screenshots, maxHeight: Self.timelineFrameMaxHeight,
        directoryPrefix: "Dayflow-codex-timeline")
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
      let accessibilityLog = await OneStepTimelineAccessibilityLog.load(
        windowStart: frames.windowStart, windowEnd: frames.windowEnd, batchId: batchId)
      let basePrompt = buildTimelinePrompt(
        frames: frames, previousCards: previousCards, categories: context.categories,
        accessibilityLog: accessibilityLog)
      let imagePaths = frames.frames.map(\.url.path)
      var currentPrompt = basePrompt
      var lastError: Error?

      for currentAttempt in 1...Self.timelineMaxAttempts {
        attempt = currentAttempt
        do {
          let run = try await runTimelineTurn(
            prompt: currentPrompt, imagePaths: imagePaths, model: model, reasoningEffort: effort)
          lastRun = run
          guard run.exitCode == 0 else {
            throw NSError(
              domain: "ChatCLI", code: Int(run.exitCode),
              userInfo: [
                NSLocalizedDescriptionKey: run.failureMessage(toolName: "codex"),
                "partialStderr": run.stderr,
              ])
          }

          let cards = normalizeCards(
            try parseCards(from: run.stdout, stderr: run.stderr), descriptors: context.categories)
          do {
            try ClaudeOutputValidator.validateActivityCards(
              cards, existingCards: previousCards, observations: [window])
          } catch {
            let detail = error.localizedDescription
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
            lastError = NSError(
              domain: "ChatCLI", code: -93, userInfo: [NSLocalizedDescriptionKey: detail])
            // Each run is a fresh session with the images attached again, so the correction
            // rides on the original prompt.
            currentPrompt =
              basePrompt + "\n\nPREVIOUS ATTEMPT FAILED - FIX THE FOLLOWING:\n" + detail
              + "\n\nThe cards together must cover the previous cards' time and the new window, "
              + formatTimestampForPrompt(frames.windowStart) + " to "
              + formatTimestampForPrompt(frames.windowEnd)
              + ", with no gaps and no overlaps. Every card except the last must be 10 to 60 "
              + "minutes long. Return JSON only."
            print("[ChatCLI] generate_timeline validation failed (attempt \(attempt)): \(detail)")
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
              batchId: batchId, operation: "generate_timeline", model: model,
              startedAt: callStart, attempt: attempt),
            finishedAt: run.finishedAt, stdout: run.stdout, stderr: run.stderr,
            responseHeaders: tokenHeaders(from: run.usage))
          let llmCall = makeLLMCall(
            start: callStart, end: run.finishedAt, input: currentPrompt, output: run.stdout)
          return (cards, observations, plan.rewriteSpan, llmCall)
        } catch {
          if error is CancellationError { throw error }
          if currentAttempt < Self.timelineMaxAttempts,
            let fallback = Self.availabilityFallback(
              for: model, error: error, stderr: lastRun?.stderr)
          {
            Self.recordModelFallback(from: model, to: fallback, operation: "generate_timeline")
            model = fallback
          }
          lastError = error
          currentPrompt = basePrompt
          print(
            "[ChatCLI] generate_timeline attempt \(currentAttempt) failed: "
              + error.localizedDescription)
        }
      }

      throw lastError
        ?? NSError(
          domain: "ChatCLI", code: -95,
          userInfo: [NSLocalizedDescriptionKey: "No timeline cards returned."])
    } catch {
      // Keep CLI output out of the failure log as defense in depth because it was generated
      // from the user's screenshots.
      logFailure(
        ctx: makeCtx(
          batchId: batchId, operation: "generate_timeline", model: model,
          startedAt: callStart, attempt: attempt),
        finishedAt: lastRun?.finishedAt ?? Date(), error: error)
      throw error
    }
  }

  private func runTimelineTurn(
    prompt: String, imagePaths: [String], model: String, reasoningEffort: String?
  ) async throws -> ChatCLIRunResult {
    let runner = runner
    let workingDirectory = config.workingDirectory
    // The frames go to the CLI as written; the shared image preparation would shrink them to
    // 720 pixels, which loses small on-screen text.
    return try await Task.detached(priority: .utility) {
      try runner.run(
        tool: .codex,
        prompt: prompt,
        workingDirectory: workingDirectory,
        imagePaths: imagePaths,
        model: model,
        reasoningEffort: reasoningEffort
      )
    }.value
  }

  // MARK: Prompt

  private func buildTimelinePrompt(
    frames: OneStepTimelineFrames,
    previousCards: [ActivityCardData],
    categories: [LLMCategoryDescriptor],
    accessibilityLog: String?
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

    let labelFormatter = DateFormatter()
    labelFormatter.dateFormat = perMinute ? "h:mm a" : "h:mm:ss a"
    labelFormatter.locale = Locale(identifier: "en_US_POSIX")
    labelFormatter.timeZone = TimeZone.current
    // The CLI attaches images ahead of the text, so each label names its image by position.
    let frameLines = frames.frames.enumerated().map { index, frame in
      let label = labelFormatter.string(
        from: Date(timeIntervalSince1970: TimeInterval(frame.capturedAt)))
      return "Image " + String(index + 1) + ": frame at " + label
    }.joined(separator: "\n")

    // Explicit concatenation keeps screen-derived text in previous cards from being interpolated.
    var text =
      CodexTimelinePrompt.system + "\n\n"
      + prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
      + CodexTimelinePrompt.additionalRules + "\n\nINPUTS:\n"
    if !userName.isEmpty {
      text += "User: " + userName + "\n"
    }
    text += "Previous cards: " + previousCardsJSON + "\n"
    text +=
      "New screenshots: " + String(frames.frames.count)
      + " frames are attached to this message as images, in order, covering "
      + formatTimestampForPrompt(frames.windowStart) + " to "
      + formatTimestampForPrompt(frames.windowEnd) + ":\n"
    text += frameLines + "\n\n"
    text += "Do not run commands or use tools; everything you need is in this message.\n\n"
    text += CodexTimelinePrompt.outputBlock
    if let accessibilityLog {
      text += ClaudeTimelinePrompt.accessibilityLogSection(accessibilityLog)
    }
    return text
  }
}
