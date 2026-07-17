import XCTest

@testable import Dayflow

final class LLMProviderRoutingTests: XCTestCase {
  private final class RecordingUserDefaults: UserDefaults {
    var writtenKeys: [String] = []
    var ignoredWriteKeys: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
      writtenKeys.append(defaultName)
      guard !ignoredWriteKeys.contains(defaultName) else { return }
      super.set(value, forKey: defaultName)
    }
  }

  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testMissingLegacyValuesDefaultToGeminiWithoutMutatingLegacyState() throws {
    let defaults = try makeDefaults()

    let migration = LegacyLLMProviderMigration.migrate(from: defaults)

    XCTAssertEqual(migration.routing, LLMProviderRouting(primary: .gemini))
    XCTAssertTrue(migration.sharedPromptOverrides.isEmpty)
    XCTAssertNil(migration.dayflowEndpointOverride)
    XCTAssertNil(migration.localEndpointOverride)
    XCTAssertNil(defaults.object(forKey: LegacyLLMProviderMigration.Key.providerType))
    XCTAssertNil(defaults.object(forKey: LegacyLLMProviderMigration.Key.selectedProvider))
    XCTAssertNil(defaults.object(forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool))
    XCTAssertNil(defaults.object(forKey: LegacyLLMProviderMigration.Key.backupProvider))
    XCTAssertNil(defaults.object(forKey: LegacyLLMProviderMigration.Key.backupChatCLITool))
    XCTAssertNil(defaults.object(forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides))
  }

  func testSelectedProviderExactAndLegacyIDsMapToExactProviderIDs() throws {
    let defaults = try makeDefaults()
    let mappings: [(String, LLMProviderID)] = [
      ("dayflow", .dayflow),
      ("gemini", .gemini),
      ("chatgpt", .chatGPT),
      ("claude", .claude),
      ("openai_compatible", .openAICompatible),
      ("local", .local),
      ("ollama", .local),
    ]

    for (storedValue, expectedProviderID) in mappings {
      defaults.set(
        "  \(storedValue.uppercased())  ", forKey: LegacyLLMProviderMigration.Key.selectedProvider)

      let migration = LegacyLLMProviderMigration.migrate(from: defaults)

      XCTAssertEqual(migration.routing.primary, expectedProviderID, storedValue)
    }
  }

  func testCombinedSelectedProviderUsesPreferredToolAndDefaultsToChatGPT() throws {
    let defaults = try makeDefaults()
    defaults.set("chatgpt_claude", forKey: LegacyLLMProviderMigration.Key.selectedProvider)

    XCTAssertEqual(LegacyLLMProviderMigration.migrate(from: defaults).routing.primary, .chatGPT)

    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)
    XCTAssertEqual(LegacyLLMProviderMigration.migrate(from: defaults).routing.primary, .claude)

    defaults.set("unknown", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)
    XCTAssertEqual(LegacyLLMProviderMigration.migrate(from: defaults).routing.primary, .chatGPT)
  }

  func testLegacyCombinedSetupCompletionMarksOnlyTheSelectedExactCLI() throws {
    let defaults = try makeDefaults()
    defaults.set("chatgpt_claude", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)
    defaults.set(true, forKey: LegacyLLMProviderMigration.Key.chatCLISetupComplete)

    _ = try LLMProviderRoutingStore.load(from: defaults)

    XCTAssertTrue(LLMProviderSetupPreferences.isComplete(.claude, in: defaults))
    XCTAssertFalse(LLMProviderSetupPreferences.isComplete(.chatGPT, in: defaults))
    XCTAssertTrue(defaults.bool(forKey: LegacyLLMProviderMigration.Key.chatCLISetupComplete))
  }

  func testLegacyCombinedBackupCompletionMarksTheBackupExactCLI() throws {
    let defaults = try makeDefaults()
    defaults.set("gemini", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("chatgpt_claude", forKey: LegacyLLMProviderMigration.Key.backupProvider)
    defaults.set("codex", forKey: LegacyLLMProviderMigration.Key.backupChatCLITool)
    defaults.set(true, forKey: LegacyLLMProviderMigration.Key.chatCLISetupComplete)

    _ = try LLMProviderRoutingStore.load(from: defaults)

    XCTAssertTrue(LLMProviderSetupPreferences.isComplete(.chatGPT, in: defaults))
    XCTAssertFalse(LLMProviderSetupPreferences.isComplete(.claude, in: defaults))
  }

  func testLegacyCLICompletionUsesPreferredToolWhenNoCLIIsRouted() throws {
    let defaults = try makeDefaults()
    defaults.set("gemini", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)
    defaults.set(true, forKey: LegacyLLMProviderMigration.Key.chatCLISetupComplete)

    _ = try LLMProviderRoutingStore.load(from: defaults)

    XCTAssertTrue(LLMProviderSetupPreferences.isComplete(.claude, in: defaults))
    XCTAssertFalse(LLMProviderSetupPreferences.isComplete(.chatGPT, in: defaults))
  }

  func testLegacyEnumDataTakesPrecedenceOverContradictorySelectedString() throws {
    let defaults = try makeDefaults()
    try setLegacyProviderType(.chatGPTClaude, in: defaults)
    defaults.set("gemini", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)

    let migration = LegacyLLMProviderMigration.migrate(from: defaults)

    XCTAssertEqual(migration.routing.primary, .claude)
  }

  func testLegacyEnumMapsDayflowEndpointLocalAndGemini() throws {
    let defaults = try makeDefaults()

    try setLegacyProviderType(
      .dayflowBackend(endpoint: "  https://example.com/api  "), in: defaults)
    var migration = LegacyLLMProviderMigration.migrate(from: defaults)
    XCTAssertEqual(migration.routing.primary, .dayflow)
    XCTAssertEqual(migration.dayflowEndpointOverride, "https://example.com/api")

    try setLegacyProviderType(.ollamaLocal(endpoint: "http://localhost:9999"), in: defaults)
    migration = LegacyLLMProviderMigration.migrate(from: defaults)
    XCTAssertEqual(migration.routing.primary, .local)
    XCTAssertNil(migration.dayflowEndpointOverride)
    XCTAssertEqual(migration.localEndpointOverride, "http://localhost:9999")

    try setLegacyProviderType(.geminiDirect, in: defaults)
    migration = LegacyLLMProviderMigration.migrate(from: defaults)
    XCTAssertEqual(migration.routing.primary, .gemini)
    XCTAssertNil(migration.dayflowEndpointOverride)
    XCTAssertNil(migration.localEndpointOverride)
  }

  func testFrozenLegacyEnumJSONFixturesRemainDecodable() throws {
    let defaults = try makeDefaults()
    let fixtures: [(String, LLMProviderID)] = [
      (#"{"geminiDirect":{}}"#, .gemini),
      (#"{"dayflowBackend":{"endpoint":"https://example.com"}}"#, .dayflow),
      (#"{"ollamaLocal":{"endpoint":"http://localhost:9999"}}"#, .local),
      (#"{"chatGPTClaude":{}}"#, .chatGPT),
    ]

    for (fixture, expectedProviderID) in fixtures {
      defaults.set(
        try XCTUnwrap(fixture.data(using: .utf8)),
        forKey: LegacyLLMProviderMigration.Key.providerType
      )

      XCTAssertEqual(
        LegacyLLMProviderMigration.migrate(from: defaults).routing.primary,
        expectedProviderID
      )
    }
  }

  func testCorruptLegacyEnumFallsBackToSelectedString() throws {
    let defaults = try makeDefaults()
    defaults.set(Data("not-json".utf8), forKey: LegacyLLMProviderMigration.Key.providerType)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.selectedProvider)

    let migration = LegacyLLMProviderMigration.migrate(from: defaults)

    XCTAssertEqual(migration.routing.primary, .claude)
  }

  func testCombinedBackupUsesIndependentBackupTool() throws {
    let defaults = try makeDefaults()
    defaults.set("chatgpt", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("chatgpt_claude", forKey: LegacyLLMProviderMigration.Key.backupProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.backupChatCLITool)
    defaults.set("codex", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)

    let migration = LegacyLLMProviderMigration.migrate(from: defaults)

    XCTAssertEqual(migration.routing, LLMProviderRouting(primary: .chatGPT, secondary: .claude))
  }

  func testCombinedBackupFallsBackToPreferredToolAndDropsDuplicate() throws {
    let defaults = try makeDefaults()
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("chatgpt_claude", forKey: LegacyLLMProviderMigration.Key.backupProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)

    let migration = LegacyLLMProviderMigration.migrate(from: defaults)

    XCTAssertEqual(migration.routing, LLMProviderRouting(primary: .claude))
  }

  func testExactBackupIDsMapWithoutConsultingChatTool() throws {
    let defaults = try makeDefaults()
    defaults.set("gemini", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("chatgpt", forKey: LegacyLLMProviderMigration.Key.backupProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.backupChatCLITool)

    var migration = LegacyLLMProviderMigration.migrate(from: defaults)
    XCTAssertEqual(migration.routing.secondary, .chatGPT)

    defaults.set("openai_compatible", forKey: LegacyLLMProviderMigration.Key.backupProvider)
    migration = LegacyLLMProviderMigration.migrate(from: defaults)
    XCTAssertEqual(migration.routing.secondary, .openAICompatible)

    defaults.set("ollama", forKey: LegacyLLMProviderMigration.Key.backupProvider)
    migration = LegacyLLMProviderMigration.migrate(from: defaults)
    XCTAssertEqual(migration.routing.secondary, .local)
  }

  func testOneShotMigrationCopiesArtifactsBeforeWritingRoute() throws {
    let defaults = try makeRecordingDefaults()
    try setLegacyProviderType(.dayflowBackend(endpoint: "https://example.com/api"), in: defaults)
    defaults.set("chatgpt_claude", forKey: LegacyLLMProviderMigration.Key.backupProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.backupChatCLITool)
    let sharedOverrides = ChatCLIPromptOverrides(
      titleBlock: "Legacy title",
      summaryBlock: "Legacy summary",
      detailedBlock: "Legacy details"
    )
    defaults.set(
      try JSONEncoder().encode(sharedOverrides),
      forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides
    )
    defaults.writtenKeys = []

    let routing = try LLMProviderRoutingStore.load(from: defaults)

    XCTAssertEqual(routing, LLMProviderRouting(primary: .dayflow, secondary: .claude))
    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .codex, from: defaults), sharedOverrides)
    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .claude, from: defaults), sharedOverrides)
    XCTAssertEqual(DayflowEndpointPreferences.load(from: defaults), "https://example.com/api")
    XCTAssertEqual(
      defaults.writtenKeys,
      [
        "chatGPTPromptOverrides",
        "claudePromptOverrides",
        "dayflowProviderEndpointV2",
        LLMProviderRoutingStore.storageKey,
      ]
    )
  }

  func testExplicitSaveStillMigratesLegacyArtifactsBeforeWritingRequestedRoute() throws {
    let defaults = try makeRecordingDefaults()
    let sharedOverrides = ChatCLIPromptOverrides(titleBlock: "Legacy title")
    defaults.set(
      try JSONEncoder().encode(sharedOverrides),
      forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides
    )
    defaults.writtenKeys = []

    try LLMProviderRoutingStore.save(
      LLMProviderRouting(primary: .openAICompatible, secondary: .claude),
      to: defaults
    )

    XCTAssertEqual(
      try LLMProviderRoutingStore.load(from: defaults),
      LLMProviderRouting(primary: .openAICompatible, secondary: .claude)
    )
    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .codex, from: defaults), sharedOverrides)
    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .claude, from: defaults), sharedOverrides)
    XCTAssertEqual(defaults.writtenKeys.last, LLMProviderRoutingStore.storageKey)
  }

  func testMigrationPreservesExactArtifactsAndOnlyFillsMissingDestinations() throws {
    let defaults = try makeRecordingDefaults()
    try setLegacyProviderType(
      .dayflowBackend(endpoint: "https://legacy.example/api"),
      in: defaults
    )
    let sharedOverrides = ChatCLIPromptOverrides(titleBlock: "Legacy title")
    defaults.set(
      try JSONEncoder().encode(sharedOverrides),
      forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides
    )
    let existingChatGPTOverrides = ChatCLIPromptOverrides(titleBlock: "Exact ChatGPT title")
    try ChatCLIPromptPreferences.saveVerified(
      existingChatGPTOverrides,
      for: .codex,
      to: defaults
    )
    try DayflowEndpointPreferences.saveVerified(
      "https://exact.example/api",
      to: defaults
    )
    defaults.writtenKeys = []

    let routing = try LLMProviderRoutingStore.load(from: defaults)

    XCTAssertEqual(routing, LLMProviderRouting(primary: .dayflow))
    XCTAssertEqual(
      ChatCLIPromptPreferences.load(for: .codex, from: defaults),
      existingChatGPTOverrides
    )
    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .claude, from: defaults), sharedOverrides)
    XCTAssertEqual(DayflowEndpointPreferences.load(from: defaults), "https://exact.example/api")
    XCTAssertEqual(
      defaults.writtenKeys,
      ["claudePromptOverrides", LLMProviderRoutingStore.storageKey]
    )
  }

  func testMigrationCopiesLegacyLocalEndpointWithoutOverwritingExactLocalConfig() throws {
    let migratedDefaults = try makeDefaults()
    try setLegacyProviderType(
      .ollamaLocal(endpoint: "  http://localhost:9999  "),
      in: migratedDefaults
    )

    let migratedRouting = try LLMProviderRoutingStore.load(from: migratedDefaults)

    XCTAssertEqual(migratedRouting, LLMProviderRouting(primary: .local))
    XCTAssertEqual(
      migratedDefaults.string(forKey: "llmLocalBaseURL"),
      "http://localhost:9999"
    )

    let exactDefaults = try makeDefaults()
    exactDefaults.set("https://exact-local.example/v1", forKey: "llmLocalBaseURL")
    try setLegacyProviderType(
      .ollamaLocal(endpoint: "http://localhost:9999"),
      in: exactDefaults
    )

    _ = try LLMProviderRoutingStore.load(from: exactDefaults)

    XCTAssertEqual(
      exactDefaults.string(forKey: "llmLocalBaseURL"),
      "https://exact-local.example/v1"
    )

    let blankDefaults = try makeDefaults()
    blankDefaults.set("  \n ", forKey: "llmLocalBaseURL")
    try setLegacyProviderType(
      .ollamaLocal(endpoint: "http://localhost:9999"),
      in: blankDefaults
    )

    _ = try LLMProviderRoutingStore.load(from: blankDefaults)

    XCTAssertEqual(blankDefaults.string(forKey: "llmLocalBaseURL"), "http://localhost:9999")
  }

  func testPromptWriteFailureLeavesRouteAbsent() throws {
    let defaults = try makeRecordingDefaults()
    let sharedOverrides = ChatCLIPromptOverrides(titleBlock: "Legacy title")
    defaults.set(
      try JSONEncoder().encode(sharedOverrides),
      forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides
    )
    defaults.ignoredWriteKeys = ["claudePromptOverrides"]

    XCTAssertThrowsError(try LLMProviderRoutingStore.load(from: defaults))
    XCTAssertNil(defaults.object(forKey: LLMProviderRoutingStore.storageKey))
    XCTAssertNil(defaults.object(forKey: "claudePromptOverrides"))
  }

  func testEndpointWriteFailureLeavesRouteAbsent() throws {
    let defaults = try makeRecordingDefaults()
    try setLegacyProviderType(.dayflowBackend(endpoint: "https://example.com/api"), in: defaults)
    defaults.ignoredWriteKeys = ["dayflowProviderEndpointV2"]

    XCTAssertThrowsError(try LLMProviderRoutingStore.load(from: defaults))
    XCTAssertNil(defaults.object(forKey: LLMProviderRoutingStore.storageKey))
    XCTAssertNil(defaults.object(forKey: "dayflowProviderEndpointV2"))
  }

  func testLocalEndpointWriteFailureLeavesRouteAbsent() throws {
    let defaults = try makeRecordingDefaults()
    try setLegacyProviderType(.ollamaLocal(endpoint: "http://localhost:9999"), in: defaults)
    defaults.ignoredWriteKeys = ["llmLocalBaseURL"]

    XCTAssertThrowsError(try LLMProviderRoutingStore.load(from: defaults))
    XCTAssertNil(defaults.object(forKey: LLMProviderRoutingStore.storageKey))
    XCTAssertNil(defaults.object(forKey: "llmLocalBaseURL"))
  }

  func testRoutingWriteFailureLeavesV2AbsentForSafeRetry() throws {
    let defaults = try makeRecordingDefaults()
    defaults.ignoredWriteKeys = [LLMProviderRoutingStore.storageKey]

    XCTAssertThrowsError(try LLMProviderRoutingStore.load(from: defaults))
    XCTAssertNil(defaults.object(forKey: LLMProviderRoutingStore.storageKey))
  }

  func testSetupMarkerWriteFailureLeavesMarkerAndRouteAbsent() throws {
    let defaults = try makeRecordingDefaults()
    defaults.set("chatgpt_claude", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)
    defaults.set(true, forKey: LegacyLLMProviderMigration.Key.chatCLISetupComplete)
    defaults.ignoredWriteKeys = ["claudeSetupComplete"]

    XCTAssertThrowsError(try LLMProviderRoutingStore.load(from: defaults))
    XCTAssertNil(defaults.object(forKey: "claudeSetupComplete"))
    XCTAssertNil(defaults.object(forKey: LLMProviderRoutingStore.storageKey))
  }

  func testCorruptV2ThrowsWithoutReimportingLegacyArtifacts() throws {
    let defaults = try makeDefaults()
    let corruptRouting = Data("corrupt-v2".utf8)
    defaults.set(corruptRouting, forKey: LLMProviderRoutingStore.storageKey)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    let sharedOverrides = ChatCLIPromptOverrides(titleBlock: "Should not import")
    defaults.set(
      try JSONEncoder().encode(sharedOverrides),
      forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides
    )

    XCTAssertThrowsError(try LLMProviderRoutingStore.load(from: defaults)) { error in
      XCTAssertEqual(error as? LLMProviderRoutingStoreError, .corruptStoredValue)
    }
    XCTAssertEqual(defaults.data(forKey: LLMProviderRoutingStore.storageKey), corruptRouting)
    XCTAssertTrue(ChatCLIPromptPreferences.load(for: .codex, from: defaults).isEmpty)
    XCTAssertTrue(ChatCLIPromptPreferences.load(for: .claude, from: defaults).isEmpty)
    XCTAssertNil(DayflowEndpointPreferences.load(from: defaults))
  }

  func testExistingV2IsAuthoritativeAndNeverReimportsLegacyValues() throws {
    let defaults = try makeDefaults()
    let existing = LLMProviderRouting(primary: .openAICompatible, secondary: .local)
    try LLMProviderRoutingStore.save(existing, to: defaults)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set(
      try JSONEncoder().encode(ChatCLIPromptOverrides(titleBlock: "Should not import")),
      forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides
    )

    let loaded = try LLMProviderRoutingStore.load(from: defaults)

    XCTAssertEqual(loaded, existing)
    XCTAssertTrue(ChatCLIPromptPreferences.load(for: .codex, from: defaults).isEmpty)
    XCTAssertTrue(ChatCLIPromptPreferences.load(for: .claude, from: defaults).isEmpty)
  }

  func testMigrationLeavesEveryLegacyValueByteForByteUnchanged() throws {
    let defaults = try makeDefaults()
    let providerData = try JSONEncoder().encode(
      LegacyLLMProviderMigration.ProviderType.chatGPTClaude)
    let promptData = try JSONEncoder().encode(
      ChatCLIPromptOverrides(
        titleBlock: "Legacy title",
        summaryBlock: "Legacy summary",
        detailedBlock: "Legacy details"
      )
    )
    defaults.set(providerData, forKey: LegacyLLMProviderMigration.Key.providerType)
    defaults.set("gemini", forKey: LegacyLLMProviderMigration.Key.selectedProvider)
    defaults.set("claude", forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool)
    defaults.set("chatgpt_claude", forKey: LegacyLLMProviderMigration.Key.backupProvider)
    defaults.set("codex", forKey: LegacyLLMProviderMigration.Key.backupChatCLITool)
    defaults.set(promptData, forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides)
    defaults.set(true, forKey: "chatgpt_claudeSetupComplete")

    _ = try LLMProviderRoutingStore.load(from: defaults)

    XCTAssertEqual(defaults.data(forKey: LegacyLLMProviderMigration.Key.providerType), providerData)
    XCTAssertEqual(
      defaults.string(forKey: LegacyLLMProviderMigration.Key.selectedProvider), "gemini")
    XCTAssertEqual(
      defaults.string(forKey: LegacyLLMProviderMigration.Key.preferredChatCLITool), "claude")
    XCTAssertEqual(
      defaults.string(forKey: LegacyLLMProviderMigration.Key.backupProvider), "chatgpt_claude")
    XCTAssertEqual(
      defaults.string(forKey: LegacyLLMProviderMigration.Key.backupChatCLITool), "codex")
    XCTAssertEqual(
      defaults.data(forKey: LegacyLLMProviderMigration.Key.sharedPromptOverrides), promptData)
    XCTAssertTrue(defaults.bool(forKey: "chatgpt_claudeSetupComplete"))
  }

  func testSaveNormalizesDuplicateSecondaryAndRejectsCorruptStoredRoute() throws {
    let defaults = try makeDefaults()
    try LLMProviderRoutingStore.save(
      LLMProviderRouting(primary: .chatGPT, secondary: .chatGPT),
      to: defaults
    )
    XCTAssertEqual(
      try LLMProviderRoutingStore.load(from: defaults), LLMProviderRouting(primary: .chatGPT))

    defaults.set(Data("not-json".utf8), forKey: LLMProviderRoutingStore.storageKey)
    XCTAssertThrowsError(try LLMProviderRoutingStore.load(from: defaults)) { error in
      XCTAssertEqual(error as? LLMProviderRoutingStoreError, .corruptStoredValue)
    }
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "LLMProviderRoutingTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  private func makeRecordingDefaults() throws -> RecordingUserDefaults {
    let suiteName = "LLMProviderRoutingTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(RecordingUserDefaults(suiteName: suiteName))
  }

  private func setLegacyProviderType(
    _ providerType: LegacyLLMProviderMigration.ProviderType,
    in defaults: UserDefaults
  ) throws {
    defaults.set(
      try JSONEncoder().encode(providerType),
      forKey: LegacyLLMProviderMigration.Key.providerType
    )
  }
}

final class TimelineProviderStartupSelectionTests: XCTestCase {
  private enum StartupError: Error {
    case unavailable
  }

  func testHealthyPrimaryKeepsConfiguredBackupAvailable() throws {
    let selection = try selectTimelineProviderStartup(
      primary: Result<String, Error>.success("gemini"),
      backup: "claude"
    )

    XCTAssertEqual(selection.baselineContext, "gemini")
    XCTAssertEqual(selection.activeContext, "gemini")
    XCTAssertEqual(selection.fallbackContext, "claude")
    XCTAssertFalse(selection.usedProviderBackup)
    XCTAssertNil(selection.primaryInitializationError)
  }

  func testPrimaryInitializationFailurePinsBatchToBackup() throws {
    let selection = try selectTimelineProviderStartup(
      primary: Result<String, Error>.failure(StartupError.unavailable),
      backup: "claude"
    )

    XCTAssertEqual(selection.baselineContext, "claude")
    XCTAssertEqual(selection.activeContext, "claude")
    XCTAssertNil(selection.fallbackContext)
    XCTAssertTrue(selection.usedProviderBackup)
    XCTAssertNotNil(selection.primaryInitializationError)
  }

  func testPrimaryInitializationFailureWithoutBackupThrowsOriginalError() {
    XCTAssertThrowsError(
      try selectTimelineProviderStartup(
        primary: Result<String, Error>.failure(StartupError.unavailable),
        backup: nil
      )
    ) { error in
      XCTAssertTrue(error is StartupError)
    }
  }
}
