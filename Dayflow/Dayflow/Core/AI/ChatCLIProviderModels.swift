//
//  ChatCLIProvider.swift
//  Dayflow
//
//  High-level LLM provider that uses ChatCLIRunner for CLI execution.
//

import AppKit
import Foundation

struct ChatCLIObservationsEnvelope: Codable {
  struct Item: Codable {
    let start: String
    let end: String
    let text: String
  }
  let observations: [Item]
}

struct ChatCLICardsEnvelope: Codable {
  struct Item: Codable {
    let start: String?
    let end: String?
    let startTime: String?
    let endTime: String?
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String?
    let distractions: [Distraction]?
    let appSites: AppSites?

    var normalizedStart: String? { start ?? startTime }
    var normalizedEnd: String? { end ?? endTime }
  }
  let cards: [Item]
}
