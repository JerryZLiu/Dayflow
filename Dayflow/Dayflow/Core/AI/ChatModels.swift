//
//  ChatModels.swift
//  Dayflow
//
//  Value types shared between ChatService and the chat UI.
//

import Foundation

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
