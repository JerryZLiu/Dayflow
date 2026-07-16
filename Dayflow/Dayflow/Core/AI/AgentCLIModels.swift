//
//  AgentCLIModels.swift
//  Dayflow
//
//  High-level LLM provider that uses ChatCLIRunner for CLI execution.
//

import AppKit
import Foundation

struct AgentCLIObservationsEnvelope: Codable {
  struct Item: Codable {
    let start: String
    let end: String
    let text: String
  }
  let observations: [Item]
}

struct AgentCLICardsEnvelope: Codable {
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

struct SegmentMergeResponse: Codable {
  struct Segment: Codable {
    let start: String
    let end: String
    let description: String
  }

  let segments: [Segment]
}

struct AgentCLITimeRange {
  let start: Double
  let end: Double
}
