import AppKit
import Foundation

extension AgentCLISupporting {
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
    if let envelope = try? decoder.decode(AgentCLICardsEnvelope.self, from: data) {
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
        if let envelope = try? decoder.decode(AgentCLICardsEnvelope.self, from: slicedData) {
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

    var decodeProperties: [String: Any] = [
      "provider": "chat_cli",
      "provider_id": providerID.rawValue,
      "operation": "parse_cards",
      "tool": cliTool.rawValue,
    ]
    decodeProperties.merge(
      TelemetryErrorSanitizer.failureOutputProperties(output, prefix: "output")
    ) { _, new in new }
    decodeProperties.merge(
      TelemetryErrorSanitizer.failureOutputProperties(stderr, prefix: "stderr")
    ) { _, new in new }
    AnalyticsService.shared.capture("llm_decode_failed", decodeProperties)

    // Surface CLI error messages to the user if available
    if let cliError = extractCLIError(stdout: output, stderr: stderr) {
      throw NSError(domain: "ChatCLI", code: -33, userInfo: [NSLocalizedDescriptionKey: cliError])
    }

    throw NSError(
      domain: "ChatCLI", code: -32,
      userInfo: [NSLocalizedDescriptionKey: "Failed to decode activity cards"])
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

  func makeCtx(
    batchId: Int64?, operation: String, model: String, startedAt: Date, attempt: Int = 1
  )
    -> LLMCallContext
  {
    LLMCallContext(
      batchId: batchId,
      callGroupId: nil,
      attempt: attempt,
      provider: "chat_cli",
      providerID: providerID.rawValue,
      model: model,
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
      "x-usage-cache-creation-input": String(usage.cacheCreationInput),
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
    stderr: String? = nil, run: ChatCLIRunResult? = nil, usage: TokenUsage? = nil
  ) {
    let http: LLMHTTPInfo?
    let out = stdout ?? ""
    let err = stderr ?? ""
    let commandDebug = cliCommandDebugText(for: run)
    let usageHeaders = tokenHeaders(from: usage ?? run?.usage)

    if out.isEmpty && err.isEmpty && commandDebug.isEmpty && usageHeaders == nil {
      http = nil
    } else {
      let sections = [
        out.isEmpty ? nil : out,
        err.isEmpty ? nil : "[stderr]\n" + err,
        commandDebug.isEmpty ? nil : commandDebug,
      ].compactMap { $0 }
      let combined = sections.joined(separator: "\n\n")
      http = LLMHTTPInfo(
        httpStatus: nil,
        responseHeaders: usageHeaders,
        responseBody: combined.isEmpty ? nil : combined.data(using: .utf8)
      )
    }

    LLMLogger.logFailure(
      ctx: ctx, http: http, finishedAt: finishedAt, errorDomain: "ChatCLI",
      errorCode: (error as NSError).code, errorMessage: error.localizedDescription,
      failureStdout: stdout, failureStderr: stderr)
  }

  func cliCommandDebugText(for run: ChatCLIRunResult?) -> String {
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
