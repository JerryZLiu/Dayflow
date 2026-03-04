//
//  GeminiModelPreference.swift
//  Dayflow
//

import Foundation

enum GeminiModel: String, Codable, CaseIterable {
  case flashLite31Preview = "gemini-3.1-flash-lite-preview"
  case flash3Preview = "gemini-3-flash-preview"
  case flash25 = "gemini-2.5-flash"

  var displayName: String {
    switch self {
    case .flashLite31Preview: return "Gemini 3.1 Flash-Lite Preview"
    case .flash3Preview: return "Gemini 3 Flash"
    case .flash25: return "Gemini 2.5 Flash"
    }
  }

  var shortLabel: String {
    switch self {
    case .flashLite31Preview: return "3.1 Flash-Lite"
    case .flash3Preview: return "3 Flash"
    case .flash25: return "2.5 Flash"
    }
  }
}

struct GeminiModelPreference: Codable {
  // Key bump intentionally hard-resets existing users to the new ordering.
  private static let storageKey = "geminiSelectedModel_v2"

  let primary: GeminiModel

  static let `default` = GeminiModelPreference(primary: .flashLite31Preview)

  var orderedModels: [GeminiModel] {
    switch primary {
    case .flashLite31Preview: return [.flashLite31Preview, .flash3Preview, .flash25]
    case .flash3Preview: return [.flash3Preview, .flash25]
    case .flash25: return [.flash25]
    }
  }

  var fallbackSummary: String {
    switch primary {
    case .flashLite31Preview:
      return "Falls back to 3 Flash, then 2.5 Flash if needed"
    case .flash3Preview:
      return "Falls back to 2.5 Flash if 3 Flash is unavailable"
    case .flash25:
      return "Always uses 2.5 Flash"
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
    return preference
  }

  func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }
}
