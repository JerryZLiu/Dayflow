//
//  ChatLLMService.swift
//  Dayflow
//

import Foundation

final class ChatLLMService {
    private let dataProvider = ChatDataProvider()
    private var conversationHistory: [[String: Any]] = []
    private var cachedTier1Data: String = ""
    private var currentDay: String = ""

    private let maxHistoryMessages = 20

    // MARK: - Public API

    func sendMessage(_ text: String, day: String) async throws -> String {
        // Refresh Tier 1 cache if day changed
        if day != currentDay {
            currentDay = day
            cachedTier1Data = dataProvider.fetchTier1Data(day: day)
        }

        // Append user message to conversation
        appendUserMessage(text)

        // Step 1: Router call — decide tier and potentially answer directly
        let decision = try await routerCall(userMessage: text)

        // Step 2: If Tier 1 sufficient and router provided answer, use it directly
        if decision.tier == .summaries, let answer = decision.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendAssistantMessage(answer)
            return answer
        }

        // Step 3: Fetch enriched data and make answerer call
        let answer = try await answererCall(decision: decision, day: day)
        appendAssistantMessage(answer)
        return answer
    }

    func generateDayOverview(day: String) async throws -> String {
        currentDay = day
        cachedTier1Data = dataProvider.fetchTier1Data(day: day)

        guard !cachedTier1Data.isEmpty else {
            return "No activity recorded for this day yet. Start recording to see your day here!"
        }

        let prompt = """
        You are a helpful assistant inside a day-tracking app called Dayflow. The user just opened the chat for their day. Give a brief, friendly overview of their day so far based on this timeline data. Be concise (3-5 sentences). Mention the main activities, approximate time spent, and any notable patterns. Use natural language, not bullet points. Address the user as "you".

        Timeline data:
        \(cachedTier1Data)
        """

        let messages: [[String: Any]] = [
            ["role": "user", "parts": [["text": prompt]]]
        ]

        let config: [String: Any] = [
            "temperature": 0.7,
            "maxOutputTokens": 1024
        ]

        let response = try await LLMService.shared.generateChat(messages: messages, generationConfig: config)
        // Don't add overview to conversationHistory — it's a UI-only greeting.
        // The real conversation starts when the user sends their first message.
        return response
    }

    func resetConversation() {
        conversationHistory = []
        cachedTier1Data = ""
        currentDay = ""
    }

    // MARK: - Router Call

    private func routerCall(userMessage: String) async throws -> ChatRoutingDecision {
        let systemPrompt = """
        You are a data retrieval router for Dayflow, a day-tracking app. The user is chatting about their day.

        You have the following SUMMARY data for today:
        \(cachedTier1Data.isEmpty ? "(No activity data available)" : cachedTier1Data)

        Based on the user's message and the conversation so far, decide what data you need to answer:
        - "summaries": The summary data above is enough (time breakdowns, what they did, categories, apps used). If so, provide your full answer in the "answer" field.
        - "detailed": You need detailed descriptions, specific file names, exact URLs, email contents, code changes (provide time range if relevant).
        - "visual": You need to look at actual screenshots to identify specific visual content on screen (provide time range).

        IMPORTANT: Default to "summaries" whenever possible. Only use "detailed" when the user asks about specifics not in the summaries. Only use "visual" when the user wants to see or identify something visually on screen.

        For time ranges, use "h:mm AM/PM" format (e.g., "2:30 PM"). Set to null for the whole day.

        Respond with JSON only.
        """

        // Build messages: inject system context as first user message, then conversation
        var messages: [[String: Any]] = [
            ["role": "user", "parts": [["text": systemPrompt]]],
            ["role": "model", "parts": [["text": "Understood. I'll route each question to the appropriate data tier and answer from summaries when possible."]]]
        ]

        // Add conversation history (truncated)
        let truncated = truncatedHistory()
        messages.append(contentsOf: truncated)

        let routingSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "tier": ["type": "STRING", "enum": ["summaries", "detailed", "visual"]],
                "timeRangeStart": ["type": "STRING", "nullable": true],
                "timeRangeEnd": ["type": "STRING", "nullable": true],
                "answer": ["type": "STRING", "nullable": true]
            ],
            "required": ["tier"]
        ]

        let config: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": 4096,
            "responseMimeType": "application/json",
            "responseSchema": routingSchema
        ]

        let response = try await LLMService.shared.generateChat(messages: messages, generationConfig: config)
        return try parseRoutingDecision(response)
    }

    // MARK: - Answerer Call

    private func answererCall(decision: ChatRoutingDecision, day: String) async throws -> String {
        // Resolve time range to unix timestamps
        let timeRange = resolveTimeRange(start: decision.timeRangeStart, end: decision.timeRangeEnd, day: day)

        // Build enriched context based on tier
        var contextText = ""
        var imageParts: [[String: Any]] = []

        switch decision.tier {
        case .summaries:
            contextText = cachedTier1Data

        case .detailed:
            contextText = dataProvider.fetchTier2Data(day: day, startTs: timeRange?.start, endTs: timeRange?.end)
            if contextText.isEmpty {
                contextText = cachedTier1Data
            }

        case .visual:
            // Get text context too for grounding
            contextText = dataProvider.fetchTier2Data(day: day, startTs: timeRange?.start, endTs: timeRange?.end)

            let screenshots = dataProvider.fetchTier3Screenshots(day: day, startTs: timeRange?.start, endTs: timeRange?.end)
            for (ss, data) in screenshots {
                let timeStr = formatTs(ss.capturedAt)
                imageParts.append(["text": "Screenshot at \(timeStr):"])
                imageParts.append([
                    "inline_data": [
                        "mime_type": "image/jpeg",
                        "data": data.base64EncodedString()
                    ]
                ])
            }

            if screenshots.isEmpty {
                contextText += "\n\n(No screenshots available for this time range — answering from text data only)"
            }
        }

        // Build the answerer prompt
        let answerPrompt = """
        You are a helpful assistant inside Dayflow, a day-tracking app. Answer the user's question using the activity data provided below. Be conversational, specific, and concise. Address the user as "you". If you're looking at screenshots, describe what you see. If data is insufficient, say so honestly.

        Activity data for context:
        \(contextText)
        """

        // Build messages with conversation history
        var messages: [[String: Any]] = [
            ["role": "user", "parts": [["text": answerPrompt]]],
            ["role": "model", "parts": [["text": "I'll answer based on the activity data provided."]]]
        ]

        // Add conversation history
        let truncated = truncatedHistory()

        // If we have image parts, attach them to the last user message
        if !imageParts.isEmpty, let lastUserIdx = truncated.lastIndex(where: { ($0["role"] as? String) == "user" }) {
            var modifiedHistory = truncated
            if var parts = modifiedHistory[lastUserIdx]["parts"] as? [[String: Any]] {
                parts.append(contentsOf: imageParts)
                modifiedHistory[lastUserIdx]["parts"] = parts
            }
            messages.append(contentsOf: modifiedHistory)
        } else {
            messages.append(contentsOf: truncated)
        }

        let config: [String: Any] = [
            "temperature": 0.7,
            "maxOutputTokens": 8192
        ]

        return try await LLMService.shared.generateChat(messages: messages, generationConfig: config)
    }

    // MARK: - Helpers

    private func appendUserMessage(_ text: String) {
        conversationHistory.append([
            "role": "user",
            "parts": [["text": text]]
        ])
    }

    private func appendAssistantMessage(_ text: String) {
        conversationHistory.append([
            "role": "model",
            "parts": [["text": text]]
        ])
    }

    private func truncatedHistory() -> [[String: Any]] {
        if conversationHistory.count <= maxHistoryMessages {
            return conversationHistory
        }
        return Array(conversationHistory.suffix(maxHistoryMessages))
    }

    private func parseRoutingDecision(_ json: String) throws -> ChatRoutingDecision {
        guard let data = json.data(using: .utf8) else {
            return ChatRoutingDecision(tier: .summaries, timeRangeStart: nil, timeRangeEnd: nil, answer: nil)
        }

        do {
            return try JSONDecoder().decode(ChatRoutingDecision.self, from: data)
        } catch {
            // Try to salvage partial JSON
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let tierStr = dict["tier"] as? String ?? "summaries"
                let tier = ChatDataTier(rawValue: tierStr) ?? .summaries
                return ChatRoutingDecision(
                    tier: tier,
                    timeRangeStart: dict["timeRangeStart"] as? String,
                    timeRangeEnd: dict["timeRangeEnd"] as? String,
                    answer: dict["answer"] as? String
                )
            }
            return ChatRoutingDecision(tier: .summaries, timeRangeStart: nil, timeRangeEnd: nil, answer: nil)
        }
    }

    private func resolveTimeRange(start: String?, end: String?, day: String) -> (start: Int, end: Int)? {
        guard let startStr = start, let endStr = end else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = Calendar.current.timeZone
        guard let dayDate = dayFormatter.date(from: day) else { return nil }

        // Try parsing various time formats
        for format in ["h:mm a", "h:mm:ss a", "H:mm", "h a"] {
            formatter.dateFormat = "yyyy-MM-dd \(format)"
            let dayStr = dayFormatter.string(from: dayDate)

            if let startDate = formatter.date(from: "\(dayStr) \(startStr)"),
               let endDate = formatter.date(from: "\(dayStr) \(endStr)") {
                // Add buffer: 5 minutes before start, 5 minutes after end
                let startTs = Int(startDate.timeIntervalSince1970) - 300
                let endTs = Int(endDate.timeIntervalSince1970) + 300
                return (startTs, endTs)
            }
        }

        return nil
    }

    private func formatTs(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}
