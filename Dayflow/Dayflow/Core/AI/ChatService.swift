//
//  ChatService.swift
//  Dayflow
//
//  Orchestrates chat conversations with the LLM, handling tool calls
//  and maintaining conversation state.
//

import Combine
import Foundation

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
  @Published private(set) var conversations: [ChatConversationRecord] = []
  @Published var showDebugPanel = false

  private(set) var currentConversationID: UUID?

  // MARK: - Private

  private var conversationHistory: [DashboardChatTurn] = []
  private var recentSuggestionHistory: [String] = []
  private var currentSessionId: String?
  private var currentConversationCreatedAt: Date?

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

    if currentConversationID == nil {
      currentConversationID = UUID()
      currentConversationCreatedAt = Date()
    }

    // Add user message
    let userMessage = ChatMessage.user(content)
    messages.append(userMessage)
    conversationHistory.append(.user(content))
    log(.user, content)

    // Process with potential tool calls
    await processConversation(provider: provider)

    isProcessing = false
    persistCurrentConversation(provider: provider)
  }

  /// Start a fresh conversation. Persisted history is kept; only in-memory
  /// state is cleared.
  func clearConversation() {
    messages = []
    conversationHistory = []
    recentSuggestionHistory = []
    streamingText = ""
    error = nil
    workStatus = nil
    currentSuggestions = []
    currentSessionId = nil
    currentConversationID = nil
    currentConversationCreatedAt = nil
  }

  // MARK: - Chat History

  func refreshConversationList() {
    conversations = StorageManager.shared.fetchChatConversations()
  }

  /// Replace the in-memory conversation with a saved one. The stored CLI
  /// session id is reused when the CLI can still resume it; otherwise the
  /// provider rebuilds its prompt from the restored history.
  func loadConversation(_ record: ChatConversationRecord) {
    guard !isProcessing else { return }

    let loaded = StorageManager.shared.fetchChatMessages(conversationId: record.id)
    guard !loaded.isEmpty else { return }

    messages = loaded
    conversationHistory = loaded.compactMap { message -> DashboardChatTurn? in
      switch message.role {
      case .user: return .user(message.content)
      case .assistant: return .assistant(message.content)
      case .toolCall: return nil
      }
    }
    currentConversationID = record.id
    currentConversationCreatedAt = record.createdAt
    currentSessionId = record.cliSessionId
    recentSuggestionHistory = []
    streamingText = ""
    error = nil
    workStatus = nil
    currentSuggestions = []
    log(.info, "📂 Loaded conversation \(record.id.uuidString) (\(loaded.count) messages)")
  }

  func deleteConversation(id: UUID) {
    StorageManager.shared.deleteChatConversation(id: id)
    conversations.removeAll { $0.id == id }
    if currentConversationID == id {
      clearConversation()
    }
  }

  private func persistCurrentConversation(provider: DashboardChatProvider) {
    guard let id = currentConversationID, !messages.isEmpty else { return }

    let firstQuestion = messages.first(where: { $0.role == .user })?.content ?? "New chat"
    let title = String(
      firstQuestion
        .components(separatedBy: .newlines).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(80)
    )

    let record = ChatConversationRecord(
      id: id,
      title: title.isEmpty ? "New chat" : title,
      provider: provider.rawValue,
      cliSessionId: currentSessionId,
      createdAt: currentConversationCreatedAt ?? Date(),
      updatedAt: Date()
    )
    StorageManager.shared.saveChatConversation(record, messages: messages)
    refreshConversationList()
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

    // Streamed deltas are coalesced (~50ms) before touching published state, so
    // the UI re-renders a handful of times per second instead of once per token.
    var pendingFlushTask: Task<Void, Never>?
    var lastFlushAt = Date.distantPast

    func flushStreamingText() {
      pendingFlushTask?.cancel()
      pendingFlushTask = nil
      lastFlushAt = Date()
      streamingText = responseText

      if let id = responseMessageId,
        let index = messages.firstIndex(where: { $0.id == id })
      {
        messages[index] = ChatMessage(id: id, role: .assistant, content: responseText)
      } else if responseMessageId == nil {
        let id = UUID()
        responseMessageId = id
        messages.append(ChatMessage(id: id, role: .assistant, content: responseText))
      }
    }

    func scheduleStreamingFlush() {
      let elapsed = Date().timeIntervalSince(lastFlushAt)
      if elapsed >= 0.05 {
        flushStreamingText()
        return
      }
      guard pendingFlushTask == nil else { return }
      pendingFlushTask = Task { [delay = 0.05 - elapsed] in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled else { return }
        flushStreamingText()
      }
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
          if let stage = workStatus?.stage, stage != .error, stage != .answering {
            updateWorkStatus { status in
              status.stage = .answering
            }
          }
          scheduleStreamingFlush()

        case .complete(let text):
          pendingFlushTask?.cancel()
          pendingFlushTask = nil
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
      pendingFlushTask?.cancel()
      pendingFlushTask = nil
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

    pendingFlushTask?.cancel()
    pendingFlushTask = nil
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

  private func buildChatRequest(provider: DashboardChatProvider, isResume: Bool)
    -> DashboardChatRequest
  {
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
    let systemPrompt = ChatPromptBuilder.cliSystemPrompt()

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
    var instruction = ChatPromptBuilder.geminiSystemPrompt()
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
      lowercased.contains("sqlite3")
      ? "Database query"
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

  private func parseAssistantMetadata(from text: String) -> ChatMetadataParser.AssistantMetadata {
    let suggestionPattern =
      "(?ims)(?:^|\\n)\\s*(?:#{1,6}\\s*Suggestions\\s*\\n+|Suggestions:\\s*)?```suggestions\\s*\\n([\\s\\S]*?)\\n?```"
    let memoryPattern =
      "(?ims)(?:^|\\n)\\s*(?:#{1,6}\\s*Memory\\s*\\n+|Memory:\\s*)?```memory\\s*\\n([\\s\\S]*?)\\n?```"

    var workingText = text
    var suggestions: [String] = []
    var memoryBlob: String?

    if let (stripped, rawSuggestions) = ChatMetadataParser.extractTaggedBlock(
      from: workingText, pattern: suggestionPattern)
    {
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
      let (stripped, rawSuggestions) = ChatMetadataParser.extractLooseSuggestions(from: workingText)
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

    if let (stripped, rawMemory) = ChatMetadataParser.extractTaggedBlock(
      from: workingText, pattern: memoryPattern)
    {
      workingText = stripped
      if let normalizedMemory = ChatMetadataParser.normalizeAutoMemoryBlob(rawMemory) {
        memoryBlob = normalizedMemory
      } else {
        log(.info, "🧠 Ignored memory block that did not match Profile/Style format")
      }
    }

    if memoryBlob == nil,
      let (stripped, rawMemory) = ChatMetadataParser.extractLooseMemory(from: workingText)
    {
      workingText = stripped
      if let normalizedMemory = ChatMetadataParser.normalizeAutoMemoryBlob(rawMemory) {
        memoryBlob = normalizedMemory
      } else {
        log(.info, "🧠 Ignored loose memory block that did not match Profile/Style format")
      }
    }

    workingText = ChatMetadataParser.stripResidualMetadataHeadings(from: workingText)

    return ChatMetadataParser.AssistantMetadata(
      cleanedText: workingText.trimmingCharacters(in: .whitespacesAndNewlines),
      suggestions: suggestions,
      memoryBlob: memoryBlob
    )
  }
}

// MARK: - Provider Check

extension ChatService {
  /// Check if an LLM provider is configured
  static var isProviderConfigured: Bool {
    let geminiKey =
      KeychainManager.shared.retrieve(for: "gemini")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !geminiKey.isEmpty || CLIDetector.isInstalled(.codex) || CLIDetector.isInstalled(.claude)
  }
}
