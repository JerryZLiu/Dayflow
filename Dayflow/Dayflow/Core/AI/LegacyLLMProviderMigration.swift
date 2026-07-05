import Foundation

/// The one-shot compatibility boundary between the combined legacy provider model and exact IDs.
/// This type only reads legacy values. Once `LLMProviderRoutingStore` writes V2 routing, none of
/// these values participate in provider selection again.
enum LegacyLLMProviderMigration {
  enum ProviderType: Codable {
    case geminiDirect
    case dayflowBackend(endpoint: String = "")
    case ollamaLocal(endpoint: String = "http://localhost:11434")
    case chatGPTClaude
  }

  struct Result: Equatable {
    let routing: LLMProviderRouting
    let sharedPromptOverrides: ChatCLIPromptOverrides
    let dayflowEndpointOverride: String?
    let localEndpointOverride: String?
    let completedChatCLIProvider: LLMProviderID?
  }

  enum Key {
    static let providerType = "llmProviderType"
    static let selectedProvider = "selectedLLMProvider"
    static let preferredChatCLITool = "chatCLIPreferredTool"
    static let backupProvider = "llmBackupProviderId"
    static let backupChatCLITool = "llmBackupChatCLITool"
    static let sharedPromptOverrides = "chatCLIPromptOverrides"
    static let chatCLISetupComplete = "chatgpt_claudeSetupComplete"
  }

  private struct PrimarySelection {
    let providerID: LLMProviderID
    let dayflowEndpointOverride: String?
    let localEndpointOverride: String?
  }

  static func migrate(from defaults: UserDefaults) -> Result {
    let primary = primarySelection(from: defaults)
    let secondary = providerID(
      from: defaults.string(forKey: Key.backupProvider),
      combinedChatCLITool: chatCLITool(
        from: defaults.string(forKey: Key.backupChatCLITool),
        defaultingTo: preferredChatCLITool(from: defaults)
      )
    )

    let routing = LLMProviderRouting(primary: primary.providerID, secondary: secondary)
    return Result(
      routing: routing,
      sharedPromptOverrides: sharedPromptOverrides(from: defaults),
      dayflowEndpointOverride: primary.dayflowEndpointOverride,
      localEndpointOverride: primary.localEndpointOverride,
      completedChatCLIProvider: completedChatCLIProvider(
        for: routing,
        defaults: defaults
      )
    )
  }

  private static func completedChatCLIProvider(
    for routing: LLMProviderRouting,
    defaults: UserDefaults
  ) -> LLMProviderID? {
    guard defaults.bool(forKey: Key.chatCLISetupComplete) else { return nil }
    let routedProviders = [routing.primary, routing.secondary].compactMap { $0 }
    if let routedProvider = routedProviders.first(where: {
      $0 == .chatGPT || $0 == .claude
    }) {
      return routedProvider
    }
    return providerID(for: preferredChatCLITool(from: defaults))
  }

  private static func primarySelection(from defaults: UserDefaults) -> PrimarySelection {
    if let data = defaults.data(forKey: Key.providerType),
      let providerType = try? JSONDecoder().decode(ProviderType.self, from: data)
    {
      return primarySelection(
        from: providerType,
        preferredChatCLITool: preferredChatCLITool(from: defaults)
      )
    }

    let providerID =
      providerID(
        from: defaults.string(forKey: Key.selectedProvider),
        combinedChatCLITool: preferredChatCLITool(from: defaults)
      ) ?? .gemini
    return PrimarySelection(
      providerID: providerID,
      dayflowEndpointOverride: nil,
      localEndpointOverride: nil
    )
  }

  private static func primarySelection(
    from providerType: ProviderType,
    preferredChatCLITool: ChatCLITool
  ) -> PrimarySelection {
    switch providerType {
    case .geminiDirect:
      return PrimarySelection(
        providerID: .gemini,
        dayflowEndpointOverride: nil,
        localEndpointOverride: nil
      )
    case .dayflowBackend(let endpoint):
      return PrimarySelection(
        providerID: .dayflow,
        dayflowEndpointOverride: normalized(endpoint),
        localEndpointOverride: nil
      )
    case .ollamaLocal(let endpoint):
      return PrimarySelection(
        providerID: .local,
        dayflowEndpointOverride: nil,
        localEndpointOverride: normalized(endpoint)
      )
    case .chatGPTClaude:
      return PrimarySelection(
        providerID: providerID(for: preferredChatCLITool),
        dayflowEndpointOverride: nil,
        localEndpointOverride: nil
      )
    }
  }

  private static func providerID(
    from rawValue: String?,
    combinedChatCLITool: ChatCLITool
  ) -> LLMProviderID? {
    switch normalized(rawValue)?.lowercased() {
    case LLMProviderID.dayflow.rawValue:
      return .dayflow
    case LLMProviderID.gemini.rawValue:
      return .gemini
    case LLMProviderID.chatGPT.rawValue:
      return .chatGPT
    case LLMProviderID.claude.rawValue:
      return .claude
    case LLMProviderID.openAICompatible.rawValue:
      return .openAICompatible
    case LLMProviderID.local.rawValue, "ollama":
      return .local
    case "chatgpt_claude":
      return providerID(for: combinedChatCLITool)
    default:
      return nil
    }
  }

  private static func preferredChatCLITool(from defaults: UserDefaults) -> ChatCLITool {
    chatCLITool(from: defaults.string(forKey: Key.preferredChatCLITool), defaultingTo: .codex)
  }

  private static func chatCLITool(
    from rawValue: String?,
    defaultingTo fallback: ChatCLITool
  ) -> ChatCLITool {
    guard let rawValue = normalized(rawValue)?.lowercased() else { return fallback }
    return ChatCLITool(rawValue: rawValue) ?? fallback
  }

  private static func providerID(for tool: ChatCLITool) -> LLMProviderID {
    switch tool {
    case .codex:
      return .chatGPT
    case .claude:
      return .claude
    }
  }

  private static func sharedPromptOverrides(from defaults: UserDefaults)
    -> ChatCLIPromptOverrides
  {
    guard let data = defaults.data(forKey: Key.sharedPromptOverrides),
      let overrides = try? JSONDecoder().decode(ChatCLIPromptOverrides.self, from: data)
    else {
      return ChatCLIPromptOverrides()
    }
    return overrides
  }

  private static func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}
