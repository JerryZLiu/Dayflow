//
//  ChatService.swift
//  Dayflow
//
//  Orchestrates chat conversations with the LLM, handling tool calls
//  and maintaining conversation state.
//

import Combine
import Foundation

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
    if let message = errorMessage, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
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

  private var conversationHistory: [DashboardChatTurn] = []
  private var recentSuggestionHistory: [String] = []
  private var currentSessionId: String?

  // MARK: - Debug Logging

  private func log(_ type: ChatDebugEntry.EntryType, _ content: String) {
    let entry = ChatDebugEntry(timestamp: Date(), type: type, content: content)
    debugLog.append(entry)
    // Also print to console for Xcode debugging
    print("[\(type.rawValue)] \(content)")
  }

  func clearDebugLog() {
    debugLog = []
  }

  // MARK: - Public API

  /// Send a user message and get a response
  func sendMessage(_ content: String, provider: DashboardChatProvider) async {
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
    conversationHistory.append(.user(content))
    log(.user, content)

    // Process with potential tool calls
    await processConversation(provider: provider)

    isProcessing = false
  }

  /// Clear the conversation
  func clearConversation() {
    messages = []
    conversationHistory = []
    recentSuggestionHistory = []
    streamingText = ""
    error = nil
    workStatus = nil
    currentSuggestions = []
    currentSessionId = nil
  }

  func didUpdateDashboardMemory(from oldValue: String, to newValue: String) {
    guard oldValue != newValue else { return }
    invalidateCLISession(reason: "dashboard memory changed")
  }

  // MARK: - Conversation Processing

  private func processConversation(provider: DashboardChatProvider) async {
    // Build a provider-specific request. Gemini gets structured history;
    // CLI providers keep the existing prompt/session flow.
    let request: DashboardChatRequest
    let usesSessionResume = provider != .gemini
    let isResume = usesSessionResume && currentSessionId != nil

    request = buildChatRequest(provider: provider, isResume: isResume)
    log(.prompt, debugDescription(for: request, isResume: isResume))

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
          let first = chunk.first, !first.isWhitespace
        {
          responseText += " "
        }
        pendingToolSeparator = false
      }
      responseText += chunk
    }

    do {
      // Use rich streaming with thinking and tool events
      let stream = LLMService.shared.generateChatStreaming(request: request)

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
            status.tools.append(
              ChatWorkStatus.ToolRun(
                id: toolId,
                command: command,
                state: .running,
                summary: toolSummary(command: command, output: "", exitCode: nil),
                output: "",
                exitCode: nil
              ))
          }

        case .toolEnd(let output, let exitCode):
          log(.toolResult, "Exit \(exitCode ?? 0): \(output)")
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
            let index = messages.firstIndex(where: { $0.id == id })
          {
            messages[index] = ChatMessage(
              id: id,
              role: .assistant,
              content: responseText
            )
          } else if responseMessageId == nil {
            let id = UUID()
            responseMessageId = id
            messages.append(
              ChatMessage(
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
            let index = messages.firstIndex(where: { $0.id == id })
          {
            messages[index] = ChatMessage(
              id: id,
              role: .assistant,
              content: responseText
            )
          } else if responseMessageId == nil,
            !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            let id = UUID()
            responseMessageId = id
            messages.append(
              ChatMessage(
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
        let index = messages.firstIndex(where: { $0.id == id })
      {
        messages[index] = ChatMessage.assistant(
          "I encountered an error: \(error.localizedDescription)")
      } else {
        messages.append(
          ChatMessage.assistant("I encountered an error: \(error.localizedDescription)"))
      }
      streamingText = ""
      return
    }

    streamingText = ""

    let metadata = parseAssistantMetadata(from: responseText)
    currentSuggestions = metadata.suggestions
    appendRecentSuggestions(metadata.suggestions)
    let cleanedText = metadata.cleanedText

    if let memoryBlob = metadata.memoryBlob {
      let previousMemory = DashboardChatMemoryStore.load()
      DashboardChatMemoryStore.save(memoryBlob)
      let updatedMemory = DashboardChatMemoryStore.load()
      didUpdateDashboardMemory(from: previousMemory, to: updatedMemory)
      let charCount = DashboardChatMemoryStore.load().count
      log(.info, "🧠 Memory updated (\(charCount) chars)")
      AnalyticsService.shared.capture(
        "chat_memory_auto_updated",
        [
          "provider": provider.analyticsProvider,
          "chars": charCount,
        ])
    }

    // Update final response (with suggestions block removed)
    if let id = responseMessageId,
      let index = messages.firstIndex(where: { $0.id == id })
    {
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

    // Add cleaned assistant response to history so metadata blocks do not bloat future prompts.
    if !cleanedText.isEmpty {
      conversationHistory.append(.assistant(cleanedText))
      // A successful completed answer should always clear transient work status UI,
      // even if an earlier tool attempt in the same turn failed and was corrected.
      workStatus = nil
    }
  }

  // MARK: - Prompt Building

  private func buildChatRequest(provider: DashboardChatProvider, isResume: Bool) -> DashboardChatRequest {
    switch provider {
    case .gemini:
      currentSessionId = nil
      return DashboardChatRequest(
        provider: provider,
        prompt: "",
        sessionId: nil,
        systemInstruction: buildGeminiSystemInstruction(),
        history: conversationHistory
      )
    case .codex, .claude:
      let prompt: String
      if isResume {
        prompt = conversationHistory.last?.content ?? ""
      } else {
        prompt = buildCLIPrompt()
      }
      return DashboardChatRequest(
        provider: provider,
        prompt: prompt,
        sessionId: isResume ? currentSessionId : nil,
        systemInstruction: nil,
        history: []
      )
    }
  }

  private func buildCLIPrompt() -> String {
    let systemPrompt = buildCLISystemPrompt()

    var prompt = systemPrompt + "\n\n"

    let memoryBlob = DashboardChatMemoryStore.load()
    if !memoryBlob.isEmpty {
      prompt += "## User Memory\n\(memoryBlob)\n\n"
    }

    // Add conversation history
    for entry in conversationHistory {
      prompt += "\(entry.role.promptLabel): \(entry.content)\n\n"
    }

    prompt += "Assistant:"
    return prompt
  }

  private func buildGeminiSystemInstruction() -> String {
    var instruction = buildGeminiSystemPrompt()
    let memoryBlob = DashboardChatMemoryStore.load()
    if !memoryBlob.isEmpty {
      instruction += "\n\n## User Memory\n\(memoryBlob)"
    }
    let recentSuggestions = recentSuggestionHistory.suffix(9)
    if !recentSuggestions.isEmpty {
      instruction += "\n\n## Recent Suggestions To Avoid\n"
      instruction +=
        recentSuggestions.map { "- \($0)" }.joined(separator: "\n")
    }
    return instruction
  }

  private func debugDescription(for request: DashboardChatRequest, isResume: Bool) -> String {
    switch request.provider {
    case .gemini:
      var lines: [String] = ["[Gemini Dashboard Chat]"]
      if let systemInstruction = request.systemInstruction, !systemInstruction.isEmpty {
        lines.append("System Instruction:")
        lines.append(systemInstruction)
      }
      lines.append("Contents:")
      for turn in request.history {
        lines.append("\(turn.role.promptLabel): \(turn.content)")
      }
      return lines.joined(separator: "\n\n")
    case .codex, .claude:
      if isResume, let sessionId = request.sessionId {
        return "[Resuming session \(sessionId)] \(request.prompt)"
      }
      return request.prompt
    }
  }

  private func buildCLISystemPrompt() -> String {
    let now = Date()
    let currentDate = chatServiceLongDateFormatter.string(from: now)
    let currentTime = chatServiceTimeFormatter.string(from: now)

    // Use full path (~ doesn't expand in sqlite3)
    let dbPath = NSHomeDirectory() + "/Library/Application Support/Dayflow/chunks.sqlite"

    let languageSection = languageOverrideSection()
    let metadataSection = metadataContractSection()

    return """
      You are a friendly assistant in Dayflow, a macOS app that tracks computer activity.

      Current date: \(currentDate)
      Current time: \(currentTime)
      Day boundary: Days start at 4:00 AM (not midnight)

      ## DATA INTEGRITY (CRITICAL)

      You have Bash tool access. You MUST:
      1. Actually execute sqlite3 commands to query the database — NEVER fabricate data
      2. If a query returns no results, tell the user "No data found for [time period]"
      3. If you cannot execute the query (tool error), tell the user what went wrong

      DO NOT:
      - Pretend to run queries by writing fake code blocks in your response
      - Make up activity data based on the schema description
      - Guess what the user might have done

      If you're unsure whether you executed a real query, you probably didn't. Use the Bash tool to run sqlite3.

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
      - Allowed chart types: bar, line, stacked_bar, donut, heatmap, gantt
      - JSON must be valid (double quotes, no trailing commas)
      - For donut charts use `type=donut` (not `pie`)
      - x and y must be arrays of the same length
      - Use numbers only for y values
      - Optional: color can be a hex string like "#F96E00" or "F96E00"
      - For stacked_bar: provide x categories and a series array; each series needs name + values (values count must match x); color optional per series
      - For donut: provide labels + values (same length); optional colors array (same length) for slice colors
      - For heatmap: provide x labels, y labels, and values as a 2D array where each row matches y and each row length matches x; optional base color
      - For gantt: provide items with label, start, end (numbers, start < end); optional color per item
      - Place the chart block where you want it to appear in the response
      - If a chart isn't helpful, omit it

      \(categoryColorsSection())

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
      - **Afternoon/evening:** back to work on code with a couple videos mixed in"

      BAD example:
      "Morning focus started with a 9:20–10:04 work block researching Dayflow/ChatCLI logging and UX notes, then shifted into about an hour of personal/break time watching League clips, YouTube Shorts..."

      NEVER mention: seconds, specific timestamps (9:20-10:04), epoch times, table names, SQL syntax, raw column values

      \(languageSection)

      \(metadataSection)

      """
  }

  private func buildGeminiSystemPrompt() -> String {
    let now = Date()
    let currentDate = chatServiceLongDateFormatter.string(from: now)
    let currentTime = chatServiceTimeFormatter.string(from: now)

    let languageSection = languageOverrideSection()
    let languageBlock: String
    if languageSection.isEmpty {
      languageBlock = ""
    } else {
      languageBlock = "\n\n\(languageSection)"
    }

    return """
      You are the AI assistant inside Dayflow, a macOS app that records what people do on their computer and builds a semantic timeline of their day. You have deep visibility into the user's work patterns — what they built, where they got stuck, how they spent their time. Use that context to give answers that feel like a well-informed colleague, not a generic chatbot.

      Current date: \(currentDate)
      Current time: \(currentTime)
      Day boundary: Days start at 4:00 AM (not midnight). "Yesterday" means the previous 4 AM–4 AM window.

      ---

      ## TOOLS & DATA INTEGRITY

      You have two read-only tools:

      1. **fetchTimeline** — Structured activity cards with titles, categories, and durations. Use this for summaries, standups, time breakdowns, and "what did I do" questions.
      2. **fetchObservations** — Raw screen observations. Use this for detailed questions like "what was I reading at 2pm" or "which tabs were open during that meeting."

      Rules:
      - Always call a tool when the user asks about their activity. Never fabricate or assume data.
      - If a tool returns no rows, say so clearly. Don't fill gaps with guesses.
      - If a tool fails, explain what happened and suggest a narrower time range.
      - For large time windows (full week+), use `includeDetailedSummary=false` to avoid oversized payloads.
      - Default to fetchTimeline unless the user needs observation-level detail.

      ---

      ## HANDLING USER INTENT

      **Format vs. content corrections:**
      If the user provides an example of their preferred format (e.g., a standup template), treat it as a *structural template*. Re-fetch or reuse the existing data and apply the new structure to it. Do not echo back the example content as if it were the answer.
      If the user is correcting formatting only, reuse previously fetched facts when available and do not import facts from the example.

      **Clarifications and retries:**
      When the user says things like "no, I meant..." or "try again but...", re-read their original request in light of the correction. Don't start from scratch — adjust your previous response.

      **Implicit context:**
      - "standup notes" → use Yesterday / Today / Blockers format unless the user has shown a different preference
      - "what did I do" → fetchTimeline for the relevant day
      - "how much time" → fetchTimeline, aggregate by category
      - "was I productive" → compare Work vs Distraction/Idle time
      - "show me" or "what was on screen" → fetchObservations

      ---

      ## RESPONSE STYLE

      - **Brief and scannable.** A few key points, not a wall of text. Bullets are fine when they help.
      - **High-level by default.** Summarize the shape of the day — don't list every 15-minute card unless asked.
      - **Human-readable durations.** "About an hour," "a couple hours," "most of the afternoon." Not "47 minutes" or "2820 seconds."
      - **No internal details.** Never mention raw timestamps, table names, SQL, schema, or tool internals.
      - **Adapt to demonstrated preferences.** If the user shows you how they want something formatted, match that structure going forward. Update the Style memory field accordingly.\(languageBlock)

      ---

      ## MEMORY

      You may receive an existing `## User Memory` block. Use it to maintain lightweight, durable context across conversations.

      Fields:
      - **Profile:** Stable user context relevant to Dayflow (role, work patterns, team).
      - **Style:** A set of format preferences **keyed by question type**. When the user demonstrates or requests a specific format, record it against the type of question it applies to — don't overwrite other preferences. Different question types can (and should) have different styles.

      Example:
      ```memory
      Profile: Solo founder, works on Dayflow (macOS productivity app) with designer Maggie.
      Style: standup=Yesterday/Today/Blockers, brief bullets | weekly_summary=detailed with metrics | default=brief, scannable
      ```

      When the user shows a preferred format, identify which question type it belongs to and add or update just that key. Preferences for one type (e.g., standups) should never affect another (e.g., weekly summaries).

      **Example flow:**

      User's current memory:
      ```memory
      Profile: Solo founder, works on Dayflow (macOS productivity app) with designer Maggie.
      Style: default=brief, scannable
      ```

      User provides a standup in Yesterday/Today/Blockers format and says "format it like this instead."

      Your response should use that structure for the standup data, and your memory block should become:
      ```memory
      Profile: Solo founder, works on Dayflow (macOS productivity app) with designer Maggie.
      Style: standup=Yesterday/Today/Blockers, brief bullets | default=brief, scannable
      ```

      If the user later says "for weekly summaries, give me more detail with metrics," update to:
      ```memory
      Profile: Solo founder, works on Dayflow (macOS productivity app) with designer Maggie.
      Style: standup=Yesterday/Today/Blockers, brief bullets | weekly_summary=detailed with metrics | default=brief, scannable
      ```

      Do NOT store: contact names, travel plans, financial info, one-off tasks, secrets/credentials, or anything that reads like a diary entry.

      ---

      ## RESPONSE FORMAT

      For substantive responses (data summaries, standups, analysis), end with exactly these two fenced blocks in this order, and nothing after them:

      ```suggestions
      ["Question 1?", "Question 2?", "Question 3?"]
      ```

      ```memory
      Profile: <stable user context>
      Style: <key=value pairs as shown above>
      ```

      Rules:
      - The `suggestions` block is required for substantive responses.
      - The `suggestions` block must be valid JSON: an array of 3-4 strings.
      - Always include the `memory` block, even if unchanged.
      - Frame each suggestion as a question the user could ask Dayflow.
      - Every suggestion must be answerable using only the user's recorded Dayflow activity/data.
      - Do not suggest anything that requires external information, browsing, recommendations, planning help, outreach, document creation, or any other action outside analyzing the existing data.
      - Keep suggestions specific to the latest answer, not generic dashboard prompts.
      - Keep suggestion text short (<50 chars) and varied.
      - Include:
      - one **deeper** question that digs further into the same topic
      - one **adjacent** question that explores a nearby angle
      - one **surprising** question that is still grounded in the actual data
      - Do not repeat recent suggestions or obvious variants of them.
      - Do not write suggestion questions as markdown bullets.
      - Do not place suggestion questions in the main response body.
      - Do not output any text after the `memory` block.
      - For quick clarifications, acknowledgments, or corrections, omit the `suggestions` block and include only the `memory` block.
      - Do not add headings like "Suggestions", "Memory", "### Suggestions", or "### Memory".
      - Emit only the fenced `suggestions` block and fenced `memory` block after the main answer.
      """
  }

  private func appendRecentSuggestions(_ suggestions: [String]) {
    guard !suggestions.isEmpty else { return }

    for suggestion in suggestions {
      let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }

      let normalized = normalizeSuggestion(trimmed)
      if let existingIndex = recentSuggestionHistory.firstIndex(where: {
        normalizeSuggestion($0) == normalized
      }) {
        recentSuggestionHistory.remove(at: existingIndex)
      }
      recentSuggestionHistory.append(trimmed)
    }

    if recentSuggestionHistory.count > 12 {
      recentSuggestionHistory.removeFirst(recentSuggestionHistory.count - 12)
    }
  }

  private func normalizeSuggestion(_ suggestion: String) -> String {
    suggestion
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private func todayDate() -> String {
    chatServiceDayFormatter.string(from: Date())
  }

  private func categoryColorsSection() -> String {
    let descriptors = CategoryStore.descriptorsForLLM()
    guard !descriptors.isEmpty else { return "" }

    var lines = ["## CHART COLORS", ""]
    lines.append("When creating charts based on activity categories, use these exact colors:")
    for desc in descriptors {
      lines.append("- \(desc.name): \(desc.colorHex)")
    }
    lines.append("")
    lines.append(
      "For other charts (not category-based), choose a warm, pastel, harmonious palette.")
    return lines.joined(separator: "\n")
  }

  private func languageOverrideSection() -> String {
    guard let instruction = LLMOutputLanguagePreferences.languageInstruction(forJSON: false) else {
      return ""
    }
    return """
      ## LANGUAGE

      \(instruction)
      """
  }

  private func metadataContractSection() -> String {
    """
      ## MEMORY CONTRACT (REQUIRED)

      You may receive an existing section called "## User Memory".
      This memory is ONLY for durable assistant behavior, not a running life log.
      Keep only these two fields:
      - Profile: stable user context relevant to this app (very short)
      - Style: response format/tone preferences (very short)

      DO NOT store:
      - Contact names/relationships
      - Travel plans or itineraries
      - Investment/trading ideas
      - One-off tasks, daily events, or temporary interests
      - Secrets, passwords, tokens, API keys, or sensitive details

      ## RESPONSE FORMAT (REQUIRED)

      At the END of every response, include exactly these blocks in order:

      ```suggestions
      ["Question 1", "Question 2", "Question 3"]
      ```

      ```memory
      Profile: <short line>
      Style: <short line>
      ```

      Rules:
      - Include 3-4 suggestions.
      - Frame each suggestion as a question the user could ask Dayflow.
      - Every suggestion must be answerable using only the user's recorded Dayflow activity/data.
      - Do not suggest anything that requires external information, browsing, recommendations, planning help, outreach, document creation, or any other action outside analyzing the existing data.
      - Keep suggestion text short (<50 chars).
      - Do not add any other metadata blocks.
      - Do not mention the memory block in normal prose.
      """
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
      let index = status.tools.firstIndex(where: { $0.id == preferredId })
    {
      return index
    }
    return status.tools.lastIndex(where: { $0.state == .running })
  }

  private func toolSummary(command: String, output: String, exitCode: Int?) -> String {
    let lowercased = command.lowercased()
    let base =
      lowercased.contains("sqlite3") ? "Database query"
      : (lowercased.contains("fetchtimeline") || lowercased.contains("fetchobservations")
        ? "Data fetch" : "Tool")
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
    if base == "Data fetch" {
      return trimmed
    }
    let rows = trimmed.split(whereSeparator: \.isNewline).count
    let rowLabel = rows == 1 ? "1 row" : "\(rows) rows"
    return "\(base) returned \(rowLabel)"
  }

  private func invalidateCLISession(reason: String) {
    guard currentSessionId != nil else { return }
    currentSessionId = nil
    log(.info, "♻️ Reset CLI session: \(reason)")
  }

  // MARK: - Metadata Parsing

  private struct AssistantMetadata {
    let cleanedText: String
    let suggestions: [String]
    let memoryBlob: String?
  }

  private func parseAssistantMetadata(from text: String) -> AssistantMetadata {
    let suggestionPattern =
      "(?ims)(?:^|\\n)\\s*(?:#{1,6}\\s*Suggestions\\s*\\n+|Suggestions:\\s*)?```suggestions\\s*\\n([\\s\\S]*?)\\n?```"
    let memoryPattern =
      "(?ims)(?:^|\\n)\\s*(?:#{1,6}\\s*Memory\\s*\\n+|Memory:\\s*)?```memory\\s*\\n([\\s\\S]*?)\\n?```"

    var workingText = text
    var suggestions: [String] = []
    var memoryBlob: String?

    if let (stripped, rawSuggestions) = extractTaggedBlock(from: workingText, pattern: suggestionPattern) {
      workingText = stripped
      let jsonString = rawSuggestions.trimmingCharacters(in: .whitespacesAndNewlines)
      if let data = jsonString.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
      {
        suggestions = parsed
        log(.info, "💡 Parsed \(parsed.count) suggestions")
      } else {
        log(.error, "Failed to parse suggestions JSON")
      }
    }

    if suggestions.isEmpty,
      let (stripped, rawSuggestions) = extractLooseSuggestions(from: workingText)
    {
      workingText = stripped
      let jsonString = rawSuggestions.trimmingCharacters(in: .whitespacesAndNewlines)
      if let data = jsonString.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
      {
        suggestions = parsed
        log(.info, "💡 Parsed \(parsed.count) suggestions")
      } else {
        log(.error, "Failed to parse loose suggestions JSON")
      }
    }

    if let (stripped, rawMemory) = extractTaggedBlock(from: workingText, pattern: memoryPattern) {
      workingText = stripped
      if let normalizedMemory = normalizeAutoMemoryBlob(rawMemory) {
        memoryBlob = normalizedMemory
      } else {
        log(.info, "🧠 Ignored memory block that did not match Profile/Style format")
      }
    }

    if memoryBlob == nil,
      let (stripped, rawMemory) = extractLooseMemory(from: workingText)
    {
      workingText = stripped
      if let normalizedMemory = normalizeAutoMemoryBlob(rawMemory) {
        memoryBlob = normalizedMemory
      } else {
        log(.info, "🧠 Ignored loose memory block that did not match Profile/Style format")
      }
    }

    workingText = stripResidualMetadataHeadings(from: workingText)

    return AssistantMetadata(
      cleanedText: workingText.trimmingCharacters(in: .whitespacesAndNewlines),
      suggestions: suggestions,
      memoryBlob: memoryBlob
    )
  }

  private func extractTaggedBlock(from text: String, pattern: String) -> (String, String)? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard
      let match = regex.firstMatch(in: text, options: [], range: range),
      let contentRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }

    let content = String(text[contentRange])
    let stripped = regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: ""
    )
    return (stripped, content)
  }

  private func extractLooseSuggestions(from text: String) -> (String, String)? {
    let pattern =
      "(?ims)(?:^|\\n)\\s*(?:#{1,6}\\s*Suggestions\\s*\\n+|Suggestions:\\s*\\n?)(\\[[\\s\\S]*?\\])(?=\\n\\s*(?:#{1,6}\\s*Memory\\b|Memory:)|\\z)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard
      let match = regex.firstMatch(in: text, options: [], range: range),
      let contentRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }

    let content = String(text[contentRange])
    let stripped = regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: "\n"
    )
    return (stripped, content)
  }

  private func extractLooseMemory(from text: String) -> (String, String)? {
    let pattern =
      "(?ims)(?:^|\\n)\\s*(?:#{1,6}\\s*Memory\\s*\\n+|Memory:\\s*\\n?)(Profile:[\\s\\S]*?Style:[^\\n]*(?:\\n[^#\\n].*)*)(?=\\z)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard
      let match = regex.firstMatch(in: text, options: [], range: range),
      let contentRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }

    let content = String(text[contentRange])
    let stripped = regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: "\n"
    )
    return (stripped, content)
  }

  private func stripResidualMetadataHeadings(from text: String) -> String {
    let patterns = [
      "(?im)^\\s*#{1,6}\\s*Suggestions\\s*$",
      "(?im)^\\s*#{1,6}\\s*Memory\\s*$",
      "(?im)^\\s*Suggestions:\\s*$",
      "(?im)^\\s*Memory:\\s*$",
    ]

    return patterns.reduce(text) { partial, pattern in
      guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return partial
      }
      let range = NSRange(partial.startIndex..., in: partial)
      return regex.stringByReplacingMatches(
        in: partial,
        options: [],
        range: range,
        withTemplate: ""
      )
    }
  }

  private func normalizeAutoMemoryBlob(_ raw: String) -> String? {
    let lines = raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !lines.isEmpty else { return nil }

    var profile: String?
    var style: String?

    for line in lines {
      let lowercased = line.lowercased()
      if lowercased.hasPrefix("profile:") {
        let value = line.dropFirst("profile:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { profile = value }
      } else if lowercased.hasPrefix("style:") {
        let value = line.dropFirst("style:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { style = value }
      }
    }

    var outputLines: [String] = []
    if let profile { outputLines.append("Profile: \(profile)") }
    if let style { outputLines.append("Style: \(style)") }
    guard !outputLines.isEmpty else { return nil }
    return outputLines.joined(separator: "\n")
  }
}

// MARK: - Provider Check

extension ChatService {
  /// Check if an LLM provider is configured
  static var isProviderConfigured: Bool {
    let geminiKey = KeychainManager.shared.retrieve(for: "gemini")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !geminiKey.isEmpty || CLIDetector.isInstalled(.codex) || CLIDetector.isInstalled(.claude)
  }
}
