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

  private static let providerDefaultsKey = "llmProviderType"
  private static let selectedProviderDefaultsKey = "selectedLLMProvider"
  private static let localBaseURLDefaultsKey = "llmLocalBaseURL"
  private static let chatCLIPreferredToolDefaultsKey = "chatCLIPreferredTool"

  static func load(from defaults: UserDefaults = .standard) -> LLMProviderType {
    if let savedData = defaults.data(forKey: providerDefaultsKey),
      let decoded = try? JSONDecoder().decode(LLMProviderType.self, from: savedData)
    {
      return decoded
    }

    guard let migrated = migrateLegacySelection(from: defaults) else {
      return .geminiDirect
    }

    migrated.persist(to: defaults)
    return migrated
  }

  func persist(to defaults: UserDefaults = .standard) {
    if let encoded = try? JSONEncoder().encode(self) {
      defaults.set(encoded, forKey: Self.providerDefaultsKey)
    }
    defaults.set(canonicalProviderID, forKey: Self.selectedProviderDefaultsKey)
  }

  var canonicalProviderID: String {
    switch self {
    case .geminiDirect:
      return "gemini"
    case .dayflowBackend:
      return "dayflow"
    case .ollamaLocal:
      return "ollama"
    case .chatGPTClaude:
      return "chatgpt_claude"
    }
  }

  private static func migrateLegacySelection(from defaults: UserDefaults) -> LLMProviderType? {
    guard
      let rawSelection = defaults.string(forKey: selectedProviderDefaultsKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      !rawSelection.isEmpty
    else {
      return nil
    }

    switch rawSelection {
    case "gemini":
      return .geminiDirect
    case "dayflow":
      return .dayflowBackend()
    case "ollama":
      let endpoint = defaults.string(forKey: localBaseURLDefaultsKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let endpoint, !endpoint.isEmpty {
        return .ollamaLocal(endpoint: endpoint)
      }
      return .ollamaLocal()
    case "chatgpt":
      if defaults.string(forKey: chatCLIPreferredToolDefaultsKey) == nil {
        defaults.set("codex", forKey: chatCLIPreferredToolDefaultsKey)
      }
      return .chatGPTClaude
    case "claude":
      if defaults.string(forKey: chatCLIPreferredToolDefaultsKey) == nil {
        defaults.set("claude", forKey: chatCLIPreferredToolDefaultsKey)
      }
      return .chatGPTClaude
    case "chatgpt_claude":
      return .chatGPTClaude
    default:
      return nil
    }
  }
}

enum LLMProviderID: String, Codable, CaseIterable {
  case gemini
  case dayflow
  case ollama
  case chatGPTClaude = "chatgpt_claude"

  var analyticsName: String {
    switch self {
    case .gemini:
      return "gemini"
    case .dayflow:
      return "dayflow"
    case .ollama:
      return "ollama"
    case .chatGPTClaude:
      return "chat_cli"
    }
  }

  static func from(_ providerType: LLMProviderType) -> LLMProviderID {
    switch providerType {
    case .geminiDirect:
      return .gemini
    case .dayflowBackend:
      return .dayflow
    case .ollamaLocal:
      return .ollama
    case .chatGPTClaude:
      return .chatGPTClaude
    }
  }

  func providerLabel(chatTool: ChatCLITool? = nil) -> String {
    switch self {
    case .gemini:
      return "gemini"
    case .dayflow:
      return "dayflow"
    case .ollama:
      return "local"
    case .chatGPTClaude:
      return chatTool == .claude ? "claude" : "chatgpt"
    }
  }
}

enum LLMProviderRoutingPreferences {
  static let backupProviderDefaultsKey = "llmBackupProviderId"
  static let backupChatCLIToolDefaultsKey = "llmBackupChatCLITool"

  static func loadBackupProvider(from defaults: UserDefaults = .standard) -> LLMProviderID? {
    guard let rawValue = defaults.string(forKey: backupProviderDefaultsKey) else {
      return nil
    }
    return LLMProviderID(rawValue: rawValue)
  }

  static func saveBackupProvider(_ provider: LLMProviderID?, to defaults: UserDefaults = .standard)
  {
    if let provider {
      defaults.set(provider.rawValue, forKey: backupProviderDefaultsKey)
    } else {
      defaults.removeObject(forKey: backupProviderDefaultsKey)
    }
  }

  static func loadBackupChatCLITool(from defaults: UserDefaults = .standard) -> ChatCLITool? {
    guard let rawValue = defaults.string(forKey: backupChatCLIToolDefaultsKey) else {
      return nil
    }
    return ChatCLITool(rawValue: rawValue)
  }

  static func saveBackupChatCLITool(_ tool: ChatCLITool?, to defaults: UserDefaults = .standard) {
    if let tool {
      defaults.set(tool.rawValue, forKey: backupChatCLIToolDefaultsKey)
    } else {
      defaults.removeObject(forKey: backupChatCLIToolDefaultsKey)
    }
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
