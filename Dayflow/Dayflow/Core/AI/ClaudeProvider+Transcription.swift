import Foundation

extension ClaudeProvider {
  // MARK: - Claude screenshot transcription

  static func transcriptionModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    (model: "claude-sonnet", reasoningEffort: "low")
  }

  func transcribeScreenshots(
    _ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?
  ) async throws -> (observations: [Observation], log: LLMCall) {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "ClaudeProvider", code: -96,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
    }

    let callStart = Date()
    let modelConfiguration = resolvedTranscriptionModelConfiguration()
    let model = modelConfiguration.model
    let effort = modelConfiguration.reasoningEffort
    let preparedInput: ClaudePreparedTranscriptionInput

    do {
      preparedInput = try await ClaudeTranscriptionInputBuilder().prepare(
        screenshots: screenshots
      )
    } catch {
      logFailure(
        ctx: makeCtx(
          batchId: batchId,
          operation: "transcribe_screenshots",
          model: model,
          startedAt: callStart
        ),
        finishedAt: Date(),
        error: error
      )
      throw error
    }
    defer { preparedInput.cleanup() }

    let durationSeconds = max(1, Int(preparedInput.durationSeconds.rounded()))
    let durationString = formatSeconds(TimeInterval(durationSeconds))
    let basePrompt = buildScreenshotTranscriptionPrompt(
      numFrames: preparedInput.selectedScreenshots.count,
      duration: durationString,
      startTime: "00:00:00",
      endTime: durationString
    )
    let prompt = optimizedTranscriptionPrompt(
      basePrompt: basePrompt,
      preparedInput: preparedInput
    )

    var run: ChatCLIRunResult?
    var accumulatedUsage: TokenUsage?
    var attempt = 1
    var currentPrompt = prompt
    do {
      let sessionID = UUID().uuidString
      let sessionCleanup = ClaudeSessionCleanup(sessionID: sessionID)
      defer { sessionCleanup.cleanup() }
      let maxAttempts = 3

      for currentAttempt in 1...maxAttempts {
        attempt = currentAttempt
        let profile =
          (currentAttempt == 1
          ? Self.optimizedTranscriptionCLIProfile()
          : Self.optimizedTranscriptionCorrectionCLIProfile())
          .allowingRead(at: preparedInput.contactSheetURL.path)
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

        do {
          let segments = try validatedClaudeSegments(
            from: currentRun,
            durationSeconds: durationSeconds,
            batchId: batchId,
            model: model,
            attempt: attempt
          )
          let observations = observations(
            from: segments,
            durationSeconds: durationSeconds,
            batchStartTime: batchStartTime,
            batchId: batchId,
            model: model
          )
          guard !observations.isEmpty else {
            throw NSError(
              domain: "ClaudeProvider",
              code: -99,
              userInfo: [
                NSLocalizedDescriptionKey: "No observations could be created from segments."
              ]
            )
          }

          logSuccess(
            ctx: makeCtx(
              batchId: batchId,
              operation: "transcribe_screenshots",
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
          return (observations, llmCall)
        } catch {
          guard currentAttempt < maxAttempts else { throw error }
          currentPrompt = buildTranscriptionCorrectionPrompt(
            validationError: error.localizedDescription,
            duration: durationString
          )
          print(
            "[ClaudeProvider] Transcription output failed validation; continuing the same session"
          )
        }
      }

      throw NSError(
        domain: "ClaudeProvider",
        code: -99,
        userInfo: [NSLocalizedDescriptionKey: "No observations could be created from segments."]
      )
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
          operation: "transcribe_screenshots",
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

  private func validatedClaudeSegments(
    from run: ChatCLIRunResult,
    durationSeconds: Int,
    batchId: Int64?,
    model: String,
    attempt: Int
  ) throws -> [SegmentMergeResponse.Segment] {
    let segments = try parseSegments(from: run.stdout, stderr: run.stderr)
    if let validationError = validateSegments(segments, duration: TimeInterval(durationSeconds)) {
      AnalyticsService.shared.captureValidationFailure(
        provider: "chat_cli",
        providerID: providerID,
        operation: "transcribe_screenshots",
        validationType: "timeline",
        attempt: attempt,
        model: model,
        batchId: batchId,
        errorDetail: validationError
      )
      throw NSError(
        domain: "ClaudeProvider",
        code: -98,
        userInfo: [NSLocalizedDescriptionKey: validationError]
      )
    }
    return segments
  }

  private func optimizedTranscriptionPrompt(
    basePrompt: String,
    preparedInput: ClaudePreparedTranscriptionInput
  ) -> String {
    basePrompt
      + """


      The one attached image is a labeled 5-column by 3-row contact sheet containing all screenshots. Tiles are chronological in row-major order and map to the timestamps in the metadata below. Treat each numbered tile as a distinct screenshot. Small text in the contact sheet may be unreadable.
      Apple Vision OCR/app hints for the matching tiles follow. They are fallible side-channel evidence: pixels decide the foreground and OCR may add exact text only when consistent with the pixels.
      Metadata: \(preparedInput.metadataJSON)
      Images:
      - \(preparedInput.contactSheetURL.path)

      Tool requirement: use Read exactly once on every supplied file before answering; skipping or rereading a file is an error. After the final Read, reason briefly without narrating, then immediately produce the timeline. Do not emit scratch notes or summarize individual frames before the answer. Then send exactly one bare JSON object. The first character of the assistant response must be { and the last must be }; do not use a preamble or Markdown fence.
      """
  }

  private func observations(
    from segments: [SegmentMergeResponse.Segment],
    durationSeconds: Int,
    batchStartTime: Date,
    batchId: Int64?,
    model: String
  ) -> [Observation] {
    let ordered = segments.sorted {
      parseVideoTimestamp($0.start) < parseVideoTimestamp($1.start)
    }
    return ordered.compactMap { segment in
      let startSeconds = TimeInterval(parseVideoTimestamp(segment.start))
      let endSeconds = TimeInterval(parseVideoTimestamp(segment.end))
      let clampedStart = max(0, startSeconds)
      let clampedEnd = min(endSeconds, TimeInterval(durationSeconds))
      guard clampedEnd > clampedStart else { return nil }

      let description = segment.description.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !description.isEmpty else { return nil }

      let startEpoch = Int(
        batchStartTime.addingTimeInterval(clampedStart).timeIntervalSince1970
      )
      let endEpoch = max(
        startEpoch + 1,
        Int(batchStartTime.addingTimeInterval(clampedEnd).timeIntervalSince1970)
      )
      return Observation(
        id: nil,
        batchId: batchId ?? -1,
        startTs: startEpoch,
        endTs: endEpoch,
        observation: description,
        metadata: nil,
        llmModel: model,
        createdAt: Date()
      )
    }
  }
}
