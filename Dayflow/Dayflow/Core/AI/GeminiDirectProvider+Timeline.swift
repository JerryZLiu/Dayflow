import Foundation

extension GeminiDirectProvider {
  // MARK: - Gemini one-step timeline

  /// Medium thinking scored as well as high on chained batches at about half the latency, and
  /// clearly better than low.
  private static var timelineThinkingLevel: String { "medium" }
  private static var timelineMaxAttempts: Int { 3 }

  /// Whether this provider writes cards straight from the batch video. Only the selected model
  /// counts: older Flash models keep the transcribe-then-generate path. While the selected
  /// model is out of quota the two-step path runs instead, on the next model that is not.
  var supportsOneStepTimeline: Bool {
    // `modelsToTry` leaves out models that are out of quota, unless every one of them is.
    modelPreference.primary.supportsOneStepTimeline
      && modelsToTry.first == modelPreference.primary
  }

  /// One call that reads the batch's 1 fps video and writes the timeline cards, with no
  /// transcript in between. It uses the same one-step prompt as Claude and ChatGPT, with its
  /// rules sent as the system instruction. Observations are rebuilt from the cards' detail lines
  /// so recaps and chat keep their per-batch record.
  ///
  /// Request failures are thrown straight away: LLMService then runs the two-step path, which
  /// has its own retries and falls back through the older models.
  func generateTimeline(
    screenshots: [Screenshot], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (
    cards: [ActivityCardData], observations: [Observation], rewriteSpan: Range<Int>?, log: LLMCall
  ) {
    let model = modelPreference.primary
    guard model.supportsOneStepTimeline else {
      throw NSError(
        domain: "GeminiDirectProvider", code: 20,
        userInfo: [
          NSLocalizedDescriptionKey: "\(model.rawValue) does not write cards in one step."
        ])
    }

    let callStart = Date()
    let video = try await makeCompressedBatchVideo(screenshots, batchId: batchId)

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("gemini_timeline_\(batchId ?? 0)_\(UUID().uuidString).mp4")
    try video.data.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    let fileURI = try await uploadAndAwait(tempURL, mimeType: "video/mp4", key: apiKey).fileURI

    // The new window: the first frame's minute to one minute after the last frame's minute.
    let windowStart = video.firstCapturedAt - video.firstCapturedAt % 60
    let windowEnd = video.lastCapturedAt - video.lastCapturedAt % 60 + 60

    let accessibilityLog = await OneStepTimelineAccessibilityLog.load(
      windowStart: windowStart, windowEnd: windowEnd, batchId: batchId)
    let rules = timelineRules(categories: context.categories)
    let inputs = timelineInputs(
      video: video,
      previousCards: context.existingCards,
      windowStart: windowStart,
      windowEnd: windowEnd,
      accessibilityLog: accessibilityLog
    )

    // The window stands in for the observations the two-step path would have, so the shared
    // one-step validator checks the cards against real timestamps (midnight included): they
    // must cover every previous card and the new window, without overlaps or short middle cards.
    let window = Observation(
      id: nil,
      batchId: batchId ?? -1,
      startTs: windowStart,
      endTs: windowEnd,
      observation: "",
      metadata: nil,
      llmModel: model.rawValue,
      createdAt: Date()
    )

    let groupId = UUID().uuidString
    var prompt = inputs
    var lastError: Error?

    for attempt in 1...Self.timelineMaxAttempts {
      let response: String
      do {
        response = try await geminiCardsRequest(
          prompt: prompt,
          batchId: batchId,
          groupId: groupId,
          model: model,
          attempt: attempt,
          video: GeminiVideoInput(fileURI: fileURI, mimeType: "video/mp4"),
          systemInstruction: rules,
          thinkingLevel: Self.timelineThinkingLevel,
          operation: "generate_timeline"
        )
      } catch {
        // A response with no usable content is worth another try; anything else goes to the
        // two-step path.
        let nsError = error as NSError
        guard nsError.domain == "GeminiError", nsError.code == 9 else { throw error }
        lastError = error
        prompt = inputs
        continue
      }

      let cards: [ActivityCardData]
      do {
        // An outer boundary a minute or two off the window is moved onto it, not sent back.
        cards = ClaudeOutputValidator.snappingOuterEdges(
          normalizeCards(try parseActivityCards(response), descriptors: context.categories),
          existingCards: context.existingCards, observations: [window])
      } catch {
        print("⚠️ [Gemini] One-step timeline returned unreadable cards on attempt \(attempt)")
        lastError = error
        prompt = inputs
        continue
      }

      do {
        try ClaudeOutputValidator.validateActivityCards(
          cards, existingCards: context.existingCards, observations: [window])
      } catch {
        let detail = error.localizedDescription
        print("⚠️ [Gemini] One-step timeline failed coverage on attempt \(attempt)")
        AnalyticsService.shared.captureValidationFailure(
          provider: "gemini",
          providerID: .gemini,
          operation: "generate_timeline",
          validationType: "time_coverage",
          attempt: attempt,
          model: model.rawValue,
          batchId: batchId,
          errorDetail: detail
        )
        lastError = NSError(
          domain: "GeminiDirectProvider", code: 21,
          userInfo: [NSLocalizedDescriptionKey: detail])
        prompt =
          inputs
          + timelineCorrection(
            validationError: detail,
            windowStart: formatTimestampForPrompt(windowStart),
            windowEnd: formatTimestampForPrompt(windowEnd)
          )
        continue
      }

      let observations = OneStepTimelineObservations.make(
        from: cards,
        windowStart: windowStart,
        windowEnd: windowEnd,
        batchId: batchId,
        model: model.rawValue
      )
      let log = LLMCall(
        timestamp: callStart,
        latency: Date().timeIntervalSince(callStart),
        input: rules + "\n\n" + prompt,
        output: response
      )
      // The prompt held every card in the lookback window, so the output replaces all of them.
      return (cards, observations, nil, log)
    }

    throw lastError
      ?? NSError(
        domain: "GeminiDirectProvider", code: 22,
        userInfo: [NSLocalizedDescriptionKey: "No timeline cards returned."])
  }

  // MARK: Prompt

  /// The one-step rules, sent as the system instruction. The frame-timing line describes
  /// irregular frames because the video holds a screenshot every few seconds, not one a minute.
  private func timelineRules(categories: [LLMCategoryDescriptor]) -> String {
    var rules = ClaudeTimelinePrompt.template
      .replacingOccurrences(
        of: ClaudeTimelinePrompt.categoriesPlaceholder, with: categoriesSection(from: categories)
      )
      .replacingOccurrences(
        of: ClaudeTimelinePrompt.languagePlaceholder,
        with: LLMOutputLanguagePreferences.languageInstruction(forJSON: true) ?? ""
      )
      .replacingOccurrences(
        of: ClaudeTimelinePrompt.perMinuteFrames, with: ClaudeTimelinePrompt.irregularFrames)
    if timelineUserName.isEmpty {
      rules = rules.replacingOccurrences(
        of: ClaudeTimelinePrompt.nameGiven, with: ClaudeTimelinePrompt.nameMissing)
    }
    return rules.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The user turn: name, previous cards, how video seconds map to clock time, and the output
  /// format, plus the accessibility log when there is one.
  private func timelineInputs(
    video: CompressedBatchVideo,
    previousCards: [ActivityCardData],
    windowStart: Int,
    windowEnd: Int,
    accessibilityLog: String?
  ) -> String {
    let previousCardsData = try? JSONEncoder().encode(previousCards)
    let previousCardsJSON = previousCardsData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    let secondsApart = max(1, Int(video.compressionFactor.rounded()))
    let videoSecondsPerMinute = max(1, Int((60 / video.compressionFactor).rounded()))

    // Explicit concatenation keeps screen-derived text in previous cards from being interpolated.
    var text = "INPUTS:\n"
    if !timelineUserName.isEmpty {
      text += "User: " + timelineUserName + "\n"
    }
    text += "Previous cards: " + previousCardsJSON + "\n"
    text +=
      "New screenshots: a video of " + String(video.frameCount) + " screenshots covering "
      + formatTimestampForPrompt(windowStart) + " to " + formatTimestampForPrompt(windowEnd)
      + ". Each second of the video is one screenshot, taken " + String(secondsApart)
      + " seconds apart: video second 0 is " + clockTimeWithSeconds(video.firstCapturedAt)
      + ", video second " + String(videoSecondsPerMinute)
      + " is one minute later, and so on.\n\n"
    text += "Do not narrate or summarize individual frames before the answer.\n\n"
    text += ClaudeTimelinePrompt.outputBlock
    if let accessibilityLog {
      text += ClaudeTimelinePrompt.accessibilityLogSection(accessibilityLog)
    }
    return text
  }

  private func timelineCorrection(
    validationError: String, windowStart: String, windowEnd: String
  ) -> String {
    """


    PREVIOUS ATTEMPT FAILED VALIDATION:
    \(validationError)

    Return the FULL corrected JSON array. The cards together must cover the previous cards' time and the new window, \(windowStart) to \(windowEnd), with no gaps and no overlaps, and must not extend past \(windowEnd). Never return only the previous cards. Every card except the last must be 10 to 60 minutes long; fold a shorter stretch into the neighbouring card and keep its detail lines.
    """
  }

  private var timelineUserName: String {
    NSFullUserName().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  private func clockTimeWithSeconds(_ unixTime: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm:ss a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixTime)))
  }
}
