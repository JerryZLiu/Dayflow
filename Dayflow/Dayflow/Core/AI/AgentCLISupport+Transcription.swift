import Foundation

extension AgentCLISupporting {
  // MARK: - Shared transcription output contract

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

    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let failureReason: String
    if trimmedOutput.isEmpty {
      failureReason = "empty_output"
    } else if lastDecodeError == "No JSON object found in output" {
      failureReason = "missing_json_object"
    } else {
      failureReason = "invalid_json"
    }

    AnalyticsService.shared.capture(
      "llm_decode_failed",
      [
        "provider": "chat_cli",
        "provider_id": providerID.rawValue,
        "operation": "parse_segments",
        "tool": cliTool.rawValue,
        "failure_reason": failureReason,
        "output_was_empty": trimmedOutput.isEmpty,
        "stderr_was_empty": trimmedStderr.isEmpty,
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
      guard let startSeconds = strictSegmentTimestamp(segment.start),
        let endSeconds = strictSegmentTimestamp(segment.end)
      else {
        return "Segments must use valid HH:MM:SS timestamps: \(segment.start) -> \(segment.end)"
      }
      if segment.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "Every segment must include a non-empty factual description."
      }
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

  private func strictSegmentTimestamp(_ timestamp: String) -> TimeInterval? {
    let components =
      timestamp
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ":", omittingEmptySubsequences: false)
    guard components.count == 3,
      let hours = Int(components[0]),
      let minutes = Int(components[1]),
      let seconds = Int(components[2]),
      hours >= 0,
      (0..<60).contains(minutes),
      (0..<60).contains(seconds)
    else {
      return nil
    }
    return TimeInterval(hours * 3600 + minutes * 60 + seconds)
  }

}
