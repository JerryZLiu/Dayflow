//
//  LLMTypes.swift
//  Dayflow
//

import Foundation

struct ActivityGenerationContext {
    let batchObservations: [Observation]
    let existingCards: [ActivityCardData]  // Cards that overlap with current analysis window
    let currentTime: Date  // Current time to prevent future timestamps
    let categories: [LLMCategoryDescriptor]
}

enum LLMProviderType: Codable {
    case geminiDirect
    case dayflowBackend(endpoint: String = "https://api.dayflow.app")
    case ollamaLocal(endpoint: String = "http://localhost:11434")
    case chatGPTClaude
}

struct BatchingConfig {
    let targetDuration: TimeInterval
    let maxGap: TimeInterval

    static let gemini = BatchingConfig(targetDuration: 30 * 60, maxGap: 5 * 60)   // 30 min batches, 5 min gap
    static let standard = BatchingConfig(targetDuration: 15 * 60, maxGap: 2 * 60) // 15 min batches, 2 min gap
}


struct AppSites: Codable {
    let primary: String?
    let secondary: String?
}

struct ActivityCardData: Codable {
    let startTime: String
    let endTime: String
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
    let distractions: [Distraction]?
    let appSites: AppSites?
}

// Distraction is defined in StorageManager.swift
// LLMCall is defined in StorageManager.swift
