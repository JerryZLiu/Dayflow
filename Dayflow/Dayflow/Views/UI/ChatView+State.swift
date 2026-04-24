import AppKit
import Charts
import SwiftUI

extension ChatView {
  var selectedProvider: DashboardChatProvider {
    DashboardChatProvider.fromStoredValue(selectedProviderRaw)
  }

  var isUnlocked: Bool {
    hasBetaAccepted
  }

  var anyRuntimeAvailable: Bool {
    geminiConfigured || codexDetected || claudeDetected
  }

  var selectedProviderAvailable: Bool {
    isProviderAvailable(selectedProvider)
  }

  var welcomePrompts: [WelcomePrompt] {
    [
      WelcomePrompt(icon: "doc.text", text: "Generate standup notes for yesterday"),
      WelcomePrompt(icon: "checkmark.seal", text: "What did I get done last week?"),
      WelcomePrompt(
        icon: "exclamationmark.bubble", text: "When was I most focused this week"),
      WelcomePrompt(
        icon: "sparkles", text: "Compare this week to last week"),
    ]
  }

  var welcomeHeroAnimation: Animation {
    if reduceMotion {
      return .easeOut(duration: 0.01)
    }
    return .timingCurve(0.16, 1, 0.3, 1, duration: 0.42)
  }

  var feedbackStateAnimation: Animation {
    if reduceMotion {
      return .easeOut(duration: 0.01)
    }
    return .easeOut(duration: 0.18)
  }

  var feedbackModalAnimation: Animation {
    if reduceMotion {
      return .easeOut(duration: 0.01)
    }
    return .spring(response: 0.28, dampingFraction: 0.88)
  }

  func welcomeSuggestionAnimation(at index: Int) -> Animation {
    if reduceMotion {
      return .easeOut(duration: 0.01)
    }
    return .timingCurve(0.16, 1, 0.3, 1, duration: 0.34)
      .delay(Double(index) * 0.045)
  }

  var trimmedInputText: String {
    inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var canSubmitCurrentInput: Bool {
    !chatService.isProcessing && !trimmedInputText.isEmpty && selectedProviderAvailable
  }

  var composerBorderColor: Color {
    if isInputFocused {
      return Color(hex: "F4A867")
    }
    return Color(hex: "E5D8CA")
  }

  var memoryCharacterCount: Int {
    memoryDraft.count
  }

  var isMemoryDirty: Bool {
    memoryDraft != storedMemoryBlob
  }

  var memoryUpdatedLabel: String {
    guard let memoryUpdatedAt else { return "Not saved yet" }
    return chatViewMemoryUpdatedFormatter.string(from: memoryUpdatedAt)
  }
}
