//
//  ChatService.swift
//  Dayflow
//
//  Orchestrates chat conversations with the LLM, handling tool calls
//  and maintaining conversation state.
//

import Foundation
import Combine

/// A debug log entry for the chat debug panel
struct ChatDebugEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: EntryType
    let content: String

    enum EntryType: String {
        case prompt = "📤 PROMPT"
        case response = "📥 RESPONSE"
        case toolDetected = "🔧 TOOL DETECTED"
        case toolResult = "📊 TOOL RESULT"
        case error = "❌ ERROR"
        case info = "ℹ️ INFO"
    }

    var typeColor: String {
        switch type {
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

    // MARK: - Published State

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var streamingText = ""
    @Published private(set) var error: String?
    @Published private(set) var debugLog: [ChatDebugEntry] = []
    @Published private(set) var workStatus: ChatWorkStatus?
    @Published var showDebugPanel = false

    // MARK: - Private

    private var conversationHistory: [(role: String, content: String)] = []

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

        // Add user message
        let userMessage = ChatMessage.user(content)
        messages.append(userMessage)
        conversationHistory.append((role: "user", content: content))

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
    }

    // MARK: - Conversation Processing

    private func processConversation() async {
        // Build prompt with system context
        let fullPrompt = buildFullPrompt()
        log(.prompt, fullPrompt)

        // Track state during streaming
        var responseText = ""
        var currentToolId: UUID?
        streamingText = ""
        startWorkStatus()

        // Add response message only when text arrives
        var responseMessageId: UUID?

        do {
            // Use rich streaming with thinking and tool events
            let stream = LLMService.shared.generateChatStreaming(prompt: fullPrompt)

            for try await event in stream {
                switch event {
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

                case .textDelta(let chunk):
                    responseText += chunk
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
                    responseText = text
                    log(.response, text)
                    if responseMessageId == nil,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let id = UUID()
                        responseMessageId = id
                        messages.append(ChatMessage(
                            id: id,
                            role: .assistant,
                            content: text
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

        // Update final response
        if let id = responseMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            // Remove response message if empty (error case or no response)
            if responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.remove(at: index)
            } else {
                messages[index] = ChatMessage(
                    id: id,
                    role: .assistant,
                    content: responseText
                )
            }
        }

        // Add to conversation history
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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        let currentDate = dateFormatter.string(from: now)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let currentTime = timeFormatter.string(from: now)

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
        - title, summary, category, subcategory
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
        - **Watch for truncation** - Tool output may get cut off. If that happens, use LIMIT, break into multiple queries, or be selective with columns

        ### Example

        Yesterday's longest block:
        SELECT title, category, (end_ts - start_ts)/60 as minutes FROM timeline_cards WHERE day = '\(yesterdayDate())' AND is_deleted = 0 ORDER BY minutes DESC LIMIT 1

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

        RULES:
        - Allowed chart types: bar, line, stacked_bar
        - JSON must be valid (double quotes, no trailing commas)
        - x and y must be arrays of the same length
        - Use numbers only for y values
        - Optional: color can be a hex string like "#F96E00" or "F96E00"
        - For stacked_bar: provide x categories and a series array; each series needs name + values (values count must match x); color optional per series
        - For donut: provide labels + values (same length); optional colors array (same length) for slice colors
        - Place the chart block where you want it to appear in the response
        - If a chart isn't helpful, omit it

        ## RESPONSE STYLE

        - **Short and scannable** - 3-5 bullet points max, not a wall of text
        - **Group by time of day** - Use "Morning", "Midday", "Afternoon/evening" - NOT specific times like "9:20-10:04"
        - **High-level summaries** - Don't list every activity, summarize the vibe
        - **Human-readable durations** - "about an hour", "a couple hours", not "45 minutes" or "4140 seconds"
        - **Markdown formatting** - Use **bold** for time periods, bullet points for structure

        GOOD example:
        "Pulled today's cards.
        - **Morning:** research/UX work, then about an hour of personal downtime
        - **Midday:** mostly personal—shorts, threads, feed browsing
        - **Afternoon/evening:** back to work on code with a couple League matches mixed in"

        BAD example:
        "Morning focus started with a 9:20–10:04 work block researching Dayflow/ChatCLI logging and UX notes, then shifted into about an hour of personal/break time watching League clips, YouTube Shorts..."

        NEVER mention: seconds, specific timestamps (9:20-10:04), epoch times, table names, SQL syntax, raw column values
        """
    }

    private func todayDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func yesterdayDate() -> String {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: yesterday)
    }

    private func weekAgoDate() -> String {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: weekAgo)
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

    private func formatDateDisplay(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = formatter.date(from: dateString) else { return dateString }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d"  // e.g., "Jan 7"
        return displayFormatter.string(from: date)
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
