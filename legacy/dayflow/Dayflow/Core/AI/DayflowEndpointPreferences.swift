import Foundation

enum DayflowEndpointPreferencesError: Error {
  case writeVerificationFailed
}

enum DayflowEndpointPreferences {
  private static let storageKey = "dayflowProviderEndpointV2"

  static func hasStoredValue(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: storageKey) != nil
  }

  static func load(from defaults: UserDefaults = .standard) -> String? {
    normalized(defaults.string(forKey: storageKey))
  }

  static func save(_ endpoint: String?, to defaults: UserDefaults = .standard) {
    try? saveVerified(endpoint, to: defaults)
  }

  static func saveVerified(_ endpoint: String?, to defaults: UserDefaults) throws {
    let previousValue = defaults.object(forKey: storageKey)
    let value = normalized(endpoint)
    if let value {
      defaults.set(value, forKey: storageKey)
    } else {
      defaults.removeObject(forKey: storageKey)
    }

    guard load(from: defaults) == value else {
      if let previousValue {
        defaults.set(previousValue, forKey: storageKey)
      } else {
        defaults.removeObject(forKey: storageKey)
      }
      throw DayflowEndpointPreferencesError.writeVerificationFailed
    }
  }

  private static func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}
