//
//  CodexModelPreference.swift
//  Dayflow
//
//  Persists the user's choice of Codex (ChatGPT) model. Mirrors
//  `ClaudeModelPreference` so the Settings → Providers tab can show a
//  picker with the same UX as the Gemini/Claude one.
//
//  The `rawValue` is the model id the Codex CLI accepts as `--model`.
//  The list is small and stable — OpenAI's flagship + a small/fast
//  variant — and is what the CLI probe iterates over
//  (`ChatCLIModelCatalog.knownCodexAliases`).

import Foundation

enum CodexModel: String, Codable, CaseIterable {
  // Two distinct "5.6" variants existed in the legacy code (one for
  // transcription, one for card generation). We expose them as
  // separate picker rows so users who care about the difference can
  // choose, but the default is the variant that was previously the
  // hard-coded card-generation choice.
  case gpt56Luna = "gpt-5.6-luna"
  case gpt56Sol = "gpt-5.6-sol"
  case gpt54 = "gpt-5.4"
  case gpt54Mini = "gpt-5.4-mini"

  var displayName: String {
    switch self {
    case .gpt56Luna: return "GPT 5.6 (luna)"
    case .gpt56Sol: return "GPT 5.6 (sol)"
    case .gpt54: return "GPT 5.4"
    case .gpt54Mini: return "GPT 5.4 mini"
    }
  }

  var hint: String {
    switch self {
    case .gpt56Luna: return "Latest — tuned for transcription"
    case .gpt56Sol: return "Latest — tuned for card generation"
    case .gpt54: return "Previous generation — solid default"
    case .gpt54Mini: return "Fast and cheap — lighter summaries"
    }
  }
}

struct CodexModelPreference: Codable {
  private static let storageKey = "codexSelectedModel_v1"

  let primary: CodexModel

  static let `default` = CodexModelPreference(primary: .gpt56Luna)

  static func load(from defaults: UserDefaults = .standard) -> CodexModelPreference {
    if let data = defaults.data(forKey: storageKey),
      let preference = try? JSONDecoder().decode(CodexModelPreference.self, from: data)
    {
      return preference
    }

    let preference = CodexModelPreference.default
    preference.save(to: defaults)
    return preference
  }

  func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }
}
