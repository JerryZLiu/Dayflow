//
//  ChatMessage.swift
//  Dayflow
//
//  Chat message model for the Dashboard chat feature.
//

import Foundation

/// Represents a single message in the chat conversation
struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    var toolStatus: ToolStatus?

    /// The role/type of message
    enum Role: Sendable {
        case user           // User's question
        case assistant      // LLM's response
        case toolCall       // Visible tool execution
    }

    /// Status for tool call messages
    enum ToolStatus: Sendable, Equatable {
        case running                    // Animated spinner, shimmer effect
        case completed(summary: String) // Checkmark, shows result summary
        case failed(error: String)      // Error state
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        toolStatus: ToolStatus? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolStatus = toolStatus
    }

    // MARK: - Convenience Initializers

    /// Create a user message
    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }

    /// Create an assistant message
    static func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: content)
    }

    /// Create a running tool call message
    static func toolCall(_ toolName: String, description: String) -> ChatMessage {
        ChatMessage(
            role: .toolCall,
            content: description,
            toolStatus: .running
        )
    }
}

// MARK: - Tool Call Helpers

extension ChatMessage {
    /// Update tool call status to completed
    func completed(summary: String) -> ChatMessage {
        var copy = self
        copy.toolStatus = .completed(summary: summary)
        return copy
    }

    /// Update tool call status to failed
    func failed(error: String) -> ChatMessage {
        var copy = self
        copy.toolStatus = .failed(error: error)
        return copy
    }

    /// Whether this is a tool call that's currently running
    var isRunning: Bool {
        guard case .running = toolStatus else { return false }
        return true
    }
}
