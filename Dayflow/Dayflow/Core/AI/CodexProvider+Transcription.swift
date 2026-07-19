import Foundation

extension CodexProvider {
  // MARK: - Codex screenshot transcription

  static func transcriptionModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    // Mirrors `ClaudeProvider.transcriptionModelConfiguration` — the
    // primary model is whatever the user picked in Settings → Providers,
    // loaded from `CodexModelPreference`. The legacy fallback stays
    // hard-coded because the picker only exposes the primary slot; if
    // the user's selected model errors out, Dayflow falls back to a
    // known-good previous-generation model.
    return (model: CodexModelPreference.load().primary.rawValue, reasoningEffort: "low")
  }

  static func legacyTranscriptionModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    return (model: CodexModel.gpt54Mini.rawValue, reasoningEffort: "low")
  }

  func transcribeScreenshots(
    _ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?
  ) async throws -> (observations: [Observation], log: LLMCall) {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "ChatCLI", code: -96,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
    }

    let callStart = Date()
    let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

    // Sample ~15 evenly spaced screenshots to reduce API calls
    let targetSamples = 15
    let strideAmount = max(1, sortedScreenshots.count / targetSamples)
    let sampledScreenshots = Swift.stride(from: 0, to: sortedScreenshots.count, by: strideAmount)
      .map { sortedScreenshots[$0] }

    let firstTs = sortedScreenshots.first!.capturedAt
    let lastTs = sortedScreenshots.last!.capturedAt
    let durationSeconds = TimeInterval(lastTs - firstTs)
    let durationString = formatSeconds(durationSeconds)

    let imagePaths: [String] = sampledScreenshots.compactMap { screenshot in
      guard FileManager.default.fileExists(atPath: screenshot.filePath) else {
        print("[ChatCLI] ⚠️ Screenshot file not found: \(screenshot.filePath)")
        return nil
      }

      return screenshot.filePath
    }

    guard !imagePaths.isEmpty else {
      throw NSError(
        domain: "ChatCLI",
        code: -97,
        userInfo: [NSLocalizedDescriptionKey: "No valid screenshot files found"]
      )
    }

    let modelConfiguration = Self.transcriptionModelConfiguration()
    let legacyModelConfiguration = Self.legacyTranscriptionModelConfiguration()
    var model = modelConfiguration.model
    var effort = modelConfiguration.reasoningEffort

    let basePrompt = buildScreenshotTranscriptionPrompt(
      numFrames: imagePaths.count,
      duration: durationString,
      startTime: "00:00:00",
      endTime: durationString
    )
    var actualPrompt = basePrompt
    var lastError: Error?
    var lastRun: ChatCLIRunResult?

    func applyLegacyModelFallback(after error: Error) -> Bool {
      guard
        Self.shouldUseLegacyModel(
          after: error,
          currentModel: model,
          fallbackModel: legacyModelConfiguration.model
        )
      else { return false }

      captureLegacyModelFallback(
        operation: "transcribe_screenshots",
        fromModel: model,
        toModel: legacyModelConfiguration.model,
        batchId: batchId
      )
      model = legacyModelConfiguration.model
      effort = legacyModelConfiguration.reasoningEffort
      actualPrompt = basePrompt
      print("[ChatCLI] Codex is outdated; retrying transcription with \(model)")
      return true
    }

    let maxTranscribeAttempts = 3
    for attempt in 1...maxTranscribeAttempts {
      do {
        let run = try runAndScrub(
          prompt: actualPrompt, imagePaths: imagePaths, model: model, reasoningEffort: effort)
        lastRun = run

        let segments: [SegmentMergeResponse.Segment]
        do {
          segments = try parseSegments(from: run.stdout, stderr: run.stderr)
        } catch {
          lastError = error
          if attempt < maxTranscribeAttempts, applyLegacyModelFallback(after: error) {
            continue
          }
          if attempt < maxTranscribeAttempts {
            print(
              "[ChatCLI] Screenshot transcribe attempt \(attempt) failed: \(error.localizedDescription) — retrying"
            )
            let backoffSeconds = pow(2.0, Double(attempt - 1)) * 2.0
            try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            continue
          }
          break
        }

        if let validationError = validateSegments(segments, duration: durationSeconds) {
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
          lastError = NSError(
            domain: "ChatCLI", code: -98, userInfo: [NSLocalizedDescriptionKey: validationError])
          actualPrompt =
            basePrompt + "\n\nPREVIOUS ATTEMPT FAILED - FIX THE FOLLOWING:\n" + validationError
            + "\n\nReturn JSON only."
          if attempt < maxTranscribeAttempts {
            print(
              "[ChatCLI] Screenshot transcribe validation failed (attempt \(attempt)): \(validationError)"
            )
            let backoffSeconds = pow(2.0, Double(attempt - 1)) * 2.0
            try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            continue
          }
        } else {
          let ordered = segments.sorted {
            parseVideoTimestamp($0.start) < parseVideoTimestamp($1.start)
          }
          var observations: [Observation] = []
          for segment in ordered {
            let startSeconds = TimeInterval(parseVideoTimestamp(segment.start))
            let endSeconds = TimeInterval(parseVideoTimestamp(segment.end))
            let clampedStart = max(0.0, startSeconds)
            let clampedEnd = durationSeconds > 0 ? min(endSeconds, durationSeconds) : endSeconds
            guard clampedEnd > clampedStart else { continue }

            let startDate = batchStartTime.addingTimeInterval(clampedStart)
            let endDate = batchStartTime.addingTimeInterval(clampedEnd)
            let startEpoch = Int(startDate.timeIntervalSince1970)
            let endEpoch = max(startEpoch + 1, Int(endDate.timeIntervalSince1970))

            let trimmedDescription = segment.description.trimmingCharacters(
              in: .whitespacesAndNewlines)
            if trimmedDescription.isEmpty { continue }

            observations.append(
              Observation(
                id: nil,
                batchId: batchId ?? -1,
                startTs: startEpoch,
                endTs: endEpoch,
                observation: trimmedDescription,
                metadata: nil,
                llmModel: cliTool.rawValue,
                createdAt: Date()
              )
            )
          }

          if observations.isEmpty {
            lastError = NSError(
              domain: "ChatCLI", code: -99,
              userInfo: [
                NSLocalizedDescriptionKey: "No observations could be created from segments."
              ])
            if attempt < maxTranscribeAttempts {
              let backoffSeconds = pow(2.0, Double(attempt - 1)) * 2.0
              try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
              continue
            }
          } else {
            let finishedAt = run.finishedAt
            logSuccess(
              ctx: makeCtx(
                batchId: batchId, operation: "transcribe_screenshots", model: model,
                startedAt: callStart,
                attempt: attempt), finishedAt: finishedAt, stdout: run.stdout, stderr: run.stderr,
              responseHeaders: tokenHeaders(from: run.usage))
            let llmCall = makeLLMCall(
              start: callStart, end: finishedAt, input: actualPrompt, output: run.stdout)
            return (observations, llmCall)
          }
        }
      } catch {
        lastError = error
        if attempt < maxTranscribeAttempts, applyLegacyModelFallback(after: error) {
          continue
        }
        if attempt < maxTranscribeAttempts {
          print(
            "[ChatCLI] Screenshot transcribe attempt \(attempt) failed: \(error.localizedDescription) — retrying"
          )
          let backoffSeconds = pow(2.0, Double(attempt - 1)) * 2.0
          try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
          continue
        }

        break
      }
    }

    let finishedAt = lastRun?.finishedAt ?? Date()
    let finalError =
      lastError
      ?? NSError(
        domain: "ChatCLI", code: -99,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Screenshot transcription failed after \(maxTranscribeAttempts) attempts from \(imagePaths.count) screenshots"
        ])
    // Keep CLI output out of the error object as defense in depth because it was
    // generated from the user's screenshots.
    logFailure(
      ctx: makeCtx(
        batchId: batchId, operation: "transcribe_screenshots", model: model,
        startedAt: callStart,
        attempt: maxTranscribeAttempts), finishedAt: finishedAt, error: finalError)
    throw finalError
  }
}
