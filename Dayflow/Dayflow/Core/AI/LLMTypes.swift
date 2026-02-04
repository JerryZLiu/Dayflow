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

    static func saveBackupProvider(_ provider: LLMProviderID?, to defaults: UserDefaults = .standard) {
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
