//
//  GeminiModelPreference.swift
//  Dayflow
//

import Foundation

enum GeminiModel: String, Codable, CaseIterable {
  case pro = "gemini-3-flash-preview"
  case flash = "gemini-2.5-flash"
  case flashLite = "gemini-2.5-flash-lite"

  // Legacy raw values for migration from older app versions
  private static let legacyRawValues: [String: GeminiModel] = [
    "gemini-2.5-pro": .pro  // Users who had 2.5 Pro selected get 3 Flash
  ]

  var displayName: String {
    switch self {
    case .pro: return "Gemini 3 Flash"
    case .flash: return "Gemini 2.5 Flash"
    case .flashLite: return "Gemini Flash Lite"
    }
  }

  var shortLabel: String {
    switch self {
    case .pro: return "3 Flash"
    case .flash: return "2.5 Flash"
    case .flashLite: return "Flash Lite"
    }
  }

  // Custom decoder to handle migration from old stored values
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)

    // Try current raw values first
    if let model = GeminiModel(rawValue: rawValue) {
      self = model
      return
    }

    // Try legacy mapping for old stored values
    if let model = Self.legacyRawValues[rawValue] {
      self = model
      return
    }

    // Unknown value - throw error (will trigger default fallback in load())
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Unknown GeminiModel: \(rawValue)"
    )
  }
}

struct GeminiModelPreference: Codable {
  private static let storageKey = "geminiSelectedModel"

  let primary: GeminiModel

  static let `default` = GeminiModelPreference(primary: .pro)

  var orderedModels: [GeminiModel] {
    switch primary {
    case .pro: return [.pro, .flash, .flashLite]
    case .flash: return [.flash, .flashLite]
    case .flashLite: return [.flashLite]
    }
  }

  var fallbackSummary: String {
    switch primary {
    case .pro:
      return "Falls back to 2.5 Flash, then Flash Lite if needed"
    case .flash:
      return "Falls back to Flash Lite if 2.5 Flash is unavailable"
    case .flashLite:
      return "Always uses Flash Lite"
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
