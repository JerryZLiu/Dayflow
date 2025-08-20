//
//  DayflowBackendProvider.swift
//  Dayflow
//

import Foundation

final class DayflowBackendProvider: LLMProvider {
    private let token: String
    private let endpoint: String
    
    init(token: String, endpoint: String = "https://api.dayflow.app") {
        self.token = token
        self.endpoint = endpoint
    }
    
    func transcribeVideo(videoData: Data, mimeType: String, prompt: String, batchStartTime: Date, videoDuration: TimeInterval) async throws -> (observations: [Observation], log: LLMCall) {
        fatalError("DayflowBackendProvider not implemented yet")
    }
    
    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext) async throws -> (cards: [ActivityCard], log: LLMCall) {
        fatalError("DayflowBackendProvider not implemented yet")
    }
}