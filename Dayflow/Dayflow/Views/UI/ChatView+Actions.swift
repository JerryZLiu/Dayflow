import AppKit
import Charts
import SwiftUI

extension ChatView {
  // MARK: - Actions

  func submitCurrentInputIfAllowed() {
    guard canSubmitCurrentInput else { return }
    sendMessage(trimmedInputText)
  }

  func sendMessage(_ text: String) {
    guard !chatService.isProcessing else { return }
    guard selectedProviderAvailable else { return }
    let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !messageText.isEmpty else { return }
    inputText = ""

    // Track conversation for analytics
    let isNewConversation = conversationId == nil || chatService.messages.isEmpty
    if isNewConversation {
      conversationId = UUID()
    }

    // Count only user messages for index
    let messageIndex = chatService.messages.filter { $0.role == .user }.count

    // Log question to PostHog (beta analytics)
    AnalyticsService.shared.capture(
      "chat_question_asked",
      [
        "question": messageText,
        "conversation_id": conversationId?.uuidString ?? "unknown",
        "is_new_conversation": isNewConversation,
        "message_index": messageIndex,
        "provider": selectedProvider.analyticsProvider,
        "chat_runtime": selectedProvider.runtimeLabel,
      ])

    Task {
      await chatService.sendMessage(messageText, provider: selectedProvider)
    }
  }

  func resetConversation() {
    chatService.clearConversation()
    conversationId = nil
    resetChatFeedbackState()
  }

  func copyDebugLog() {
    let text = chatService.debugLog.map { entry in
      "[\(chatViewDebugTimestampFormatter.string(from: entry.timestamp))] \(entry.type.rawValue)\n\(entry.content)"
    }.joined(separator: "\n\n---\n\n")

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  func shouldShowAssistantFeedbackFooter(for message: ChatMessage) -> Bool {
    guard message.role == .assistant else { return false }
    guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }

    if chatService.isProcessing,
      let lastMessage = chatService.messages.last,
      lastMessage.role == .assistant,
      lastMessage.id == message.id
    {
      return false
    }

    return true
  }

  func copyAssistantMessage(_ message: ChatMessage) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.content, forType: .string)

    AnalyticsService.shared.capture(
      "chat_answer_copied",
      chatFeedbackAnalyticsPayload(for: message, direction: nil)
    )
  }

  func handleAssistantRating(_ direction: TimelineRatingDirection, for message: ChatMessage) {
    guard message.role == .assistant else { return }

    withAnimation(feedbackStateAnimation) {
      chatVoteSelections[message.id] = direction
    }

    AnalyticsService.shared.capture(
      "chat_answer_rated",
      chatFeedbackAnalyticsPayload(for: message, direction: direction)
    )

    switch direction {
    case .up:
      showTransientThanks(for: message.id)
    case .down:
      openChatFeedback(for: message, direction: direction)
    }
  }

  func openChatFeedback(for message: ChatMessage, direction: TimelineRatingDirection) {
    chatFeedbackMessage = ""
    chatFeedbackShareLogs = true
    chatFeedbackMode = .form

    withAnimation(feedbackModalAnimation) {
      chatFeedbackTarget = ChatFeedbackTarget(
        messageID: message.id,
        content: message.content,
        direction: direction
      )
    }
  }

  func submitChatFeedback() {
    guard let chatFeedbackTarget else { return }

    let trimmed = chatFeedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    var props = chatFeedbackAnalyticsPayload(
      for: chatFeedbackTarget.message,
      direction: chatFeedbackTarget.direction,
      includeSharedAnswerContext: chatFeedbackShareLogs
    )
    props["feedback_message_length"] = trimmed.count
    props["share_logs_enabled"] = chatFeedbackShareLogs
    if !trimmed.isEmpty {
      props["feedback_message"] = trimmed
    }

    AnalyticsService.shared.capture("chat_answer_feedback_submitted", props)
    chatFeedbackMessage = ""

    withAnimation(feedbackModalAnimation) {
      chatFeedbackMode = .thanks
    }
  }

  func dismissChatFeedback(animated: Bool = true) {
    let shouldShowThanks = chatFeedbackMode == .thanks
    let messageID = chatFeedbackTarget?.messageID

    let reset = {
      chatFeedbackTarget = nil
      chatFeedbackMessage = ""
      chatFeedbackShareLogs = true
      chatFeedbackMode = .form
    }

    if animated {
      withAnimation(feedbackModalAnimation) {
        reset()
      }
    } else {
      reset()
    }

    if shouldShowThanks, let messageID {
      showTransientThanks(for: messageID)
    }
  }

  func resetChatFeedbackState() {
    for task in thankResetTasks.values {
      task.cancel()
    }
    thankResetTasks.removeAll()
    chatVoteSelections.removeAll()
    thankedMessageIDs.removeAll()
    chatFeedbackTarget = nil
    chatFeedbackMessage = ""
    chatFeedbackShareLogs = true
    chatFeedbackMode = .form
  }

  func showTransientThanks(for messageID: UUID) {
    thankResetTasks[messageID]?.cancel()

    withAnimation(feedbackStateAnimation) {
      thankedMessageIDs.formUnion([messageID])
    }

    thankResetTasks[messageID] = Task {
      try? await Task.sleep(nanoseconds: 1_600_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        withAnimation(feedbackStateAnimation) {
          thankedMessageIDs.subtract([messageID])
        }
        thankResetTasks[messageID] = nil
      }
    }
  }

  func chatFeedbackAnalyticsPayload(
    for message: ChatMessage,
    direction: TimelineRatingDirection?,
    includeSharedAnswerContext: Bool = true
  ) -> [String: Any] {
    var props: [String: Any] = [
      "provider": selectedProvider.analyticsProvider,
      "chat_runtime": selectedProvider.runtimeLabel,
      "share_logs_default": true,
    ]

    if let direction {
      props["thumb_direction"] = direction.rawValue
    }

    guard includeSharedAnswerContext else { return props }

    let messageIndex = chatService.messages.firstIndex(where: { $0.id == message.id }) ?? -1
    props["conversation_id"] = conversationId?.uuidString ?? "unknown"
    props["message_id"] = message.id.uuidString
    props["message_index"] = messageIndex
    props["assistant_message_length"] = message.content.count
    props["assistant_has_chart"] = message.content.contains("```chart")
    props["assistant_message_preview"] = String(message.content.prefix(240))

    return props
  }

  func loadMemoryFromStore(resetDraft: Bool) {
    let latest = DashboardChatMemoryStore.load()
    storedMemoryBlob = latest
    memoryUpdatedAt = DashboardChatMemoryStore.lastUpdatedAt()
    if resetDraft {
      memoryDraft = latest
    }
  }

  func syncMemoryFromStoreIfNeeded() {
    if isMemoryDirty {
      storedMemoryBlob = DashboardChatMemoryStore.load()
      memoryUpdatedAt = DashboardChatMemoryStore.lastUpdatedAt()
      return
    }
    loadMemoryFromStore(resetDraft: true)
  }

  func saveMemoryDraft() {
    let previousMemory = DashboardChatMemoryStore.load()
    DashboardChatMemoryStore.save(memoryDraft)
    let updatedMemory = DashboardChatMemoryStore.load()
    ChatService.shared.didUpdateDashboardMemory(from: previousMemory, to: updatedMemory)
    loadMemoryFromStore(resetDraft: true)
    AnalyticsService.shared.capture(
      "chat_memory_manual_saved",
      [
        "chars": storedMemoryBlob.count
      ])
  }

  func reloadMemoryDraft() {
    loadMemoryFromStore(resetDraft: true)
  }

  func clearMemoryDraft() {
    let previousMemory = DashboardChatMemoryStore.load()
    DashboardChatMemoryStore.clear()
    ChatService.shared.didUpdateDashboardMemory(from: previousMemory, to: "")
    loadMemoryFromStore(resetDraft: true)
    AnalyticsService.shared.capture("chat_memory_cleared")
  }

  func refreshRuntimeAvailability() async {
    cliDetectionTask?.cancel()
    cliDetectionTask = Task { @MainActor in
      let detection = await Task.detached(priority: .utility) {
        (
          CLIDetector.isInstalled(.codex),
          CLIDetector.isInstalled(.claude)
        )
      }.value

      guard !Task.isCancelled else { return }
      codexDetected = detection.0
      claudeDetected = detection.1
      geminiConfigured = isGeminiConfigured()
      normalizeSelectedProviderIfNeeded()
    }
  }

  func handleProviderSelection(_ provider: DashboardChatProvider) {
    guard provider != selectedProvider else { return }
    guard isProviderAvailable(provider) else { return }
    guard !chatService.isProcessing else { return }

    if chatService.messages.isEmpty {
      resetConversation()
      applySelectedProvider(provider)
      return
    }

    pendingProviderSelection = provider
    showToolSwitchConfirm = true
  }

  func confirmProviderSwitch() {
    guard let pendingProviderSelection else { return }
    resetConversation()
    applySelectedProvider(pendingProviderSelection)
    self.pendingProviderSelection = nil
  }

  func applySelectedProvider(_ provider: DashboardChatProvider) {
    selectedProviderRaw = provider.rawValue
    switch provider {
    case .gemini:
      break
    case .codex:
      chatCLIPreferredTool = "codex"
    case .claude:
      chatCLIPreferredTool = "claude"
    }
  }

  func isProviderAvailable(_ provider: DashboardChatProvider) -> Bool {
    switch provider {
    case .gemini:
      return geminiConfigured
    case .codex:
      return codexDetected
    case .claude:
      return claudeDetected
    }
  }

  func normalizeSelectedProviderIfNeeded() {
    guard !isProviderAvailable(selectedProvider) else { return }
    if geminiConfigured {
      applySelectedProvider(.gemini)
    } else if codexDetected {
      applySelectedProvider(.codex)
    } else if claudeDetected {
      applySelectedProvider(.claude)
    }
  }

  func isGeminiConfigured() -> Bool {
    let key =
      KeychainManager.shared.retrieve(for: "gemini")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !key.isEmpty
  }

  var pendingProviderLabel: String {
    switch pendingProviderSelection {
    case .gemini:
      return "Gemini"
    case .claude:
      return "Claude"
    case .codex:
      return "Codex"
    case .none:
      return "selected provider"
    }
  }

  var providerToggleHelpText: String {
    if selectedProviderAvailable {
      return "Choose chat provider"
    }
    return "Configure Gemini key or install Codex/Claude CLI"
  }
}
