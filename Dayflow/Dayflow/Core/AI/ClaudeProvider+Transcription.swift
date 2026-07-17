import Foundation

extension ClaudeProvider {
  // MARK: - Claude screenshot transcription

  static func transcriptionModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    (model: "claude-sonnet-5", reasoningEffort: "low")
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
    let modelConfiguration = Self.transcriptionModelConfiguration()
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
    do {
      let profile = Self.optimizedTranscriptionCLIProfile().allowingRead(
        at: preparedInput.contactSheetURL.path
      )
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

      let segments: [SegmentMergeResponse.Segment]
      let finalRun: ChatCLIRunResult
      let totalUsage: TokenUsage?
      do {
        segments = try validatedClaudeSegments(
          from: initialRun,
          durationSeconds: durationSeconds
        )
        finalRun = initialRun
        totalUsage = accumulatedUsage
      } catch {
        attempt = 2
        let correctionPrompt = buildTranscriptionCorrectionPrompt(
          validationError: error.localizedDescription,
          duration: durationString
        )
        print(
          "[ClaudeProvider] Transcription output failed strict validation; continuing the same session once"
        )
        let correctionRun = try await runOptimizedClaudeTurn(
          prompt: correctionPrompt,
          model: model,
          reasoningEffort: effort,
          profile: Self.optimizedTranscriptionCorrectionCLIProfile().allowingRead(
            at: preparedInput.contactSheetURL.path
          ),
          sessionMode: .resume(id: sessionID)
        )
        run = correctionRun
        accumulatedUsage = Self.combinedTokenUsage(accumulatedUsage, correctionRun.usage)
        try validateSuccessfulClaudeProcess(correctionRun)
        segments = try validatedClaudeSegments(
          from: correctionRun,
          durationSeconds: durationSeconds
        )
        finalRun = correctionRun
        totalUsage = accumulatedUsage
      }

      let observations = observations(
        from: segments,
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
      return (observations, llmCall)
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
    durationSeconds: Int
  ) throws -> [SegmentMergeResponse.Segment] {
    let segments = try parseClaudeSegmentsStrict(from: run.stdout, stderr: run.stderr)
    if let validationError = ClaudeOutputValidator.validateExactSegments(
      segments,
      duration: TimeInterval(durationSeconds)
    ) {
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
    batchStartTime: Date,
    batchId: Int64?,
    model: String
  ) -> [Observation] {
    segments.map { segment in
      let startSeconds = TimeInterval(parseVideoTimestamp(segment.start))
      let endSeconds = TimeInterval(parseVideoTimestamp(segment.end))
      let startEpoch = Int(batchStartTime.addingTimeInterval(startSeconds).timeIntervalSince1970)
      let endEpoch = Int(batchStartTime.addingTimeInterval(endSeconds).timeIntervalSince1970)
      return Observation(
        id: nil,
        batchId: batchId ?? -1,
        startTs: startEpoch,
        endTs: endEpoch,
        observation: segment.description,
        metadata: nil,
        llmModel: model,
        createdAt: Date()
      )
    }
  }
}
