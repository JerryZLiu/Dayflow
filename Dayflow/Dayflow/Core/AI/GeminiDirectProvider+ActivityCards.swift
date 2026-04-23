import Foundation

extension GeminiDirectProvider {
  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let callStart = Date()

    // Convert observations to human-readable format for the prompt
    let transcriptText = observations.map { obs in
      let startTime = formatTimestampForPrompt(obs.startTs)
      let endTime = formatTimestampForPrompt(obs.endTs)
      return "[" + startTime + " - " + endTime + "]: " + obs.observation
    }.joined(separator: "\n")

    // Convert existing cards to JSON string with pretty printing
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let existingCardsJSON = try encoder.encode(context.existingCards)
    let existingCardsString = String(data: existingCardsJSON, encoding: .utf8) ?? "[]"
    let promptSections = GeminiPromptSections(overrides: GeminiPromptPreferences.load())

    let languageBlock =
      LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
      .map { "\n\n\($0)" } ?? ""

    let basePrompt = """
      # Timeline Card Generation

      You're writing someone's personal work journal. You'll get raw activity logs — screenshots, app switches, URLs — and your job is to turn them into timeline cards that help this person remember what they actually did.

      The test: when they scan their timeline tomorrow morning, each card should make them go "oh right, that."

      Write as if you ARE the person jotting down notes about their day. Not an analyst writing a report. Not a manager filing a status update.

      ---

      ## Card Structure

      Each card covers one cohesive chunk of activity, roughly 15–60 minutes.

      - Minimum 10 minutes per card. If something would be shorter, fold it into the neighboring card that makes the most sense.
      - Maximum 60 minutes. If a card runs longer, split it where the focus naturally shifts.
      - No gaps or overlaps between cards. If there's a real gap in the source data, preserve it. Otherwise, cards should meet cleanly.

      **When to start a new card:**
      1. What's the main thing happening right now?
      2. Does the next chunk of activity continue that same thing? → Keep extending.
      3. Is there a brief unrelated detour (<5 min)? → Log it as a distraction, keep the card going.
      4. Has the focus genuinely shifted for 10+ minutes? → New card.

      **When to merge with a previous card:**
      1. Is the previous card's main activity the same as what's happening now? (same PR, same feature, same codebase, same article) → Merge.
      2. Did the person just take a 2–5 minute break (X, messages, YouTube) and come back to the same thing? → That's a distraction, not a new card. Merge.
      3. Are two adjacent cards both "scrolling X with occasional work check-ins"? → Merge. The vibe didn't change.
      4. Only start a new card if the CORE INTENT changed for 10+ minutes.

      DEFAULT TO MERGING. Two 15-minute cards about the same work stream should almost never exist. If you're unsure whether to merge or split, merge.

      ---

      \(promptSections.title)

      ---

      \(promptSections.summary)

      ---

      \(promptSections.detailedSummary)

      \(languageBlock)

      ---

      ## Category

      \(categoriesSection(from: context.categories))

      ---

      ## Distractions

      A distraction is a brief (<5 min) unrelated interruption inside a card. Checking X for 2 minutes while debugging is a distraction. Spending 15 minutes on X is not a distraction — it's either part of the card's theme or it's a new card.

      Don't label related sub-tasks as distractions. Googling an error message while debugging isn't a distraction, it's part of debugging.

      ---

      ## App Sites

      Identify the main app or website for each card.

      - primary: the main app used in the card (canonical domain, lowercase, no protocol).
      - secondary: another meaningful app used, or the enclosing app (e.g., browser). Omit if there isn't a clear one.

      Be specific: docs.google.com not google.com, mail.google.com not google.com.

      Common mappings:
      - Figma → figma.com
      - Notion → notion.so
      - Google Docs → docs.google.com
      - Gmail → mail.google.com
      - VS Code → code.visualstudio.com
      - Xcode → developer.apple.com/xcode
      - Twitter/X → x.com
      - Zoom → zoom.us
      - ChatGPT → chatgpt.com

      ---

      ## Continuity Rules

      Your output cards must cover the same total time range as the previous cards plus any new observations. Think of previous cards as a draft you're revising and extending, not locked history.

      - Don't drop time segments that were previously covered.
      - If new observations extend beyond the previous range, add cards to cover the new time.
      - Preserve genuine gaps in the source data.

      Before generating output, review the previous cards and ask:
      - Could any two adjacent previous cards be the same activity session?
      - Does your first new card continue the last previous card's work?
      If yes to either, merge them in your output.

      INPUTS:
      Previous cards: \(existingCardsString)
      New observations: \(transcriptText)
      Return ONLY a JSON array with this EXACT structure:

              [
                {
                  "startTime": "1:12 AM",
                  "endTime": "1:30 AM",
                  "category": "",
                  "subcategory": "",
                  "title": "",
                  "summary": "",
                  "detailedSummary": "",
                  "distractions": [
                    {
                      "startTime": "1:15 AM",
                      "endTime": "1:18 AM",
                      "title": "",
                      "summary": ""
                    }
                  ],
                  "appSites": {
                    "primary": "",
                    "secondary": "
                  }
                }
              ]
      """

    // UNIFIED RETRY LOOP - Handles ALL errors comprehensively
    let maxRetries = 4
    var attempt = 0
    var lastError: Error?
    var actualPromptUsed = basePrompt
    var finalResponse = ""
    var finalCards: [ActivityCardData] = []

    var modelState = ModelRunState(models: modelPreference.orderedModels)
    let callGroupId = UUID().uuidString

    while attempt < maxRetries {
      do {
        // THE ENTIRE PIPELINE: Request → Parse → Validate
        print("🔄 Activity cards attempt \(attempt + 1)/\(maxRetries)")
        let activeModel = modelState.current
        let response = try await geminiCardsRequest(
          prompt: actualPromptUsed,
          batchId: batchId,
          groupId: callGroupId,
          model: activeModel,
          attempt: attempt + 1
        )

        let cards = try parseActivityCards(response)
        let normalizedCards = normalizeCards(cards, descriptors: context.categories)

        // Validation phase
        let (coverageValid, coverageError) = validateTimeCoverage(
          existingCards: context.existingCards, newCards: normalizedCards)
        let (durationValid, durationError) = validateTimeline(normalizedCards)

        if coverageValid && durationValid {
          // SUCCESS! All validations passed
          print("✅ Activity cards generation succeeded on attempt \(attempt + 1)")
          finalResponse = response
          finalCards = normalizedCards
          break
        }

        // Validation failed - this gets enhanced prompt treatment
        print("⚠️ Validation failed on attempt \(attempt + 1)")

        var errorMessages: [String] = []
        if !coverageValid && coverageError != nil {
          AnalyticsService.shared.captureValidationFailure(
            provider: "gemini",
            operation: "generate_activity_cards",
            validationType: "time_coverage",
            attempt: attempt + 1,
            model: modelState.current.rawValue,
            batchId: batchId,
            errorDetail: coverageError
          )
          errorMessages.append(
            """
            TIME COVERAGE ERROR:
            \(coverageError!)

            You MUST ensure your output cards collectively cover ALL time periods from the input cards. Do not drop any time segments.
            """)
        }

        if !durationValid && durationError != nil {
          AnalyticsService.shared.captureValidationFailure(
            provider: "gemini",
            operation: "generate_activity_cards",
            validationType: "duration",
            attempt: attempt + 1,
            model: modelState.current.rawValue,
            batchId: batchId,
            errorDetail: durationError
          )
          errorMessages.append(
            """
            DURATION ERROR:
            \(durationError!)

            REMINDER: All cards except the last one must be at least 10 minutes long. Please merge short activities into longer, more meaningful cards that tell a coherent story.
            """)
        }

        // Create enhanced prompt for validation retry
        actualPromptUsed =
          basePrompt + """


            PREVIOUS ATTEMPT FAILED - CRITICAL REQUIREMENTS NOT MET:

            \(errorMessages.joined(separator: "\n\n"))

            Please fix these issues and ensure your output meets all requirements.
            """

        // Brief delay for enhanced prompt retry
        if attempt < maxRetries - 1 {
          try await Task.sleep(nanoseconds: UInt64(1.0 * 1_000_000_000))
        }

      } catch {
        lastError = error
        print("❌ Attempt \(attempt + 1) failed: \(error.localizedDescription)")

        var appliedFallback = false
        if let nsError = error as NSError?,
          nsError.domain == "GeminiError",
          Self.capacityErrorCodes.contains(nsError.code),
          let transition = modelState.advance()
        {

          appliedFallback = true
          let reason = fallbackReason(for: nsError.code)
          print("↔️ Switching to \(transition.to.rawValue) after \(nsError.code)")

          Task { @MainActor in
            AnalyticsService.shared.capture(
              "llm_model_fallback",
              [
                "provider": "gemini",
                "operation": "generate_activity_cards",
                "from_model": transition.from.rawValue,
                "to_model": transition.to.rawValue,
                "reason": reason,
                "batch_id": batchId as Any,
              ])
          }
        }

        if !appliedFallback {
          // Normal error handling with backoff
          let strategy = classifyError(error)

          // Check if we should retry
          if strategy == .noRetry || attempt >= maxRetries - 1 {
            print("🚫 Not retrying: strategy=\(strategy), attempt=\(attempt + 1)/\(maxRetries)")
            throw error
          }

          // Apply appropriate delay based on error type
          let delay = delayForStrategy(strategy, attempt: attempt)
          if delay > 0 {
            print(
              "⏳ Waiting \(String(format: "%.1f", delay))s before retry (strategy: \(strategy))")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          }

          // For non-validation errors, reset to base prompt
          if strategy != .enhancedPrompt {
            actualPromptUsed = basePrompt
          }
        }
      }

      attempt += 1
    }

    // If we get here and finalCards is empty, all retries were exhausted
    if finalCards.isEmpty {
      print("❌ All \(maxRetries) attempts failed")
      throw lastError
        ?? NSError(
          domain: "GeminiError", code: 999,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Activity card generation failed after \(maxRetries) attempts"
          ])
    }

    let log = LLMCall(
      timestamp: callStart,
      latency: Date().timeIntervalSince(callStart),
      input: actualPromptUsed,
      output: finalResponse
    )

    return (finalCards, log)
  }

  func geminiCardsRequest(
    prompt: String, batchId: Int64?, groupId: String, model: GeminiModel, attempt: Int
  ) async throws -> String {
    let distractionSchema: [String: Any] = [
      "type": "OBJECT",
      "properties": [
        "startTime": ["type": "STRING"], "endTime": ["type": "STRING"], "title": ["type": "STRING"],
        "summary": ["type": "STRING"],
      ],
      "required": ["startTime", "endTime", "title", "summary"],
      "propertyOrdering": ["startTime", "endTime", "title", "summary"],
    ]

    let appSitesSchema: [String: Any] = [
      "type": "OBJECT",
      "properties": [
        "primary": ["type": "STRING"],
        "secondary": ["type": "STRING"],
      ],
      "required": [],
      "propertyOrdering": ["primary", "secondary"],
    ]

    let cardSchema: [String: Any] = [
      "type": "ARRAY",
      "items": [
        "type": "OBJECT",
        "properties": [
          "startTime": ["type": "STRING"], "endTime": ["type": "STRING"],
          "category": ["type": "STRING"],
          "subcategory": ["type": "STRING"], "title": ["type": "STRING"],
          "summary": ["type": "STRING"],
          "detailedSummary": ["type": "STRING"],
          "distractions": ["type": "ARRAY", "items": distractionSchema],
          "appSites": appSitesSchema,
        ],
        "required": [
          "startTime", "endTime", "category", "subcategory", "title", "summary", "detailedSummary",
        ],
        "propertyOrdering": [
          "startTime", "endTime", "category", "subcategory", "title", "summary", "detailedSummary",
          "distractions", "appSites",
        ],
      ],
    ]

    let generationConfig: [String: Any] = [
      "temperature": 0.3,
      "maxOutputTokens": 65536,
      "responseMimeType": "application/json",
      "responseSchema": cardSchema,
    ]

    let requestBody: [String: Any] = [
      "contents": [["parts": [["text": prompt]]]],
      "generationConfig": generationConfig,
    ]

    // Single API call (retry logic handled by outer loop in generateActivityCards)
    let urlWithKey = endpointForModel(model) + "?key=\(apiKey)"
    var request = URLRequest(url: URL(string: urlWithKey)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120  // 2 minutes timeout
    let requestStart = Date()

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

      let (data, response) = try await URLSession.shared.data(for: request)
      let requestDuration = Date().timeIntervalSince(requestStart)

      guard let httpResponse = response as? HTTPURLResponse else {
        print("🔴 Non-HTTP response received for cards request")
        throw NSError(
          domain: "GeminiError", code: 9, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"]
        )
      }

      logCallDuration(
        operation: "cards.generateContent", duration: requestDuration,
        status: httpResponse.statusCode)

      // Prepare logging context
      let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
        acc, kv in
        if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
          acc[k] = v.description
        }
      }
      let modelName = model.rawValue
      let ctx = LLMCallContext(
        batchId: batchId,
        callGroupId: groupId,
        attempt: attempt,
        provider: "gemini",
        model: modelName,
        operation: "generate_activity_cards",
        requestMethod: request.httpMethod,
        requestURL: request.url,
        requestHeaders: request.allHTTPHeaderFields,
        requestBody: request.httpBody,
        startedAt: requestStart
      )
      let httpInfo = LLMHTTPInfo(
        httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data)

      // Check HTTP status first - any 400+ is a failure
      if httpResponse.statusCode >= 400 {
        print("🔴 HTTP error status for cards: \(httpResponse.statusCode)")
        if let bodyText = String(data: data, encoding: .utf8) {
          print("   Response Body: \(truncate(bodyText, max: 2000))")
        } else {
          print("   Response Body: <non-UTF8 data, \(data.count) bytes>")
        }

        // Try to parse error details for better error message
        var errorMessage = "HTTP \(httpResponse.statusCode) error"
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = json["error"] as? [String: Any]
        {
          if let code = error["code"] { print("   Error Code: \(code)") }
          if let message = error["message"] as? String {
            print("   Error Message: \(message)")
            errorMessage = message
          }
          if let status = error["status"] { print("   Error Status: \(status)") }
          if let details = error["details"] { print("   Error Details: \(details)") }
        }

        // Log as failure and throw
        LLMLogger.logFailure(
          ctx: ctx,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "HTTPError",
          errorCode: httpResponse.statusCode,
          errorMessage: errorMessage
        )
        logGeminiFailure(
          context: "cards.httpError", attempt: attempt, response: response, data: data, error: nil)
        throw NSError(
          domain: "GeminiError", code: httpResponse.statusCode,
          userInfo: [NSLocalizedDescriptionKey: errorMessage])
      }

      // HTTP status is good (200-299), now validate content
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let candidates = json["candidates"] as? [[String: Any]],
        let firstCandidate = candidates.first,
        let content = firstCandidate["content"] as? [String: Any]
      else {
        LLMLogger.logFailure(
          ctx: ctx,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "ParseError",
          errorCode: 9,
          errorMessage: "Invalid response format - missing candidates or content"
        )
        logGeminiFailure(
          context: "cards.generateContent.invalidFormat", attempt: attempt, response: response,
          data: data, error: nil)
        throw NSError(
          domain: "GeminiError", code: 9,
          userInfo: [
            NSLocalizedDescriptionKey: "Invalid response format - missing candidates or content"
          ])
      }

      // Check for parts array - if missing, this is likely a schema validation failure
      guard let parts = content["parts"] as? [[String: Any]],
        let firstPart = parts.first,
        let text = firstPart["text"] as? String
      else {
        LLMLogger.logFailure(
          ctx: ctx,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "ParseError",
          errorCode: 9,
          errorMessage: "Schema validation likely failed - no content parts in response"
        )
        logGeminiFailure(
          context: "cards.generateContent.emptyContent", attempt: attempt, response: response,
          data: data, error: nil)
        throw NSError(
          domain: "GeminiError", code: 9,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Schema validation likely failed - no content parts in response"
          ])
      }

      // Everything succeeded - log success and return
      LLMLogger.logSuccess(
        ctx: ctx,
        http: httpInfo,
        finishedAt: Date()
      )

      return text

    } catch {
      // Only log if this is a network/transport error (not our custom GeminiError which was already logged)
      if (error as NSError).domain != "GeminiError" {
        let modelName = model.rawValue
        let ctx = LLMCallContext(
          batchId: batchId,
          callGroupId: groupId,
          attempt: attempt,
          provider: "gemini",
          model: modelName,
          operation: "generate_activity_cards",
          requestMethod: request.httpMethod,
          requestURL: request.url,
          requestHeaders: request.allHTTPHeaderFields,
          requestBody: request.httpBody,
          startedAt: requestStart
        )
        LLMLogger.logFailure(
          ctx: ctx,
          http: nil,
          finishedAt: Date(),
          errorDomain: (error as NSError).domain,
          errorCode: (error as NSError).code,
          errorMessage: (error as NSError).localizedDescription
        )
      }

      // Log detailed error information
      print("🔴 GEMINI CARDS REQUEST FAILED:")
      print("   Error Type: \(type(of: error))")
      print("   Error Description: \(error.localizedDescription)")

      // Log URLError details if applicable
      if let urlError = error as? URLError {
        print("   URLError Code: \(urlError.code.rawValue) (\(urlError.code))")
        if let failingURL = urlError.failingURL {
          print("   Failing URL: \(failingURL.absoluteString)")
        }

        // Check for specific network errors
        switch urlError.code {
        case .timedOut:
          print("   ⏱️ REQUEST TIMED OUT")
        case .notConnectedToInternet:
          print("   📵 NO INTERNET CONNECTION")
        case .networkConnectionLost:
          print("   📡 NETWORK CONNECTION LOST")
        case .cannotFindHost:
          print("   🔍 CANNOT FIND HOST")
        case .cannotConnectToHost:
          print("   🚫 CANNOT CONNECT TO HOST")
        case .badServerResponse:
          print("   💔 BAD SERVER RESPONSE")
        default:
          break
        }
      }

      // Log NSError details if applicable
      if let nsError = error as NSError? {
        print("   NSError Domain: \(nsError.domain)")
        print("   NSError Code: \(nsError.code)")
        if !nsError.userInfo.isEmpty {
          print("   NSError UserInfo: \(nsError.userInfo)")
        }
      }

      // Log transport/parse error
      logGeminiFailure(
        context: "cards.generateContent.catch", attempt: attempt, response: nil, data: nil,
        error: error)

      // Rethrow error (outer loop in generateActivityCards handles retries)
      throw error
    }
  }

  func parseActivityCards(_ response: String) throws -> [ActivityCardData] {
    guard let data = response.data(using: .utf8) else {
      print(
        "🔎 GEMINI DEBUG: parseActivityCards received non-UTF8 or empty response: \(truncate(response, max: 400))"
      )
      throw NSError(
        domain: "GeminiError", code: 10,
        userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
    }

    // Need to map the response format to our ActivityCard format
    struct GeminiActivityCard: Codable {
      let startTime: String
      let endTime: String
      let category: String
      let subcategory: String
      let title: String
      let summary: String
      let detailedSummary: String
      let distractions: [GeminiDistraction]?
      let appSites: AppSites?

      // Make distractions optional with default nil
      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try container.decode(String.self, forKey: .startTime)
        endTime = try container.decode(String.self, forKey: .endTime)
        category = try container.decode(String.self, forKey: .category)
        subcategory = try container.decode(String.self, forKey: .subcategory)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        detailedSummary = try container.decode(String.self, forKey: .detailedSummary)
        distractions = try container.decodeIfPresent(
          [GeminiDistraction].self, forKey: .distractions)
        appSites = try container.decodeIfPresent(AppSites.self, forKey: .appSites)
      }
    }

    struct GeminiDistraction: Codable {
      let startTime: String
      let endTime: String
      let title: String
      let summary: String
    }

    let geminiCards: [GeminiActivityCard]
    do {
      geminiCards = try JSONDecoder().decode([GeminiActivityCard].self, from: data)
    } catch {
      let snippet = truncate(String(data: data, encoding: .utf8) ?? "<non-utf8>", max: 1200)
      print(
        "🔎 GEMINI DEBUG: parseActivityCards JSON decode failed: \(error.localizedDescription) bodySnippet=\(snippet)"
      )
      throw error
    }

    // Convert to our ActivityCard format
    return geminiCards.map { geminiCard in
      ActivityCardData(
        startTime: geminiCard.startTime,
        endTime: geminiCard.endTime,
        category: geminiCard.category,
        subcategory: geminiCard.subcategory,
        title: geminiCard.title,
        summary: geminiCard.summary,
        detailedSummary: geminiCard.detailedSummary,
        distractions: geminiCard.distractions?.map { d in
          Distraction(
            startTime: d.startTime,
            endTime: d.endTime,
            title: d.title,
            summary: d.summary
          )
        },
        appSites: geminiCard.appSites
      )
    }
  }

  // (no local logging helpers needed; centralized via LLMLogger)

  struct TimeRange {
    let start: Double  // minutes from midnight
    let end: Double
  }

  func timeToMinutes(_ timeStr: String) -> Double {
    // Handle both "10:30 AM" and "05:30" formats
    if timeStr.contains("AM") || timeStr.contains("PM") {
      // Clock format - parse as date
      let formatter = DateFormatter()
      formatter.dateFormat = "h:mm a"
      formatter.locale = Locale(identifier: "en_US_POSIX")

      if let date = formatter.date(from: timeStr) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
      }
      return 0
    } else {
      // MM:SS format - convert to minutes
      let seconds = parseVideoTimestamp(timeStr)
      return Double(seconds) / 60.0
    }
  }

  func mergeOverlappingRanges(_ ranges: [TimeRange]) -> [TimeRange] {
    guard !ranges.isEmpty else { return [] }

    // Sort by start time
    let sorted = ranges.sorted { $0.start < $1.start }
    var merged: [TimeRange] = []

    for range in sorted {
      if merged.isEmpty || range.start > merged.last!.end + 1 {
        // No overlap - add as new range
        merged.append(range)
      } else {
        // Overlap or adjacent - merge with last range
        let last = merged.removeLast()
        merged.append(TimeRange(start: last.start, end: max(last.end, range.end)))
      }
    }

    return merged
  }

  func validateTimeCoverage(existingCards: [ActivityCardData], newCards: [ActivityCardData])
    -> (isValid: Bool, error: String?)
  {
    guard !existingCards.isEmpty else {
      return (true, nil)
    }

    // Extract time ranges from input cards
    var inputRanges: [TimeRange] = []
    for card in existingCards {
      let startMin = timeToMinutes(card.startTime)
      var endMin = timeToMinutes(card.endTime)
      if endMin < startMin {  // Handle day rollover
        endMin += 24 * 60
      }
      inputRanges.append(TimeRange(start: startMin, end: endMin))
    }

    // Merge overlapping/adjacent ranges
    let mergedInputRanges = mergeOverlappingRanges(inputRanges)

    // Extract time ranges from output cards (Fix #1: Skip zero or negative duration cards)
    var outputRanges: [TimeRange] = []
    for card in newCards {
      let startMin = timeToMinutes(card.startTime)
      var endMin = timeToMinutes(card.endTime)
      if endMin < startMin {  // Handle day rollover
        endMin += 24 * 60
      }
      // Skip zero or very short duration cards (less than 0.1 minutes = 6 seconds)
      guard endMin - startMin >= 0.1 else {
        continue
      }
      outputRanges.append(TimeRange(start: startMin, end: endMin))
    }

    // Check coverage with 3-minute flexibility
    let flexibility = 3.0  // minutes
    var uncoveredSegments: [(start: Double, end: Double)] = []

    for inputRange in mergedInputRanges {
      // Check if this input range is covered by output ranges
      var coveredStart = inputRange.start
      var safetyCounter = 10000  // Fix #3: Safety cap to prevent infinite loops

      while coveredStart < inputRange.end && safetyCounter > 0 {
        safetyCounter -= 1
        // Find an output range that covers this point
        var foundCoverage = false

        for outputRange in outputRanges {
          // Check if this output range covers the current point (with flexibility)
          if outputRange.start - flexibility <= coveredStart
            && coveredStart <= outputRange.end + flexibility
          {
            // Move coveredStart to the end of this output range (Fix #2: Force progress)
            let newCoveredStart = outputRange.end
            // Ensure we make at least minimal progress (0.01 minutes = 0.6 seconds)
            coveredStart = max(coveredStart + 0.01, newCoveredStart)
            foundCoverage = true
            break
          }
        }

        if !foundCoverage {
          // Find the next covered point
          var nextCovered = inputRange.end
          for outputRange in outputRanges {
            if outputRange.start > coveredStart && outputRange.start < nextCovered {
              nextCovered = outputRange.start
            }
          }

          // Add uncovered segment
          if nextCovered > coveredStart {
            uncoveredSegments.append((start: coveredStart, end: min(nextCovered, inputRange.end)))
            coveredStart = nextCovered
          } else {
            // No more coverage found, add remaining segment and break
            uncoveredSegments.append((start: coveredStart, end: inputRange.end))
            break
          }
        }
      }

      // Check if safety counter was exhausted
      if safetyCounter == 0 {
        return (
          false,
          "Time coverage validation loop exceeded safety limit - possible infinite loop detected"
        )
      }
    }

    // Check if uncovered segments are significant
    if !uncoveredSegments.isEmpty {
      var uncoveredDesc: [String] = []
      for segment in uncoveredSegments {
        let duration = segment.end - segment.start
        if duration > flexibility {  // Only report significant gaps
          let startTime = minutesToTimeString(segment.start)
          let endTime = minutesToTimeString(segment.end)
          uncoveredDesc.append("\(startTime)-\(endTime) (\(Int(duration)) min)")
        }
      }

      if !uncoveredDesc.isEmpty {
        // Build detailed error message with input/output cards
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

  func validateTimeline(_ cards: [ActivityCardData]) -> (isValid: Bool, error: String?) {
    for (index, card) in cards.enumerated() {
      let startTime = card.startTime
      let endTime = card.endTime

      var durationMinutes: Double = 0

      // Check if times are in clock format (contains AM/PM)
      if startTime.contains("AM") || startTime.contains("PM") {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if let startDate = formatter.date(from: startTime),
          let endDate = formatter.date(from: endTime)
        {

          var adjustedEndDate = endDate
          // Handle day rollover (e.g., 11:30 PM to 12:30 AM)
          if endDate < startDate {
            adjustedEndDate =
              Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
          }

          durationMinutes = adjustedEndDate.timeIntervalSince(startDate) / 60.0
        } else {
          // Failed to parse clock times
          durationMinutes = 0
        }
      } else {
        // Parse MM:SS format
        let startSeconds = parseVideoTimestamp(startTime)
        let endSeconds = parseVideoTimestamp(endTime)
        durationMinutes = Double(endSeconds - startSeconds) / 60.0
      }

      // Check if card is too short (except for last card)
      if durationMinutes < 10 && index < cards.count - 1 {
        return (
          false,
          "Card \(index + 1) '\(card.title)' is only \(String(format: "%.1f", durationMinutes)) minutes long"
        )
      }
    }

    return (true, nil)
  }

  func minutesToTimeString(_ minutes: Double) -> String {
    let hours = (Int(minutes) / 60) % 24  // Handle > 24 hours
    let mins = Int(minutes) % 60
    let period = hours < 12 ? "AM" : "PM"
    var displayHour = hours % 12
    if displayHour == 0 {
      displayHour = 12
    }
    return String(format: "%d:%02d %@", displayHour, mins, period)
  }

}
