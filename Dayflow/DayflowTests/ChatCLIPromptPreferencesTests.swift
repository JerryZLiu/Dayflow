import XCTest

@testable import Dayflow

final class ProviderPromptPreferencesTests: XCTestCase {
  private final class IgnoringUserDefaults: UserDefaults {
    var ignoredWriteKeys: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
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

  func testChatGPTAndClaudeOverridesRoundTripIndependently() throws {
    let defaults = try makeDefaults()
    let chatGPT = ActivityCardPromptOverrides(
      titleBlock: "ChatGPT title",
      summaryBlock: "ChatGPT summary",
      detailedBlock: "ChatGPT details"
    )
    let claude = ActivityCardPromptOverrides(
      titleBlock: "Claude title",
      summaryBlock: "Claude summary",
      detailedBlock: "Claude details"
    )

    CodexPromptPreferences.save(chatGPT, to: defaults)
    ClaudePromptPreferences.save(claude, to: defaults)

    XCTAssertEqual(CodexPromptPreferences.load(from: defaults), chatGPT)
    XCTAssertEqual(ClaudePromptPreferences.load(from: defaults), claude)
  }

  func testResetOnlyClearsTheSelectedProviderPrompt() throws {
    let defaults = try makeDefaults()
    let chatGPT = ActivityCardPromptOverrides(titleBlock: "ChatGPT title")
    let claude = ActivityCardPromptOverrides(titleBlock: "Claude title")
    CodexPromptPreferences.save(chatGPT, to: defaults)
    ClaudePromptPreferences.save(claude, to: defaults)

    CodexPromptPreferences.reset(in: defaults)

    XCTAssertTrue(CodexPromptPreferences.load(from: defaults).isEmpty)
    XCTAssertEqual(ClaudePromptPreferences.load(from: defaults), claude)
  }

  func testCorruptProviderPromptFallsBackToDefaultsWithoutAffectingOtherProvider() throws {
    let defaults = try makeDefaults()
    let claude = ActivityCardPromptOverrides(titleBlock: "Claude title")
    defaults.set(Data("not-json".utf8), forKey: "chatGPTPromptOverrides")
    ClaudePromptPreferences.save(claude, to: defaults)

    XCTAssertTrue(CodexPromptPreferences.load(from: defaults).isEmpty)
    XCTAssertEqual(ClaudePromptPreferences.load(from: defaults), claude)
  }

  func testPromptSectionsUseOnlyTheProvidedProviderOverrides() {
    let chatGPT = ActivityCardPromptOverrides(
      titleBlock: "ChatGPT-only title",
      summaryBlock: nil,
      detailedBlock: nil
    )
    let claude = ActivityCardPromptOverrides(
      titleBlock: nil,
      summaryBlock: "Claude-only summary",
      detailedBlock: nil
    )

    let chatGPTSections = CodexPromptSections(overrides: chatGPT)
    let claudeSections = ClaudePromptSections(overrides: claude)

    XCTAssertEqual(chatGPTSections.title, "ChatGPT-only title")
    XCTAssertEqual(chatGPTSections.summary, CodexPromptDefaults.summaryBlock)
    XCTAssertEqual(claudeSections.title, ClaudePromptDefaults.titleBlock)
    XCTAssertEqual(claudeSections.summary, "Claude-only summary")
  }

  func testWhitespaceOnlyOverrideUsesDefaultBlock() {
    let overrides = ActivityCardPromptOverrides(
      titleBlock: "  \n  ",
      summaryBlock: "Custom summary",
      detailedBlock: nil
    )

    let sections = CodexPromptSections(overrides: overrides)

    XCTAssertEqual(sections.title, CodexPromptDefaults.titleBlock)
    XCTAssertEqual(sections.summary, "Custom summary")
    XCTAssertEqual(sections.detailedSummary, CodexPromptDefaults.detailedSummaryBlock)
  }

  func testVerifiedSaveReportsAWriteThatDoesNotStick() throws {
    let defaults = try makeIgnoringDefaults()
    defaults.ignoredWriteKeys = ["chatGPTPromptOverrides"]
    let overrides = ActivityCardPromptOverrides(titleBlock: "ChatGPT title")

    XCTAssertThrowsError(
      try CodexPromptPreferences.saveVerified(overrides, to: defaults)
    ) { error in
      guard case ProviderPromptPreferencesError.writeVerificationFailed = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "ProviderPromptPreferencesTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  private func makeIgnoringDefaults() throws -> IgnoringUserDefaults {
    let suiteName = "ProviderPromptPreferencesTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(IgnoringUserDefaults(suiteName: suiteName))
  }
}
