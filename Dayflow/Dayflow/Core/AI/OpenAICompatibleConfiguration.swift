import Foundation

protocol OpenAICompatibleKeychainStoring {
  func retrieve(for provider: String) -> String?

  @discardableResult
  func store(_ apiKey: String, for provider: String) -> Bool

  @discardableResult
  func delete(for provider: String) -> Bool
}

extension KeychainManager: OpenAICompatibleKeychainStoring {}

enum OpenAICompatiblePreset: String, Codable, CaseIterable, Hashable {
  case openRouter = "openrouter"
  case siliconFlow = "siliconflow"
  case custom

  var displayName: String {
    switch self {
    case .openRouter:
      return "OpenRouter"
    case .siliconFlow:
      return "SiliconFlow"
    case .custom:
      return "Custom"
    }
  }
}

struct OpenAICompatibleDraft: Equatable {
  var baseURL: String
  var modelID: String
  var apiKey: String
}

struct OpenAICompatibleConfiguration: Codable, Equatable {
  static let openRouterBaseURL = "https://openrouter.ai/api/v1"
  static let siliconFlowBaseURL = "https://api.siliconflow.com/v1"
  static let siliconFlowDefaultModelID = "Qwen/Qwen3.6-35B-A3B"

  let preset: OpenAICompatiblePreset
  let baseURL: String
  let modelID: String

  init(preset: OpenAICompatiblePreset, baseURL: String, modelID: String) {
    self.preset = preset
    self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func openRouter(modelID: String = "") -> OpenAICompatibleConfiguration {
    OpenAICompatibleConfiguration(
      preset: .openRouter,
      baseURL: openRouterBaseURL,
      modelID: modelID
    )
  }

  static func siliconFlow(
    modelID: String = siliconFlowDefaultModelID
  ) -> OpenAICompatibleConfiguration {
    OpenAICompatibleConfiguration(
      preset: .siliconFlow,
      baseURL: siliconFlowBaseURL,
      modelID: modelID
    )
  }

  var chatCompletionsURL: URL? {
    LocalEndpointUtilities.chatCompletionsURL(baseURL: baseURL)
  }

  var isComplete: Bool {
    !baseURL.isEmpty && !modelID.isEmpty && chatCompletionsURL != nil
  }
}

enum OpenAICompatiblePreferences {
  /// Kept for compatibility with older installations that used one shared item.
  static let keychainProvider = "openai_compatible"
  private static let configurationKey = "llmOpenAICompatibleConfigurationV1"

  static func keychainProvider(for preset: OpenAICompatiblePreset) -> String {
    "openai_compatible_\(preset.rawValue)"
  }

  /// API keys are opaque tokens and never contain meaningful whitespace. Removing
  /// pasted line breaks keeps keys copied from a browser or terminal usable.
  static func normalizedAPIKey(_ apiKey: String) -> String {
    apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
  }

  /// Reads a preset-specific key and migrates the pre-preset shared key only for the
  /// currently persisted preset. This prevents a legacy key from appearing in every tab.
  static func apiKey(
    for preset: OpenAICompatiblePreset,
    migrateLegacyKey: Bool = true,
    keychain: OpenAICompatibleKeychainStoring = KeychainManager.shared
  ) -> String? {
    let provider = keychainProvider(for: preset)
    if let apiKey = keychain.retrieve(for: provider) {
      let normalizedKey = normalizedAPIKey(apiKey)
      if !normalizedKey.isEmpty {
        return normalizedKey
      }
    }

    guard migrateLegacyKey,
      let legacyKey = keychain.retrieve(for: keychainProvider),
      !normalizedAPIKey(legacyKey).isEmpty
    else {
      return nil
    }

    let normalizedLegacyKey = normalizedAPIKey(legacyKey)

    // Keep the current session usable even if the best-effort migration cannot write.
    if keychain.store(normalizedLegacyKey, for: provider) {
      _ = keychain.delete(for: keychainProvider)
    }
    return normalizedLegacyKey
  }

  static func load(from defaults: UserDefaults = .standard) -> OpenAICompatibleConfiguration? {
    guard let data = defaults.data(forKey: configurationKey) else { return nil }
    return try? JSONDecoder().decode(OpenAICompatibleConfiguration.self, from: data)
  }

  @discardableResult
  static func save(
    _ configuration: OpenAICompatibleConfiguration,
    to defaults: UserDefaults = .standard
  ) -> Bool {
    guard let data = try? JSONEncoder().encode(configuration) else { return false }
    let previousValue = defaults.object(forKey: configurationKey)
    defaults.set(data, forKey: configurationKey)
    guard load(from: defaults) == configuration else {
      if let previousValue {
        defaults.set(previousValue, forKey: configurationKey)
      } else {
        defaults.removeObject(forKey: configurationKey)
      }
      return false
    }
    return true
  }

  static func reset(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: configurationKey)
  }
}

struct OpenAICompatibleRuntimeConfiguration: Sendable {
  let endpoint: String
  let modelID: String
  let bearerToken: String?
  let analyticsProvider: String
  let shouldDisableThinking: Bool

  init(
    configuration: OpenAICompatibleConfiguration,
    bearerToken: String?,
    analyticsProvider: String = OpenAICompatiblePreferences.keychainProvider
  ) {
    endpoint = configuration.baseURL
    modelID = configuration.modelID
    shouldDisableThinking = configuration.preset == .siliconFlow
    let trimmedToken =
      bearerToken.map(OpenAICompatiblePreferences.normalizedAPIKey) ?? ""
    self.bearerToken = trimmedToken.isEmpty ? nil : trimmedToken

    let trimmedProvider = analyticsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    self.analyticsProvider =
      trimmedProvider.isEmpty
      ? OpenAICompatiblePreferences.keychainProvider
      : trimmedProvider
  }
}
