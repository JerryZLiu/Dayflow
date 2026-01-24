//
//  ChatService.swift
//  Dayflow
//
//  Orchestrates chat conversations with the LLM, handling tool calls
//  and maintaining conversation state.
//

import Foundation
import Combine

private let chatServiceLongDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    return formatter
}()

private let chatServiceTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
}()

private let chatServiceDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private let chatServiceDisplayDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter
}()

/// A debug log entry for the chat debug panel
struct ChatDebugEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: EntryType
    let content: String

    enum EntryType: String {
        case user = "📝 USER"
        case prompt = "📤 PROMPT"
        case response = "📥 RESPONSE"
        case toolDetected = "🔧 TOOL DETECTED"
        case toolResult = "📊 TOOL RESULT"
        case error = "❌ ERROR"
        case info = "ℹ️ INFO"
    }

    var typeColor: String {
        switch type {
        case .user: return "F96E00"
        case .prompt: return "4A90D9"
        case .response: return "7B68EE"
        case .toolDetected: return "F96E00"
        case .toolResult: return "34C759"
        case .error: return "FF3B30"
        case .info: return "8E8E93"
        }
    }
}

/// Status data for the in-progress chat panel
struct ChatWorkStatus: Sendable, Equatable {
    let id: UUID
    var stage: Stage
    var thinkingText: String
    var tools: [ToolRun]
    var errorMessage: String?
    var lastUpdated: Date

    enum Stage: Sendable, Equatable {
        case thinking
        case runningTools
        case answering
        case error
    }

    enum ToolState: Sendable, Equatable {
        case running
        case completed
        case failed
    }

    struct ToolRun: Identifiable, Sendable, Equatable {
        let id: UUID
        let command: String
        var state: ToolState
        var summary: String
        var output: String
        var exitCode: Int?
    }

    var hasDetails: Bool {
        let trimmedThinking = thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedThinking.isEmpty { return true }
        return tools.contains { !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var hasErrors: Bool {
        if stage == .error { return true }
        if tools.contains(where: { $0.state == .failed }) { return true }
        if let message = errorMessage, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }
}

/// Orchestrates chat conversations with tool-calling support
@MainActor
final class ChatService: ObservableObject {

    // MARK: - Singleton

    static let shared = ChatService()

    // MARK: - Published State

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var streamingText = ""
    @Published private(set) var error: String?
    @Published private(set) var debugLog: [ChatDebugEntry] = []
    @Published private(set) var workStatus: ChatWorkStatus?
    @Published private(set) var currentSuggestions: [String] = []
    @Published var showDebugPanel = false

    // MARK: - Private

    private var conversationHistory: [(role: String, content: String)] = []
    private var currentSessionId: String?

    // MARK: - Debug Logging

    private func log(_ type: ChatDebugEntry.EntryType, _ content: String) {
        let entry = ChatDebugEntry(timestamp: Date(), type: type, content: content)
        debugLog.append(entry)
        // Also print to console for Xcode debugging
        print("[\(type.rawValue)] \(content.prefix(200))...")
    }

    func clearDebugLog() {
        debugLog = []
    }

    // MARK: - Public API

    /// Send a user message and get a response
    func sendMessage(_ content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isProcessing else { return }

        isProcessing = true
        error = nil
        streamingText = ""
        workStatus = nil
        currentSuggestions = []

        // Add user message
        let userMessage = ChatMessage.user(content)
        messages.append(userMessage)
        conversationHistory.append((role: "user", content: content))
        log(.user, content)

        // Process with potential tool calls
        await processConversation()

        isProcessing = false
    }

    /// Clear the conversation
    func clearConversation() {
        messages = []
        conversationHistory = []
        streamingText = ""
        error = nil
        workStatus = nil
        currentSuggestions = []
        currentSessionId = nil
    }

    // MARK: - Conversation Processing

    private func processConversation() async {
        // Build prompt - full prompt for new session, just user message for resume
        let prompt: String
        let isResume = currentSessionId != nil

        if isResume {
            // For resumed sessions, just send the latest user message
            prompt = conversationHistory.last?.content ?? ""
            log(.prompt, "[Resuming session \(currentSessionId!)] \(prompt)")
        } else {
            // For new sessions, send full prompt with system context
            prompt = buildFullPrompt()
            log(.prompt, prompt)
        }

        // Track state during streaming
        var responseText = ""
        var currentToolId: UUID?
        var pendingToolSeparator = false
        var sawTextDelta = false
        streamingText = ""
        startWorkStatus()

        // Add response message only when text arrives
        var responseMessageId: UUID?

        func appendWithToolSeparatorIfNeeded(_ chunk: String) {
            if pendingToolSeparator {
                if let last = responseText.last, !last.isWhitespace,
                   let first = chunk.first, !first.isWhitespace {
                    responseText += " "
                }
                pendingToolSeparator = false
            }
            responseText += chunk
        }

        do {
            // Use rich streaming with thinking and tool events
            let stream = LLMService.shared.generateChatStreaming(prompt: prompt, sessionId: currentSessionId)

            for try await event in stream {
                switch event {
                case .sessionStarted(let id):
                    // Capture session ID for future messages
                    if currentSessionId == nil {
                        currentSessionId = id
                        log(.info, "📍 Session started: \(id)")
                    }

                case .thinking(let text):
                    log(.info, "💭 Thinking: \(text)")
                    updateWorkStatus { status in
                        status.stage = .thinking
                        status.thinkingText += text
                    }

                case .toolStart(let command):
                    log(.toolDetected, "Starting: \(command)")
                    let toolId = UUID()
                    currentToolId = toolId
                    updateWorkStatus { status in
                        status.stage = .runningTools
                        status.tools.append(ChatWorkStatus.ToolRun(
                            id: toolId,
                            command: command,
                            state: .running,
                            summary: toolSummary(command: command, output: "", exitCode: nil),
                            output: "",
                            exitCode: nil
                        ))
                    }

                case .toolEnd(let output, let exitCode):
                    log(.toolResult, "Exit \(exitCode ?? 0): \(output.prefix(100))...")
                    let toolId = currentToolId
                    updateWorkStatus { status in
                        let toolIndex = toolCompletionIndex(in: status, preferredId: toolId)
                        guard let toolIndex else { return }
                        let summary = toolSummary(
                            command: status.tools[toolIndex].command,
                            output: output,
                            exitCode: exitCode
                        )
                        status.tools[toolIndex].summary = summary
                        status.tools[toolIndex].output = output
                        status.tools[toolIndex].exitCode = exitCode
                        if let exitCode, exitCode != 0 {
                            status.tools[toolIndex].state = .failed
                            status.stage = .error
                            status.errorMessage = summary
                        } else {
                            status.tools[toolIndex].state = .completed
                        }
                    }
                    currentToolId = nil
                    pendingToolSeparator = true

                case .textDelta(let chunk):
                    sawTextDelta = true
                    appendWithToolSeparatorIfNeeded(chunk)
                    streamingText = responseText
                    updateWorkStatus { status in
                        if status.stage != .error {
                            status.stage = .answering
                        }
                    }

                    // Update response message in place
                    if let id = responseMessageId,
                       let index = messages.firstIndex(where: { $0.id == id }) {
                        messages[index] = ChatMessage(
                            id: id,
                            role: .assistant,
                            content: responseText
                        )
                    } else if responseMessageId == nil {
                        let id = UUID()
                        responseMessageId = id
                        messages.append(ChatMessage(
                            id: id,
                            role: .assistant,
                            content: responseText
                        ))
                    }

                case .complete(let text):
                    if responseText.isEmpty {
                        responseText = text
                        pendingToolSeparator = false
                    } else if pendingToolSeparator {
                        appendWithToolSeparatorIfNeeded(text)
                    } else if !sawTextDelta {
                        responseText = text
                    }
                    streamingText = responseText
                    log(.response, responseText)
                    if let id = responseMessageId,
                       let index = messages.firstIndex(where: { $0.id == id }) {
                        messages[index] = ChatMessage(
                            id: id,
                            role: .assistant,
                            content: responseText
                        )
                    } else if responseMessageId == nil,
                              !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let id = UUID()
                        responseMessageId = id
                        messages.append(ChatMessage(
                            id: id,
                            role: .assistant,
                            content: responseText
                        ))
                    }

                case .error(let errorMessage):
                    log(.error, errorMessage)
                    self.error = errorMessage
                    updateWorkStatus { status in
                        status.stage = .error
                        status.errorMessage = errorMessage
                    }
                }
            }
        } catch {
            // Show error
            log(.error, "LLM error: \(error.localizedDescription)")
            self.error = error.localizedDescription
            if workStatus == nil {
                startWorkStatus()
            }
            updateWorkStatus { status in
                status.stage = .error
                status.errorMessage = error.localizedDescription
            }

            // Update response message with error
            if let id = responseMessageId,
               let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index] = ChatMessage.assistant("I encountered an error: \(error.localizedDescription)")
            } else {
                messages.append(ChatMessage.assistant("I encountered an error: \(error.localizedDescription)"))
            }
            streamingText = ""
            return
        }

        streamingText = ""

        if let status = workStatus, !status.hasErrors {
            workStatus = nil
        }

        // Parse suggestions from response
        let (cleanedText, suggestions) = parseSuggestions(from: responseText)
        currentSuggestions = suggestions

        // Update final response (with suggestions block removed)
        if let id = responseMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            // Remove response message if empty (error case or no response)
            if cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.remove(at: index)
            } else {
                messages[index] = ChatMessage(
                    id: id,
                    role: .assistant,
                    content: cleanedText
                )
            }
        }

        // Add to conversation history (keep original with suggestions for context)
        if !responseText.isEmpty {
            conversationHistory.append((role: "assistant", content: responseText))
        }
    }

    // MARK: - Prompt Building

    private func buildFullPrompt() -> String {
        let systemPrompt = buildSystemPrompt()

        var prompt = systemPrompt + "\n\n"

        // Add conversation history
        for entry in conversationHistory {
            switch entry.role {
            case "user":
                prompt += "User: \(entry.content)\n\n"
            case "assistant":
                prompt += "Assistant: \(entry.content)\n\n"
            case "system":
                prompt += "[System: \(entry.content)]\n\n"
            default:
                break
            }
        }

        prompt += "Assistant:"
        return prompt
    }

    private func buildSystemPrompt() -> String {
        let now = Date()
        let currentDate = chatServiceLongDateFormatter.string(from: now)
        let currentTime = chatServiceTimeFormatter.string(from: now)

        // Use full path (~ doesn't expand in sqlite3)
        let dbPath = NSHomeDirectory() + "/Library/Application Support/Dayflow/chunks.sqlite"

        return """
        You are a friendly assistant in Dayflow, a macOS app that tracks computer activity.

        Current date: \(currentDate)
        Current time: \(currentTime)
        Day boundary: Days start at 4:00 AM (not midnight)

        ## DATABASE

        Path: \(dbPath)
        Query: sqlite3 "\(dbPath)" "YOUR SQL"

        ### Tables

        **timeline_cards** - High-level activity summaries (start here)
        - day (YYYY-MM-DD), start_ts/end_ts (epoch seconds)
        - title, summary, detailed_summary, category, subcategory (detailed_summary is large—only pull if you really need the granularity)
        - category values: Work, Personal, Distraction, Idle, System
        - is_deleted (0=active, 1=deleted) - ALWAYS filter is_deleted=0
        - Ignore "processing failed" cards unless user explicitly asks about them
        - Duration in minutes: (end_ts - start_ts)/60

        **observations** - Low-level granular snapshots (for deeper analysis)
        - Raw activity descriptions captured every few minutes
        - Use when user wants more specific information

        ### Data Fetching

        - **Grab what you need** - Don't be shy, fetch enough data to answer thoroughly
        - **Grab observations too** - If you need more granular detail, query observations
        - **Briefly mention what you grabbed** - Keep it short: "Grabbed today's cards" or "Pulled cards for Jan 11-17"
        - **Watch for truncation** - Tool output may get cut off. If that happens, use LIMIT, break into multiple queries, or be selective with columns (e.g., exclude detailed_summary)
        - **Prefer human-readable times when needed** - Use SQLite datetime() with localtime for start/end

        ### Interpretation rules (read raw data)

        - This data is LLM-generated and not standardized. Avoid brittle SQL filtering.
        - Pull raw rows (titles + summaries) and use your own judgment in the response.
        - Titles/summaries may use different terms for the same thing (e.g., X vs Twitter).

        Examples:
        - "How much did I focus this week?" → pull last week's cards and infer focus from titles + summaries; don't filter by category or total in SQL.
        - "How long on Twitter?" → scan titles + summaries for Twitter/X mentions; don't filter only on title.

        ### Negative examples (don't do this)

        1) Context switches (bad: category transitions)
           - Bad approach: Use window functions (LAG) + GROUP BY category/subcategory to count switches.
           - Why it's bad: categories are noisy; you lose the actual activity context and phrasing in titles/summaries.
           - Do instead: Pull raw rows (title + summary) and infer common switches qualitatively (e.g., "coding → browsing threads").

        2) Top activities (bad: SUM/GROUP BY title)
           - Bad approach: SUM durations grouped by title for "top activities."
           - Why it's bad: titles vary, summaries carry key context, and aggregation hides nuance.
           - Do instead: Read raw cards and summarize the dominant themes.

        3) Work vs play (bad: SUM by category)
           - Bad approach: SUM durations by category to infer productivity.
           - Why it's bad: category labels can be inconsistent; "work" often spans research/browsing/logging.
           - Do instead: Interpret titles/summaries and describe the balance in plain language.

        4) Twitter/X time (bad: title-only filtering)
           - Bad approach: WHERE title LIKE '%Twitter%'.
           - Why it's bad: activity might be labeled "X", or only mentioned in summaries.
           - Do instead: Scan titles + summaries for Twitter/X mentions and summarize.

        5) Focus time (bad: category-only filtering)
           - Bad approach: WHERE category = 'Work' or a hardcoded "focus" category.
           - Why it's bad: focus is a judgment call and may include deep research or analysis labeled differently.
           - Do instead: Infer focus from the actual content in titles/summaries.

        Human-readable timeline template (use when you need readable times):
        SELECT
          datetime(start_ts, 'unixepoch', 'localtime') AS start_time,
          datetime(end_ts, 'unixepoch', 'localtime') AS end_time,
          title,
          summary,
          category,
          subcategory
        FROM timeline_cards
        WHERE day = '\(todayDate())' AND is_deleted = 0
        ORDER BY start_ts

        ## INLINE CHARTS (OPTIONAL)

        You may include inline charts inside your markdown response. Use fenced chart blocks exactly like this:

        ```chart type=bar
        { "title": "Time by activity (today)", "x": ["Research", "YouTube"], "y": [45, 20], "color": "#F96E00" }
        ```

        ```chart type=line
        { "title": "Focus time by day", "x": ["Mon", "Tue", "Wed"], "y": [2.5, 3.0, 1.8], "color": "#1F6FEB" }
        ```

        ```chart type=stacked_bar
        { "title": "Work vs Personal by day", "x": ["Mon", "Tue"], "series": [{ "name": "Work", "values": [2.5, 3.1], "color": "#1F6FEB" }, { "name": "Personal", "values": [1.2, 0.8], "color": "#F96E00" }] }
        ```

        ```chart type=donut
        { "title": "Time split (today)", "labels": ["Work", "Personal"], "values": [3.0, 5.7], "colors": ["#1F6FEB", "#F96E00"] }
        ```

        ```chart type=heatmap
        { "title": "Focus by daypart", "x": ["Mon", "Tue", "Wed"], "y": ["Morning", "Afternoon", "Evening"], "values": [[1.2, 0.8, 1.5], [2.0, 1.6, 1.1], [0.7, 1.0, 0.9]], "color": "#1F6FEB" }
        ```

        ```chart type=gantt
        { "title": "Focus blocks (today)", "items": [{ "label": "Research", "start": 9.0, "end": 10.5, "color": "#1F6FEB" }, { "label": "Break", "start": 10.5, "end": 11.0, "color": "#F96E00" }] }
        ```

        RULES:
        - Allowed chart types: bar, line, stacked_bar
        - JSON must be valid (double quotes, no trailing commas)
        - x and y must be arrays of the same length
        - Use numbers only for y values
        - Optional: color can be a hex string like "#F96E00" or "F96E00"
        - For stacked_bar: provide x categories and a series array; each series needs name + values (values count must match x); color optional per series
        - For donut: provide labels + values (same length); optional colors array (same length) for slice colors
        - For heatmap: provide x labels, y labels, and values as a 2D array where each row matches y and each row length matches x; optional base color
        - For gantt: provide items with label, start, end (numbers, start < end); optional color per item
        - Place the chart block where you want it to appear in the response
        - If a chart isn't helpful, omit it

        ## RESPONSE STYLE

        - **Brief and scannable** - A few key points, not a wall of text. Use bullets if they help organize.
        - **Avoid overly granular timestamps.**
        - **High-level summaries** - Don't list every activity, summarize the vibe
        - **Human-readable durations** - "about an hour", "a couple hours", not "45 minutes" or "4140 seconds"
        - **Markdown** - Use **bold** for emphasis where helpful

        GOOD example:
        "Pulled today's cards.
        - **Morning:** research/UX work, then about an hour of personal downtime
        - **Midday:** mostly personal—shorts, threads, feed browsing
        - **Afternoon/evening:** back to work on code with a couple League matches mixed in"

        BAD example:
        "Morning focus started with a 9:20–10:04 work block researching Dayflow/ChatCLI logging and UX notes, then shifted into about an hour of personal/break time watching League clips, YouTube Shorts..."

        NEVER mention: seconds, specific timestamps (9:20-10:04), epoch times, table names, SQL syntax, raw column values

        ## FOLLOW-UP SUGGESTIONS

        At the END of your response, include 3-4 follow-up question suggestions:
        - 1-2 natural follow-ups (dig deeper into something you mentioned)
        - 1-2 questions that explore the data in an entirely new direction from the user's most recent question; aim for unique, helpful insights they could get from their data

        Format EXACTLY like this (no "Suggestions:" label, just the block):
        ```suggestions
        ["Question 1", "Question 2", "Question 3"]
        ```

        Keep questions short (<50 chars), start with verbs like "Show", "Compare", "Break down", "What's".
        """
    }

    private func todayDate() -> String {
        chatServiceDayFormatter.string(from: Date())
    }


    // MARK: - Helpers

    // MARK: - Work Status Helpers

    private func startWorkStatus() {
        workStatus = ChatWorkStatus(
            id: UUID(),
            stage: .thinking,
            thinkingText: "",
            tools: [],
            errorMessage: nil,
            lastUpdated: Date()
        )
    }

    private func updateWorkStatus(_ update: (inout ChatWorkStatus) -> Void) {
        guard var status = workStatus else { return }
        update(&status)
        status.lastUpdated = Date()
        workStatus = status
    }

    private func toolCompletionIndex(in status: ChatWorkStatus, preferredId: UUID?) -> Int? {
        if let preferredId,
           let index = status.tools.firstIndex(where: { $0.id == preferredId }) {
            return index
        }
        return status.tools.lastIndex(where: { $0.state == .running })
    }

    private func toolSummary(command: String, output: String, exitCode: Int?) -> String {
        let base = command.contains("sqlite3") ? "Database query" : "Tool"
        if let exitCode, exitCode != 0 {
            return "\(base) failed (exit \(exitCode))"
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode == nil && trimmed.isEmpty {
            return "Running \(base.lowercased())…"
        }
        if trimmed.isEmpty {
            return "\(base) completed"
        }
        let rows = trimmed.split(whereSeparator: \.isNewline).count
        let rowLabel = rows == 1 ? "1 row" : "\(rows) rows"
        return "\(base) returned \(rowLabel)"
    }

    // MARK: - Suggestions Parsing

    /// Parse suggestions block from response and return cleaned text + suggestions array
    private func parseSuggestions(from text: String) -> (cleanedText: String, suggestions: [String]) {
        // Look for ```suggestions ... ``` block (with optional "Suggestions:" label before it)
        // Pattern captures: optional label + the code block with JSON array inside
        let pattern = "(?:Suggestions:\\s*)?```suggestions\\s*\\n([\\s\\S]*?)\\n?```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (text, [])
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let jsonRange = Range(match.range(at: 1), in: text) else {
            return (text, [])
        }

        let jsonString = String(text[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse JSON array
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            print("[ChatService] Failed to parse suggestions JSON: \(jsonString)")
            return (text, [])
        }

        // Remove the entire suggestions block (including optional label) from the text
        let cleanedText = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        print("[ChatService] Parsed \(parsed.count) suggestions")
        return (cleanedText, parsed)
    }
}

// MARK: - Provider Check

extension ChatService {
    /// Check if an LLM provider is configured
    static var isProviderConfigured: Bool {
        // Check if any provider credentials exist
        if let _ = KeychainManager.shared.retrieve(for: "gemini"), !KeychainManager.shared.retrieve(for: "gemini")!.isEmpty {
            return true
        }
        if let _ = KeychainManager.shared.retrieve(for: "dayflow"), !KeychainManager.shared.retrieve(for: "dayflow")!.isEmpty {
            return true
        }
        // ChatCLI doesn't need keychain - check if tool preference is set
        if UserDefaults.standard.string(forKey: "chatCLIPreferredTool") != nil {
            return true
        }
        // Ollama is always "configured" since it uses localhost
        if UserDefaults.standard.data(forKey: "llmProviderType") != nil {
            return true
        }
        return false
    }
}
