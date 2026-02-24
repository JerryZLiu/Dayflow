//
//  DayflowBackendProvider.swift
//  Dayflow
//

import Foundation

final class DayflowBackendProvider {
  private let token: String
  private let endpoint: String

  init(token: String, endpoint: String = "https://api.dayflow.app") {
    self.token = token
    self.endpoint = endpoint
  }

  func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?)
    async throws -> (observations: [Observation], log: LLMCall)
  {
    fatalError("DayflowBackendProvider not implemented yet")
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    fatalError("DayflowBackendProvider not implemented yet")
  }

  func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
    throw NSError(
      domain: "DayflowBackend",
      code: -1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Text generation is not yet supported with Dayflow Backend. Please configure Gemini, Ollama, or ChatGPT/Claude CLI in Settings."
      ]
    )
  }
}
