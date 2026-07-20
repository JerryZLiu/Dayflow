//
//  ClaudeModelPreference.swift
//  Dayflow
//
//  Persists the user's choice of Claude model. Mirrors
//  `GeminiModelPreference` so the Settings → Providers tab can show a
//  picker with the same UX as the Gemini one.
//
//  The `rawValue` is the alias the Claude CLI accepts (e.g. `sonnet`),
//  while `displayName` is the user-facing label that includes the
//  resolved full model name (e.g. "Claude Sonnet 5"). The catalog
//  (`ChatCLIModelCatalog`) is what populates `displayName` — at minimum
//  we know the alias resolves to a real model on the user's account,
//  because we probed the CLI to build the list in the first place.
//
//  The stored preference is the *alias* (not the full name) because
//  that's what the CLI's `--model` flag actually accepts and because
//  aliases track the user's account to the latest release of that
//  model family (e.g. `sonnet` will follow Sonnet 5 → Sonnet 5.5
//  without us having to bump a stored version).

import Foundation

enum ClaudeModel: String, Codable, CaseIterable {
  // Aliases the Claude CLI accepts as `--model` values. Each one
  // resolves to the latest model in that family on the user's account.
  // The list is the same set the CLI probe iterates over
  // (`ChatCLIModelCatalog.knownClaudeAliases`); keeping them in sync
  // matters because `ClaudeModel(rawValue:)` is how we read a probed
  // result back into the picker.
  case sonnet
  case opus
  case fable
  case haiku

  /// User-facing label for the picker. The `displayName` baked in
  /// here is a *baseline* — the Settings UI prefers the live
  /// `displayName` returned by `ChatCLIModelCatalog` so the user
  /// always sees the resolved full model name (e.g. "Claude Sonnet 5")
  /// rather than a hard-coded string.
  var displayName: String {
    switch self {
    case .sonnet: return "Claude Sonnet"
    case .opus: return "Claude Opus"
    case .fable: return "Claude Fable"
    case .haiku: return "Claude Haiku"
    }
  }

  /// One-line hint shown under the picker — keeps users oriented
  /// between quality/speed tradeoffs without overwhelming the UI.
  var hint: String {
    switch self {
    case .sonnet: return "Balanced — best default for most users"
    case .opus: return "Highest quality, slower and pricier"
    case .fable: return "Experimental — newest reasoning family"
    case .haiku: return "Fastest — lower quality summaries"
    }
  }
}

struct ClaudeModelPreference: Codable {
  // Key bump intentionally hard-resets existing users to the new
  // ordering, matching the `GeminiModelPreference` convention.
  private static let storageKey = "claudeSelectedModel_v1"

  let primary: ClaudeModel

  static let `default` = ClaudeModelPreference(primary: .sonnet)

  static func load(from defaults: UserDefaults = .standard) -> ClaudeModelPreference {
    if let data = defaults.data(forKey: storageKey),
      let preference = try? JSONDecoder().decode(ClaudeModelPreference.self, from: data)
    {
      return preference
    }

    let preference = ClaudeModelPreference.default
    preference.save(to: defaults)
    return preference
  }

  func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }
}
