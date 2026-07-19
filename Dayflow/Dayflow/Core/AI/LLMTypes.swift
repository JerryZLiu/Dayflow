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

enum DashboardChatProvider: String, Codable, CaseIterable {
  case gemini
  case codex
  case claude

  static func fromStoredValue(_ value: String?) -> DashboardChatProvider {
    guard let value else { return .gemini }
    return DashboardChatProvider(rawValue: value) ?? .gemini
  }

  var analyticsProvider: String {
    rawValue
  }

  var runtimeLabel: String {
    switch self {
    case .gemini:
      return "gemini_function_calling"
    case .codex, .claude:
      return "chat_cli"
    }
  }
}

enum DashboardChatTurnRole: String, Codable, Sendable {
  case user
  case assistant

  var promptLabel: String {
    switch self {
    case .user:
      return "User"
    case .assistant:
      return "Assistant"
    }
  }

  var geminiRole: String {
    switch self {
    case .user:
      return "user"
    case .assistant:
      return "model"
    }
  }
}

struct DashboardChatTurn: Codable, Sendable, Equatable {
  let role: DashboardChatTurnRole
  let content: String

  static func user(_ content: String) -> DashboardChatTurn {
    DashboardChatTurn(role: .user, content: content)
  }

  static func assistant(_ content: String) -> DashboardChatTurn {
    DashboardChatTurn(role: .assistant, content: content)
  }
}

struct DashboardChatRequest: Sendable {
  let provider: DashboardChatProvider
  let prompt: String
  let sessionId: String?
  let systemInstruction: String?
  let history: [DashboardChatTurn]
}

enum LLMProviderID: String, Codable, CaseIterable {
  case dayflow
  case gemini
  case chatGPT = "chatgpt"
  case claude
  case openAICompatible = "openai_compatible"
  case local
  case minimax

  var analyticsName: String {
    switch self {
    case .dayflow:
      return "dayflow"
    case .gemini:
      return "gemini"
    case .chatGPT, .claude:
      return "chat_cli"
    case .openAICompatible:
      return "openai_compatible"
    case .local:
      return "ollama"
    case .minimax:
      return "minimax"
    }
  }

  var providerLabel: String {
    switch self {
    case .dayflow: return "dayflow"
    case .gemini: return "gemini"
    case .chatGPT: return "chatgpt"
    case .claude: return "claude"
    case .openAICompatible: return "openai_compatible"
    case .local:
      return "local"
    case .minimax:
      return "minimax"
    }
  }
}

enum LLMProviderSetupPreferencesError: Error {
  case writeVerificationFailed
}

enum LLMProviderSetupPreferences {
  static func isComplete(
    _ providerID: LLMProviderID,
    in defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.bool(forKey: completionKey(for: providerID))
  }

  static func markComplete(
    _ providerID: LLMProviderID,
    in defaults: UserDefaults = .standard
  ) throws {
    let key = completionKey(for: providerID)
    let previousValue = defaults.object(forKey: key)
    defaults.set(true, forKey: key)
    guard isComplete(providerID, in: defaults) else {
      if let previousValue {
        defaults.set(previousValue, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
      throw LLMProviderSetupPreferencesError.writeVerificationFailed
    }
  }

  private static func completionKey(for providerID: LLMProviderID) -> String {
    "\(providerID.rawValue)SetupComplete"
  }
}

struct BatchingConfig {
  let targetDuration: TimeInterval
  let maxGap: TimeInterval
  let cardLookbackDuration: TimeInterval

  static let standard = BatchingConfig(
    targetDuration: 15 * 60,  // 15-minute analysis batches
    maxGap: 2 * 60,  // Split batches if gap exceeds 2 minutes
    cardLookbackDuration: 45 * 60  // Build cards with a 45-minute lookback window
  )
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
