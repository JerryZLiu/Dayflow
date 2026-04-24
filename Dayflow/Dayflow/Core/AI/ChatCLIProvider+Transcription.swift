import AppKit
import Foundation

extension ChatCLIProvider {
  // MARK: - Screenshot Transcription

  func buildScreenshotTranscriptionPrompt(
    numFrames: Int, duration: String, startTime: String, endTime: String
  ) -> String {
    return """
      Analyze these \(numFrames) screenshots from a \(duration) screen recording
      (\(startTime) to \(endTime)). They are 1 min apart and in order.

      Create an activity log detailed enough that someone could reconstruct what
      the user did.

      For each segment, ask yourself: "What EXACTLY did they do? What SPECIFIC
      things can I see?"

      Capture from screenshots:
      - Exact app/site names visible
      - Exact file names, URLs, page titles
      - Exact usernames, search queries, messages
      - Exact numbers, stats, prices shown

      Bad: "Checked email"
      Good: "Gmail: Read email from boss@company.com 'RE: Budget approval' - replied 'Looks good'"

      Bad: "Browsing Twitter"
      Good: "Twitter/X: Scrolled feed - viewed posts by @pmarca about AI, @sama thread on GPT-5 (12 tweets)"

      Bad: "Working on code"
      Good: "VS Code: Editing StorageManager.swift - fixed type error on line 47, changed String to String?"

      3-8 segments total.
      Exception: You may use 1 segment only if the user appears idle for most of the recording.
      Group by GOAL not app (debugging across IDE+Terminal+Browser = 1 segment).

      Timestamps must start at \(startTime) and end at \(endTime). No gaps.

      Return JSON only:
      {"segments":[{"start":"HH:MM:SS","end":"HH:MM:SS","description":"..."}]}
      """
  }

  func parseSegments(from output: String, stderr: String) throws -> [SegmentMergeResponse
    .Segment]
  {
    // First try parsing without any modifications
    let basicCleaned =
      output
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    var lastDecodeError: String?

    // Strategy 1: Direct decode
    if let data = basicCleaned.data(using: .utf8),
      let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
      !parsed.segments.isEmpty
    {
      return parsed.segments
    }

    // Strategy 2: Array decode
    if let data = basicCleaned.data(using: .utf8),
      let parsed = try? JSONDecoder().decode([SegmentMergeResponse.Segment].self, from: data),
      !parsed.isEmpty
    {
      return parsed
    }

    // Strategy 3: Brace extraction
    if let firstBrace = basicCleaned.firstIndex(of: "{"),
      let lastBrace = basicCleaned.lastIndex(of: "}"),
      firstBrace < lastBrace
    {
      let slice = String(basicCleaned[firstBrace...lastBrace])
      if let data = slice.data(using: .utf8),
        let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
        !parsed.segments.isEmpty
      {
        return parsed.segments
      }
    }

    // Strategy 4 (fallback): Strip OSC escapes and retry brace extraction
    let oscCleaned = stripOSCEscapes(basicCleaned)
    if let firstBrace = oscCleaned.firstIndex(of: "{"),
      let lastBrace = oscCleaned.lastIndex(of: "}"),
      firstBrace < lastBrace
    {
      let slice = String(oscCleaned[firstBrace...lastBrace])
      if let data = slice.data(using: .utf8) {
        do {
          let parsed = try JSONDecoder().decode(SegmentMergeResponse.self, from: data)
          if !parsed.segments.isEmpty { return parsed.segments }
        } catch {
          lastDecodeError = "Strategy 4 (OSC strip + brace): \(error.localizedDescription)"
        }
      }
    } else {
      lastDecodeError = "No JSON object found in output"
    }

    // Log full raw output to PostHog for debugging decode failures
    AnalyticsService.shared.capture(
      "llm_decode_failed",
      [
        "provider": "chat_cli",
        "operation": "parse_segments",
        "tool": tool.rawValue,
        "raw_output": output,
        "output_length": output.count,
        "stderr": stderr,
        "stderr_length": stderr.count,
        "decode_error": lastDecodeError ?? "no JSON found",
      ])

    // Surface CLI error messages to the user if available
    if let cliError = extractCLIError(stdout: output, stderr: stderr) {
      throw NSError(domain: "ChatCLI", code: -33, userInfo: [NSLocalizedDescriptionKey: cliError])
    }

    throw NSError(
      domain: "ChatCLI", code: -31,
      userInfo: [NSLocalizedDescriptionKey: "Failed to decode segments JSON"])
  }

  func validateSegments(_ segments: [SegmentMergeResponse.Segment], duration: TimeInterval)
    -> String?
  {
    guard !segments.isEmpty else { return "No segments returned." }

    let tolerance: TimeInterval = 2.0
    var parsed: [(start: TimeInterval, end: TimeInterval, description: String)] = []

    for segment in segments {
      let startSeconds = TimeInterval(parseVideoTimestamp(segment.start))
      let endSeconds = TimeInterval(parseVideoTimestamp(segment.end))
      if endSeconds <= startSeconds {
        return "Segment end time must be after start time: \(segment.start) -> \(segment.end)"
      }
      if startSeconds < 0 {
        return "Segment start time must be >= 00:00:00 (got \(segment.start))."
      }
      if duration > 0, endSeconds > duration + tolerance {
        return
          "Segment out of bounds: \(segment.start) -> \(segment.end) (duration \(formatSeconds(duration)))"
      }
      parsed.append((startSeconds, endSeconds, segment.description))
    }

    let ordered = parsed.sorted { $0.start < $1.start }
    if duration > 0, let first = ordered.first, first.start > tolerance {
      return "First segment must start at 00:00:00 (starts at \(formatSeconds(first.start)))."
    }

    for i in 1..<ordered.count {
      let prev = ordered[i - 1]
      let next = ordered[i]
      let gap = next.start - prev.end
      if gap > tolerance {
        return
          "Gap detected between segments: \(formatSeconds(prev.end)) -> \(formatSeconds(next.start))"
      }
      if gap < -tolerance {
        return
          "Overlap detected between segments: \(formatSeconds(next.start)) starts before \(formatSeconds(prev.end))"
      }
    }

    if duration > 0, let last = ordered.last, duration - last.end > tolerance {
      return
        "Last segment must end at \(formatSeconds(duration)) (ends at \(formatSeconds(last.end)))."
    }

    return nil
  }

  /// Transcribe observations from screenshots using a single-shot prompt.
  func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?)
    async throws -> (observations: [Observation], log: LLMCall)
  {
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

    let model: String
    let effort: String?
    switch tool {
    case .claude:
      model = "haiku"
      effort = nil
    case .codex:
      model = "gpt-5.4-mini"
      effort = "low"
    }

    let basePrompt = buildScreenshotTranscriptionPrompt(
      numFrames: imagePaths.count,
      duration: durationString,
      startTime: "00:00:00",
      endTime: durationString
    )
    var actualPrompt = basePrompt
    var lastError: Error?
    var lastRun: ChatCLIRunResult?
    var lastRawOutput: String = ""
    var lastRawStderr: String = ""

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
          let debugOutput = buildDebugResponseBody(stdout: run.stdout, rawStdout: run.rawStdout)
          if !debugOutput.isEmpty {
            lastRawOutput = debugOutput
            if tool == .claude {
              print(
                "[ChatCLI] Claude transcribe_screenshots decode failure (attempt \(attempt)):\n\(debugOutput)"
              )
            }
          }
          if !run.stderr.isEmpty {
            lastRawStderr = run.stderr
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
                llmModel: tool.rawValue,
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
                batchId: batchId, operation: "transcribe_screenshots", startedAt: callStart,
                attempt: attempt), finishedAt: finishedAt, stdout: run.stdout, stderr: run.stderr,
              responseHeaders: tokenHeaders(from: run.usage))
            let llmCall = makeLLMCall(
              start: callStart, end: finishedAt, input: actualPrompt, output: run.stdout)
            return (observations, llmCall)
          }
        }
      } catch {
        lastError = error
        // Capture partial output from timeout errors for logging
        let nsErr = error as NSError
        if let partialOut = nsErr.userInfo["partialStdout"] as? String, !partialOut.isEmpty {
          lastRawOutput = partialOut
        }
        if let partialErr = nsErr.userInfo["partialStderr"] as? String, !partialErr.isEmpty {
          lastRawStderr = partialErr
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
    let finalStdout =
      lastRawOutput.isEmpty
      ? (lastRun.map { buildDebugResponseBody(stdout: $0.stdout, rawStdout: $0.rawStdout) } ?? "")
      : lastRawOutput
    let finalStderr = lastRun?.stderr ?? lastRawStderr
    logFailure(
      ctx: makeCtx(
        batchId: batchId, operation: "transcribe_screenshots", startedAt: callStart,
        attempt: maxTranscribeAttempts), finishedAt: finishedAt, error: finalError,
      stdout: finalStdout, stderr: finalStderr, run: lastRun)
    throw finalError
  }

}
