//
//  GeminiModelPreference.swift
//  Dayflow
//

import Foundation

enum GeminiModel: String, Codable, CaseIterable {
  case hydrogen = "gemini-4-hydrogen"
  case flash38 = "gemini-3.8-flash"
  case flash37 = "gemini-3.7-flash"
  case flash36 = "gemini-3.6-flash"
  case flash35 = "gemini-3.5-flash"
  case flashLite35 = "gemini-3.5-flash-lite"

  var displayName: String {
    switch self {
    case .hydrogen: return String(localized: "Gemini 4 Hydrogen")
    case .flash38: return String(localized: "Gemini 3.8 Flash")
    case .flash37: return String(localized: "Gemini 3.7 Flash")
    case .flash36: return String(localized: "Gemini 3.6 Flash")
    case .flash35: return String(localized: "Gemini 3.5 Flash")
    case .flashLite35: return String(localized: "Gemini 3.5 Flash-Lite")
    }
  }

  var shortLabel: String {
    switch self {
    case .hydrogen: return String(localized: "4 Hydrogen")
    case .flash38: return String(localized: "3.8 Flash")
    case .flash37: return String(localized: "3.7 Flash")
    case .flash36: return String(localized: "3.6 Flash")
    case .flash35: return String(localized: "3.5 Flash")
    case .flashLite35: return String(localized: "3.5 Flash-Lite")
    }
  }

  /// Whether the model reads a batch's video and writes its cards in one call. Older models
  /// keep the transcribe-then-generate path.
  var supportsOneStepTimeline: Bool {
    self == .hydrogen
  }
}

struct GeminiModelPreference: Codable {
  // v6 resets everyone onto 4 Hydrogen, which writes cards in one step. Earlier keys kept
  // users pinned on Flash models that only run the two-step pipeline.
  private static let storageKey = "geminiSelectedModel_v6"
  private static let legacyStorageKeys = ["geminiSelectedModel_v5", "geminiSelectedModel_v4"]

  let primary: GeminiModel

  static let `default` = GeminiModelPreference(primary: .hydrogen)

  var orderedModels: [GeminiModel] {
    switch primary {
    case .hydrogen: return [.hydrogen, .flash38, .flash37, .flash36, .flash35, .flashLite35]
    case .flash38: return [.flash38, .flash37, .flash36, .flash35, .flashLite35]
    case .flash37: return [.flash37, .flash36, .flash35, .flashLite35]
    case .flash36: return [.flash36, .flash35, .flashLite35]
    case .flash35: return [.flash35, .flashLite35]
    case .flashLite35: return [.flashLite35]
    }
  }

  var fallbackSummary: String {
    switch primary {
    case .hydrogen:
      return
        "Falls back to 3.8 Flash, then 3.7 Flash, then 3.6 Flash, then 3.5 Flash, then 3.5 Flash-Lite if needed"
    case .flash38:
      return
        "Falls back to 3.7 Flash, then 3.6 Flash, then 3.5 Flash, then 3.5 Flash-Lite if needed"
    case .flash37:
      return "Falls back to 3.6 Flash, then 3.5 Flash, then 3.5 Flash-Lite if needed"
    case .flash36:
      return "Falls back to 3.5 Flash, then 3.5 Flash-Lite if needed"
    case .flash35:
      return "Falls back to 3.5 Flash-Lite if needed"
    case .flashLite35:
      return "Always uses 3.5 Flash-Lite"
    }
  }

  static func load(from defaults: UserDefaults = .standard) -> GeminiModelPreference {
    if let data = defaults.data(forKey: storageKey),
      let preference = try? JSONDecoder().decode(GeminiModelPreference.self, from: data)
    {
      return preference
    }

    let preference = GeminiModelPreference.default
    preference.save(to: defaults)
    for key in legacyStorageKeys {
      defaults.removeObject(forKey: key)
    }
    return preference
  }

  func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }
}
