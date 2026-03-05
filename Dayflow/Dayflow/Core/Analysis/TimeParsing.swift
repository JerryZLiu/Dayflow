import Foundation

/// Cached DateFormatters for time parsing - creating DateFormatters is expensive (ICU initialization)
private let cachedHMMAFormatters: [DateFormatter] = {
  let formats = [
    "h:mma",  // 09:30AM, 9:30AM
    "hh:mma",  // 09:30AM
    "h:mm a",  // 09:30 AM, 9:30 AM
    "hh:mm a",  // 09:30 AM
  ]
  return formats.map { format in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")  // Essential for AM/PM parsing
    formatter.dateFormat = format
    return formatter
  }
}()

/// Parses a time string in "h:mm a", "hh:mm a", "h:mma", or "hh:mma" format (case-insensitive for AM/PM)
/// into total minutes since midnight (0-1439).
/// Returns nil if parsing fails.
func parseTimeHMMA(timeString: String) -> Int? {
  let trimmedTime = timeString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

  for formatter in cachedHMMAFormatters {
    if let date = formatter.date(from: trimmedTime) {
      let calendar = Calendar.current
      let hour = calendar.component(.hour, from: date)
      let minute = calendar.component(.minute, from: date)
      return hour * 60 + minute
    }
  }

  return nil
}

// MARK: - LLM video/timeline helpers

/// Shared utilities for parsing timestamps emitted by LLMs during video/timelapse transcription.
///
/// NOTE: These helpers are intentionally lightweight and avoid shared DateFormatter instances
/// because DateFormatter is not thread-safe.
enum LLMVideoTimestampUtilities {
  /// Parses either `HH:MM:SS` or `MM:SS` into total seconds.
  /// Returns `0` for invalid input.
  static func parseVideoTimestamp(_ timestamp: String) -> Int {
    let parts =
      timestamp
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: ":")

    if parts.count == 3 {
      let h = Int(parts[0]) ?? 0
      let m = Int(parts[1]) ?? 0
      let s = Int(parts[2]) ?? 0
      return h * 3600 + m * 60 + s
    }
    if parts.count == 2 {
      let m = Int(parts[0]) ?? 0
      let s = Int(parts[1]) ?? 0
      return m * 60 + s
    }
    return 0
  }

  static func formatSecondsHHMMSS(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return String(format: "%02d:%02d:%02d", h, m, sec)
  }
}

/// Shared validation utilities for ensuring timeline cards fully cover time ranges and
/// don't violate minimum duration constraints.
enum LLMTimelineCardValidation {
  struct TimeRange {
    let start: Double
    let end: Double
  }

  static func formatTimestampForPrompt(_ unixTime: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  static func timeToMinutes(_ timeStr: String) -> Double {
    let trimmed = timeStr.trimmingCharacters(in: .whitespacesAndNewlines)
    if let minutes = parseTimeHMMA(timeString: trimmed) {
      return Double(minutes)
    }

    // Fallback to MM:SS / HH:MM:SS video-style time.
    let seconds = LLMVideoTimestampUtilities.parseVideoTimestamp(trimmed)
    return Double(seconds) / 60.0
  }

  static func minutesToTimeString(_ minutes: Double) -> String {
    let hours = (Int(minutes) / 60) % 24
    let mins = Int(minutes) % 60
    let period = hours < 12 ? "AM" : "PM"
    var displayHour = hours % 12
    if displayHour == 0 { displayHour = 12 }
    return String(format: "%d:%02d %@", displayHour, mins, period)
  }

  private static func mergeOverlappingRanges(_ ranges: [TimeRange]) -> [TimeRange] {
    guard !ranges.isEmpty else { return [] }
    let sorted = ranges.sorted { $0.start < $1.start }
    var merged: [TimeRange] = []
    for range in sorted {
      if merged.isEmpty || range.start > merged.last!.end + 1 {
        merged.append(range)
      } else {
        let last = merged.removeLast()
        merged.append(TimeRange(start: last.start, end: max(last.end, range.end)))
      }
    }
    return merged
  }

  static func validateTimeCoverage(existingCards: [ActivityCardData], newCards: [ActivityCardData])
    -> (isValid: Bool, error: String?)
  {
    guard !existingCards.isEmpty else { return (true, nil) }

    var inputRanges: [TimeRange] = []
    for card in existingCards {
      let startMin = timeToMinutes(card.startTime)
      var endMin = timeToMinutes(card.endTime)
      if endMin < startMin { endMin += 24 * 60 }
      inputRanges.append(TimeRange(start: startMin, end: endMin))
    }
    let mergedInputRanges = mergeOverlappingRanges(inputRanges)

    var outputRanges: [TimeRange] = []
    for card in newCards {
      let startMin = timeToMinutes(card.startTime)
      var endMin = timeToMinutes(card.endTime)
      if endMin < startMin { endMin += 24 * 60 }
      guard endMin - startMin >= 0.1 else { continue }
      outputRanges.append(TimeRange(start: startMin, end: endMin))
    }

    let flexibility = 3.0
    var uncoveredSegments: [(start: Double, end: Double)] = []

    for inputRange in mergedInputRanges {
      var coveredStart = inputRange.start
      var safetyCounter = 10000

      while coveredStart < inputRange.end && safetyCounter > 0 {
        safetyCounter -= 1
        var foundCoverage = false

        for outputRange in outputRanges {
          if outputRange.start - flexibility <= coveredStart
            && coveredStart <= outputRange.end + flexibility
          {
            let newCoveredStart = outputRange.end
            coveredStart = max(coveredStart + 0.01, newCoveredStart)
            foundCoverage = true
            break
          }
        }

        if !foundCoverage {
          var nextCovered = inputRange.end
          for outputRange in outputRanges {
            if outputRange.start > coveredStart && outputRange.start < nextCovered {
              nextCovered = outputRange.start
            }
          }
          if nextCovered > coveredStart {
            uncoveredSegments.append((start: coveredStart, end: min(nextCovered, inputRange.end)))
            coveredStart = nextCovered
          } else {
            uncoveredSegments.append((start: coveredStart, end: inputRange.end))
            break
          }
        }
      }

      if safetyCounter == 0 {
        return (
          false,
          "Time coverage validation loop exceeded safety limit - possible infinite loop detected"
        )
      }
    }

    if !uncoveredSegments.isEmpty {
      var uncoveredDesc: [String] = []
      for segment in uncoveredSegments {
        let duration = segment.end - segment.start
        if duration > flexibility {
          uncoveredDesc.append(
            "\(minutesToTimeString(segment.start))-\(minutesToTimeString(segment.end)) (\(Int(duration)) min)"
          )
        }
      }

      if !uncoveredDesc.isEmpty {
        var errorMsg =
          "Missing coverage for time segments: \(uncoveredDesc.joined(separator: ", "))"
        errorMsg += "\n\n📥 INPUT CARDS:"
        for (i, card) in existingCards.enumerated() {
          errorMsg += "\n  \(i+1). \(card.startTime) - \(card.endTime): \(card.title)"
        }
        errorMsg += "\n\n📤 OUTPUT CARDS:"
        for (i, card) in newCards.enumerated() {
          errorMsg += "\n  \(i+1). \(card.startTime) - \(card.endTime): \(card.title)"
        }
        return (false, errorMsg)
      }
    }

    return (true, nil)
  }

  static func validateTimeline(_ cards: [ActivityCardData]) -> (isValid: Bool, error: String?) {
    for (index, card) in cards.enumerated() {
      let startTime = card.startTime
      let endTime = card.endTime

      var durationMinutes: Double = 0

      if let startMin = parseTimeHMMA(timeString: startTime),
        let endMinRaw = parseTimeHMMA(timeString: endTime)
      {
        var endMin = endMinRaw
        if endMin < startMin { endMin += 24 * 60 }
        durationMinutes = Double(endMin - startMin)
      } else {
        let startSeconds = LLMVideoTimestampUtilities.parseVideoTimestamp(startTime)
        let endSeconds = LLMVideoTimestampUtilities.parseVideoTimestamp(endTime)
        durationMinutes = Double(endSeconds - startSeconds) / 60.0
      }

      if durationMinutes < 10 && index < cards.count - 1 {
        return (
          false,
          "Card \(index + 1) '\(card.title)' is only \(String(format: "%.1f", durationMinutes)) minutes long"
        )
      }
    }
    return (true, nil)
  }
}

// MARK: - LLM transcript helpers

/// Shared utilities for decoding model-generated transcript JSON and converting it into Dayflow observations.
///
/// Providers differ in transport (Gemini schema-constrained vs Ark chat-completions), but the transcript payload
/// is intentionally normalized to the same `[{ startTimestamp, endTimestamp, description }]` array.
enum LLMTranscriptUtilities {
  struct VideoTranscriptChunk: Codable {
    let startTimestamp: String
    let endTimestamp: String
    let description: String
  }

  struct ObservationConversionResult {
    let observations: [Observation]
    /// Count of chunks dropped due to timestamp validation failures.
    let invalidTimestampCount: Int
  }

  static func decodeTranscriptChunks(from output: String, allowBracketFallback: Bool) throws
    -> [VideoTranscriptChunk]
  {
    let cleaned = cleanJSONResponse(output)

    if let data = cleaned.data(using: .utf8),
      let parsed = try? JSONDecoder().decode([VideoTranscriptChunk].self, from: data),
      !parsed.isEmpty
    {
      return parsed
    }

    guard allowBracketFallback else {
      throw NSError(
        domain: "LLMTranscriptUtilities",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to decode transcript JSON array"]
      )
    }

    // Bracket-balance extraction (outside string literals): find the last JSON array in the response.
    if let slice = extractLastJSONArraySlice(from: cleaned),
      let data = slice.data(using: .utf8),
      let parsed = try? JSONDecoder().decode([VideoTranscriptChunk].self, from: data),
      !parsed.isEmpty
    {
      return parsed
    }

    throw NSError(
      domain: "LLMTranscriptUtilities",
      code: 2,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Failed to decode transcript JSON array (fallback extraction did not help)"
      ]
    )
  }

  static func observations(
    from chunks: [VideoTranscriptChunk],
    batchStartTime: Date,
    observationBatchId: Int64,
    llmModel: String,
    compressedVideoDuration: TimeInterval,
    compressionFactor: TimeInterval,
    tolerance: TimeInterval = 10.0,
    debugPrintExpansion: Bool = false
  ) -> ObservationConversionResult {
    var invalidCount = 0
    let observations: [Observation] = chunks.compactMap { chunk in
      let compressedStartSeconds = LLMVideoTimestampUtilities.parseVideoTimestamp(
        chunk.startTimestamp)
      let compressedEndSeconds = LLMVideoTimestampUtilities.parseVideoTimestamp(chunk.endTimestamp)

      if Double(compressedStartSeconds) < -tolerance
        || Double(compressedEndSeconds) > compressedVideoDuration + tolerance
      {
        invalidCount += 1
        return nil
      }

      let realStartSeconds = TimeInterval(compressedStartSeconds) * compressionFactor
      let realEndSeconds = TimeInterval(compressedEndSeconds) * compressionFactor

      if debugPrintExpansion {
        print(
          "📐 Timestamp expansion: \(chunk.startTimestamp)-\(chunk.endTimestamp) → \(Int(realStartSeconds))s-\(Int(realEndSeconds))s real"
        )
      }

      let startDate = batchStartTime.addingTimeInterval(realStartSeconds)
      let endDate = batchStartTime.addingTimeInterval(realEndSeconds)
      let trimmed = chunk.description.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }

      return Observation(
        id: nil,
        batchId: observationBatchId,
        startTs: Int(startDate.timeIntervalSince1970),
        endTs: Int(endDate.timeIntervalSince1970),
        observation: trimmed,
        metadata: nil,
        llmModel: llmModel,
        createdAt: Date()
      )
    }

    return ObservationConversionResult(
      observations: observations, invalidTimestampCount: invalidCount)
  }

  // MARK: - Private

  private static func cleanJSONResponse(_ output: String) -> String {
    output
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func extractLastJSONArraySlice(from str: String) -> String? {
    let brackets = bracketPositionsOutsideStrings(in: str)
    guard let lastClose = brackets.last(where: { $0.char == "]" }) else { return nil }

    var balance = 0
    for entry in brackets.reversed() {
      if entry.index > lastClose.index { continue }
      if entry.char == "]" {
        balance += 1
      } else if entry.char == "[" {
        balance -= 1
        if balance == 0 {
          let slice = String(str[entry.index...lastClose.index]).trimmingCharacters(
            in: .whitespacesAndNewlines)
          return slice
        }
      }
    }

    return nil
  }

  private struct BracketEntry {
    let char: Character
    let index: String.Index
  }

  private static func bracketPositionsOutsideStrings(in str: String) -> [BracketEntry] {
    var result: [BracketEntry] = []
    var inString = false
    var escaped = false

    for idx in str.indices {
      let ch = str[idx]

      if inString {
        if escaped {
          escaped = false
        } else if ch == "\\" {
          escaped = true
        } else if ch == "\"" {
          inString = false
        }
        continue
      }

      if ch == "\"" {
        inString = true
        continue
      }

      if ch == "[" || ch == "]" {
        result.append(BracketEntry(char: ch, index: idx))
      }
    }

    return result
  }
}
