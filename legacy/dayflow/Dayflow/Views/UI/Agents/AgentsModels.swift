//
//  AgentsModels.swift
//  Dayflow
//
//  Data model for the Agents tab. A headless Fable run (see AgentsRecapPrompt)
//  sweeps the day's Claude Code and Codex sessions and writes a JSON recap file
//  that decodes into these types. Every card style renders from the same
//  `turns` array — the styles are pure view-layer projections.
//
//  Decoding is deliberately lenient (decodeIfPresent + fallbacks everywhere):
//  the file is authored by a model, so a missing field or an unexpected enum
//  string should degrade gracefully instead of failing the whole recap.
//

import SwiftUI

struct AgentsDayRecap: Codable, Sendable {
  var schemaVersion: Int
  var day: String
  var generatedAt: String
  var workstreams: [AgentWorkstream]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
    day = (try? container.decodeIfPresent(String.self, forKey: .day)) ?? ""
    generatedAt = (try? container.decodeIfPresent(String.self, forKey: .generatedAt)) ?? ""
    workstreams =
      (try? container.decodeIfPresent([AgentWorkstream].self, forKey: .workstreams)) ?? []
  }

  var totalCounts: AgentStatusCounts {
    workstreams.reduce(AgentStatusCounts()) { $0.adding($1.counts) }
  }
}

struct AgentWorkstream: Codable, Identifiable, Sendable {
  var id: String
  var name: String
  var summary: String
  var bullets: [String]
  var threads: [AgentThread]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
    id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? name
    summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? ""
    bullets = (try? container.decodeIfPresent([String].self, forKey: .bullets)) ?? []
    threads = (try? container.decodeIfPresent([AgentThread].self, forKey: .threads)) ?? []
  }

  var counts: AgentStatusCounts {
    threads.reduce(AgentStatusCounts()) { $0.adding($1.status) }
  }
}

struct AgentThread: Codable, Identifiable, Sendable {
  var id: String
  var title: String
  var source: AgentThreadSource
  var projectName: String
  var sessionPath: String
  var status: AgentThreadStatus
  var startedAt: String
  var endedAt: String
  var latestOutcome: String
  var turns: [AgentTurn]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled thread"
    id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? title
    let sourceRaw = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? ""
    source = AgentThreadSource(rawValue: sourceRaw) ?? .claude
    projectName = (try? container.decodeIfPresent(String.self, forKey: .projectName)) ?? ""
    sessionPath = (try? container.decodeIfPresent(String.self, forKey: .sessionPath)) ?? ""
    let statusRaw = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? ""
    status = AgentThreadStatus(rawValue: statusRaw) ?? .completed
    startedAt = (try? container.decodeIfPresent(String.self, forKey: .startedAt)) ?? ""
    endedAt = (try? container.decodeIfPresent(String.self, forKey: .endedAt)) ?? ""
    latestOutcome = (try? container.decodeIfPresent(String.self, forKey: .latestOutcome)) ?? ""
    turns = (try? container.decodeIfPresent([AgentTurn].self, forKey: .turns)) ?? []
  }

  var firstPrompt: String {
    turns.first(where: { $0.role == .user })?.text ?? title
  }

  /// Intermediate agent milestones: every agent turn except the one that
  /// already appears as `latestOutcome`.
  var milestoneTexts: [String] {
    let agentTexts = turns.filter { $0.role == .agent }.map(\.text)
    if agentTexts.last == latestOutcome {
      return Array(agentTexts.dropLast())
    }
    return agentTexts
  }
}

struct AgentTurn: Codable, Identifiable, Sendable {
  let id = UUID()
  var role: AgentTurnRole
  var text: String
  var highlight: AgentTurnHighlight
  var bullets: [String]
  var artifactName: String?
  var artifactPath: String?

  private enum CodingKeys: String, CodingKey {
    case role, text, highlight, bullets, artifactName, artifactPath
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let roleRaw = (try? container.decodeIfPresent(String.self, forKey: .role)) ?? ""
    role = AgentTurnRole(rawValue: roleRaw) ?? .agent
    text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
    let highlightRaw = (try? container.decodeIfPresent(String.self, forKey: .highlight)) ?? ""
    highlight = AgentTurnHighlight(rawValue: highlightRaw) ?? .none
    bullets = (try? container.decodeIfPresent([String].self, forKey: .bullets)) ?? []
    artifactName = try? container.decodeIfPresent(String.self, forKey: .artifactName)
    artifactPath = try? container.decodeIfPresent(String.self, forKey: .artifactPath)
  }
}

enum AgentTurnRole: String, Codable, Sendable {
  case user
  case agent
}

enum AgentTurnHighlight: String, Codable, Sendable {
  case none
  case keyDecision
  case keyInfo
  case readyForReview
}

enum AgentThreadSource: String, Codable, Sendable {
  case claude
  case codex

  var displayName: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    }
  }
}

enum AgentThreadStatus: String, Codable, CaseIterable, Sendable {
  case blocked
  case reviewReady
  case inProgress
  case completed

  var displayName: String {
    switch self {
    case .blocked: return "Blocked"
    case .reviewReady: return "Review ready"
    case .inProgress: return "In progress"
    case .completed: return "Completed"
    }
  }
}

struct AgentStatusCounts: Sendable {
  var blocked = 0
  var reviewReady = 0
  var inProgress = 0
  var completed = 0

  func adding(_ status: AgentThreadStatus) -> AgentStatusCounts {
    var copy = self
    switch status {
    case .blocked: copy.blocked += 1
    case .reviewReady: copy.reviewReady += 1
    case .inProgress: copy.inProgress += 1
    case .completed: copy.completed += 1
    }
    return copy
  }

  func adding(_ other: AgentStatusCounts) -> AgentStatusCounts {
    var copy = self
    copy.blocked += other.blocked
    copy.reviewReady += other.reviewReady
    copy.inProgress += other.inProgress
    copy.completed += other.completed
    return copy
  }

  func count(for status: AgentThreadStatus) -> Int {
    switch status {
    case .blocked: return blocked
    case .reviewReady: return reviewReady
    case .inProgress: return inProgress
    case .completed: return completed
    }
  }
}

// MARK: - Card rendering styles

/// The four rendering sub-directions from the Figma exploration, toggleable at
/// runtime so each can be evaluated with real data.
enum AgentCardStyle: String, CaseIterable, Identifiable {
  case messenger
  case transcript
  case brief
  case milestones

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .messenger: return "Messenger"
    case .transcript: return "Transcript"
    case .brief: return "Brief"
    case .milestones: return "Milestones"
    }
  }
}

// MARK: - Shared palette

enum AgentsPalette {
  // Soft blob fills, assigned to workstreams by index (mirrors the Figma
  // scatter: blue, purple, orange, tan, light blue).
  static let blobColors: [Color] = [
    Color(hex: "9FC1F2"),
    Color(hex: "CBB8F5"),
    Color(hex: "F5A25C"),
    Color(hex: "DEC9B2"),
    Color(hex: "B4CDF0"),
    Color(hex: "F2B8C6"),
    Color(hex: "A8DCC5"),
  ]

  static func blobColor(at index: Int) -> Color {
    blobColors[index % blobColors.count]
  }

  static func chipBackground(for status: AgentThreadStatus) -> Color {
    switch status {
    case .blocked: return Color(hex: "FFDCDA")
    case .reviewReady: return Color(hex: "CFF3E4")
    case .inProgress: return Color.white
    case .completed: return Color(hex: "ECEAE7")
    }
  }

  static func chipForeground(for status: AgentThreadStatus) -> Color {
    switch status {
    case .blocked: return Color(hex: "B03A31")
    case .reviewReady: return Color(hex: "1F8A6E")
    case .inProgress: return Color(hex: "6B655F")
    case .completed: return Color(hex: "8D8781")
    }
  }

  static func legendDot(for status: AgentThreadStatus) -> Color {
    switch status {
    case .blocked: return Color(hex: "F58B84")
    case .reviewReady: return Color(hex: "5ED4AC")
    case .inProgress: return Color(hex: "FFFFFF")
    case .completed: return Color(hex: "CFCAC4")
    }
  }

  // Highlight pill colors, constant across all card styles: purple = key
  // decision, blue = key info, orange = ready for review.
  static let keyDecisionBackground = Color(hex: "EDE4FC")
  static let keyDecisionForeground = Color(hex: "7A4FD1")
  static let keyInfoBackground = Color(hex: "E1ECFC")
  static let keyInfoForeground = Color(hex: "3E76D6")
  static let reviewBackground = Color(hex: "FFF1E5")
  static let reviewForeground = Color(hex: "F96E00")
}
