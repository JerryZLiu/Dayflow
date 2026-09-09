import Foundation

final class CodexProvider: AgentCLISupporting {
  let providerID: LLMProviderID = .chatGPT
  var cliTool: ChatCLITool { .codex }
  let runner = ChatCLIProcessRunner()
  let config = ChatCLIConfigManager.shared

  init() {
    config.ensureWorkingDirectory()
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
