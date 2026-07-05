import Foundation

struct LLMProviderRouting: Codable, Equatable {
  static let currentSchemaVersion = 2

  let schemaVersion: Int
  var primary: LLMProviderID
  var secondary: LLMProviderID?

  init(
    schemaVersion: Int = currentSchemaVersion,
    primary: LLMProviderID,
    secondary: LLMProviderID? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.primary = primary
    self.secondary = secondary == primary ? nil : secondary
  }
}

enum LLMProviderRoutingStoreError: Error, Equatable {
  case corruptStoredValue
  case unsupportedSchemaVersion(Int)
  case invalidRouting
  case encodingFailed
  case writeVerificationFailed
}

enum LLMProviderRoutingStore {
  static let storageKey = "llmProviderRoutingV2"
  private static let localBaseURLKey = "llmLocalBaseURL"

  private static let lock = NSLock()

  static func load(from defaults: UserDefaults = .standard) throws -> LLMProviderRouting {
    lock.lock()
    defer { lock.unlock() }

    if defaults.object(forKey: storageKey) != nil {
      return try decodeStoredRouting(from: defaults)
    }

    let migration = try migrateLegacyArtifacts(from: defaults)
    return try saveLocked(migration.routing, to: defaults)
  }

  static func save(
    _ routing: LLMProviderRouting,
    to defaults: UserDefaults = .standard
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    if defaults.object(forKey: storageKey) == nil {
      _ = try migrateLegacyArtifacts(from: defaults)
    }
    _ = try saveLocked(routing, to: defaults)
  }

  private static func migrateLegacyArtifacts(from defaults: UserDefaults) throws
    -> LegacyLLMProviderMigration.Result
  {
    let migration = LegacyLLMProviderMigration.migrate(from: defaults)
    if !ChatCLIPromptPreferences.hasStoredOverrides(for: .codex, in: defaults) {
      try ChatCLIPromptPreferences.saveVerified(
        migration.sharedPromptOverrides,
        for: .codex,
        to: defaults
      )
    }
    if !ChatCLIPromptPreferences.hasStoredOverrides(for: .claude, in: defaults) {
      try ChatCLIPromptPreferences.saveVerified(
        migration.sharedPromptOverrides,
        for: .claude,
        to: defaults
      )
    }
    if let endpoint = migration.dayflowEndpointOverride,
      !DayflowEndpointPreferences.hasStoredValue(in: defaults)
    {
      try DayflowEndpointPreferences.saveVerified(endpoint, to: defaults)
    }
    if let endpoint = migration.localEndpointOverride,
      normalizedLocalEndpoint(in: defaults) == nil
    {
      let previousValue = defaults.object(forKey: localBaseURLKey)
      defaults.set(endpoint, forKey: localBaseURLKey)
      guard defaults.string(forKey: localBaseURLKey) == endpoint else {
        if let previousValue {
          defaults.set(previousValue, forKey: localBaseURLKey)
        } else {
          defaults.removeObject(forKey: localBaseURLKey)
        }
        throw LLMProviderRoutingStoreError.writeVerificationFailed
      }
    }
    if let completedProvider = migration.completedChatCLIProvider,
      !LLMProviderSetupPreferences.isComplete(completedProvider, in: defaults)
    {
      try LLMProviderSetupPreferences.markComplete(completedProvider, in: defaults)
    }
    return migration
  }

  private static func normalizedLocalEndpoint(in defaults: UserDefaults) -> String? {
    let value =
      defaults.string(forKey: localBaseURLKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private static func saveLocked(
    _ routing: LLMProviderRouting,
    to defaults: UserDefaults
  ) throws -> LLMProviderRouting {
    guard routing.schemaVersion == LLMProviderRouting.currentSchemaVersion else {
      throw LLMProviderRoutingStoreError.unsupportedSchemaVersion(routing.schemaVersion)
    }

    let normalized = LLMProviderRouting(
      schemaVersion: routing.schemaVersion,
      primary: routing.primary,
      secondary: routing.secondary
    )

    let encoded: Data
    do {
      encoded = try JSONEncoder().encode(normalized)
    } catch {
      throw LLMProviderRoutingStoreError.encodingFailed
    }

    let previousValue = defaults.object(forKey: storageKey)
    defaults.set(encoded, forKey: storageKey)
    do {
      let verified = try decodeStoredRouting(from: defaults)
      guard verified == normalized else {
        throw LLMProviderRoutingStoreError.writeVerificationFailed
      }
      return verified
    } catch {
      if let previousValue {
        defaults.set(previousValue, forKey: storageKey)
      } else {
        defaults.removeObject(forKey: storageKey)
      }
      throw error
    }
  }

  private static func decodeStoredRouting(from defaults: UserDefaults) throws
    -> LLMProviderRouting
  {
    guard let data = defaults.data(forKey: storageKey) else {
      throw LLMProviderRoutingStoreError.corruptStoredValue
    }

    let routing: LLMProviderRouting
    do {
      routing = try JSONDecoder().decode(LLMProviderRouting.self, from: data)
    } catch {
      throw LLMProviderRoutingStoreError.corruptStoredValue
    }

    guard routing.schemaVersion == LLMProviderRouting.currentSchemaVersion else {
      throw LLMProviderRoutingStoreError.unsupportedSchemaVersion(routing.schemaVersion)
    }
    guard routing.secondary != routing.primary else {
      throw LLMProviderRoutingStoreError.invalidRouting
    }
    return routing
  }
}
