//
//  ChatModels.swift
//  Dayflow
//

import Foundation

// MARK: - Chat Message

struct ChatMessage: Identifiable {
    let id: UUID
    let role: ChatRole
    var content: String
    let timestamp: Date
    var attachedScreenshotPaths: [String]?
    var isLoading: Bool

    enum ChatRole {
        case user
        case assistant
        case system
    }

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        timestamp: Date = Date(),
        attachedScreenshotPaths: [String]? = nil,
        isLoading: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.attachedScreenshotPaths = attachedScreenshotPaths
        self.isLoading = isLoading
    }
}

// MARK: - Data Tier

enum ChatDataTier: String, Codable {
    case summaries  // Tier 1: card titles, summaries, categories, times
    case detailed   // Tier 2: detailed summaries + observations
    case visual     // Tier 3: actual screenshots
}

// MARK: - Routing Decision

struct ChatRoutingDecision: Codable {
    let tier: ChatDataTier
    let timeRangeStart: String?
    let timeRangeEnd: String?
    let answer: String?
}
