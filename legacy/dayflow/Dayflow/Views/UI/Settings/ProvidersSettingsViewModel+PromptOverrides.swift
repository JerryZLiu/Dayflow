//
//  ProvidersSettingsViewModel+PromptOverrides.swift
//  Dayflow
//
//  Load/persist/reset for the custom prompt overrides (Gemini, Ollama,
//  ChatGPT/Claude CLI). Touches only the view model's published state.
//

import Foundation

extension ProvidersSettingsViewModel {
  func loadGeminiPromptOverridesIfNeeded(force: Bool = false) {
    if geminiPromptOverridesLoaded && !force { return }
    isUpdatingGeminiPromptState = true
    let overrides = GeminiPromptPreferences.load()

    let trimmedTitle = overrides.titleBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSummary = overrides.summaryBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDetailed = overrides.detailedBlock?.trimmingCharacters(in: .whitespacesAndNewlines)

    useCustomGeminiTitlePrompt = trimmedTitle?.isEmpty == false
    useCustomGeminiSummaryPrompt = trimmedSummary?.isEmpty == false
    useCustomGeminiDetailedPrompt = trimmedDetailed?.isEmpty == false

    geminiTitlePromptText = trimmedTitle ?? GeminiPromptDefaults.titleBlock
    geminiSummaryPromptText = trimmedSummary ?? GeminiPromptDefaults.summaryBlock
    geminiDetailedPromptText = trimmedDetailed ?? GeminiPromptDefaults.detailedSummaryBlock

    isUpdatingGeminiPromptState = false
    geminiPromptOverridesLoaded = true
  }

  func persistGeminiPromptOverridesIfReady() {
    guard geminiPromptOverridesLoaded, !isUpdatingGeminiPromptState else { return }
    persistGeminiPromptOverrides()
  }

  func persistGeminiPromptOverrides() {
    let overrides = GeminiPromptOverrides(
      titleBlock: normalizedOverride(
        text: geminiTitlePromptText, enabled: useCustomGeminiTitlePrompt),
      summaryBlock: normalizedOverride(
        text: geminiSummaryPromptText, enabled: useCustomGeminiSummaryPrompt),
      detailedBlock: normalizedOverride(
        text: geminiDetailedPromptText, enabled: useCustomGeminiDetailedPrompt)
    )

    if overrides.isEmpty {
      GeminiPromptPreferences.reset()
    } else {
      GeminiPromptPreferences.save(overrides)
    }
  }

  func resetGeminiPromptOverrides() {
    isUpdatingGeminiPromptState = true
    useCustomGeminiTitlePrompt = false
    useCustomGeminiSummaryPrompt = false
    useCustomGeminiDetailedPrompt = false
    geminiTitlePromptText = GeminiPromptDefaults.titleBlock
    geminiSummaryPromptText = GeminiPromptDefaults.summaryBlock
    geminiDetailedPromptText = GeminiPromptDefaults.detailedSummaryBlock
    GeminiPromptPreferences.reset()
    isUpdatingGeminiPromptState = false
    geminiPromptOverridesLoaded = true
  }

  func loadOllamaPromptOverridesIfNeeded(force: Bool = false) {
    if ollamaPromptOverridesLoaded && !force { return }
    isUpdatingOllamaPromptState = true
    let overrides = OllamaPromptPreferences.load()

    let trimmedSummary = overrides.summaryBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedTitle = overrides.titleBlock?.trimmingCharacters(in: .whitespacesAndNewlines)

    useCustomOllamaSummaryPrompt = trimmedSummary?.isEmpty == false
    useCustomOllamaTitlePrompt = trimmedTitle?.isEmpty == false

    ollamaSummaryPromptText = trimmedSummary ?? OllamaPromptDefaults.summaryBlock
    ollamaTitlePromptText = trimmedTitle ?? OllamaPromptDefaults.titleBlock

    isUpdatingOllamaPromptState = false
    ollamaPromptOverridesLoaded = true
  }

  func persistOllamaPromptOverridesIfReady() {
    guard ollamaPromptOverridesLoaded, !isUpdatingOllamaPromptState else { return }
    persistOllamaPromptOverrides()
  }

  func persistOllamaPromptOverrides() {
    let overrides = OllamaPromptOverrides(
      summaryBlock: normalizedOverride(
        text: ollamaSummaryPromptText, enabled: useCustomOllamaSummaryPrompt),
      titleBlock: normalizedOverride(
        text: ollamaTitlePromptText, enabled: useCustomOllamaTitlePrompt)
    )

    if overrides.isEmpty {
      OllamaPromptPreferences.reset()
    } else {
      OllamaPromptPreferences.save(overrides)
    }
  }

  func resetOllamaPromptOverrides() {
    isUpdatingOllamaPromptState = true
    useCustomOllamaSummaryPrompt = false
    useCustomOllamaTitlePrompt = false
    ollamaSummaryPromptText = OllamaPromptDefaults.summaryBlock
    ollamaTitlePromptText = OllamaPromptDefaults.titleBlock
    OllamaPromptPreferences.reset()
    isUpdatingOllamaPromptState = false
    ollamaPromptOverridesLoaded = true
  }

  func loadAgentPromptOverridesIfNeeded(force: Bool = false) {
    if agentPromptOverridesLoaded && !force { return }
    isUpdatingAgentPromptState = true
    let overrides: ActivityCardPromptOverrides
    let defaults: (titleBlock: String, summaryBlock: String, detailedSummaryBlock: String)
    switch selectedAgentPromptProvider {
    case .chatGPT:
      overrides = CodexPromptPreferences.load()
      defaults = (
        CodexPromptDefaults.titleBlock,
        CodexPromptDefaults.summaryBlock,
        CodexPromptDefaults.detailedSummaryBlock
      )
    case .claude:
      overrides = ClaudePromptPreferences.load()
      defaults = (
        ClaudePromptDefaults.titleBlock,
        ClaudePromptDefaults.summaryBlock,
        ClaudePromptDefaults.detailedSummaryBlock
      )
    case .dayflow, .gemini, .openAICompatible, .local:
      assertionFailure("Agent prompt editor only supports Codex and Claude")
      overrides = ActivityCardPromptOverrides()
      defaults = (
        CodexPromptDefaults.titleBlock,
        CodexPromptDefaults.summaryBlock,
        CodexPromptDefaults.detailedSummaryBlock
      )
    }

    let trimmedTitle = overrides.titleBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSummary = overrides.summaryBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDetailed = overrides.detailedBlock?.trimmingCharacters(in: .whitespacesAndNewlines)

    useCustomAgentTitlePrompt = trimmedTitle?.isEmpty == false
    useCustomAgentSummaryPrompt = trimmedSummary?.isEmpty == false
    useCustomAgentDetailedPrompt = trimmedDetailed?.isEmpty == false

    agentTitlePromptText = trimmedTitle ?? defaults.titleBlock
    agentSummaryPromptText = trimmedSummary ?? defaults.summaryBlock
    agentDetailedPromptText = trimmedDetailed ?? defaults.detailedSummaryBlock

    isUpdatingAgentPromptState = false
    agentPromptOverridesLoaded = true
  }

  func persistAgentPromptOverridesIfReady() {
    guard agentPromptOverridesLoaded, !isUpdatingAgentPromptState else { return }
    persistAgentPromptOverrides()
  }

  func persistAgentPromptOverrides() {
    let overrides = ActivityCardPromptOverrides(
      titleBlock: normalizedOverride(
        text: agentTitlePromptText, enabled: useCustomAgentTitlePrompt),
      summaryBlock: normalizedOverride(
        text: agentSummaryPromptText, enabled: useCustomAgentSummaryPrompt),
      detailedBlock: normalizedOverride(
        text: agentDetailedPromptText, enabled: useCustomAgentDetailedPrompt)
    )

    if overrides.isEmpty {
      switch selectedAgentPromptProvider {
      case .chatGPT:
        CodexPromptPreferences.reset()
      case .claude:
        ClaudePromptPreferences.reset()
      case .dayflow, .gemini, .openAICompatible, .local:
        assertionFailure("Agent prompt editor only supports Codex and Claude")
      }
    } else {
      switch selectedAgentPromptProvider {
      case .chatGPT:
        CodexPromptPreferences.save(overrides)
      case .claude:
        ClaudePromptPreferences.save(overrides)
      case .dayflow, .gemini, .openAICompatible, .local:
        assertionFailure("Agent prompt editor only supports Codex and Claude")
      }
    }
  }

  func resetAgentPromptOverrides() {
    isUpdatingAgentPromptState = true
    let defaults: (titleBlock: String, summaryBlock: String, detailedSummaryBlock: String)
    switch selectedAgentPromptProvider {
    case .chatGPT:
      defaults = (
        CodexPromptDefaults.titleBlock,
        CodexPromptDefaults.summaryBlock,
        CodexPromptDefaults.detailedSummaryBlock
      )
    case .claude:
      defaults = (
        ClaudePromptDefaults.titleBlock,
        ClaudePromptDefaults.summaryBlock,
        ClaudePromptDefaults.detailedSummaryBlock
      )
    case .dayflow, .gemini, .openAICompatible, .local:
      assertionFailure("Agent prompt editor only supports Codex and Claude")
      defaults = (
        CodexPromptDefaults.titleBlock,
        CodexPromptDefaults.summaryBlock,
        CodexPromptDefaults.detailedSummaryBlock
      )
    }
    useCustomAgentTitlePrompt = false
    useCustomAgentSummaryPrompt = false
    useCustomAgentDetailedPrompt = false
    agentTitlePromptText = defaults.titleBlock
    agentSummaryPromptText = defaults.summaryBlock
    agentDetailedPromptText = defaults.detailedSummaryBlock
    switch selectedAgentPromptProvider {
    case .chatGPT:
      CodexPromptPreferences.reset()
    case .claude:
      ClaudePromptPreferences.reset()
    case .dayflow, .gemini, .openAICompatible, .local:
      assertionFailure("Agent prompt editor only supports Codex and Claude")
    }
    isUpdatingAgentPromptState = false
    agentPromptOverridesLoaded = true
  }

  func normalizedOverride(text: String, enabled: Bool) -> String? {
    guard enabled else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
