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

  func loadChatCLIPromptOverridesIfNeeded(force: Bool = false) {
    if chatCLIPromptOverridesLoaded && !force { return }
    isUpdatingChatCLIPromptState = true
    let overrides = ChatCLIPromptPreferences.load()

    let trimmedTitle = overrides.titleBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSummary = overrides.summaryBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDetailed = overrides.detailedBlock?.trimmingCharacters(in: .whitespacesAndNewlines)

    useCustomChatCLITitlePrompt = trimmedTitle?.isEmpty == false
    useCustomChatCLISummaryPrompt = trimmedSummary?.isEmpty == false
    useCustomChatCLIDetailedPrompt = trimmedDetailed?.isEmpty == false

    chatCLITitlePromptText = trimmedTitle ?? ChatCLIPromptDefaults.titleBlock
    chatCLISummaryPromptText = trimmedSummary ?? ChatCLIPromptDefaults.summaryBlock
    chatCLIDetailedPromptText = trimmedDetailed ?? ChatCLIPromptDefaults.detailedSummaryBlock

    isUpdatingChatCLIPromptState = false
    chatCLIPromptOverridesLoaded = true
  }

  func persistChatCLIPromptOverridesIfReady() {
    guard chatCLIPromptOverridesLoaded, !isUpdatingChatCLIPromptState else { return }
    persistChatCLIPromptOverrides()
  }

  func persistChatCLIPromptOverrides() {
    let overrides = ChatCLIPromptOverrides(
      titleBlock: normalizedOverride(
        text: chatCLITitlePromptText, enabled: useCustomChatCLITitlePrompt),
      summaryBlock: normalizedOverride(
        text: chatCLISummaryPromptText, enabled: useCustomChatCLISummaryPrompt),
      detailedBlock: normalizedOverride(
        text: chatCLIDetailedPromptText, enabled: useCustomChatCLIDetailedPrompt)
    )

    if overrides.isEmpty {
      ChatCLIPromptPreferences.reset()
    } else {
      ChatCLIPromptPreferences.save(overrides)
    }
  }

  func resetChatCLIPromptOverrides() {
    isUpdatingChatCLIPromptState = true
    useCustomChatCLITitlePrompt = false
    useCustomChatCLISummaryPrompt = false
    useCustomChatCLIDetailedPrompt = false
    chatCLITitlePromptText = ChatCLIPromptDefaults.titleBlock
    chatCLISummaryPromptText = ChatCLIPromptDefaults.summaryBlock
    chatCLIDetailedPromptText = ChatCLIPromptDefaults.detailedSummaryBlock
    ChatCLIPromptPreferences.reset()
    isUpdatingChatCLIPromptState = false
    chatCLIPromptOverridesLoaded = true
  }

  func normalizedOverride(text: String, enabled: Bool) -> String? {
    guard enabled else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
