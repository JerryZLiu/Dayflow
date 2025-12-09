//
//  OllamaProvider.swift
//  Dayflow
//

import Foundation
import AppKit

final class OllamaProvider: LLMProvider {
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

    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        let callStart = Date()
        var logs: [String] = []
        
        let sortedObservations = context.batchObservations.sorted { $0.startTs < $1.startTs }
        
        
        // Generate initial activity card for these observations
        let (titleSummary, firstLog) = try await generateTitleAndSummary(
            observations: sortedObservations,
            categories: context.categories,
            batchId: batchId
        )
        logs.append(firstLog)
        
        let normalizedCategory = normalizeCategory(titleSummary.category, categories: context.categories)

        let initialCard = ActivityCardData(
            startTime: formatTimestampForPrompt(sortedObservations.first!.startTs),
            endTime: formatTimestampForPrompt(sortedObservations.last!.endTs),
            category: normalizedCategory,
            subcategory: "",
            title: titleSummary.title,
            summary: titleSummary.summary,
            detailedSummary: "",
            distractions: nil,
            appSites: nil
        )
        
        var allCards = context.existingCards
        
        // Check if we should merge with the last existing card
        if !allCards.isEmpty, let lastExistingCard = allCards.last {
            // Hard cap: Don't even try to merge if the last card is already 25+ minutes
            let lastCardDuration = calculateDurationInMinutes(from: lastExistingCard.startTime, to: lastExistingCard.endTime)
            
            print("[DEBUG] Last card: \(lastExistingCard.startTime) - \(lastExistingCard.endTime) (\(lastCardDuration) minutes)")
            print("[DEBUG] New card: \(initialCard.startTime) - \(initialCard.endTime)")
            
            if lastCardDuration >= 40 {
                print("[DEBUG] Skipping merge - last card already \(lastCardDuration) minutes")
                allCards.append(initialCard)
            } else {
                let gapMinutes = calculateDurationInMinutes(from: lastExistingCard.endTime, to: initialCard.startTime)
                if gapMinutes > 5 {
                    print("[DEBUG] Skipping merge - gap between cards is \(gapMinutes) minutes")
                    allCards.append(initialCard)
                } else {
                    let candidateDuration = calculateDurationInMinutes(from: lastExistingCard.startTime, to: initialCard.endTime)
                    if candidateDuration > 60 {
                        print("[DEBUG] Skipping merge - merged card would be \(candidateDuration) minutes")
                        allCards.append(initialCard)
                    } else {
                        let (shouldMerge, mergeLog) = try await checkShouldMerge(
                            previousCard: lastExistingCard,
                            newCard: initialCard,
                            batchId: batchId
                        )
                        logs.append(mergeLog)

                        print("[DEBUG] Merge decision: \(shouldMerge)")

                        if shouldMerge {
                            let (mergedCard, mergeCreateLog) = try await mergeTwoCards(
                                previousCard: lastExistingCard,
                                newCard: initialCard,
                                batchId: batchId
                            )

                            let mergedDuration = calculateDurationInMinutes(from: mergedCard.startTime, to: mergedCard.endTime)
                            print("[DEBUG] Merged card: \(mergedCard.startTime) - \(mergedCard.endTime) (\(mergedDuration) minutes)")

                            if mergedDuration > 60 {
                                print("[DEBUG] Discarding merged card - duration exceeds safety cap")
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
            print("[DEBUG] No existing cards, adding initial card")
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
    
    private func parseActivityCards(from data: Data) throws -> [ActivityCardData] {
        // Define response structure
        struct ResponseCard: Codable {
            let startTime: String
            let endTime: String
            let category: String
            let subcategory: String
            let title: String
            let summary: String
            let detailedSummary: String
            let distractions: [ResponseDistraction]?
        }
        
        struct ResponseDistraction: Codable {
            let startTime: String
            let endTime: String
            let title: String
            let summary: String
        }
        
        // Helper function to convert ResponseCard to ActivityCardData
        func convertCard(_ card: ResponseCard) -> ActivityCardData {
            return ActivityCardData(
                startTime: card.startTime,
                endTime: card.endTime,
                category: card.category,
                subcategory: card.subcategory,
                title: card.title,
                summary: card.summary,
                detailedSummary: card.detailedSummary,
                distractions: card.distractions?.map { d in
                    Distraction(
                        startTime: d.startTime,
                        endTime: d.endTime,
                        title: d.title,
                        summary: d.summary
                    )
                },
                appSites: nil
            )
        }
        
        // First try to decode as array
        do {
            let responseCards = try JSONDecoder().decode([ResponseCard].self, from: data)
            return responseCards.map(convertCard)
        } catch {
            // Try to decode as single object
            do {
                let singleCard = try JSONDecoder().decode(ResponseCard.self, from: data)
                return [convertCard(singleCard)]
            } catch {
                // If that fails, try to extract JSON from the response
            
            guard let responseString = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "OllamaProvider", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response as string"])
            }
            
            // Try to find JSON array in the response
            if let startIndex = responseString.firstIndex(of: "["),
               let endIndex = responseString.lastIndex(of: "]") {
                let jsonSubstring = responseString[startIndex...endIndex]
                if let jsonData = jsonSubstring.data(using: .utf8) {
                    let responseCards = try JSONDecoder().decode([ResponseCard].self, from: jsonData)
                    return responseCards.map(convertCard)
                }
            }
            
                throw NSError(domain: "OllamaProvider", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not find valid JSON array in response: \(error.localizedDescription)"])
            }
        }
    }
    
    
    private struct FrameData {
        let image: Data  // Base64 encoded image
        let timestamp: TimeInterval  // Seconds from batch start
    }

    private struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double = 0.7
        let max_tokens: Int = 4000
        let stream: Bool = false
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
        var content: [MessageContent] = [
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
            do {
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                applyAuthorizationHeader(to: &urlRequest)
                urlRequest.httpBody = try JSONEncoder().encode(request)
                urlRequest.timeoutInterval = 60.0  // 60-second timeout
                
                let apiStart = Date()
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
                    startedAt: apiStart
                )
                ctxForAttempt = ctx
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let apiTime = Date().timeIntervalSince(apiStart)
                
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
    }

    private struct SummaryResponse: Codable {
        let reasoning: String
        let summary: String
        let category: String
    }

    private struct TitleResponse: Codable {
        let reasoning: String
        let title: String
    }

    private struct MergeDecision: Codable {
        let reason: String
        let combine: Bool
        let confidence: Double
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


    private func generateSummary(observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?) async throws -> (SummaryResponse, String) {
        print("[DEBUG] generateSummary - Input observations:")
        for (i, obs) in observations.enumerated() {
            print("  [\(i)] observation type: \(type(of: obs.observation))")
            print("       observation value: \(obs.observation)")
        }

        let observationLines: [String] = observations.map { obs in
            let startTime = formatTimestampForPrompt(obs.startTs)
            let endTime = formatTimestampForPrompt(obs.endTs)
            print("[DEBUG] generateSummary processing observation: \(obs.observation)")
            return "[\(startTime) - \(endTime)]: \(obs.observation)"
        }
        let observationsText: String = stripUserReferences(observationLines.joined(separator: "\n\n"))

        print("[DEBUG] generateSummary observationsText:")
        print(observationsText)

        let descriptorList = categories.isEmpty ? CategoryStore.descriptorsForLLM() : categories
        let categoryLines: [String] = descriptorList.enumerated().map { index, descriptor in
            var description = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if descriptor.isIdle && description.isEmpty {
                description = "Use when the user is idle for most of the period."
            }
            let dashDescription = description.isEmpty ? "" : " — \(description)"
            print("[DEBUG] generateSummary processing category: \(descriptor.name)")
            return "- \"\(descriptor.name)\"\(dashDescription)"
        }
        let categoriesSection: String = categoryLines.joined(separator: "\n")

        print("[DEBUG] generateSummary categoriesSection:")
        print(categoriesSection)

        let allowedValues: String = descriptorList
            .map { "\"\($0.name)\"" }
            .joined(separator: ", ")

        let promptSections = OllamaPromptSections(overrides: OllamaPromptPreferences.load())

        let basePrompt = """
        You are analyzing someone's computer activity from the last 15 minutes.

        Activity periods:
        \(observationsText)

          Create a summary that captures what happened during this time period.

        \(promptSections.summary)

        CATEGORIES:
        Choose exactly one:
        \(categoriesSection)

          REASONING:
          Explain your thinking process:
          1. What were the main activities and how much time was spent on each?
          2. Was this primarily work-related, personal, or brief distractions?
          3. Which category best fits based on the MAJORITY of time and focus?
          4. How did you structure the summary to capture the most important activities?

        Return JSON:
        {
          "reasoning": "Your step-by-step thinking process",
          "summary": "Your 2-3 sentence summary",
          "category": "\(allowedValues)"
        }
        """

        print("[DEBUG] generateSummary final prompt:")

        let maxAttempts = 3
        var prompt = basePrompt
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                print("[DEBUG] generateSummary attempt \(attempt)")
                let response = try await callTextAPI(prompt, operation: "generate_summary", expectJSON: true, batchId: batchId)

                guard let data = response.data(using: .utf8) else {
                    throw NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to parse summary response"])
                }

                let result = try parseJSONResponse(SummaryResponse.self, from: data)

                print("[DEBUG] Summary generation result:")
                print("  Reasoning: \(result.reasoning)")
                print("  Summary: \(result.summary)")
                print("  Category: \(result.category)")

                return (result, response)
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    throw error
                }

                print("[OLLAMA] ⚠️ generateSummary attempt \(attempt) failed: \(error.localizedDescription)")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
                Respond with ONLY the JSON object described above. Ensure it contains "reasoning", "summary", and "category" fields.
                """
            }
        }

        throw lastError ?? NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to generate summary after multiple attempts"])
    }


    private func generateTitle(summary: String, batchId: Int64?) async throws -> (TitleResponse, String) {
        print("[DEBUG] generateTitle - Input summary:")
        print("Summary type: \(type(of: summary))")
        print("Summary value: \(summary)")

        let promptSections = OllamaPromptSections(overrides: OllamaPromptPreferences.load())

        let basePrompt = """
        Create a casual, conversational title for this activity summary.

        INPUT SUMMARY:
        "\(summary)"

        \(promptSections.title)

        Return JSON:
        {
          "reasoning": "Explain how you chose the title",
          "title": "5-8 word conversational title highlighting one standout activity (optionally plus one other dominant action) using only summary facts"
        }

        Avoid comma-separated lists or multiple conjunctions; only mention a second activity if it clearly shares the spotlight without turning into a checklist.
        Always describe what happened (e.g., "Reviewed GitHub PRs") instead of just naming apps or panes.
        """

        print("[DEBUG] generateTitle final prompt:")

        let maxAttempts = 3
        var prompt = basePrompt
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                print("[DEBUG] generateTitle attempt \(attempt)")
                let response = try await callTextAPI(prompt, operation: "generate_title", expectJSON: true, batchId: batchId)

                guard let data = response.data(using: .utf8) else {
                    throw NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to parse title response"])
                }

                let result = try parseJSONResponse(TitleResponse.self, from: data)

                print("[DEBUG] Title generation result:")
                print("  Reasoning: \(result.reasoning)")
                print("  Title: \(result.title)")

                return (result, response)
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    throw error
                }

                print("[OLLAMA] ⚠️ generateTitle attempt \(attempt) failed: \(error.localizedDescription)")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
                Respond with ONLY the JSON object described above. Ensure the title uses 5-8 words drawn from the summary details.
                """
            }
        }

        throw lastError ?? NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to generate title after multiple attempts"])
    }

    private func generateTitleAndSummary(observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?) async throws -> (TitleSummaryResponse, String) {
        print("[DEBUG] generateTitleAndSummary - Starting two-step approach")

        // Step 1: Generate summary + category
        print("[DEBUG] generateTitleAndSummary - Step 1: Generating summary")
        let (summaryResult, summaryLog) = try await generateSummary(
            observations: observations,
            categories: categories,
            batchId: batchId
        )

        // Step 2: Generate title from summary
        print("[DEBUG] generateTitleAndSummary - Step 2: Generating title from summary")
        let (titleResult, titleLog) = try await generateTitle(summary: summaryResult.summary, batchId: batchId)

        // Combine into the expected response format
        let combinedResult = TitleSummaryResponse(
            reasoning: "Summary: \(summaryResult.reasoning) | Title: \(titleResult.reasoning)",
            title: titleResult.title,
            summary: summaryResult.summary,
            category: summaryResult.category
        )

        // Combine logs
        let combinedLog = "=== SUMMARY GENERATION ===\n\(summaryLog)\n\n=== TITLE GENERATION ===\n\(titleLog)"

        print("[DEBUG] generateTitleAndSummary - Two-step generation complete:")
        print("  Final Title: \(combinedResult.title)")
        print("  Final Summary: \(combinedResult.summary)")
        print("  Final Category: \(combinedResult.category)")

        return (combinedResult, combinedLog)
    }
    

    private func checkShouldMerge(previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?) async throws -> (Bool, String) {
        let basePrompt = """
        Look at these two consecutive activity periods and decide if they should be combined into one card.

        Previous activity (\(previousCard.startTime) - \(previousCard.endTime)):
        Title: \(previousCard.title)
        Summary: \(previousCard.summary)

        New activity (\(newCard.startTime) - \(newCard.endTime)):
        Title: \(newCard.title)
        Summary: \(newCard.summary)

        MERGE DECISION RULE:
        The Golden Rule: When merged, they should tell one coherent story, not two different ones

        MERGE ONLY IF:
        ✓ Same project or closely related task
        ✓ Not a context switch
        ✓ You're 80%+ confident they're the same activity

        GOOD MERGING EXAMPLES:
        ✓ MERGE: "Debugging auth flow in VS Code" + "Testing auth endpoints in Postman"
          (Same exact auth bug work continuing, confidence: 0.95)
        ✓ MERGE: "Writing Q3 report in Docs" + "Adding charts to Q3 report"
          (Same document, natural progression, confidence: 0.92)
        ✓ MERGE: "Refactoring UserProfile component" + "Testing UserProfile after refactor"
          (Same component, testing what was just built, confidence: 0.91)

        BAD MERGING EXAMPLES:
        ✗ DON'T MERGE: "Debugging Dayflow timeline cards" + "Checking Twitter & Reddit"
          (Work interrupted by social media = context switch, confidence: 0.4)
        ✗ DON'T MERGE: "Fixed CORS bug in API" + "Started implementing user dashboard"
          (Different features, even same project, confidence: 0.6)
        ✗ DON'T MERGE: "Writing docs for API" + "Debugging API endpoints"
          (Documentation vs. coding = different mental modes, confidence: 0.7)
        ✗ DON'T MERGE: "Reviewing PR comments" + "Working on new feature"
          (Review work vs. creation work, confidence: 0.5)
        ✗ DON'T MERGE: "Python data analysis" + "Answering Slack messages"
          (Deep work vs. communication, confidence: 0.3)
        ✗ DON'T MERGE: "Researching React patterns" + "Implementing React component"
          (Research/learning vs. actual coding, confidence: 0.8)
        ✗ DON'T MERGE: "Email, Twitter, general browsing" + "More email and browsing"
          (Too vague - what emails? what browsing?, confidence: 0.4)

        CONFIDENCE SCORING:
        - 0.9-1.0: Same exact activity continuing (merge)
        - 0.7-0.9: Related but slightly different (probably don't merge)
        - 0.5-0.7: Somewhat related (don't merge)
        - 0.0-0.5: Different activities (definitely don't merge)

        Remember: You need 0.8+ confidence to merge!

        Return JSON:
        {
          "reason": "Brief explanation of your decision",
          "combine": true or false,
          "confidence": 0.0 to 1.0
        }
        """

        let confidenceThreshold = 0.8
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

                let shouldMerge = decision.combine && decision.confidence >= confidenceThreshold

                print("[DEBUG] Merge check input:")
                print("  Previous: \(previousCard.title) (\(previousCard.startTime) - \(previousCard.endTime))")
                print("  New: \(newCard.title) (\(newCard.startTime) - \(newCard.endTime))")
                print("[DEBUG] Merge check result:")
                print("  Raw decision: \(decision.combine ? "MERGE" : "KEEP SEPARATE")")
                print("  Confidence: \(String(format: "%.2f", decision.confidence))")
                print("  Final decision: \(shouldMerge ? "MERGE" : "KEEP SEPARATE") (threshold: \(confidenceThreshold))")
                print("  Reason: \(decision.reason)")

                return (shouldMerge, response)
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    throw error
                }

                print("[OLLAMA] ⚠️ evaluate_card_merge attempt \(attempt) failed: \(error.localizedDescription)")

                prompt = basePrompt + """


                PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
                Return ONLY the JSON object described above with "reason", "combine", and "confidence" fields.
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
        Title: 5-8 words, conversational, spotlight the main through-line. You may mention one other equally dominant action, but connect it with a quick “while” or em dash—never comma lists or “and” chains. Cite only the most important apps/sites rather than every noun.
        Summary: Two sentences max, first-person perspective without using the word I. Retell how the work flowed from the first card into the second with concrete verbs (debugged, reviewed, watched) and name the stand-out tools/topics once each. Skip laundry lists, filler like “various tasks,” and bullet points.
        Avoid the words social, media, platform, platforms, interaction, interactions, various, engaged, blend, activity, activities.
        Do not refer to the user; write from the user’s perspective.

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
                    appSites: previousCard.appSites
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

        func asNSError() -> NSError {
            NSError(
                domain: "OllamaProvider",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: errorDescription ?? "Segments failed coverage validation."]
            )
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

                let (segments, reasoning) = try decodeSegmentResponse(response)
                let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedReasoning.isEmpty {
                    print("[OLLAMA] Segment reasoning (attempt \(attempt)): \(trimmedReasoning)")
                }

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
                if attempt == maxAttempts {
                    print("[OLLAMA] ❌ segment_video_activity retries exhausted (coverage) — returning raw frame observations")
                    return try observationsFromFrames(
                        frameDescriptions,
                        batchStartTime: batchStartTime,
                        videoDuration: videoDuration
                    )
                }

                let coveragePercent = max(0, min(100, Int(coverageError.coverageRatio * 100)))
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

        // Calculate duration from timestamp range
        let firstTs = sortedScreenshots.first!.capturedAt
        let lastTs = sortedScreenshots.last!.capturedAt
        let durationSeconds = TimeInterval(lastTs - firstTs)

        // Describe each screenshot
        var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []

        for screenshot in sortedScreenshots {
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
        let url = URL(fileURLWithPath: screenshot.filePath)

        guard let imageData = try? Data(contentsOf: url) else {
            return nil
        }

        let base64String = imageData.base64EncodedString()
        let base64Data = Data(base64String.utf8)
        let relativeTimestamp = TimeInterval(screenshot.capturedAt - baseTimestamp)

        return FrameData(image: base64Data, timestamp: relativeTimestamp)
    }
}
