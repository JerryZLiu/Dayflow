import Foundation

final class CodexProvider: AgentCLISupporting {
  let providerID: LLMProviderID = .chatGPT
  var cliTool: ChatCLITool { .codex }
  let runner = ChatCLIProcessRunner()
  let config = ChatCLIConfigManager.shared
  /// When non-nil, this overrides whatever the static `*ModelConfiguration`
  /// methods would otherwise pick as the canonical Codex model. `LLMService`
  /// populates it from `UserDefaults` (key: `llmCodexModel`) so the model the
  /// provider uses stays in sync with the user's Settings selection. When
  /// nil, providers fall back to the hardcoded default.
  let defaultModel: String?

  init(defaultModel: String? = nil) {
    self.defaultModel = defaultModel
    config.ensureWorkingDirectory()
  }
}

extension CodexProvider {
  /// Resolved model for activity-card generation. Uses `defaultModel` when the
  /// user has configured one in Settings, otherwise falls back to the
  /// canonical Codex model returned by `activityCardModelConfiguration()`.
  /// Reasoning effort is always taken from the static default because the
  /// effort is a property of the Codex profile, not the model id.
  func resolvedActivityCardModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    let fallback = Self.activityCardModelConfiguration()
    return (model: defaultModel ?? fallback.model, reasoningEffort: fallback.reasoningEffort)
  }

  /// Resolved model for screenshot transcription. Same shape as
  /// `resolvedActivityCardModelConfiguration()`; kept distinct so future per-
  /// operation overrides (e.g. a faster transcription-only model) can be
  /// added without touching the activity-card path.
  func resolvedTranscriptionModelConfiguration() -> (
    model: String, reasoningEffort: String?
  ) {
    let fallback = Self.transcriptionModelConfiguration()
    return (model: defaultModel ?? fallback.model, reasoningEffort: fallback.reasoningEffort)
  }

  /// Model used for one-off `generateChatStreaming` calls (dashboard chat,
  /// on-demand text). Falls back to a stable Codex default.
  var resolvedChatStreamingModel: String {
    defaultModel ?? Self.activityCardModelConfiguration().model
  }
}

extension CodexProvider {
  static func shouldUseLegacyModel(
    after error: Error,
    currentModel: String,
    fallbackModel: String
  ) -> Bool {
    currentModel != fallbackModel
      && TimelineFailureClassifier.classify(error).kind == .cliOutdated
  }

  func captureLegacyModelFallback(
    operation: String,
    fromModel: String,
    toModel: String,
    batchId: Int64?
  ) {
    var properties: [String: Any] = [
      "provider": "chat_cli",
      "provider_id": providerID.rawValue,
      "operation": operation,
      "from_model": fromModel,
      "to_model": toModel,
      "reason": TimelineFailureKind.cliOutdated.rawValue,
    ]
    if let batchId {
      properties["batch_id"] = batchId
    }
    AnalyticsService.shared.capture("llm_model_fallback", properties)
  }
}
