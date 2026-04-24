import AppKit
import Foundation

extension ChatCLIProvider {
  // MARK: - Parsing

  /// Strip OSC (Operating System Command) escape sequences from CLI output.
  /// These are injected by terminal integrations like iTerm2 and pollute JSON responses.
  /// Examples: ]1337;RemoteHost=user@host, ]9;4;0;, ]1337;CurrentDir=/path
  /// Safety: Only strips if semicolon appears within first 5 chars (real OSC always has it)
  func stripOSCEscapes(_ input: String) -> String {
    var result = ""
    var i = input.startIndex
    while i < input.endIndex {
      if input[i] == "]" {
        let next = input.index(after: i)
        if next < input.endIndex, input[next].isNumber {
          // Look ahead to see if there's a semicolon within first 5 chars (OSC signature)
          var hasSemicolon = false
          var lookAhead = next
          var lookCount = 0
          while lookAhead < input.endIndex, lookCount < 5 {
            if input[lookAhead] == ";" {
              hasSemicolon = true
              break
            }
            if !input[lookAhead].isNumber { break }
            lookAhead = input.index(after: lookAhead)
            lookCount += 1
          }

          if hasSemicolon {
            // This is a real OSC sequence - skip it
            var j = next
            while j < input.endIndex {
              let c = input[j]
              if c.isNumber || c == ";" || c == "=" || c.isLetter || c == "@" || c == "."
                || c == "-" || c == "_" || c == "/"
              {
                j = input.index(after: j)
              } else {
                break
              }
            }
            i = j
            continue
          }
        }
      }
      result.append(input[i])
      i = input.index(after: i)
    }
    return result
  }

  /// Extract user-facing error message from CLI stderr/stdout.
  /// Returns the actual error message from the CLI tool if found, nil otherwise.
  func extractCLIError(stdout: String, stderr: String) -> String? {
    // Check stderr for ERROR: lines (Codex format)
    // e.g. "ERROR: You've hit your usage limit..."
    // e.g. "ERROR: Your access token could not be refreshed..."
    for line in stderr.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("ERROR:") {
        return trimmed
      }
    }

    // Check stdout for API Error messages (Claude format)
    // e.g. "API Error: The SSO session associated with this profile has expired..."
    // e.g. "You've hit your limit · resets 3pm (Asia/Shanghai)"
    // e.g. "Invalid API key · Please run /login"
    for line in stdout.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("API Error:") || trimmed.hasPrefix("Invalid API key")
        || trimmed.hasPrefix("You've hit your limit")
      {
        // Strip trailing escape sequences like ]9;4;0;
        let cleaned = trimmed.replacingOccurrences(
          of: #"\][\d;]+$"#, with: "", options: .regularExpression)
        return cleaned
      }
    }

    return nil
  }

  func parseCards(from output: String, stderr: String) throws -> [ActivityCardData] {
    // Try parsing without modifications first, OSC stripping is a fallback
    guard let data = output.data(using: .utf8) else {
      throw NSError(
        domain: "ChatCLI", code: -31, userInfo: [NSLocalizedDescriptionKey: "No stdout to parse"])
    }

    let decoder = JSONDecoder()

    // Strategy 1: {"cards":[...]}
    if let envelope = try? decoder.decode(ChatCLICardsEnvelope.self, from: data) {
      let cards: [ActivityCardData?] = envelope.cards.map { item in
        guard let start = item.normalizedStart, let end = item.normalizedEnd else { return nil }
        return ActivityCardData(
          startTime: start,
          endTime: end,
          category: item.category,
          subcategory: item.subcategory,
          title: item.title,
          summary: item.summary,
          detailedSummary: item.detailedSummary ?? item.summary,
          distractions: item.distractions,
          appSites: item.appSites
        )
      }
      let filtered = cards.compactMap { $0 }
      if !filtered.isEmpty { return filtered }
    }

    // Strategy 2: top-level array of cards (Gemini-style)
    if let arrayCards = try? decoder.decode([ActivityCardData].self, from: data) {
      return arrayCards
    }

    // Strategy 3: LLM may output preamble text containing brackets (e.g., git help `[-v | --version]`).
    // Use bracket balancing: start from the last ']' and walk backwards tracking balance.
    // When balance hits 0, we've found the '[' that opens our JSON array.
    func findBalancedArrayStart(_ str: String, endBracket: String.Index) -> String.Index? {
      var balance = 0
      var index = endBracket
      while true {
        let char = str[index]
        if char == "]" {
          balance += 1
        } else if char == "[" {
          balance -= 1
          if balance == 0 {
            return index
          }
        }
        if index == str.startIndex { break }
        index = str.index(before: index)
      }
      return nil
    }

    if let lastBracket = output.lastIndex(of: "]"),
      let firstBracket = findBalancedArrayStart(output, endBracket: lastBracket)
    {
      let sliced = String(output[firstBracket...lastBracket])
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if let slicedData = sliced.data(using: .utf8) {
        if let envelope = try? decoder.decode(ChatCLICardsEnvelope.self, from: slicedData) {
          let cards: [ActivityCardData?] = envelope.cards.map { item in
            guard let start = item.normalizedStart, let end = item.normalizedEnd else { return nil }
            return ActivityCardData(
              startTime: start,
              endTime: end,
              category: item.category,
              subcategory: item.subcategory,
              title: item.title,
              summary: item.summary,
              detailedSummary: item.detailedSummary ?? item.summary,
              distractions: item.distractions,
              appSites: item.appSites
            )
          }
          let filtered = cards.compactMap { $0 }
          if !filtered.isEmpty { return filtered }
        }

        if let arrayCards = try? decoder.decode([ActivityCardData].self, from: slicedData) {
          return arrayCards
        }
      }
    }

    // Strategy 4 (fallback): Strip OSC escapes and retry bracket extraction
    let oscCleaned = stripOSCEscapes(output)
    if let lastBracket = oscCleaned.lastIndex(of: "]"),
      let firstBracket = findBalancedArrayStart(oscCleaned, endBracket: lastBracket)
    {
      let sliced = String(oscCleaned[firstBracket...lastBracket])
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if let slicedData = sliced.data(using: .utf8) {
        if let arrayCards = try? decoder.decode([ActivityCardData].self, from: slicedData) {
          return arrayCards
        }
      }
    }

    // Log full raw output to PostHog for debugging decode failures
    AnalyticsService.shared.capture(
      "llm_decode_failed",
      [
        "provider": "chat_cli",
        "operation": "parse_cards",
        "tool": tool.rawValue,
        "raw_output": output,
        "output_length": output.count,
        "stderr": stderr,
        "stderr_length": stderr.count,
      ])

    // Surface CLI error messages to the user if available
    if let cliError = extractCLIError(stdout: output, stderr: stderr) {
      throw NSError(domain: "ChatCLI", code: -33, userInfo: [NSLocalizedDescriptionKey: cliError])
    }

    throw NSError(
      domain: "ChatCLI", code: -32,
      userInfo: [NSLocalizedDescriptionKey: "Failed to decode activity cards"])
  }

  struct SegmentMergeResponse: Codable {
    struct Segment: Codable {
      let start: String
      let end: String
      let description: String
    }
    let segments: [Segment]
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

  struct TimeRange {
    let start: Double
    let end: Double
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

  func mergeOverlappingRanges(_ ranges: [TimeRange]) -> [TimeRange] {
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

  func validateTimeCoverage(existingCards: [ActivityCardData], newCards: [ActivityCardData])
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

  // MARK: - Logging helpers

  func buildDebugResponseBody(stdout: String, rawStdout: String) -> String {
    let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedRawStdout = rawStdout.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedStdout.isEmpty && trimmedRawStdout.isEmpty {
      return ""
    }

    var sections: [String] = []
    if !trimmedStdout.isEmpty {
      sections.append("[assistant_text]\n" + stdout)
    }
    if !trimmedRawStdout.isEmpty && trimmedRawStdout != trimmedStdout {
      sections.append("[raw_stdout]\n" + rawStdout)
    } else if sections.isEmpty {
      sections.append(rawStdout)
    }

    return sections.joined(separator: "\n\n")
  }

  func makeCtx(batchId: Int64?, operation: String, startedAt: Date, attempt: Int = 1)
    -> LLMCallContext
  {
    LLMCallContext(
      batchId: batchId,
      callGroupId: nil,
      attempt: attempt,
      provider: "chat_cli",
      model: tool.rawValue,
      operation: operation,
      requestMethod: nil,
      requestURL: nil,
      requestHeaders: nil,
      requestBody: nil,
      startedAt: startedAt
    )
  }

  func tokenHeaders(from usage: TokenUsage?) -> [String: String]? {
    guard let usage else { return nil }
    return [
      "x-usage-input": String(usage.input),
      "x-usage-cached-input": String(usage.cachedInput),
      "x-usage-output": String(usage.output),
    ]
  }

  func logSuccess(
    ctx: LLMCallContext, finishedAt: Date, stdout: String, stderr: String,
    responseHeaders: [String: String]? = nil
  ) {
    let separator = stdout.isEmpty || stderr.isEmpty ? "" : "\n\n[stderr]\n"
    let combined = stdout + separator + stderr
    let http = LLMHTTPInfo(
      httpStatus: nil, responseHeaders: responseHeaders, responseBody: combined.data(using: .utf8))
    LLMLogger.logSuccess(ctx: ctx, http: http, finishedAt: finishedAt)
  }

  func logFailure(
    ctx: LLMCallContext, finishedAt: Date, error: Error, stdout: String? = nil,
    stderr: String? = nil, run: ChatCLIRunResult? = nil
  ) {
    let http: LLMHTTPInfo?
    let out = stdout ?? ""
    let err = stderr ?? ""
    let commandDebug = chatCLICommandDebugText(for: run)

    if out.isEmpty && err.isEmpty && commandDebug.isEmpty {
      http = nil
    } else {
      let sections = [
        out.isEmpty ? nil : out,
        err.isEmpty ? nil : "[stderr]\n" + err,
        commandDebug.isEmpty ? nil : commandDebug,
      ].compactMap { $0 }
      let combined = sections.joined(separator: "\n\n")
      http = LLMHTTPInfo(
        httpStatus: nil, responseHeaders: nil, responseBody: combined.data(using: .utf8))
    }

    LLMLogger.logFailure(
      ctx: ctx, http: http, finishedAt: finishedAt, errorDomain: "ChatCLI",
      errorCode: (error as NSError).code, errorMessage: error.localizedDescription)
  }

  func chatCLICommandDebugText(for run: ChatCLIRunResult?) -> String {
    guard let run else { return "" }

    var sections: [String] = []
    if let shellCommand = run.shellCommand, !shellCommand.isEmpty {
      sections.append("[command]\n" + shellCommand)
    }
    if !run.environmentOverrides.isEmpty {
      let environmentText = run.environmentOverrides
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\(LoginShellRunner.shellEscape($0.value))" }
        .joined(separator: "\n")
      sections.append("[environment]\n" + environmentText)
    }
    return sections.joined(separator: "\n\n")
  }

  func makeLLMCall(start: Date, end: Date, input: String?, output: String?) -> LLMCall {
    LLMCall(timestamp: end, latency: end.timeIntervalSince(start), input: input, output: output)
  }

  /// Parse thinking content from Codex stderr (between "thinking" markers)
  func parseThinkingFromStderr(_ stderr: String) -> String? {
    // Codex outputs thinking like:
    // thinking
    // **Some thinking text**
    // thinking
    // **More thinking**
    // codex
    // <actual response>

    var thinkingParts: [String] = []
    let lines = stderr.components(separatedBy: .newlines)
    var inThinking = false
    var currentThinking: [String] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "thinking" {
        if inThinking {
          // End of thinking block
          if !currentThinking.isEmpty {
            thinkingParts.append(currentThinking.joined(separator: "\n"))
          }
          currentThinking = []
        }
        inThinking = !inThinking
      } else if inThinking && !trimmed.isEmpty {
        // Clean up markdown bold markers if present
        let cleaned = trimmed.replacingOccurrences(of: "**", with: "")
        currentThinking.append(cleaned)
      }
    }

    // Handle unclosed thinking block
    if inThinking && !currentThinking.isEmpty {
      thinkingParts.append(currentThinking.joined(separator: "\n"))
    }

    guard !thinkingParts.isEmpty else { return nil }
    return thinkingParts.joined(separator: "\n\n")
  }

}
