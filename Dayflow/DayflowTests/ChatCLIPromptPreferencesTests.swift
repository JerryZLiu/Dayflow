import XCTest

@testable import Dayflow

final class ChatCLIPromptPreferencesTests: XCTestCase {
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
    let chatGPT = ChatCLIPromptOverrides(
      titleBlock: "ChatGPT title",
      summaryBlock: "ChatGPT summary",
      detailedBlock: "ChatGPT details"
    )
    let claude = ChatCLIPromptOverrides(
      titleBlock: "Claude title",
      summaryBlock: "Claude summary",
      detailedBlock: "Claude details"
    )

    ChatCLIPromptPreferences.save(chatGPT, for: .codex, to: defaults)
    ChatCLIPromptPreferences.save(claude, for: .claude, to: defaults)

    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .codex, from: defaults), chatGPT)
    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .claude, from: defaults), claude)
  }

  func testResetOnlyClearsTheSelectedProviderPrompt() throws {
    let defaults = try makeDefaults()
    let chatGPT = ChatCLIPromptOverrides(titleBlock: "ChatGPT title")
    let claude = ChatCLIPromptOverrides(titleBlock: "Claude title")
    ChatCLIPromptPreferences.save(chatGPT, for: .codex, to: defaults)
    ChatCLIPromptPreferences.save(claude, for: .claude, to: defaults)

    ChatCLIPromptPreferences.reset(for: .codex, in: defaults)

    XCTAssertTrue(ChatCLIPromptPreferences.load(for: .codex, from: defaults).isEmpty)
    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .claude, from: defaults), claude)
  }

  func testCorruptProviderPromptFallsBackToDefaultsWithoutAffectingOtherProvider() throws {
    let defaults = try makeDefaults()
    let claude = ChatCLIPromptOverrides(titleBlock: "Claude title")
    defaults.set(Data("not-json".utf8), forKey: "chatGPTPromptOverrides")
    ChatCLIPromptPreferences.save(claude, for: .claude, to: defaults)

    XCTAssertTrue(ChatCLIPromptPreferences.load(for: .codex, from: defaults).isEmpty)
    XCTAssertEqual(ChatCLIPromptPreferences.load(for: .claude, from: defaults), claude)
  }

  func testPromptSectionsUseOnlyTheProvidedProviderOverrides() {
    let chatGPT = ChatCLIPromptOverrides(
      titleBlock: "ChatGPT-only title",
      summaryBlock: nil,
      detailedBlock: nil
    )
    let claude = ChatCLIPromptOverrides(
      titleBlock: nil,
      summaryBlock: "Claude-only summary",
      detailedBlock: nil
    )

    let chatGPTSections = ChatCLIPromptSections(overrides: chatGPT)
    let claudeSections = ChatCLIPromptSections(overrides: claude)

    XCTAssertEqual(chatGPTSections.title, "ChatGPT-only title")
    XCTAssertEqual(chatGPTSections.summary, ChatCLIPromptDefaults.summaryBlock)
    XCTAssertEqual(claudeSections.title, ChatCLIPromptDefaults.titleBlock)
    XCTAssertEqual(claudeSections.summary, "Claude-only summary")
  }

  func testWhitespaceOnlyOverrideUsesDefaultBlock() {
    let overrides = ChatCLIPromptOverrides(
      titleBlock: "  \n  ",
      summaryBlock: "Custom summary",
      detailedBlock: nil
    )

    let sections = ChatCLIPromptSections(overrides: overrides)

    XCTAssertEqual(sections.title, ChatCLIPromptDefaults.titleBlock)
    XCTAssertEqual(sections.summary, "Custom summary")
    XCTAssertEqual(sections.detailedSummary, ChatCLIPromptDefaults.detailedSummaryBlock)
  }

  func testVerifiedSaveReportsAWriteThatDoesNotStick() throws {
    let defaults = try makeIgnoringDefaults()
    defaults.ignoredWriteKeys = ["chatGPTPromptOverrides"]
    let overrides = ChatCLIPromptOverrides(titleBlock: "ChatGPT title")

    XCTAssertThrowsError(
      try ChatCLIPromptPreferences.saveVerified(overrides, for: .codex, to: defaults)
    ) { error in
      guard case ChatCLIPromptPreferencesError.writeVerificationFailed = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "ChatCLIPromptPreferencesTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  private func makeIgnoringDefaults() throws -> IgnoringUserDefaults {
    let suiteName = "ChatCLIPromptPreferencesTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(IgnoringUserDefaults(suiteName: suiteName))
  }
}
