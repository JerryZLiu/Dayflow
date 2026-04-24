//
//  ChatView.swift
//  Dayflow
//
//  Chat interface for asking questions about activity data.
//

import AppKit
import Charts
import SwiftUI

let chatViewDebugTimestampFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm:ss.SSS"
  return formatter
}()

let chatViewMemoryUpdatedFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "MMM d, h:mm a"
  return formatter
}()

struct ChatView: View {
  @ObservedObject var chatService = ChatService.shared
  @State var inputText = ""
  @State var showWorkDetails = false
  @State var isInputFocused = false
  @State var composerFocusToken = 0
  @Namespace var bottomID
  @AppStorage("dashboardChatProvider") var selectedProviderRaw: String = "gemini"
  @AppStorage("chatCLIPreferredTool") var chatCLIPreferredTool: String = "codex"
  @AppStorage("hasChatBetaAccepted") var hasBetaAccepted: Bool = false
  @State var geminiConfigured = false
  @State var codexDetected = false
  @State var claudeDetected = false
  @State var cliDetectionTask: Task<Void, Never>?
  @State var didCheckCLI = false
  @State var showToolSwitchConfirm = false
  @State var pendingProviderSelection: DashboardChatProvider?
  @State var conversationId: UUID?
  @State var didAnimateWelcome = false
  @State var showMemoryPanel = false
  @State var memoryDraft = ""
  @State var storedMemoryBlob = ""
  @State var memoryUpdatedAt: Date?
  @State var chatVoteSelections: [UUID: TimelineRatingDirection] = [:]
  @State var thankedMessageIDs: Set<UUID> = []
  @State var thankResetTasks: [UUID: Task<Void, Never>] = [:]
  @State var chatFeedbackTarget: ChatFeedbackTarget?
  @State var chatFeedbackMessage = ""
  @State var chatFeedbackShareLogs = true
  @State var chatFeedbackMode: TimelineFeedbackMode = .form
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  var body: some View {
    ZStack {
      if isUnlocked {
        HStack(spacing: 0) {
          chatContent
          if showMemoryPanel {
            memoryPanel
          }
          if chatService.showDebugPanel {
            debugPanel
          }
        }
        .allowsHitTesting(chatFeedbackTarget == nil)
        .transition(.opacity)

        if let chatFeedbackTarget {
          TimelineFeedbackModal(
            message: $chatFeedbackMessage,
            shareLogs: $chatFeedbackShareLogs,
            direction: chatFeedbackTarget.direction,
            mode: chatFeedbackMode,
            content: .chat,
            onSubmit: submitChatFeedback,
            onClose: { dismissChatFeedback() }
          )
          .padding(.leading, 20)
          .padding(.bottom, 16)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(2)
        }
      } else {
        betaLockScreen
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .task {
      guard !didCheckCLI else { return }
      didCheckCLI = true
      await refreshRuntimeAvailability()
    }
    .onAppear {
      loadMemoryFromStore(resetDraft: true)
      Task { await refreshRuntimeAvailability() }
    }
    .onDisappear {
      cliDetectionTask?.cancel()
      cliDetectionTask = nil
      for task in thankResetTasks.values {
        task.cancel()
      }
      thankResetTasks.removeAll()
    }
    .onChange(of: chatService.messages.count) { _, _ in
      syncMemoryFromStoreIfNeeded()
    }
    .alert("Switch provider?", isPresented: $showToolSwitchConfirm) {
      Button("Switch and Reset", role: .destructive) {
        confirmProviderSwitch()
      }
      Button("Cancel", role: .cancel) {
        pendingProviderSelection = nil
      }
    } message: {
      Text("Switching to \(pendingProviderLabel) will clear this chat's context.")
    }
    .environment(\.colorScheme, .light)
  }
}
