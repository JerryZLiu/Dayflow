import Foundation

/// Pure formatting and validation shared by CLI and HTTP timeline providers.
protocol TimelineOutputSupporting {}

extension TimelineOutputSupporting {
  func parseVideoTimestamp(_ timestamp: String) -> Int {
    let components = timestamp.components(separatedBy: ":")

    if components.count == 3 {
      guard let hours = Int(components[0]),
        let minutes = Int(components[1]),
        let seconds = Int(components[2])
      else {
        return 0
      }
      return hours * 3600 + minutes * 60 + seconds
    }

    if components.count == 2 {
      guard let minutes = Int(components[0]),
        let seconds = Int(components[1])
      else {
        return 0
      }
      return minutes * 60 + seconds
    }

    return 0
  }

  func formatTimestampForPrompt(_ unixTime: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  func formatSeconds(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return String(format: "%02d:%02d:%02d", h, m, sec)
  }

  func categoriesSection(from descriptors: [LLMCategoryDescriptor]) -> String {
    guard !descriptors.isEmpty else {
      return
        "USER CATEGORIES: No categories configured. Use consistent labels based on the activity story."
    }

    // Use explicit string concatenation to avoid GRDB SQL interpolation pollution
    let allowed = descriptors.map { "\"" + $0.name + "\"" }.joined(separator: ", ")
    var lines: [String] = ["USER CATEGORIES (choose exactly one label):"]

    for (index, descriptor) in descriptors.enumerated() {
      var desc = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if descriptor.isIdle && desc.isEmpty {
        desc = "Use when the user is idle for most of this period."
      }
      let suffix = desc.isEmpty ? "" : " — " + desc
      lines.append(String(index + 1) + ". \"" + descriptor.name + "\"" + suffix)
    }

    if let idle = descriptors.first(where: { $0.isIdle }) {
      lines.append(
        "Only use \"" + idle.name
          + "\" when the user is idle for more than half of the timeframe. Otherwise pick the closest non-idle label."
      )
    }

    lines.append("Return the category exactly as written. Allowed values: [" + allowed + "].")
    return lines.joined(separator: "\n")
  }

  func normalizeCategory(_ raw: String, descriptors: [LLMCategoryDescriptor]) -> String {
    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return descriptors.first?.name ?? "" }
    let normalized = cleaned.lowercased()
    if let match = descriptors.first(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }) {
      return match.name
    }
    if let idle = descriptors.first(where: { $0.isIdle }) {
      let idleLabels = ["idle", "idle time", idle.name.lowercased()]
      if idleLabels.contains(normalized) {
        return idle.name
      }
    }
    return descriptors.first?.name ?? cleaned
  }

  func normalizeCards(_ cards: [ActivityCardData], descriptors: [LLMCategoryDescriptor])
    -> [ActivityCardData]
  {
    cards.map { card in
      ActivityCardData(
        startTime: card.startTime,
        endTime: card.endTime,
        category: normalizeCategory(card.category, descriptors: descriptors),
        subcategory: card.subcategory,
        title: card.title,
        summary: card.summary,
        detailedSummary: card.detailedSummary,
        distractions: card.distractions,
        appSites: card.appSites
      )
    }
  }

  func timeToMinutes(_ timeStr: String) -> Double {
    let trimmed = timeStr.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("AM") || trimmed.contains("PM") {
      let formatter = DateFormatter()
      formatter.dateFormat = "h:mm a"
      formatter.locale = Locale(identifier: "en_US_POSIX")
      guard let date = formatter.date(from: trimmed) else { return 0 }
      let components = Calendar.current.dateComponents([.hour, .minute], from: date)
      let hours = Double(components.hour ?? 0)
      let minutes = Double(components.minute ?? 0)
      return hours * 60 + minutes
    } else {
      let seconds = parseVideoTimestamp(timeStr)
      return Double(seconds) / 60.0
    }
  }

  func mergeOverlappingRanges(_ ranges: [AgentCLITimeRange]) -> [AgentCLITimeRange] {
    guard !ranges.isEmpty else { return [] }
    let sorted = ranges.sorted { $0.start < $1.start }
    var merged: [AgentCLITimeRange] = []
    for range in sorted {
      if merged.isEmpty || range.start > merged.last!.end + 1 {
        merged.append(range)
      } else {
        let last = merged.removeLast()
        merged.append(AgentCLITimeRange(start: last.start, end: max(last.end, range.end)))
      }
    }
    return merged
  }

  func validateTimeCoverage(existingCards: [ActivityCardData], newCards: [ActivityCardData])
    -> (isValid: Bool, error: String?)
  {
    guard !existingCards.isEmpty else { return (true, nil) }

    var inputRanges: [AgentCLITimeRange] = []
    for card in existingCards {
      let startMin = timeToMinutes(card.startTime)
      var endMin = timeToMinutes(card.endTime)
      if endMin < startMin { endMin += 24 * 60 }
      inputRanges.append(AgentCLITimeRange(start: startMin, end: endMin))
    }
    let mergedInputRanges = mergeOverlappingRanges(inputRanges)

    var outputRanges: [AgentCLITimeRange] = []
    for card in newCards {
      let startMin = timeToMinutes(card.startTime)
      var endMin = timeToMinutes(card.endTime)
      if endMin < startMin { endMin += 24 * 60 }
      guard endMin - startMin >= 0.1 else { continue }
      outputRanges.append(AgentCLITimeRange(start: startMin, end: endMin))
    }

    let flexibility = 3.0  // minutes
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
          let startTime = minutesToTimeString(segment.start)
          let endTime = minutesToTimeString(segment.end)
          uncoveredDesc.append(startTime + "-" + endTime + " (" + String(Int(duration)) + " min)")
        }
      }

      if !uncoveredDesc.isEmpty {
        let missing = uncoveredDesc.joined(separator: ", ")
        var errorMsg = "Missing coverage for time segments: " + missing
        errorMsg += "\n\n📥 INPUT CARDS:"
        for (i, card) in existingCards.enumerated() {
          errorMsg +=
            "\n  " + String(i + 1) + ". " + card.startTime + " - " + card.endTime + ": "
            + card.title
        }
        errorMsg += "\n\n📤 OUTPUT CARDS:"
        for (i, card) in newCards.enumerated() {
          errorMsg +=
            "\n  " + String(i + 1) + ". " + card.startTime + " - " + card.endTime + ": "
            + card.title
        }
        return (false, errorMsg)
      }
    }

    return (true, nil)
  }

  func validateTimeline(_ cards: [ActivityCardData]) -> (isValid: Bool, error: String?) {
    for (index, card) in cards.enumerated() {
      let startTime = card.startTime
      let endTime = card.endTime
      var durationMinutes: Double = 0

      if startTime.contains("AM") || startTime.contains("PM") {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if let startDate = formatter.date(from: startTime),
          let endDate = formatter.date(from: endTime)
        {
          var adjustedEndDate = endDate
          if endDate < startDate {
            adjustedEndDate =
              Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
          }
          durationMinutes = adjustedEndDate.timeIntervalSince(startDate) / 60.0
        } else {
          durationMinutes = 0
        }
      } else {
        let startSeconds = parseVideoTimestamp(startTime)
        let endSeconds = parseVideoTimestamp(endTime)
        durationMinutes = Double(endSeconds - startSeconds) / 60.0
      }

      if durationMinutes < 10 && index < cards.count - 1 {
        let msg = String(
          format: "Card %d '%@' is only %.1f minutes long", index + 1, card.title, durationMinutes)
        return (false, msg)
      }
    }

    return (true, nil)
  }

  func minutesToTimeString(_ minutes: Double) -> String {
    let hours = (Int(minutes) / 60) % 24
    let mins = Int(minutes) % 60
    let period = hours < 12 ? "AM" : "PM"
    var displayHour = hours % 12
    if displayHour == 0 { displayHour = 12 }
    return String(format: "%d:%02d %@", displayHour, mins, period)
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

}
