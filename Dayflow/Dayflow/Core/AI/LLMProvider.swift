//
//  LLMProvider.swift
//  Dayflow
//

import Foundation

protocol LLMProvider {
    func transcribeVideo(videoData: Data, mimeType: String, prompt: String, batchStartTime: Date, videoDuration: TimeInterval) async throws -> (observations: [Observation], log: LLMCall)
    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext) async throws -> (cards: [ActivityCard], log: LLMCall)
}

struct ActivityGenerationContext {
    let userTaxonomy: String
    let extractedTaxonomy: String
    let batchObservations: [Observation]
    let existingCards: [ActivityCard]  // Cards that overlap with current analysis window
    let currentTime: Date  // Current time to prevent future timestamps
}

enum LLMProviderType: Codable {
    case geminiDirect
    case dayflowBackend(endpoint: String = "https://api.dayflow.app")
    case ollamaLocal(endpoint: String = "http://localhost:11434")
}

// MARK: - Data Models

struct ActivityCard: Codable {
    let startTime: String
    let endTime: String
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
    let distractions: [Distraction]?
}

// Distraction is defined in StorageManager.swift
// LLMCall is defined in StorageManager.swift

// MARK: - Helper Extensions for Timestamp Conversion

extension LLMProvider {
    // Convert "MM:SS" or "HH:MM:SS" to seconds from video start
    func parseVideoTimestamp(_ timestamp: String) -> Int {
        let components = timestamp.components(separatedBy: ":")
        
        if components.count == 3 {
            // HH:MM:SS format
            guard let hours = Int(components[0]),
                  let minutes = Int(components[1]),
                  let seconds = Int(components[2]) else {
                return 0
            }
            return hours * 3600 + minutes * 60 + seconds
        } else if components.count == 2 {
            // MM:SS format
            guard let minutes = Int(components[0]),
                  let seconds = Int(components[1]) else {
                return 0
            }
            return minutes * 60 + seconds
        }
        
        return 0
    }
    
    // Convert Unix timestamp to "h:mm a" for prompts
    func formatTimestampForPrompt(_ unixTime: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}
