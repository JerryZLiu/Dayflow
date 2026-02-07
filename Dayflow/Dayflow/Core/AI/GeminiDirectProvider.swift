//
//  GeminiDirectProvider.swift
//  Dayflow
//

import Foundation

final class GeminiDirectProvider {
    private let apiKey: String
    private let fileEndpoint = "https://generativelanguage.googleapis.com/upload/v1beta/files"
    private let modelPreference: GeminiModelPreference

    private static let capacityErrorCodes: Set<Int> = [403, 429, 503]

    private struct ModelRunState {
        private let models: [GeminiModel]
        private(set) var index: Int = 0

        init(models: [GeminiModel]) {
            self.models = models.isEmpty ? GeminiModelPreference.default.orderedModels : models
        }

        var current: GeminiModel {
            models[min(index, models.count - 1)]
        }

        mutating func advance() -> (from: GeminiModel, to: GeminiModel)? {
            guard index < models.count - 1 else { return nil }
            let fromModel = models[index]
            index += 1
            return (fromModel, models[index])
        }
    }

    private func endpointForModel(_ model: GeminiModel) -> String {
        return "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent"
    }
    
    init(apiKey: String, preference: GeminiModelPreference = .default) {
        self.apiKey = apiKey
        self.modelPreference = preference
    }

    private func categoriesSection(from descriptors: [LLMCategoryDescriptor]) -> String {
        guard !descriptors.isEmpty else {
            return "USER CATEGORIES: No categories configured. Use consistent labels based on the activity story."
        }

        let allowed = descriptors.map { "\"\($0.name)\"" }.joined(separator: ", ")
        var lines: [String] = ["USER CATEGORIES (choose exactly one label):"]

        for (index, descriptor) in descriptors.enumerated() {
            var desc = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if descriptor.isIdle && desc.isEmpty {
                desc = "Use when the user is idle for most of this period."
            }
            let suffix = desc.isEmpty ? "" : " — \(desc)"
            lines.append("\(index + 1). \"\(descriptor.name)\"\(suffix)")
        }

        if let idle = descriptors.first(where: { $0.isIdle }) {
            lines.append("Only use \"\(idle.name)\" when the user is idle for more than half of the timeframe. Otherwise pick the closest non-idle label.")
        }

        lines.append("Return the category exactly as written. Allowed values: [\(allowed)].")
        return lines.joined(separator: "\n")
    }

    private func normalizeCategory(_ raw: String, descriptors: [LLMCategoryDescriptor]) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return descriptors.first?.name ?? "" }
        let normalized = cleaned.lowercased()
        if let match = descriptors.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }) {
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

    private func normalizeCards(_ cards: [ActivityCardData], descriptors: [LLMCategoryDescriptor]) -> [ActivityCardData] {
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

    private func truncate(_ text: String, max: Int = 2000) -> String {
        if text.count <= max { return text }
        let endIdx = text.index(text.startIndex, offsetBy: max)
        return String(text[..<endIdx]) + "…(truncated)"
    }

    private func headerValue(_ response: URLResponse?, _ name: String) -> String? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: name)
    }

    private func logGeminiFailure(context: String, attempt: Int? = nil, response: URLResponse?, data: Data?, error: Error?) {
        var parts: [String] = []
        parts.append("🔎 GEMINI DEBUG: context=\(context)")
        if let attempt { parts.append("attempt=\(attempt)") }
        if let http = response as? HTTPURLResponse {
            parts.append("status=\(http.statusCode)")
            let reqId = headerValue(response, "X-Goog-Request-Id") ?? headerValue(response, "x-request-id")
            if let reqId { parts.append("requestId=\(reqId)") }
            if let ct = headerValue(response, "Content-Type") { parts.append("contentType=\(ct)") }
        }
        if let error = error as NSError? {
            parts.append("error=\(error.domain)#\(error.code): \(error.localizedDescription)")
        }
        print(parts.joined(separator: " "))

        if let data {
            if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let keys = Array(jsonObj.keys).sorted().joined(separator: ", ")
                if let err = jsonObj["error"] as? [String: Any] {
                    let message = err["message"] as? String ?? "<none>"
                    let status = err["status"] as? String ?? "<none>"
                    let code = err["code"] as? Int ?? -1
                    print("🔎 GEMINI DEBUG: errorObject code=\(code) status=\(status) message=\(truncate(message, max: 500))")
                } else {
                    print("🔎 GEMINI DEBUG: jsonKeys=[\(keys)]")
                }
            }
            if let body = String(data: data, encoding: .utf8) {
                print("🔎 GEMINI DEBUG: bodySnippet=\(truncate(body, max: 1200))")
            } else {
                print("🔎 GEMINI DEBUG: bodySnippet=<non-UTF8 data length=\(data.count) bytes>")
            }
        }
    }
    
    private func logCallDuration(operation: String, duration: TimeInterval, status: Int? = nil) {
        let statusText = status.map { " status=\($0)" } ?? ""
        print("⏱️ [Gemini] \(operation) \(String(format: "%.2f", duration))s\(statusText)")
    }

    // Gemini sometimes streams a well-formed JSON payload before aborting with HTTP 503.
    // When this happens we want to salvage the first JSON object so the caller can proceed.
    private func extractFirstJSONObject(from body: String) -> String? {
        guard let start = body.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) else { return nil }
        guard body[start] == "{" else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start

        while index < body.endIndex {
            let ch = body[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(body[start...index])
                    }
                default:
                    break
                }
            }

            index = body.index(after: index)
        }

        return nil
    }

    private func recover503CandidateText(_ data: Data) -> String? {
        guard let bodyString = String(data: data, encoding: .utf8) else { return nil }
        guard let objectString = extractFirstJSONObject(from: bodyString) else { return nil }
        guard let objectData = objectString.data(using: .utf8) else { return nil }

        guard
            let json = try? JSONSerialization.jsonObject(with: objectData) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else {
            return nil
        }

        return text
    }
    
    /// Internal method to transcribe video data after compositing from screenshots.
    ///
    /// - Parameters:
    ///   - videoData: The video file data
    ///   - mimeType: MIME type of the video
    ///   - batchStartTime: When this batch started (for absolute timestamp calculation)
    ///   - videoDuration: Duration of the compressed video (in seconds)
    ///   - realDuration: Actual real-world duration this video represents (in seconds)
    ///   - compressionFactor: How much the timeline is compressed (e.g., 10 = 10x faster)
    ///   - batchId: Optional batch ID for logging
    private func transcribeVideoData(
        _ videoData: Data,
        mimeType: String,
        batchStartTime: Date,
        videoDuration: TimeInterval,
        realDuration: TimeInterval,
        compressionFactor: TimeInterval,
        batchId: Int64?
    ) async throws -> (observations: [Observation], log: LLMCall) {
        let callStart = Date()

        // First, save video data to a temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try videoData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fileURI = try await uploadAndAwait(tempURL, mimeType: mimeType, key: apiKey).1

        // Format compressed video duration for the prompt
        let durationMinutes = Int(videoDuration / 60)
        let durationSeconds = Int(videoDuration.truncatingRemainder(dividingBy: 60))
        let durationString = String(format: "%02d:%02d", durationMinutes, durationSeconds)

        // realDuration is available via compressionFactor if needed for debugging
        
        let finalTranscriptionPrompt = """
        # Screen Recording Transcription (Reconstruct Mode)

        Watch this screen recording and create an activity log detailed enough that someone could reconstruct the session.

        CRITICAL: This video is exactly \(durationString) long. ALL timestamps must be within 00:00 to \(durationString). No gaps.

        For each segment, ask yourself:
        "What EXACTLY did they do? What SPECIFIC things can I see?"

        Capture:
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

        Segments:
        - 3-8 segments total
        - You may use 1 segment only if the user appears idle for most of the recording
        - Group by GOAL not app (IDE + Terminal + Browser for the same task = 1 segment)
        - Do not create gaps; cover the full timeline

        Return ONLY JSON in this format:
        [
          {
            "startTimestamp": "MM:SS",
            "endTimestamp": "MM:SS",
            "description": "1-3 sentences with specific details"
          }
        ]
        """

        // UNIFIED RETRY LOOP - Handles ALL errors comprehensively
        let maxRetries = 3
        var attempt = 0
        var lastError: Error?
        var finalResponse = ""
        var finalObservations: [Observation] = []

        var modelState = ModelRunState(models: Array(modelPreference.orderedModels.reversed()))
        let callGroupId = UUID().uuidString

        while attempt < maxRetries {
            do {
                print("🔄 Video transcribe attempt \(attempt + 1)/\(maxRetries)")
                let activeModel = modelState.current
                let (response, usedModel) = try await geminiTranscribeRequest(
                    fileURI: fileURI,
                    mimeType: mimeType,
                    prompt: finalTranscriptionPrompt,
                    batchId: batchId,
                    groupId: callGroupId,
                    model: activeModel,
                    attempt: attempt + 1
                )

                let videoTranscripts = try parseTranscripts(response)

                // Convert video transcripts to observations with proper Unix timestamps
                // Timestamps from Gemini are in compressed video time, so we expand them
                // by the compression factor to get real-world timestamps.
                var hasValidationErrors = false
                let observations = videoTranscripts.compactMap { chunk -> Observation? in
                    let compressedStartSeconds = parseVideoTimestamp(chunk.startTimestamp)
                    let compressedEndSeconds = parseVideoTimestamp(chunk.endTimestamp)

                    // Validate timestamps are within compressed video duration (with small tolerance)
                    let tolerance: TimeInterval = 10.0 // 10 seconds tolerance in compressed time
                    if Double(compressedStartSeconds) < -tolerance || Double(compressedEndSeconds) > videoDuration + tolerance {
                        print("❌ VALIDATION ERROR: Observation timestamps (\(chunk.startTimestamp) - \(chunk.endTimestamp)) exceed video duration \(durationString)!")
                        hasValidationErrors = true
                        return nil
                    }

                    // Expand timestamps by compression factor to get real-world time
                    let realStartSeconds = TimeInterval(compressedStartSeconds) * compressionFactor
                    let realEndSeconds = TimeInterval(compressedEndSeconds) * compressionFactor

                    let startDate = batchStartTime.addingTimeInterval(realStartSeconds)
                    let endDate = batchStartTime.addingTimeInterval(realEndSeconds)

                    print("📐 Timestamp expansion: \(chunk.startTimestamp)-\(chunk.endTimestamp) → \(Int(realStartSeconds))s-\(Int(realEndSeconds))s real")

                    return Observation(
                        id: nil,
                        batchId: 0, // Will be set when saved
                        startTs: Int(startDate.timeIntervalSince1970),
                        endTs: Int(endDate.timeIntervalSince1970),
                        observation: chunk.description,
                        metadata: nil,
                        llmModel: usedModel,
                        createdAt: Date()
                    )
                }

                // If we had validation errors, throw to trigger retry
                if hasValidationErrors {
                    AnalyticsService.shared.captureValidationFailure(
                        provider: "gemini",
                        operation: "transcribe",
                        validationType: "timestamp_exceeds_duration",
                        attempt: attempt + 1,
                        model: activeModel.rawValue,
                        batchId: batchId,
                        errorDetail: "Observations exceeded video duration \(durationString)"
                    )
                    throw NSError(domain: "GeminiProvider", code: 100, userInfo: [
                        NSLocalizedDescriptionKey: "Gemini generated observations with timestamps exceeding video duration. Video is \(durationString) long but observations extended beyond this."
                    ])
                }

                // Ensure we have at least one observation
                if observations.isEmpty {
                    AnalyticsService.shared.captureValidationFailure(
                        provider: "gemini",
                        operation: "transcribe",
                        validationType: "empty_observations",
                        attempt: attempt + 1,
                        model: activeModel.rawValue,
                        batchId: batchId,
                        errorDetail: "No valid observations after filtering"
                    )
                    throw NSError(domain: "GeminiProvider", code: 101, userInfo: [
                        NSLocalizedDescriptionKey: "No valid observations generated after filtering out invalid timestamps"
                    ])
                }

                // SUCCESS! All validations passed
                print("✅ Video transcription succeeded on attempt \(attempt + 1)")
                finalResponse = response
                finalObservations = observations
                break

            } catch {
                lastError = error
                print("❌ Attempt \(attempt + 1) failed: \(error.localizedDescription)")

                var appliedFallback = false
                if let nsError = error as NSError?,
                   nsError.domain == "GeminiError",
                   Self.capacityErrorCodes.contains(nsError.code),
                   let transition = modelState.advance() {

                    appliedFallback = true
                    let reason = fallbackReason(for: nsError.code)
                    print("↔️ Switching to \(transition.to.rawValue) after \(nsError.code)")

                    Task { @MainActor in
                        AnalyticsService.shared.capture("llm_model_fallback", [
                            "provider": "gemini",
                            "operation": "transcribe",
                            "from_model": transition.from.rawValue,
                            "to_model": transition.to.rawValue,
                            "reason": reason,
                            "batch_id": batchId as Any
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
                        print("⏳ Waiting \(String(format: "%.1f", delay))s before retry (strategy: \(strategy))")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }

            attempt += 1
        }

        // Check if we succeeded
        guard !finalObservations.isEmpty else {
            throw lastError ?? NSError(domain: "GeminiProvider", code: 102, userInfo: [
                NSLocalizedDescriptionKey: "Video transcription failed after \(maxRetries) attempts"
            ])
        }
        
        let log = LLMCall(
            timestamp: callStart,
            latency: Date().timeIntervalSince(callStart),
            input: finalTranscriptionPrompt,
            output: finalResponse
        )

        return (finalObservations, log)
    }
    
    // MARK: - Error Classification for Unified Retry

    private enum RetryStrategy {
        case immediate           // Parsing/encoding errors - retry immediately
        case shortBackoff       // Network timeouts - retry with 2s, 4s, 8s
        case longBackoff        // Rate limits - retry with 30s, 60s, 120s
        case enhancedPrompt     // Validation errors - retry with enhanced prompt
        case noRetry            // Auth/permanent errors - don't retry
    }

    private func fallbackReason(for code: Int) -> String {
        switch code {
        case 429:
            return "rate_limit_429"
        case 503:
            return "service_unavailable_503"
        case 403:
            return "forbidden_quota_403"
        default:
            return "http_\(code)"
        }
    }

    private func classifyError(_ error: Error) -> RetryStrategy {
        // JSON/Parsing errors - should retry immediately (different LLM response likely)
        if error is DecodingError {
            return .immediate
        }

        // Network/Transport errors
        if let nsError = error as NSError? {
            switch nsError.domain {
            case NSURLErrorDomain:
                switch nsError.code {
                case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                     NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                     NSURLErrorNotConnectedToInternet:
                    return .shortBackoff
                default:
                    return .noRetry
                }

            case "GeminiError":
                switch nsError.code {
                // Rate limiting
                case 429:
                    return .longBackoff
                // Server errors
                case 500...599:
                    return .shortBackoff
                // Auth errors
                case 401, 403:
                    return .noRetry
                // Parsing/encoding errors
                case 7, 9, 10:
                    return .immediate
                // Client errors (bad request, etc)
                case 400...499:
                    return .noRetry
                default:
                    return .shortBackoff
                }

            default:
                break
            }
        }

        // Default: short backoff for unknown errors
        return .shortBackoff
    }

    private func delayForStrategy(_ strategy: RetryStrategy, attempt: Int) -> TimeInterval {
        switch strategy {
        case .immediate:
            return 0
        case .shortBackoff:
            return pow(2.0, Double(attempt)) * 2.0  // 2s, 4s, 8s
        case .longBackoff:
            return Double(min(3, attempt + 1)) // 1s, 2s, 3s (capped)
        case .enhancedPrompt:
            return 1.0  // Brief delay for enhanced prompt
        case .noRetry:
            return 0
        }
    }

    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
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

        let languageBlock = LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
            .map { "\n\n\($0)" } ?? ""

        let basePrompt = """
        You are a digital anthropologist, observing a user's raw activity log. Your goal is to synthesize this log into a high-level, human-readable story of their session, presented as a series of timeline cards.
        THE GOLDEN RULE:
            Create cards that narrate one cohesive session, aiming for 15–60 minutes. Keep every card ≥10 minutes, split up any cards that are >60 minutes, and if a prospective card would be <10 minutes, merge it into the neighboring card that preserves the best story.

            CONTINUITY RULE:
            You may adjust boundaries for clarity, but never introduce new gaps or overlaps. Preserve any original gaps in the source timeline and keep adjacent covered
          spans meeting cleanly.

            CORE DIRECTIVES:
            - Theme Test Before Extending: Extend the current card only when the new observations continue the same dominant activity. Shifts shorter than 10 minutes should
          be logged as distractions or merged into the adjacent segment that keeps the theme coherent; shifts ≥10 minutes become new cards.
        
        \(promptSections.title)

        \(promptSections.summary)

        \(categoriesSection(from: context.categories))

        \(promptSections.detailedSummary)

        \(languageBlock)

        APP SITES (Website Logos)
        Identify the main app or website used for each card and include an appSites object.

        Rules:
        - primary: The canonical domain (or canonical product path) of the main app used in the card.
        - secondary: Another meaningful app used during this session OR the enclosing app (e.g., browser), if relevant.
        - Format: lower-case, no protocol, no query or fragments. Use product subdomains/paths when they are canonical (e.g., docs.google.com for Google Docs).
        - Be specific: prefer product domains over generic ones (docs.google.com over google.com).
        - If you cannot determine a secondary, omit it.
        - Do not invent brands; rely on evidence from observations.

        Canonical examples:
        - Figma → figma.com
        - Notion → notion.so
        - Google Docs → docs.google.com
        - Gmail → mail.google.com
        - Google Sheets → sheets.google.com
        - Zoom → zoom.us
        - ChatGPT → chatgpt.com
        - VS Code → code.visualstudio.com
        - Xcode → developer.apple.com/xcode
        - Chrome → google.com/chrome
        - Safari → apple.com/safari
        - Twitter/X → x.com

        YOUR MENTAL MODEL (How to Decide):
        Before making a decision, ask yourself these questions in order:

        What is the dominant theme of the current card?
        Do the new observations continue or relate to this theme? If yes, extend the card.
        Is this a brief (<5 min) and unrelated pivot? If yes, add it as a distraction to the current card and continue extending.
        Is this a sustained shift in focus (>15 min) that represents a different activity category or goal? If yes, create a new card regardless of the current card's length.

        DISTRACTIONS:
        A "distraction" is a brief (<5 min) and unrelated activity that interrupts the main theme of a card. Sustained activities (>5 min) are NOT distractions - they either belong to the current theme or warrant a new card. Don't label related sub-tasks as distractions.

        INPUT/OUTPUT CONTRACT:
        Your output cards MUST cover the same total time range as the "Previous cards" plus any new time from observations.
        - If Previous cards span 11:11 AM - 11:53 AM, your output must also cover 11:11 AM - 11:53 AM (you may restructure the cards, but don't drop time segments)
        - If new observations extend beyond the previous cards' time range, create additional cards to cover that new time
        - The only exception: if there's a genuine gap between previous cards (e.g., 11:27 AM to 11:33 AM with no activity), preserve that gap
        - Think of "Previous cards" as a DRAFT that you're revising/extending, not as locked history

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
                let (coverageValid, coverageError) = validateTimeCoverage(existingCards: context.existingCards, newCards: normalizedCards)
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
                    errorMessages.append("""
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
                    errorMessages.append("""
                    DURATION ERROR:
                    \(durationError!)

                    REMINDER: All cards except the last one must be at least 10 minutes long. Please merge short activities into longer, more meaningful cards that tell a coherent story.
                    """)
                }

                // Create enhanced prompt for validation retry
                actualPromptUsed = basePrompt + """


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
                   let transition = modelState.advance() {

                    appliedFallback = true
                    let reason = fallbackReason(for: nsError.code)
                    print("↔️ Switching to \(transition.to.rawValue) after \(nsError.code)")

                    Task { @MainActor in
                        AnalyticsService.shared.capture("llm_model_fallback", [
                            "provider": "gemini",
                            "operation": "generate_activity_cards",
                            "from_model": transition.from.rawValue,
                            "to_model": transition.to.rawValue,
                            "reason": reason,
                            "batch_id": batchId as Any
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
                        print("⏳ Waiting \(String(format: "%.1f", delay))s before retry (strategy: \(strategy))")
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
            throw lastError ?? NSError(domain: "GeminiError", code: 999, userInfo: [
                NSLocalizedDescriptionKey: "Activity card generation failed after \(maxRetries) attempts"
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
    
    
    private func uploadAndAwait(_ fileURL: URL, mimeType: String, key: String, maxWaitTime: TimeInterval = 3 * 60) async throws -> (fileSize: Int64, fileURI: String) {
        let fileData = try Data(contentsOf: fileURL)
        let fileSize = fileData.count

        // Full cycle retry: upload + processing
        let maxCycles = 3
        var lastError: Error?

        for cycle in 1...maxCycles {
            print("🔄 Upload+Processing cycle \(cycle)/\(maxCycles)")

            var uploadedFileURI: String? = nil

            // Upload with retries
            let maxUploadRetries = 3
            var uploadAttempt = 0

            while uploadAttempt < maxUploadRetries {
                do {
                    uploadedFileURI = try await uploadResumable(data: fileData, mimeType: mimeType)
                    break // Upload success, exit upload retry loop
                } catch {
                    uploadAttempt += 1
                    lastError = error

                    // Check if this is a retryable error
                    if shouldRetryUpload(error: error) && uploadAttempt < maxUploadRetries {
                        let delay = pow(2.0, Double(uploadAttempt)) // Exponential backoff: 2s, 4s, 8s
                        print("🔄 Upload attempt \(uploadAttempt) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } else {
                        // Either non-retryable error or max upload retries exceeded
                        if uploadAttempt >= maxUploadRetries {
                            print("❌ Upload failed after \(maxUploadRetries) attempts in cycle \(cycle)")
                        }
                        break // Break upload retry loop, will continue to next cycle
                    }
                }
            }

            // If upload failed completely, try next cycle
            guard let fileURI = uploadedFileURI else {
                if cycle == maxCycles {
                    throw lastError ?? NSError(domain: "GeminiError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload file after \(maxCycles) cycles"])
                }
                print("🔄 Upload failed in cycle \(cycle), trying next cycle")
                continue
            }

            // Upload succeeded, now poll for processing with 3-minute timeout
            print("✅ Upload succeeded in cycle \(cycle), polling for file processing...")
            let startTime = Date()

            while Date().timeIntervalSince(startTime) < maxWaitTime {
                do {
                    let status = try await getFileStatus(fileURI: fileURI)
                    if status == "ACTIVE" {
                        print("✅ File processing completed in cycle \(cycle)")
                        return (Int64(fileSize), fileURI)
                    }
                } catch {
                    print("⚠️ Error checking file status: \(error.localizedDescription)")
                    lastError = error
                }
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }

            // Processing timeout occurred
            print("⏰ File processing timeout (3 minutes) in cycle \(cycle)")
            lastError = NSError(domain: "GeminiError", code: 2, userInfo: [NSLocalizedDescriptionKey: "File processing timeout"])

            if cycle < maxCycles {
                print("🔄 Starting next upload+processing cycle...")
            }
        }

        // All cycles failed
        throw lastError ?? NSError(domain: "GeminiError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Upload and processing failed after \(maxCycles) complete cycles"])
    }

    private func shouldRetryUpload(error: Error) -> Bool {
        // Retry on network connection issues
        if let nsError = error as NSError? {
            // Network connection lost (error -1005)
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost {
                return true
            }
            // Connection timeout (error -1001)
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                return true
            }
            // DNS lookup failed (error -1003)
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotFindHost {
                return true
            }
            // Socket connection issues (various codes)
            if nsError.domain == NSURLErrorDomain && (nsError.code == NSURLErrorCannotConnectToHost || nsError.code == NSURLErrorNotConnectedToInternet) {
                return true
            }
        }

        // Don't retry on API key issues, file format problems, etc.
        return false
    }
    
    private func uploadSimple(data: Data, mimeType: String) async throws -> String {
        var request = URLRequest(url: URL(string: fileEndpoint + "?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let requestStart = Date()
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let requestDuration = Date().timeIntervalSince(requestStart)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        logCallDuration(operation: "upload.simple", duration: requestDuration, status: statusCode)

        if let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let file = json["file"] as? [String: Any],
           let uri = file["uri"] as? String {
            return uri
        }
        // Log unexpected response to help debugging
        logGeminiFailure(context: "uploadSimple", response: response, data: responseData, error: nil)
        throw NSError(domain: "GeminiError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse upload response"])
    }
    
private func uploadResumable(data: Data, mimeType: String) async throws -> String {
        print("📤 Starting resumable video upload:")
        print("   Size: \(data.count / 1024 / 1024) MB")
        print("   MIME Type: \(mimeType)")
        
        let metadata = GeminiFileMetadata(file: GeminiFileInfo(displayName: "dayflow_video"))
        let boundary = UUID().uuidString
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONEncoder().encode(metadata))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        var request = URLRequest(url: URL(string: fileEndpoint + "?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Raw-Size")
        request.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(metadata)
        
        let startTime = Date()
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let initDuration = Date().timeIntervalSince(startTime)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("🔴 Upload init failed: Non-HTTP response")
            throw NSError(domain: "GeminiError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response during upload init"])
        }
        
        logCallDuration(operation: "upload.init", duration: initDuration, status: httpResponse.statusCode)
        
        guard let uploadURL = httpResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
            print("🔴 No upload URL in response")
            if let bodyText = String(data: responseData, encoding: .utf8) {
                print("   Response Body: \(truncate(bodyText, max: 1000))")
            }
            logGeminiFailure(context: "uploadResumable(start)", response: response, data: responseData, error: nil)
            throw NSError(domain: "GeminiError", code: 4, userInfo:  [NSLocalizedDescriptionKey: "No upload URL in response"])
        }
        
        var uploadRequest = URLRequest(url: URL(string: uploadURL)!)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.httpBody = data
        
        let uploadStartTime = Date()
        let (uploadResponseData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
        let uploadDuration = Date().timeIntervalSince(uploadStartTime)

        guard let httpUploadResponse = uploadResponse as? HTTPURLResponse else {
            print("🔴 Upload finalize failed: Non-HTTP response")
            throw NSError(domain: "GeminiError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response during upload finalize"])
        }
        
        logCallDuration(operation: "upload.finalize", duration: uploadDuration, status: httpUploadResponse.statusCode)
        
        if httpUploadResponse.statusCode != 200 {
            print("🔴 Upload failed with status \(httpUploadResponse.statusCode)")
            if let bodyText = String(data: uploadResponseData, encoding: .utf8) {
                print("   Response Body: \(truncate(bodyText, max: 1000))")
            }
        }
        
        if let json = try JSONSerialization.jsonObject(with: uploadResponseData) as? [String: Any],
           let file = json["file"] as? [String: Any],
           let uri = file["uri"] as? String {
            return uri
        }
        
        print("🔴 Failed to parse upload response")
        if let bodyText = String(data: uploadResponseData, encoding: .utf8) {
            print("   Response Body: \(truncate(bodyText, max: 1000))")
        }
        logGeminiFailure(context: "uploadResumable(finalize)", response: uploadResponse, data: uploadResponseData, error: nil)
        throw NSError(domain: "GeminiError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to parse upload response"])
    }
    
    private func getFileStatus(fileURI: String) async throws -> String {
        guard let url = URL(string: fileURI + "?key=\(apiKey)") else {
            throw NSError(domain: "GeminiError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid file URI"])
        }
        
        let requestStart = Date()
        let (data, response) = try await URLSession.shared.data(from: url)
        let requestDuration = Date().timeIntervalSince(requestStart)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        logCallDuration(operation: "file.status", duration: requestDuration, status: statusCode)

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let state = json["state"] as? String {
            return state
        }
        // Unexpected response – log for diagnosis but still return UNKNOWN
        logGeminiFailure(context: "getFileStatus", response: response, data: data, error: nil)
        return "UNKNOWN"
    }
    
    private func geminiTranscribeRequest(fileURI: String, mimeType: String, prompt: String, batchId: Int64?, groupId: String, model: GeminiModel, attempt: Int) async throws -> (String, String) {
        let transcriptionSchema: [String:Any] = [
          "type":"ARRAY",
          "items": [
            "type":"OBJECT",
            "properties":[
              "startTimestamp":["type":"STRING"],
              "endTimestamp":  ["type":"STRING"],
              "description":   ["type":"STRING"]
            ],
            "required":["startTimestamp","endTimestamp","description"],
            "propertyOrdering":["startTimestamp","endTimestamp","description"]
          ]
        ]
        
        let generationConfig: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": 65536,
            "responseMimeType": "application/json",
            "responseSchema": transcriptionSchema
        ]

        let requestBody: [String: Any] = [
            "contents": [["parts": [
                ["file_data": ["mime_type": mimeType, "file_uri": fileURI]],
                ["text": prompt]
            ]]],
            "generationConfig": generationConfig
        ]

        // Single API call (no retry logic in this function)
        let urlWithKey = endpointForModel(model) + "?key=\(apiKey)"
        var request = URLRequest(url: URL(string: urlWithKey)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120 // 2 minutes timeout
        let requestStart = Date()

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            let (data, response) = try await URLSession.shared.data(for: request)
            let requestDuration = Date().timeIntervalSince(requestStart)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("🔴 Non-HTTP response received")
                throw NSError(domain: "GeminiError", code: 9, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
            }

            logCallDuration(operation: "transcribe.generateContent", duration: requestDuration, status: httpResponse.statusCode)

            // Prepare logging context
            let responseHeaders: [String:String] = httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
                if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible { acc[k] = v.description }
            }
            let modelName = model.rawValue
            let ctx = LLMCallContext(
                batchId: batchId,
                callGroupId: groupId,
                attempt: attempt,
                provider: "gemini",
                model: modelName,
                operation: "transcribe",
                requestMethod: request.httpMethod,
                requestURL: request.url,
                requestHeaders: request.allHTTPHeaderFields,
                requestBody: request.httpBody,
                startedAt: requestStart
            )
            let httpInfo = LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data)

            // Check HTTP status first - any 400+ is a failure, except for a special 503 case where
            // Gemini sometimes streams a valid payload before closing with an error.
            if httpResponse.statusCode >= 400 {
                if httpResponse.statusCode == 503, let recovered = recover503CandidateText(data) {
                    print("⚠️ HTTP 503 received, but valid candidate payload was recovered; treating as success.")
                    logGeminiFailure(context: "transcribe.http503.salvaged", attempt: attempt, response: response, data: data, error: nil)
                    LLMLogger.logSuccess(
                        ctx: ctx,
                        http: httpInfo,
                        finishedAt: Date()
                    )
                    return (recovered, model.rawValue)
                } else if httpResponse.statusCode == 503 {
                    let preview = String(data: data, encoding: .utf8).map { truncate($0, max: 200) } ?? "<non-UTF8 body>"
                    print("⚠️ HTTP 503 contained no recoverable payload. preview=\(preview)")
                    logGeminiFailure(context: "transcribe.http503.unrecoverable", attempt: attempt, response: response, data: data, error: nil)
                }

                print("🔴 HTTP error status: \(httpResponse.statusCode)")
                if let bodyText = String(data: data, encoding: .utf8) {
                    print("   Response Body: \(truncate(bodyText, max: 2000))")
                } else {
                    print("   Response Body: <non-UTF8 data, \(data.count) bytes>")
                }

                // Try to parse error details for better error message
                var errorMessage = "HTTP \(httpResponse.statusCode) error"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any] {
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
                logGeminiFailure(context: "transcribe.httpError", attempt: attempt, response: response, data: data, error: nil)
                throw NSError(domain: "GeminiError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }

            // HTTP status is good (200-299), now validate content
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LLMLogger.logFailure(
                    ctx: ctx,
                    http: httpInfo,
                    finishedAt: Date(),
                    errorDomain: "ParseError",
                    errorCode: 7,
                    errorMessage: "Invalid JSON response"
                )
                logGeminiFailure(context: "transcribe.generateContent.invalidJSON", attempt: attempt, response: response, data: data, error: nil)
                throw NSError(domain: "GeminiError", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
            }

            guard let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first else {
                LLMLogger.logFailure(
                    ctx: ctx,
                    http: httpInfo,
                    finishedAt: Date(),
                    errorDomain: "ParseError",
                    errorCode: 7,
                    errorMessage: "No candidates in response"
                )
                logGeminiFailure(context: "transcribe.generateContent.noCandidates", attempt: attempt, response: response, data: data, error: nil)
                throw NSError(domain: "GeminiError", code: 7, userInfo: [NSLocalizedDescriptionKey: "No candidates in response"])
            }

            guard let content = firstCandidate["content"] as? [String: Any] else {
                LLMLogger.logFailure(
                    ctx: ctx,
                    http: httpInfo,
                    finishedAt: Date(),
                    errorDomain: "ParseError",
                    errorCode: 7,
                    errorMessage: "No content in candidate"
                )
                logGeminiFailure(context: "transcribe.generateContent.noContent", attempt: attempt, response: response, data: data, error: nil)
                throw NSError(domain: "GeminiError", code: 7, userInfo: [NSLocalizedDescriptionKey: "No content in candidate"])
            }

            guard let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? String else {
                LLMLogger.logFailure(
                    ctx: ctx,
                    http: httpInfo,
                    finishedAt: Date(),
                    errorDomain: "ParseError",
                    errorCode: 7,
                    errorMessage: "Empty content - no parts array"
                )
                logGeminiFailure(context: "transcribe.generateContent.emptyContent", attempt: attempt, response: response, data: data, error: nil)
                throw NSError(domain: "GeminiError", code: 7, userInfo: [NSLocalizedDescriptionKey: "Empty content - no parts array"])
            }

            // Everything succeeded - log success and return
            LLMLogger.logSuccess(
                ctx: ctx,
                http: httpInfo,
                finishedAt: Date()
            )

            return (text, model.rawValue)
                
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
                        operation: "transcribe",
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
                print("🔴 GEMINI TRANSCRIBE FAILED:")
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
                logGeminiFailure(context: "transcribe.generateContent.catch", attempt: attempt, response: nil, data: nil, error: error)

                // Rethrow error (outer loop in calling function handles retries)
                throw error
            }
    }
    
    // Temporary struct for parsing Gemini response
    private struct VideoTranscriptChunk: Codable {
        let startTimestamp: String   // MM:SS
        let endTimestamp: String     // MM:SS
        let description: String
    }
    
    private func parseTranscripts(_ response: String) throws -> [VideoTranscriptChunk] {
        guard let data = response.data(using: .utf8) else {
            print("🔎 GEMINI DEBUG: parseTranscripts received non-UTF8 or empty response: \(truncate(response, max: 400))")
            throw NSError(domain: "GeminiError", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
        }
        do {
            let transcripts = try JSONDecoder().decode([VideoTranscriptChunk].self, from: data)
            return transcripts
        } catch {
            let snippet = truncate(String(data: data, encoding: .utf8) ?? "<non-utf8>", max: 1200)
            print("🔎 GEMINI DEBUG: parseTranscripts JSON decode failed: \(error.localizedDescription) bodySnippet=\(snippet)")
            throw error
        }
    }
    
    private func geminiCardsRequest(prompt: String, batchId: Int64?, groupId: String, model: GeminiModel, attempt: Int) async throws -> String {
        let distractionSchema: [String: Any] = [
            "type": "OBJECT", "properties": ["startTime": ["type": "STRING"], "endTime": ["type": "STRING"], "title": ["type": "STRING"], "summary": ["type": "STRING"]],
            "required": ["startTime", "endTime", "title", "summary"], "propertyOrdering": ["startTime", "endTime", "title", "summary"]
        ]
        
        let appSitesSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "primary": ["type": "STRING"],
                "secondary": ["type": "STRING"]
            ],
            "required": [],
            "propertyOrdering": ["primary", "secondary"]
        ]
        
        let cardSchema: [String: Any] = [
            "type": "ARRAY", "items": [
                "type": "OBJECT", "properties": [
                    "startTime": ["type": "STRING"], "endTime": ["type": "STRING"], "category": ["type": "STRING"],
                    "subcategory": ["type": "STRING"], "title": ["type": "STRING"], "summary": ["type": "STRING"],
                    "detailedSummary": ["type": "STRING"], "distractions": ["type": "ARRAY", "items": distractionSchema],
                    "appSites": appSitesSchema
                ],
                "required": ["startTime", "endTime", "category", "subcategory", "title", "summary", "detailedSummary"],
                "propertyOrdering": ["startTime", "endTime", "category", "subcategory", "title", "summary", "detailedSummary", "distractions", "appSites"]
            ]
        ]
        
        let generationConfig: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": 65536,
            "responseMimeType": "application/json",
            "responseSchema": cardSchema
        ]
        
        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig
        ]

        // Single API call (retry logic handled by outer loop in generateActivityCards)
        let urlWithKey = endpointForModel(model) + "?key=\(apiKey)"
        var request = URLRequest(url: URL(string: urlWithKey)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120 // 2 minutes timeout
        let requestStart = Date()

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            let (data, response) = try await URLSession.shared.data(for: request)
            let requestDuration = Date().timeIntervalSince(requestStart)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("🔴 Non-HTTP response received for cards request")
                throw NSError(domain: "GeminiError", code: 9, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
            }

            logCallDuration(operation: "cards.generateContent", duration: requestDuration, status: httpResponse.statusCode)

            // Prepare logging context
            let responseHeaders: [String:String] = httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
                if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible { acc[k] = v.description }
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
            let httpInfo = LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data)

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
                   let error = json["error"] as? [String: Any] {
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
                logGeminiFailure(context: "cards.httpError", attempt: attempt, response: response, data: data, error: nil)
                throw NSError(domain: "GeminiError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }

            // HTTP status is good (200-299), now validate content
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any] else {
                LLMLogger.logFailure(
                    ctx: ctx,
                    http: httpInfo,
                    finishedAt: Date(),
                    errorDomain: "ParseError",
                    errorCode: 9,
                    errorMessage: "Invalid response format - missing candidates or content"
                )
                logGeminiFailure(context: "cards.generateContent.invalidFormat", attempt: attempt, response: response, data: data, error: nil)
                throw NSError(domain: "GeminiError", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid response format - missing candidates or content"])
            }

            // Check for parts array - if missing, this is likely a schema validation failure
            guard let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? String else {
                LLMLogger.logFailure(
                    ctx: ctx,
                    http: httpInfo,
                    finishedAt: Date(),
                    errorDomain: "ParseError",
                    errorCode: 9,
                    errorMessage: "Schema validation likely failed - no content parts in response"
                )
                logGeminiFailure(context: "cards.generateContent.emptyContent", attempt: attempt, response: response, data: data, error: nil)
                throw NSError(domain: "GeminiError", code: 9, userInfo: [NSLocalizedDescriptionKey: "Schema validation likely failed - no content parts in response"])
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
            logGeminiFailure(context: "cards.generateContent.catch", attempt: attempt, response: nil, data: nil, error: error)

            // Rethrow error (outer loop in generateActivityCards handles retries)
            throw error
        }
    }
    
    private func parseActivityCards(_ response: String) throws -> [ActivityCardData] {
        guard let data = response.data(using: .utf8) else {
            print("🔎 GEMINI DEBUG: parseActivityCards received non-UTF8 or empty response: \(truncate(response, max: 400))")
            throw NSError(domain: "GeminiError", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
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
                distractions = try container.decodeIfPresent([GeminiDistraction].self, forKey: .distractions)
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
            print("🔎 GEMINI DEBUG: parseActivityCards JSON decode failed: \(error.localizedDescription) bodySnippet=\(snippet)")
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
    
    
    private struct TimeRange {
        let start: Double  // minutes from midnight
        let end: Double
    }
    
    private func timeToMinutes(_ timeStr: String) -> Double {
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
    
    private func mergeOverlappingRanges(_ ranges: [TimeRange]) -> [TimeRange] {
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
    
    private func validateTimeCoverage(existingCards: [ActivityCardData], newCards: [ActivityCardData]) -> (isValid: Bool, error: String?) {
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
                    if outputRange.start - flexibility <= coveredStart && coveredStart <= outputRange.end + flexibility {
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
                return (false, "Time coverage validation loop exceeded safety limit - possible infinite loop detected")
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
                var errorMsg = "Missing coverage for time segments: \(uncoveredDesc.joined(separator: ", "))"
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
    
    private func validateTimeline(_ cards: [ActivityCardData]) -> (isValid: Bool, error: String?) {
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
                   let endDate = formatter.date(from: endTime) {
                    
                    var adjustedEndDate = endDate
                    // Handle day rollover (e.g., 11:30 PM to 12:30 AM)
                    if endDate < startDate {
                        adjustedEndDate = Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
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
                return (false, "Card \(index + 1) '\(card.title)' is only \(String(format: "%.1f", durationMinutes)) minutes long")
            }
        }
        
        return (true, nil)
    }
    
    private func minutesToTimeString(_ minutes: Double) -> String {
        let hours = (Int(minutes) / 60) % 24  // Handle > 24 hours
        let mins = Int(minutes) % 60
        let period = hours < 12 ? "AM" : "PM"   
        var displayHour = hours % 12
        if displayHour == 0 {
            displayHour = 12
        }
        return String(format: "%d:%02d %@", displayHour, mins, period)
    }
    
    private func parseVideoTimestamp(_ timestamp: String) -> Int {
        let components = timestamp.components(separatedBy: ":")
        
        if components.count == 2 {
            // MM:SS format
            let minutes = Int(components[0]) ?? 0
            let seconds = Int(components[1]) ?? 0
            return minutes * 60 + seconds
        } else if components.count == 3 {
            // HH:MM:SS format
            let hours = Int(components[0]) ?? 0
            let minutes = Int(components[1]) ?? 0
            let seconds = Int(components[2]) ?? 0
            return hours * 3600 + minutes * 60 + seconds
        } else {
            // Invalid format, return 0
            print("Warning: Invalid video timestamp format: \(timestamp)")
            return 0
        }
    }
    
    // Helper function to format timestamps
    private func formatTimestampForPrompt(_ unixTime: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    // MARK: - Text Generation

    func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
        let callStart = Date()

        let generationConfig: [String: Any] = [
            "temperature": 0.7,
            "maxOutputTokens": 8192
        ]

        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig
        ]

        let maxRetries = 4
        var attempt = 0
        var lastError: Error?
        var modelState = ModelRunState(models: modelPreference.orderedModels)

        while attempt < maxRetries {
            do {
                print("🔄 generateText attempt \(attempt + 1)/\(maxRetries)")
                let activeModel = modelState.current
                let urlWithKey = endpointForModel(activeModel) + "?key=\(apiKey)"

                var request = URLRequest(url: URL(string: urlWithKey)!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 120
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

                let requestStart = Date()
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "GeminiError", code: 9, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
                }
                let requestDuration = Date().timeIntervalSince(requestStart)
                logCallDuration(operation: "generateText", duration: requestDuration, status: httpResponse.statusCode)

                if httpResponse.statusCode >= 400 {
                    var errorMessage = "HTTP \(httpResponse.statusCode) error"
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        errorMessage = message
                    }
                    throw NSError(domain: "GeminiError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let firstCandidate = candidates.first,
                      let content = firstCandidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let text = parts.first?["text"] as? String else {
                    throw NSError(domain: "GeminiError", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to parse response"])
                }

                // Success!
                print("✅ generateText succeeded on attempt \(attempt + 1)")
                let log = LLMCall(
                    timestamp: callStart,
                    latency: Date().timeIntervalSince(callStart),
                    input: prompt,
                    output: text
                )
                return (text.trimmingCharacters(in: .whitespacesAndNewlines), log)

            } catch {
                lastError = error
                print("❌ generateText attempt \(attempt + 1) failed: \(error.localizedDescription)")

                var appliedFallback = false
                if let nsError = error as NSError?,
                   nsError.domain == "GeminiError",
                   Self.capacityErrorCodes.contains(nsError.code),
                   let transition = modelState.advance() {

                    appliedFallback = true
                    let reason = fallbackReason(for: nsError.code)
                    print("↔️ Switching to \(transition.to.rawValue) after \(nsError.code)")

                    Task { @MainActor in
                        AnalyticsService.shared.capture("llm_model_fallback", [
                            "provider": "gemini",
                            "operation": "generate_text",
                            "from_model": transition.from.rawValue,
                            "to_model": transition.to.rawValue,
                            "reason": reason
                        ])
                    }
                }

                if !appliedFallback {
                    let strategy = classifyError(error)

                    // Check if we should retry
                    if strategy == .noRetry || attempt >= maxRetries - 1 {
                        print("🚫 Not retrying generateText: strategy=\(strategy), attempt=\(attempt + 1)/\(maxRetries)")
                        throw error
                    }

                    // Apply appropriate delay based on error type
                    let delay = delayForStrategy(strategy, attempt: attempt)
                    if delay > 0 {
                        print("⏳ Waiting \(String(format: "%.1f", delay))s before retry (strategy: \(strategy))")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }

            attempt += 1
        }

        // Should never reach here, but just in case
        throw lastError ?? NSError(domain: "GeminiError", code: 999, userInfo: [NSLocalizedDescriptionKey: "generateText failed after \(maxRetries) attempts"])
    }


    private struct GeminiFileMetadata: Codable {
        let file: GeminiFileInfo
    }

    private struct GeminiFileInfo: Codable {
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    // MARK: - Screenshot Transcription

    /// Transcribe observations from screenshots by first compositing them into a video.
    /// Gemini's API expects video files, so we composite screenshots → video → upload → transcribe.
    ///
    /// We use a compressed timeline: each screenshot = 1 second of video.
    /// This reduces a 15-minute batch (90 screenshots) to a 90-second video.
    /// Timestamps returned by Gemini are then expanded by the screenshot interval.
    func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
        guard !screenshots.isEmpty else {
            throw NSError(domain: "GeminiDirectProvider", code: 11, userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
        }

        let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

        // Calculate real duration from timestamp range (for timestamp expansion later)
        let firstTs = sortedScreenshots.first!.capturedAt
        let lastTs = sortedScreenshots.last!.capturedAt
        let realDuration = TimeInterval(lastTs - firstTs)

        // Compressed video duration: 1 second per screenshot
        let compressedVideoDuration = TimeInterval(sortedScreenshots.count)

        // Compression factor = screenshot interval (e.g., 10s screenshots → 10x compression)
        let compressionFactor = ScreenshotConfig.interval

        print("[Gemini] 📊 Timeline compression: \(Int(realDuration))s real → \(Int(compressedVideoDuration))s video (\(Int(compressionFactor))x)")

        // Create temp video file
        let tempVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini_batch_\(batchId ?? 0)_\(UUID().uuidString).mp4")

        defer {
            try? FileManager.default.removeItem(at: tempVideoURL)
        }

        // Composite screenshots into compressed video (1fps)
        let videoService = VideoProcessingService()
        do {
            try await videoService.generateVideoFromScreenshots(
                screenshots: sortedScreenshots,
                outputURL: tempVideoURL,
                fps: 1,
                useCompressedTimeline: true,  // Each frame = 1 second
                options: .init(
                    maxOutputHeight: 720,
                    frameStride: 1,
                    averageBitRate: 1_200_000,
                    codec: .h264,
                    keyframeIntervalSeconds: 10
                )
            )
        } catch {
            print("[Gemini] ❌ Failed to composite screenshots into video: \(error.localizedDescription)")
            throw NSError(
                domain: "GeminiDirectProvider",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to composite screenshots into video: \(error.localizedDescription)"]
            )
        }

        // Load video data
        let videoData = try Data(contentsOf: tempVideoURL)
        print("[Gemini] 📹 Composited \(screenshots.count) screenshots into compressed video (\(videoData.count / 1024)KB)")

        // Transcribe the composited video with compression info
        return try await transcribeVideoData(
            videoData,
            mimeType: "video/mp4",
            batchStartTime: batchStartTime,
            videoDuration: compressedVideoDuration,
            realDuration: realDuration,
            compressionFactor: compressionFactor,
            batchId: batchId
        )
    }
}
