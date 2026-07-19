//
//  MiniMaxModelPreference.swift
//  Dayflow
//
//  Persisted preference for the active MiniMax model. Mirrors the shape of
//  `GeminiModelPreference` so the settings UI can drop the same component in.
//

import Foundation

struct MiniMaxModelPreference: Codable, Equatable {
  /// Wire-format model id sent in chat completion requests.
  var modelId: String

  /// Whether the user has selected a non-default model.
  var hasUserOverride: Bool

  static let `default` = MiniMaxModelPreference(
    modelId: MiniMaxProvider.defaultModelId,
    hasUserOverride: false
  )

  static let storageKey = "minimaxModelPreference"

  static func load(from defaults: UserDefaults = .standard) -> MiniMaxModelPreference {
    guard let data = defaults.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode(MiniMaxModelPreference.self, from: data)
    else {
      return .default
    }
    return decoded
  }

  func persist(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }

  mutating func setModelId(_ newValue: String) {
    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    self.modelId = trimmed
    self.hasUserOverride = (trimmed != MiniMaxProvider.defaultModelId)
  }

  mutating func reset() {
    self = .default
  }
}
