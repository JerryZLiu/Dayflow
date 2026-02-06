//
//  OllamaProvider.swift
//  Dayflow
//

import Foundation
import AppKit

final class OllamaProvider {
    private let endpoint: String
    private let screenshotInterval: TimeInterval = 10  // seconds between screenshots
    // Read persisted local settings
    private var savedModelId: String {
        if let m = UserDefaults.standard.string(forKey: "llmLocalModelId"), !m.isEmpty {
            return m
        }
        // Fallback to a sensible default
        let engine: LocalEngine = isLMStudio ? .lmstudio : .ollama
        return LocalModelPreferences.defaultModelId(for: engine)
    }
    private var isLMStudio: Bool {
        (UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama") == "lmstudio"
    }
    private var isCustomEngine: Bool {
        (UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama") == "custom"
    }
    private var customAPIKey: String? {
        let trimmed = UserDefaults.standard.string(forKey: "llmLocalAPIKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // Get the actual local engine type for analytics tracking
    private var localEngine: String {
        UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
    }

    init(endpoint: String = "http://localhost:1234") {
        self.endpoint = endpoint
    }

    // Strip user references from observations to prevent LLM from using third-person language
    // For some reason, even after adding negative prompts during observation generation,
    // it still generates text with "a user" and "the user", which poisons the context
    // for the summary prompt and makes it more likely to write in 3rd person.
    // TODO: Remove this when observation generation is fixed upstream
    private func stripUserReferences(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "The user", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "A user", with: "", options: .caseInsensitive)
    }

    private func logCallDuration(operation: String, duration: TimeInterval, status: Int? = nil) {
        let statusText = status.map { " status=\($0)" } ?? ""
        print("⏱️ [\(localEngine)] \(operation) \(String(format: "%.2f", duration))s\(statusText)")
    }

    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        let callStart = Date()
        var logs: [String] = []
        
        let sortedObservations = context.batchObservations.sorted { $0.startTs < $1.startTs }

        guard let firstObservation = sortedObservations.first,
              let lastObservation = sortedObservations.last else {
            throw NSError(
                domain: "OllamaProvider",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "Cannot generate activity cards: no observations provided"]
            )
        }

        // Generate initial activity card for these observations
        let (titleSummary, firstLog) = try await generateTitleAndSummary(
            observations: sortedObservations,
            categories: context.categories,
            batchId: batchId
        )
        logs.append(firstLog)
        
        let normalizedCategory = normalizeCategory(titleSummary.category, categories: context.categories)

        let initialCard = ActivityCardData(
            startTime: formatTimestampForPrompt(firstObservation.startTs),
            endTime: formatTimestampForPrompt(lastObservation.endTs),
            category: normalizedCategory,
            subcategory: "",
            title: titleSummary.title,
            summary: titleSummary.summary,
            detailedSummary: "",
            distractions: nil,
            appSites: titleSummary.appSites
        )
        
        var allCards = context.existingCards
        
        // Check if we should merge with the last existing card
        if !allCards.isEmpty, let lastExistingCard = allCards.last {
            // Hard cap: Don't even try to merge if the last card is already 25+ minutes
            let lastCardDuration = calculateDurationInMinutes(from: lastExistingCard.startTime, to: lastExistingCard.endTime)
            
            if lastCardDuration >= 40 {
                allCards.append(initialCard)
            } else {
                let gapMinutes = calculateDurationInMinutes(from: lastExistingCard.endTime, to: initialCard.startTime)
                if gapMinutes > 5 {
                    allCards.append(initialCard)
                } else {
                    let candidateDuration = calculateDurationInMinutes(from: lastExistingCard.startTime, to: initialCard.endTime)
                    if candidateDuration > 60 {
                        allCards.append(initialCard)
                    } else {
                        let (shouldMerge, mergeLog) = try await checkShouldMerge(
                            previousCard: lastExistingCard,
                            newCard: initialCard,
                            batchId: batchId
                        )
                        logs.append(mergeLog)

                        if shouldMerge {
                            let (mergedCard, mergeCreateLog) = try await mergeTwoCards(
                                previousCard: lastExistingCard,
                                newCard: initialCard,
                                batchId: batchId
                            )

                            let mergedDuration = calculateDurationInMinutes(from: mergedCard.startTime, to: mergedCard.endTime)

                            if mergedDuration > 60 {
                                allCards.append(initialCard)
                            } else {
                                logs.append(mergeCreateLog)
                                // Replace the last card with the merged version
                                allCards[allCards.count - 1] = mergedCard
                            }
                        } else {
                            // Add as new card
                            allCards.append(initialCard)
                        }
                    }
                }
            }
        } else {
            // No existing cards, just add the initial card
            allCards.append(initialCard)
        }
        
        let totalLatency = Date().timeIntervalSince(callStart)
        
        
        let combinedLog = LLMCall(
            timestamp: callStart,
            latency: totalLatency,
            input: "Two-pass activity card generation",
            output: logs.joined(separator: "\n\n---\n\n")
        )
        
        return (allCards, combinedLog)
    }
    
    
    private struct FrameData {
        let image: Data  // Base64 encoded image
        let timestamp: TimeInterval  // Seconds from batch start
    }

    private struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        var temperature: Double = 0.7
        var max_tokens: Int = 4000
        var stream: Bool = false
    }
    
    private struct ChatMessage: Codable {
        let role: String
        let content: [MessageContent]
    }
    
    private struct MessageContent: Codable {
        let type: String
        let text: String?
        let image_url: ImageURL?
        
        struct ImageURL: Codable {
            let url: String
        }
    }
    
    private struct ChatResponse: Codable {
        let choices: [Choice]
        
        struct Choice: Codable {
            let message: ResponseMessage
        }
        
        struct ResponseMessage: Codable {
            let content: String
        }
    }
    
    private func getSimpleFrameDescription(_ frame: FrameData, batchId: Int64?) async -> String? {
        // Simple prompt focused on just describing what's happening
        let prompt = """
        Describe what you see on this computer screen in 1-2 sentences.
        Focus on: what application/site is open, what the user is doing, and any relevant details visible.
        Be specific and factual.
        
        GOOD EXAMPLES:
        ✓ "VS Code open with index.js file, writing a React component for user authentication."
        ✓ "Gmail compose window writing email to client@company.com about project timeline."
        ✓ "Slack conversation in #engineering channel discussing API rate limiting issues."
        
        BAD EXAMPLES:
        ✗ "User is coding" (too vague)
        ✗ "Looking at a website" (doesn't identify which site)
        ✗ "Working on computer" (completely non-specific)
        """
        
        // Convert base64 data back to string (return nil if we can't decode)
        guard let base64String = String(data: frame.image, encoding: .utf8) else {
            print("[OLLAMA] ⚠️ Failed to decode frame image — skipping frame")
            return nil
        }
        
        // Build message content with image and text
        let content: [MessageContent] = [
            MessageContent(type: "text", text: prompt, image_url: nil),
            MessageContent(type: "image_url", text: nil, image_url: MessageContent.ImageURL(url: "data:image/jpeg;base64,\(base64String)"))
        ]
        
        let request = ChatRequest(
            model: savedModelId,
            messages: [
                ChatMessage(role: "user", content: content)
            ]
        )
        
        do {
            let response = try await callChatAPI(request, operation: "describe_frame", batchId: batchId, maxRetries: 1)
            // Return the raw text response (no JSON parsing needed for simple descriptions)
            return response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            print("[OLLAMA] ⚠️ describe_frame failed at \(frame.timestamp)s — skipping frame: \(error.localizedDescription)")
            return nil
        }
    }

    private func callChatAPI(_ request: ChatRequest, operation: String, batchId: Int64? = nil, maxRetries: Int = 3) async throws -> ChatResponse {
        guard let url = LocalEndpointUtilities.chatCompletionsURL(baseURL: endpoint) else {
            throw NSError(domain: "OllamaProvider", code: 15, userInfo: [NSLocalizedDescriptionKey: "Invalid local endpoint URL"])
        }
        
        // Retry logic with exponential backoff
        let attempts = max(1, maxRetries)
        var lastError: Error?

        let callGroupId = UUID().uuidString
        for attempt in 0..<attempts {
            var ctxForAttempt: LLMCallContext?
            var didLogFailureThisAttempt = false
            var didLogTiming = false
            var apiStart: Date?
            do {
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                applyAuthorizationHeader(to: &urlRequest)
                urlRequest.httpBody = try JSONEncoder().encode(request)
                urlRequest.timeoutInterval = 60.0  // 60-second timeout
                
                let start = Date()
                apiStart = start
                let requestBodyForLogging: Data?
                if operation == "describe_frame" {
                    // Don't persist raw base64 image payloads to the LLM call log (SQLite)
                    requestBodyForLogging = nil
                } else {
                    requestBodyForLogging = urlRequest.httpBody
                }
                let ctx = LLMCallContext(
                    batchId: batchId,
                    callGroupId: callGroupId,
                    attempt: attempt + 1,
                    provider: localEngine, // Track actual engine: ollama, lmstudio, or custom
                    model: request.model,
                    operation: operation,
                    requestMethod: urlRequest.httpMethod,
                    requestURL: urlRequest.url,
                    requestHeaders: urlRequest.allHTTPHeaderFields,
                    requestBody: requestBodyForLogging,
                    startedAt: start
                )
                ctxForAttempt = ctx
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let requestDuration = Date().timeIntervalSince(start)
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                logCallDuration(operation: operation, duration: requestDuration, status: statusCode)
                didLogTiming = true

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "OllamaProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                }
                
                
                guard httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    // Log failure with response body via centralized logger
                    let responseHeaders: [String:String] = httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
                        if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible { acc[k] = v.description }
                    }
                    LLMLogger.logFailure(
                        ctx: ctx,
                        http: LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data),
                        finishedAt: Date(),
                        errorDomain: "OllamaProvider",
                        errorCode: httpResponse.statusCode,
                        errorMessage: errorBody
                    )
                    didLogFailureThisAttempt = true
                    throw NSError(domain: "OllamaProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Ollama API request failed with status \(httpResponse.statusCode): \(errorBody)"])
                }
                
                
                do {
                    let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
                    // Centralized success log
                    let responseHeaders: [String:String] = httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
                        if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible { acc[k] = v.description }
                    }
                    LLMLogger.logSuccess(
                        ctx: ctx,
                        http: LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data),
                        finishedAt: Date()
                    )
                    return chatResponse
                } catch {
                    // Centralized parse failure
                    let responseHeaders: [String:String] = httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
                        if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible { acc[k] = v.description }
                    }
                    LLMLogger.logFailure(
                        ctx: ctx,
                        http: LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data),
                        finishedAt: Date(),
                        errorDomain: (error as NSError).domain,
                        errorCode: (error as NSError).code,
                        errorMessage: (error as NSError).localizedDescription
                    )
                    didLogFailureThisAttempt = true
                    throw error
                }
                
            } catch {
                lastError = error
                if !didLogTiming, let startedAt = apiStart {
                    let requestDuration = Date().timeIntervalSince(startedAt)
                    logCallDuration(operation: operation, duration: requestDuration, status: nil)
                    didLogTiming = true
                }
                print("[OLLAMA] Request failed (attempt \(attempt + 1)/\(attempts)): \(error)")
                
                // If it's not the last attempt, wait before retrying
                if attempt < attempts - 1 {
                    let backoffDelay = pow(2.0, Double(attempt)) * 2.0 // 2s, 4s, 8s
                    try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                }
                // Network error log without http info
                if !didLogFailureThisAttempt {
                    let fallbackBodyForLogging: Data?
                    if operation == "describe_frame" {
                        fallbackBodyForLogging = nil
                    } else {
                        fallbackBodyForLogging = try? JSONEncoder().encode(request)
                    }
                    let ctx = ctxForAttempt ?? LLMCallContext(
                        batchId: batchId,
                        callGroupId: callGroupId,
                        attempt: attempt + 1,
                        provider: localEngine, // Track actual engine: ollama, lmstudio, or custom
                        model: request.model,
                        operation: operation,
                        requestMethod: "POST",
                        requestURL: url,
                        requestHeaders: ["Content-Type": "application/json"],
                        requestBody: fallbackBodyForLogging,
                        startedAt: Date()
                    )
                    LLMLogger.logFailure(
                        ctx: ctx,
                        http: nil,
                        finishedAt: Date(),
                        errorDomain: (error as NSError).domain,
                        errorCode: (error as NSError).code,
                        errorMessage: (error as NSError).localizedDescription
                    )
                    didLogFailureThisAttempt = true
                }
            }
        }
        
        throw lastError ?? NSError(domain: "OllamaProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Request failed after \(attempts) attempts"])
    }

    // (no local logging helpers needed; centralized via LLMLogger)

    // Helper method for text-only requests
    private func callTextAPI(_ prompt: String, operation: String, expectJSON: Bool = false, batchId: Int64? = nil, maxRetries: Int = 3) async throws -> String {
        let systemPrompt = expectJSON ? "You are a helpful assistant. Always respond with valid JSON." : "You are a helpful assistant."
        
        let request = ChatRequest(
            model: savedModelId,
            messages: [
                ChatMessage(role: "system", content: [MessageContent(type: "text", text: systemPrompt, image_url: nil)]),
                ChatMessage(role: "user", content: [MessageContent(type: "text", text: prompt, image_url: nil)])
            ]
        )
        
        let response = try await callChatAPI(request, operation: operation, batchId: batchId, maxRetries: maxRetries)
        return response.choices.first?.message.content ?? ""
    }
    
    
    private struct TitleSummaryResponse: Codable {
        let reasoning: String
        let title: String
        let summary: String
        let category: String
        let appSites: AppSites?
    }

    private struct SummaryResponse: Codable {
        let reasoning: String
        let summary: String
        let category: String
        let appSites: AppSitesResponse?

        struct AppSitesResponse: Codable {
            let primary: String?
            let secondary: String?
        }

        enum CodingKeys: String, CodingKey {
            case reasoning
            case summary
            case category
            case appSites = "app_sites"
        }
    }

    private struct TitleResponse: Codable {
        let reasoning: String
        let title: String
    }

    private struct MergeDecision: Codable {
        let reason: String
        let combine: Bool
    }

    private func normalizeCategory(_ raw: String, categories: [LLMCategoryDescriptor]) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return categories.first?.name ?? "" }
        let normalized = cleaned.lowercased()
        if let match = categories.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }) {
            return match.name
        }
        if let idle = categories.first(where: { $0.isIdle }) {
            let idleLabels = ["idle", "idle time", idle.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            if idleLabels.contains(normalized) {
                return idle.name
            }
        }
        return categories.first?.name ?? cleaned
    }

    private func normalizeTitleText(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        var result = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.hasPrefix("\""), result.hasSuffix("\""), result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }

        let lowercased = result.lowercased()
        if lowercased.hasPrefix("title:") {
            let dropped = String(result.dropFirst("title:".count))
            result = dropped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    private func buildAppSites(from response: SummaryResponse.AppSitesResponse?) -> AppSites? {
        guard let response else { return nil }
        let primary = response.primary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = response.secondary?.trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanedPrimary = primary?.isEmpty == false ? primary : nil
        let cleanedSecondary = secondary?.isEmpty == false ? secondary : nil

        if cleanedPrimary == nil && cleanedSecondary == nil {
            return nil
        }

        return AppSites(primary: cleanedPrimary, secondary: cleanedSecondary)
    }


    private func generateSummary(observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?) async throws -> (SummaryResponse, String) {
        let observationLines: [String] = observations.map { obs in
            let startTime = formatTimestampForPrompt(obs.startTs)
            let endTime = formatTimestampForPrompt(obs.endTs)
            return "[\(startTime) - \(endTime)]: \(obs.observation)"
        }
        let observationsText: String = stripUserReferences(observationLines.joined(separator: "\n\n"))

        let descriptorList = categories.isEmpty ? CategoryStore.descriptorsForLLM() : categories
        let categoryLines: [String] = descriptorList.enumerated().map { index, descriptor in
            var description = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if descriptor.isIdle && description.isEmpty {
                description = "Use when the user is idle for most of the period."
            }
            let dashDescription = description.isEmpty ? "" : " — \(description)"
            return "- \"\(descriptor.name)\"\(dashDescription)"
        }
        let categoriesSection: String = categoryLines.joined(separator: "\n")

        let allowedValues: String = descriptorList
            .map { "\"\($0.name)\"" }
            .joined(separator: ", ")

        let promptSections = OllamaPromptSections(overrides: OllamaPromptPreferences.load())

        let languageBlock = LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
            .map { "\n\n\($0)" } ?? ""

        let basePrompt = """
        You are analyzing someone's computer activity from the last 15 minutes.

        Activity periods:
        \(observationsText)

          Create a summary that captures what happened during this time period.

        \(promptSections.summary)

        CATEGORIES:
        Choose exactly one:
        \(categoriesSection)

        APP SITES (Website Logos)
        Identify the main app or website used for this period. Output the canonical DOMAIN, not the app name.
        - primary: canonical domain of the main app/website used.
        - secondary: another meaningful app used, if relevant.
        - Format: lower-case, no protocol, no query or fragments.
        - Use product subdomains/paths when canonical (e.g., docs.google.com).
        - If you cannot determine a secondary, omit it.
        - Do not invent brands; rely on evidence from observations.

          REASONING:
          Explain your thinking process:
          1. What were the main activities and how much time was spent on each?
          2. Was this primarily work-related, personal, or brief distractions?
          3. Which category best fits based on the MAJORITY of time and focus?
          4. How did you structure the summary to capture the most important activities?

        \(languageBlock)

        Return JSON:
        {
          "reasoning": "Your step-by-step thinking process",
          "summary": "Your 2-3 sentence summary",
          "category": "\(allowedValues)",
          "app_sites": {"primary": "domain.com", "secondary": "domain.com"}
        }
        """

        let maxAttempts = 3
        var prompt = basePrompt
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let response = try await callTextAPI(prompt, operation: "generate_summary", expectJSON: true, batchId: batchId)

                guard let data = response.data(using: .utf8) else {
                    throw NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to parse summary response"])
                }

                let result = try parseJSONResponse(SummaryResponse.self, from: data)

                return (result, response)
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    throw error
                }

                print("[OLLAMA] ⚠️ generateSummary attempt \(attempt) failed: \(error.localizedDescription)")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
                Respond with ONLY the JSON object described above. Ensure it contains "reasoning", "summary", "category", and "app_sites" fields.
                """
            }
        }

        throw lastError ?? NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to generate summary after multiple attempts"])
    }


    private func generateTitle(observations: [Observation], batchId: Int64?) async throws -> (TitleResponse, String) {
        let promptSections = OllamaPromptSections(overrides: OllamaPromptPreferences.load())
        let languageBlock = LLMOutputLanguagePreferences.languageInstruction(forJSON: false)
            .map { "\n\n\($0)" } ?? ""
        let observationsText = observations
            .map { $0.observation.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
            .joined(separator: "\n")

        let basePrompt = """
        \(promptSections.title)
        \(languageBlock)

        OBSERVATIONS:
        \(observationsText)
        """

        let maxAttempts = 3
        var prompt = basePrompt
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let response = try await callTextAPI(prompt, operation: "generate_title", expectJSON: false, batchId: batchId)
                let title = normalizeTitleText(response)
                guard !title.isEmpty else {
                    throw NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Empty title response"])
                }

                let result = TitleResponse(reasoning: "Generated from observations.", title: title)
                return (result, response)
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    throw error
                }

                print("[OLLAMA] ⚠️ generateTitle attempt \(attempt) failed: \(error.localizedDescription)")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
                Respond with ONLY the title text on a single line. Do not include JSON or quotes.
                """
            }
        }

        throw lastError ?? NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to generate title after multiple attempts"])
    }

    private func generateTitleAndSummary(observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?) async throws -> (TitleSummaryResponse, String) {
        // Step 1: Generate summary + category
        let (summaryResult, summaryLog) = try await generateSummary(
            observations: observations,
            categories: categories,
            batchId: batchId
        )

        // Step 2: Generate title from observations
        let (titleResult, titleLog) = try await generateTitle(observations: observations, batchId: batchId)

        let appSites = buildAppSites(from: summaryResult.appSites)

        // Combine into the expected response format
        let combinedResult = TitleSummaryResponse(
            reasoning: "Summary: \(summaryResult.reasoning) | Title: \(titleResult.reasoning)",
            title: titleResult.title,
            summary: summaryResult.summary,
            category: summaryResult.category,
            appSites: appSites
        )

        // Combine logs
        let combinedLog = "=== SUMMARY GENERATION ===\n\(summaryLog)\n\n=== TITLE GENERATION ===\n\(titleLog)"

        return (combinedResult, combinedLog)
    }
    

    private func checkShouldMerge(previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?) async throws -> (Bool, String) {
        let basePrompt = """
        Decide if two consecutive activity cards should be merged.

        Previous activity (\(previousCard.startTime) - \(previousCard.endTime)):
        Title: \(previousCard.title)
        Summary: \(previousCard.summary)

        New activity (\(newCard.startTime) - \(newCard.endTime)):
        Title: \(newCard.title)
        Summary: \(newCard.summary)

        Merge ONLY if they clearly describe the same ongoing task or intent.
        - Tool/app switches are allowed if they support the same goal (e.g., doc writing + research).
        - Do NOT merge if there’s a context switch to a different intent (social feed, chat, video, gaming, email, shopping, unrelated reading).
        - If unsure, do NOT merge.

        Return JSON only:
        {"combine": true/false, "reason": "1 short sentence explaining the decision"}

        EXAMPLES (5):

        1) MERGE
        Prev: "Drafted onboarding doc in Google Docs. Looked up API details in the Stripe docs."
        New:  "Continued the onboarding doc, then cross-checked examples in Stripe docs."
        → {"combine": true, "reason": "Same intent: onboarding doc + supporting research."}

        2) MERGE
        Prev: "Analyzed retention curves in Claude. Adjusted questions for clarity."
        New:  "Kept refining retention metrics in Claude and Notion."
        → {"combine": true, "reason": "Same intent: retention analysis across tools."}

        3) MERGE
        Prev: "Fixed React auth bug in VS Code. Ran local tests."
        New:  "Validated the auth fix in Postman and added notes to the PR."
        → {"combine": true, "reason": "Same task: auth fix and verification."}

        4) DON'T MERGE
        Prev: "Reviewed VC blog post on trohan.com."
        New:  "Watched League of Legends stream and chatted on Messenger."
        → {"combine": false, "reason": "Different intent: research vs entertainment/chat."}

        5) DON'T MERGE
        Prev: "Drafted email reply about product launch."
        New:  "Scrolled X.com and watched a YouTube clip."
        → {"combine": false, "reason": "Context switch to social/video."}
        """

        let maxAttempts = 3
        var prompt = basePrompt
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let response = try await callTextAPI(prompt, operation: "evaluate_card_merge", expectJSON: true, batchId: batchId)

                guard let data = response.data(using: String.Encoding.utf8) else {
                    throw NSError(domain: "OllamaProvider", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to parse merge decision"])
                }

                let decision = try parseJSONResponse(MergeDecision.self, from: data)

                let shouldMerge = decision.combine

                return (shouldMerge, response)
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    throw error
                }

                print("[OLLAMA] ⚠️ evaluate_card_merge attempt \(attempt) failed: \(error.localizedDescription)")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
                Return ONLY the JSON object described above with "reason" and "combine" fields.
                """
            }
        }

        throw lastError ?? NSError(domain: "OllamaProvider", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to evaluate merge decision after multiple attempts"])
    }
    

    private func mergeTwoCards(previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?) async throws -> (ActivityCardData, String) {
        let basePrompt = """
        Create a single activity card that covers both time periods.

        Activity 1 (\(previousCard.startTime) - \(previousCard.endTime)):
        Title: \(previousCard.title)
        Summary: \(previousCard.summary)

        Activity 2 (\(newCard.startTime) - \(newCard.endTime)):
        Title: \(newCard.title)
        Summary: \(newCard.summary)

        Create a unified title and summary that covers the entire period from \(previousCard.startTime) to \(newCard.endTime).
        Title rules (use ONLY the titles and summaries above):
        - 5-10 words, natural and specific, single line
        - Choose the dominant activity (most time), not necessarily the first
        - Ignore brief interruptions (<3 minutes) mentioned in the summaries
        - Include a second activity only if both take ~5+ minutes
        - If 3+ unrelated activities appear, output exactly: "Scattered apps and sites"
        - Prefer proper nouns/topics (Bookface, Claude, League of Legends, Paul Graham, etc.)
        - Never use: worked on, looked at, handled, various, some, multiple, browsing, browse, multitasking, tabs, brief, quick, short
        - Do NOT use the word "browsing"; use "scrolling" or "reading" instead
        - Avoid long lists; no more than one conjunction
        - In the JSON below, the "title" field must contain only the title text (no extra labels or quotes)
        Summary: Two sentences max, first-person perspective without using the word I. Retell how the work flowed from the first card into the second with concrete verbs (debugged, reviewed, watched) and name the stand-out tools/topics once each. Skip laundry lists, filler like “various tasks,” and bullet points.
        Avoid the words social, media, platform, platforms, interaction, interactions, various, engaged, blend, activity, activities.
        Do not refer to the user; write from the user’s perspective.

        \(LLMOutputLanguagePreferences.languageInstruction(forJSON: true) ?? "")

          GOOD EXAMPLES:
          Card 1: Customer interviews wrap-up + Card 2: Insights deck synthesis
          Merged Title: Shaped customer story for insights deck
          Merged Summary: Logged interview quotes into Airtable. Highlighted the strongest themes and molded them into the insights deck outline.

          Card 1: QA-ing mobile release + Card 2: Answering support tickets
          Merged Title: Balanced mobile QA while clearing support
          Merged Summary: Ran through the iOS smoke checklist in TestFlight. Hopped into Help Scout to close the urgent tickets.

          BAD EXAMPLES:
          ✗ Title: Coding, gaming, and Swift fixes with AI tools and Dayflow (comma list trying to cover everything)
          ✗ Title: Busy afternoon session (too vague)
          ✗ Summary: Worked on several things across platforms (generic, missing specifics)
          ✗ Summary that omits a named site/app/topic from the inputs
          ✗ Summary longer than three sentences or formatted as bullet points

        Return JSON:
        {
          "title": "Merged title",
          "summary": "Merged summary"
        }
        """

        let maxAttempts = 3
        var prompt = basePrompt
        var lastError: Error?

        struct MergedContent: Codable {
            let title: String
            let summary: String
        }

        for attempt in 1...maxAttempts {
            do {
                let response = try await callTextAPI(prompt, operation: "merge_cards", expectJSON: true, batchId: batchId)

                guard let data = response.data(using: .utf8) else {
                    throw NSError(domain: "OllamaProvider", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to parse merged card"])
                }

                let merged = try parseJSONResponse(MergedContent.self, from: data)

                // Use known chronological order: previous card comes first, new card follows.
                // Avoid re-parsing string timestamps, which breaks across midnight boundaries.
                let mergedStartTime = previousCard.startTime
                let mergedEndTime = newCard.endTime

                let mergedCard = ActivityCardData(
                    startTime: mergedStartTime,
                    endTime: mergedEndTime,
                    category: previousCard.category,
                    subcategory: previousCard.subcategory,
                    title: merged.title,
                    summary: merged.summary,
                    detailedSummary: previousCard.detailedSummary,
                    distractions: previousCard.distractions,
                    appSites: previousCard.appSites ?? newCard.appSites
                )

                return (mergedCard, response)
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    throw error
                }

                print("[OLLAMA] ⚠️ merge_cards attempt \(attempt) failed: \(error.localizedDescription)")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
                Respond with ONLY the JSON object described above containing merged "title" and "summary" fields.
                """
            }
        }

        throw lastError ?? NSError(domain: "OllamaProvider", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to merge cards after multiple attempts"])
    }
    
    private func parseJSONResponse<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        // First try direct parsing
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Try to extract JSON from the response
            guard let responseString = String(data: data, encoding: .utf8) else {
                throw error
            }
            
            // Look for JSON object
            if let startIndex = responseString.firstIndex(of: "{"),
               let endIndex = responseString.lastIndex(of: "}") {
                let jsonSubstring = responseString[startIndex...endIndex]
                if let jsonData = jsonSubstring.data(using: .utf8) {
                    return try JSONDecoder().decode(type, from: jsonData)
                }
            }
            
            throw error
        }
    }
    
    private func formatTimestampForPrompt(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private func parseVideoTimestamp(_ timestamp: String) -> Int {
        let components = timestamp.components(separatedBy: ":")

        if components.count == 3 {
            guard let hours = Int(components[0]),
                  let minutes = Int(components[1]),
                  let seconds = Int(components[2]) else {
                return 0
            }
            return hours * 3600 + minutes * 60 + seconds
        } else if components.count == 2 {
            guard let minutes = Int(components[0]),
                  let seconds = Int(components[1]) else {
                return 0
            }
            return minutes * 60 + seconds
        }

        return 0
    }
    
    private func calculateDurationInMinutes(from startTime: String, to endTime: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        
        guard let start = formatter.date(from: startTime),
              let end = formatter.date(from: endTime) else {
            return 0
        }
        
        var duration = end.timeIntervalSince(start)
        
        // Handle day boundary - if end is before start, assume it's the next day
        if duration < 0 {
            duration += 24 * 60 * 60  // Add 24 hours in seconds
        }
        
        return Int(duration / 60)
    }
    
    
    private struct VideoSegment: Codable {
        let startTimestamp: String  // MM:SS format
        let endTimestamp: String    // MM:SS format
        let description: String
    }

    private struct SegmentGroupingResponse: Codable {
        let reasoning: String
        let segments: [VideoSegment]
    }

    private struct SegmentCoverageError: LocalizedError {
        let coverageRatio: Double
        let durationString: String

        private var percentage: Int {
            max(0, min(100, Int(coverageRatio * 100)))
        }

        var errorDescription: String? {
            "Segments only cover \(percentage)% of video (expected >80%). Video is \(durationString) long. LLM needs to generate observations that span the full video duration."
        }
    }

    private func decodeSegmentResponse(_ response: String) throws -> (segments: [VideoSegment], reasoning: String) {
        guard let rawData = response.data(using: .utf8) else {
            throw NSError(domain: "OllamaProvider", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to parse merge response"])
        }

        if let object = try? parseJSONResponse(SegmentGroupingResponse.self, from: rawData) {
            return (object.segments, object.reasoning)
        }

        if let array = try? parseJSONResponse([VideoSegment].self, from: rawData) {
            return (array, "")
        }

        if let start = response.firstIndex(of: "{"),
           let end = response.lastIndex(of: "}") {
            let substring = response[start...end]
            if let data = substring.data(using: .utf8),
               let object = try? parseJSONResponse(SegmentGroupingResponse.self, from: data) {
                return (object.segments, object.reasoning)
            }
        }

        if let start = response.firstIndex(of: "["),
           let end = response.lastIndex(of: "]") {
            let substring = response[start...end]
            if let data = substring.data(using: .utf8),
               let array = try? parseJSONResponse([VideoSegment].self, from: data) {
                return (array, "")
            }
        }

        throw NSError(domain: "OllamaProvider", code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not parse segment response as JSON"])
    }

    private func convertSegmentsToObservations(_ segments: [VideoSegment],
                                              batchStartTime: Date,
                                              videoDuration: TimeInterval,
                                              durationString: String) throws -> (observations: [Observation], coverage: Double) {
        var observations: [Observation] = []
        var totalDuration: TimeInterval = 0
        var lastEndTime: TimeInterval?

        for (index, segment) in segments.enumerated() {
            let startSeconds = TimeInterval(parseVideoTimestamp(segment.startTimestamp))
            let endSeconds = TimeInterval(parseVideoTimestamp(segment.endTimestamp))

            let tolerance: TimeInterval = 30.0
            if startSeconds < -tolerance || endSeconds > videoDuration + tolerance {
                print("[OLLAMA] ❌ Segment \(index + 1) exceeds video duration: \(segment.startTimestamp)-\(segment.endTimestamp) (video is \(durationString))")
                continue
            }

            if let prevEnd = lastEndTime {
                let gap = startSeconds - prevEnd
                if gap > 60.0 {
                    print("[OLLAMA] ⚠️ Gap of \(Int(gap))s between segments at \(String(format: "%02d:%02d", Int(prevEnd) / 60, Int(prevEnd) % 60))")
                }
            }

            let clampedDuration = max(0, endSeconds - startSeconds)
            totalDuration += clampedDuration
            lastEndTime = endSeconds

            let startDate = batchStartTime.addingTimeInterval(startSeconds)
            let endDate = batchStartTime.addingTimeInterval(endSeconds)

            observations.append(
                Observation(
                    id: nil,
                    batchId: 0,
                    startTs: Int(startDate.timeIntervalSince1970),
                    endTs: Int(endDate.timeIntervalSince1970),
                    observation: segment.description,
                    metadata: nil,
                    llmModel: savedModelId,
                    createdAt: Date()
                )
            )
        }

        if observations.isEmpty {
            throw NSError(domain: "OllamaProvider", code: 11, userInfo: [NSLocalizedDescriptionKey: "Screenshots failed to process - check Ollama/LMStudio logs or report a bug."])
        }

        if observations.count > 5 {
            throw NSError(domain: "OllamaProvider", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Generated \(observations.count) observations, but expected 2-5. The LLM must follow the instruction to create EXACTLY 2-5 segments."
            ])
        }

        let coverage = videoDuration > 0 ? totalDuration / videoDuration : 0

        if coverage > 1.2 {
            print("[OLLAMA] ⚠️ Segments exceed video duration by \(Int((coverage - 1) * 100))%")
        }

        return (observations, coverage)
    }

    private func observationsFromFrames(
        _ frameDescriptions: [(timestamp: TimeInterval, description: String)],
        batchStartTime: Date,
        videoDuration: TimeInterval
    ) throws -> [Observation] {
        guard !frameDescriptions.isEmpty else {
            throw NSError(
                domain: "OllamaProvider",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "It looks like your local AI is currently down. Please make sure that your Ollama/LMStudio is up and running properly. If you're having trouble getting local AI to work, consider switching to Gemini in settings."]
            )
        }

        let sortedFrames = frameDescriptions.sorted { $0.timestamp < $1.timestamp }
        let durationCap = videoDuration > 0 ? videoDuration : nil
        var observations: [Observation] = []

        for (index, frame) in sortedFrames.enumerated() {
            let startSeconds = max(0, frame.timestamp)
            var endSeconds = startSeconds + screenshotInterval

            if index + 1 < sortedFrames.count {
                endSeconds = min(endSeconds, sortedFrames[index + 1].timestamp)
            }

            if let cap = durationCap {
                endSeconds = min(endSeconds, cap)
            }

            if endSeconds <= startSeconds {
                endSeconds = startSeconds + max(1, screenshotInterval)
                if let cap = durationCap {
                    endSeconds = min(endSeconds, cap)
                }
            }

            let startDate = batchStartTime.addingTimeInterval(startSeconds)
            let endDate = batchStartTime.addingTimeInterval(endSeconds)

            observations.append(
                Observation(
                    id: nil,
                    batchId: 0,
                    startTs: Int(startDate.timeIntervalSince1970),
                    endTs: Int(endDate.timeIntervalSince1970),
                    observation: frame.description,
                    metadata: nil,
                    llmModel: nil,
                    createdAt: Date()
                )
            )
        }

        return observations
    }

    private func mergeFrameDescriptions(_ frameDescriptions: [(timestamp: TimeInterval, description: String)],
                                      batchStartTime: Date,
                                      videoDuration: TimeInterval,
                                      batchId: Int64?) async throws -> [Observation] {

        var formattedDescriptions = ""
        for frame in frameDescriptions {
            let minutes = Int(frame.timestamp) / 60
            let seconds = Int(frame.timestamp) % 60
            let timeStr = String(format: "%02d:%02d", minutes, seconds)
            formattedDescriptions += "[\(timeStr)] \(frame.description)\n"
        }

        let durationMinutes = Int(videoDuration / 60)
        let durationSeconds = Int(videoDuration.truncatingRemainder(dividingBy: 60))
        let durationString = String(format: "%02d:%02d", durationMinutes, durationSeconds)

        let basePrompt = """
        You have \(frameDescriptions.count) snapshots from a \(durationString) screen recording.

        CRITICAL TASK: Group these snapshots into EXACTLY 2-5 coherent segments that collectively explain \(durationString) of activity. Brief interruptions (< 2 minutes) should be absorbed into the surrounding segment.

        <thinking>
        Draft how you'll group the snapshots before you answer. Decide where the natural breaks occur and ensure the full video is covered.
        </thinking>

        Here are the snapshots (timestamp → description):
        \(formattedDescriptions)

        Respond with a JSON object using this exact shape:
        {
          "reasoning": "Use this space to think through how you're going to construct the segments",
          "segments": [
            {
              "startTimestamp": "MM:SS",
              "endTimestamp": "MM:SS",
              "description": "Natural language summary of what happened"
            }
          ]
        }

        HARD REQUIREMENTS:
        - "segments" MUST contain between 2 and 5 items.
        - Every timestamp must stay within 00:00 and \(durationString).
        - Segments should cover at least 80% of the video (ideally 100%) without inventing events.
        - Merge small gaps instead of creating tiny standalone segments.
        - Never output additional text outside the JSON object.
        """

        let maxAttempts = 2
        var prompt = basePrompt
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let response = try await callTextAPI(
                    prompt,
                    operation: "segment_video_activity",
                    expectJSON: true,
                    batchId: batchId
                )

                let (segments, _) = try decodeSegmentResponse(response)

                let (observations, coverage) = try convertSegmentsToObservations(
                    segments,
                    batchStartTime: batchStartTime,
                    videoDuration: videoDuration,
                    durationString: durationString
                )

                if coverage < 0.8 {
                    throw SegmentCoverageError(coverageRatio: coverage, durationString: durationString)
                }

                return observations
            } catch let coverageError as SegmentCoverageError {
                lastError = coverageError
                let coveragePercent = max(0, min(100, Int(coverageError.coverageRatio * 100)))

                AnalyticsService.shared.captureValidationFailure(
                    provider: "ollama",
                    operation: "segment_video_activity",
                    validationType: "coverage",
                    attempt: attempt,
                    model: savedModelId,
                    batchId: batchId,
                    errorDetail: "Coverage only \(coveragePercent)% (expected >80%)"
                )

                if attempt == maxAttempts {
                    print("[OLLAMA] ❌ segment_video_activity retries exhausted (coverage) — returning raw frame observations")
                    return try observationsFromFrames(
                        frameDescriptions,
                        batchStartTime: batchStartTime,
                        videoDuration: videoDuration
                    )
                }

                print("[OLLAMA] ⚠️ Segment coverage attempt \(attempt) only reached \(coveragePercent)% — retrying")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — Your segments only covered \(coveragePercent)% of the \(durationString) video.
                Merge adjacent snapshots or extend segment boundaries so the segments cover at least 80% of the runtime without inventing events.
                """
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    print("[OLLAMA] ❌ segment_video_activity retries exhausted (error: \(error.localizedDescription)) — returning raw frame observations")
                    return try observationsFromFrames(
                        frameDescriptions,
                        batchStartTime: batchStartTime,
                        videoDuration: videoDuration
                    )
                }

                print("[OLLAMA] ⚠️ segment_video_activity attempt \(attempt) failed: \(error.localizedDescription)")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
                Respond with ONLY the JSON object described above. Ensure it contains a "reasoning" string and a "segments" array with 2-5 items covering at least 80% of the video.
                """
            }
        }

        throw lastError ?? NSError(
            domain: "OllamaProvider",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "Failed to generate merged observations after multiple attempts"]
        )
    }
}

extension OllamaProvider {
    private func applyAuthorizationHeader(to request: inout URLRequest) {
        if isLMStudio {
            request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        } else if isCustomEngine, let token = customAPIKey {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

// MARK: - Text Generation

extension OllamaProvider {
    func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
        let callStart = Date()

        let response = try await callTextAPI(prompt, operation: "generate_text", expectJSON: false, batchId: nil, maxRetries: 3)

        let log = LLMCall(
            timestamp: callStart,
            latency: Date().timeIntervalSince(callStart),
            input: prompt,
            output: response
        )

        return (response.trimmingCharacters(in: .whitespacesAndNewlines), log)
    }
}

// MARK: - Screenshot Transcription

extension OllamaProvider {
    /// Transcribe observations from screenshots.
    func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
        guard !screenshots.isEmpty else {
            throw NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
        }

        let callStart = Date()
        let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

        // Sample ~15 evenly spaced screenshots to avoid hammering the local LLM
        let targetSamples = 15
        let strideAmount = max(1, sortedScreenshots.count / targetSamples)
        let sampledScreenshots = Swift.stride(from: 0, to: sortedScreenshots.count, by: strideAmount).map { sortedScreenshots[$0] }

        // Calculate duration from timestamp range
        let firstTs = sampledScreenshots.first!.capturedAt
        let lastTs = sampledScreenshots.last!.capturedAt
        let durationSeconds = TimeInterval(lastTs - firstTs)

        // Describe each screenshot
        var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []

        for screenshot in sampledScreenshots {
            guard let frameData = loadScreenshotAsFrameData(screenshot, relativeTo: firstTs) else {
                print("[OLLAMA] ⚠️ Failed to load screenshot: \(screenshot.filePath)")
                continue
            }

            if let description = await getSimpleFrameDescription(frameData, batchId: batchId) {
                frameDescriptions.append((timestamp: frameData.timestamp, description: description))
            }
        }

        guard !frameDescriptions.isEmpty else {
            throw NSError(
                domain: "OllamaProvider",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to describe any screenshots. Please check that Ollama/LMStudio is running."]
            )
        }

        // Merge frame descriptions into coherent observations
        let observations = try await mergeFrameDescriptions(
            frameDescriptions,
            batchStartTime: batchStartTime,
            videoDuration: durationSeconds,
            batchId: batchId
        )

        let totalTime = Date().timeIntervalSince(callStart)
        let log = LLMCall(
            timestamp: callStart,
            latency: totalTime,
            input: "Screenshot transcription: \(screenshots.count) screenshots → \(observations.count) observations",
            output: "Processed \(screenshots.count) screenshots in \(String(format: "%.2f", totalTime))s"
        )

        return (observations, log)
    }

    /// Load a screenshot file and convert it to FrameData for description
    private func loadScreenshotAsFrameData(_ screenshot: Screenshot, relativeTo baseTimestamp: Int) -> FrameData? {
        guard let imageData = loadScreenshotDataForOllama(screenshot) else {
            return nil
        }

        let base64String = imageData.base64EncodedString()
        let base64Data = Data(base64String.utf8)
        let relativeTimestamp = TimeInterval(screenshot.capturedAt - baseTimestamp)

        return FrameData(image: base64Data, timestamp: relativeTimestamp)
    }

    private func loadScreenshotDataForOllama(_ screenshot: Screenshot, maxHeight: Double = 720, jpegQuality: CGFloat = 0.85) -> Data? {
        let url = URL(fileURLWithPath: screenshot.filePath)

        guard let image = NSImage(contentsOf: url) else {
            return try? Data(contentsOf: url)
        }

        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first ?? image.representations.first
        let pixelsWide = rep?.pixelsWide ?? Int(image.size.width)
        let pixelsHigh = rep?.pixelsHigh ?? Int(image.size.height)

        if pixelsHigh <= Int(maxHeight) {
            return try? Data(contentsOf: url)
        }

        let scale = maxHeight / Double(pixelsHigh)
        let targetW = max(2, Int((Double(pixelsWide) * scale).rounded(.toNearestOrAwayFromZero)))
        let targetH = Int(maxHeight)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = NSSize(width: targetW, height: targetH)
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        image.draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(targetW), height: CGFloat(targetH)),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: jpegQuality]
        return bitmap.representation(using: NSBitmapImageRep.FileType.jpeg, properties: props)
    }
}
