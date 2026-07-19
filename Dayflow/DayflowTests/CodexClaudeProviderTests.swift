import XCTest

@testable import Dayflow

final class CodexClaudeProviderTests: XCTestCase {
  private let runner = ChatCLIProcessRunner()
  private let claudeProvider = ClaudeProvider()

  func testClaudeStreamingCommandIncludesExplicitEffort() {
    let parts = runner.buildClaudeStreamingCommandParts(
      prompt: "Generate cards",
      model: "sonnet",
      reasoningEffort: "medium",
      sessionId: nil
    )

    XCTAssertEqual(
      Array(parts.prefix(10)),
      [
        "claude", "-p", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--model", "sonnet", "--effort", "medium",
      ]
    )
  }

  func testClaudeStreamingResumeKeepsExplicitEffort() {
    let parts = runner.buildClaudeStreamingCommandParts(
      prompt: "Fix the cards",
      model: "sonnet",
      reasoningEffort: "medium",
      sessionId: "session-123"
    )

    XCTAssertEqual(
      Array(parts.prefix(12)),
      [
        "claude", "-p", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--resume", "session-123", "--model", "sonnet",
        "--effort", "medium",
      ]
    )
  }

  func testClaudeActivityCardsUseSonnetAliasAtLowEffort() {
    let configuration = ClaudeProvider.activityCardModelConfiguration()

    // Default for the Claude picker is the `sonnet` alias (which the
    // Claude CLI resolves to the current Sonnet release on the
    // user's account). The previous hard-coded value was
    // `claude-sonnet`, which the CLI rejects with "It may not
    // exist or you may not have access to it" — see the comment
    // on `ClaudeProvider.activityCardModelConfiguration`.
    XCTAssertEqual(configuration.model, "sonnet")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }

  func testChatGPTActivityCardsUseUserPickedModelAtLowEffort() {
    let configuration = CodexProvider.activityCardModelConfiguration()

    // The picker drives both `transcriptionModelConfiguration` and
    // `activityCardModelConfiguration` — they read the same
    // `CodexModelPreference`. The default is `gpt-5.6-luna` (the
    // transcription-tuned variant). The previous hard-coded value
    // was `gpt-5.6-sol`; that alias is still selectable from the
    // picker, just no longer the default.
    XCTAssertEqual(configuration.model, "gpt-5.6-luna")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }

  func testChatGPTTranscriptionUsesGPT56LunaAtLowEffort() {
    let configuration = CodexProvider.transcriptionModelConfiguration()

    XCTAssertEqual(configuration.model, "gpt-5.6-luna")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }

  func testChatGPTLegacyFallbackModelsMatchPre201Models() {
    let transcription = CodexProvider.legacyTranscriptionModelConfiguration()
    let cards = CodexProvider.legacyActivityCardModelConfiguration()

    XCTAssertEqual(transcription.model, "gpt-5.4-mini")
    XCTAssertEqual(transcription.reasoningEffort, "low")
    XCTAssertEqual(cards.model, "gpt-5.4")
    XCTAssertEqual(cards.reasoningEffort, "low")
  }

  func testChatGPTOnlyUsesLegacyFallbackForOutdatedCLIError() {
    let outdatedError = NSError(
      domain: "ChatCLI",
      code: -33,
      userInfo: [
        NSLocalizedDescriptionKey: "This model requires a newer version of Codex."
      ]
    )
    let transientError = NSError(
      domain: "ChatCLI",
      code: -3,
      userInfo: [NSLocalizedDescriptionKey: "CLI process timed out"]
    )

    XCTAssertTrue(
      CodexProvider.shouldUseLegacyModel(
        after: outdatedError,
        currentModel: "gpt-5.6-luna",
        fallbackModel: "gpt-5.4-mini"
      )
    )
    XCTAssertFalse(
      CodexProvider.shouldUseLegacyModel(
        after: transientError,
        currentModel: "gpt-5.6-luna",
        fallbackModel: "gpt-5.4-mini"
      )
    )
    XCTAssertFalse(
      CodexProvider.shouldUseLegacyModel(
        after: outdatedError,
        currentModel: "gpt-5.4-mini",
        fallbackModel: "gpt-5.4-mini"
      )
    )
  }

  func testClaudeTranscriptionUsesSonnetAliasAtLowEffort() {
    let configuration = ClaudeProvider.transcriptionModelConfiguration()

    XCTAssertEqual(configuration.model, "sonnet")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }

  func testLegacyCardCoverageAllowsBridgingExistingGaps() {
    let existingCards = [
      card(start: "9:00 AM", end: "9:15 AM", title: "Before gap"),
      card(start: "9:25 AM", end: "9:40 AM", title: "After gap"),
    ]
    let generatedCards = [
      card(start: "9:00 AM", end: "9:40 AM", title: "Combined session")
    ]

    let result = claudeProvider.validateTimeCoverage(
      existingCards: existingCards,
      newCards: generatedCards
    )

    XCTAssertTrue(result.isValid)
  }

  func testLegacyCardCoverageAllowsThreeMinutesOfBoundaryDrift() {
    let existingCards = [card(start: "9:00 AM", end: "9:30 AM", title: "Existing")]

    XCTAssertTrue(
      claudeProvider.validateTimeCoverage(
        existingCards: existingCards,
        newCards: [card(start: "9:03 AM", end: "9:30 AM", title: "Within tolerance")]
      ).isValid
    )
    XCTAssertFalse(
      claudeProvider.validateTimeCoverage(
        existingCards: existingCards,
        newCards: [card(start: "9:04 AM", end: "9:30 AM", title: "Outside tolerance")]
      ).isValid
    )
  }

  func testLegacyCardDurationOnlyRejectsShortNonFinalCards() {
    XCTAssertTrue(
      claudeProvider.validateTimeline([
        card(start: "9:00 AM", end: "10:30 AM", title: "Long card"),
        card(start: "10:30 AM", end: "10:35 AM", title: "Short final card"),
      ]).isValid
    )
    XCTAssertFalse(
      claudeProvider.validateTimeline([
        card(start: "9:00 AM", end: "9:05 AM", title: "Short non-final card"),
        card(start: "9:05 AM", end: "9:20 AM", title: "Final card"),
      ]).isValid
    )
  }

  func testLegacyCardValidationNormalizesConfiguredCategories() {
    let category = LLMCategoryDescriptor(
      id: UUID(),
      name: "Deep Work",
      colorHex: "000000",
      description: nil,
      isSystem: false,
      isIdle: false
    )
    let cards = [
      card(start: "9:00 AM", end: "9:30 AM", category: "deep work", title: "Writing")
    ]

    let normalized = claudeProvider.normalizeCards(cards, descriptors: [category])

    XCTAssertEqual(normalized.first?.category, "Deep Work")
  }

  func testLegacyTranscriptionValidationSortsSegmentsAndAllowsTwoSecondDrift() {
    let segments = [
      segment(start: "00:00:28", end: "00:00:58", description: "Second"),
      segment(start: "00:00:02", end: "00:00:30", description: "First"),
    ]

    XCTAssertNil(claudeProvider.validateSegments(segments, duration: 60))
  }

  func testLegacyTranscriptionValidationRejectsDriftBeyondTwoSeconds() {
    let segments = [
      segment(start: "00:00:03", end: "00:00:30", description: "First"),
      segment(start: "00:00:30", end: "00:00:57", description: "Second"),
    ]

    XCTAssertNotNil(claudeProvider.validateSegments(segments, duration: 60))
  }

  func testLegacyTranscriptionValidationDoesNotRejectEmptyDescriptions() {
    let segments = [
      segment(start: "00:00:00", end: "00:01:00", description: "   ")
    ]

    XCTAssertNil(claudeProvider.validateSegments(segments, duration: 60))
  }

  func testLegacyTranscriptionParserExtractsJSONFromWrappedOutput() throws {
    let output = """
      I inspected the screenshots.
      ```json
      {"segments":[{"start":"00:00:00","end":"00:01:00","description":"Writing"}]}
      ```
      """

    let segments = try claudeProvider.parseSegments(from: output, stderr: "")

    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments.first?.description, "Writing")
  }

  func testTelemetryErrorSanitizerKeepsUsefulValidationReasonWithoutCardData() {
    let detail = """
      Missing coverage from 9:00 AM to 9:04 AM.

      📥 INPUT CARDS:
      Secret Project — customer@example.com
      """

    let sanitized = TelemetryErrorSanitizer.sanitize(detail)

    XCTAssertEqual(sanitized, "Missing coverage from 9:00 AM to 9:04 AM.")
  }

  func testTelemetryErrorSanitizerRedactsCommonIdentifiersAndBoundsLength() {
    let detail =
      "user@example.com /Users/jerry/private.txt https://example.com sk-proj-abcdefghijklmnop "
      + String(repeating: "x", count: 600)

    let sanitized = TelemetryErrorSanitizer.sanitize(detail)

    XCTAssertNotNil(sanitized)
    XCTAssertLessThanOrEqual(sanitized?.count ?? 0, 500)
    XCTAssertFalse(sanitized?.contains("user@example.com") ?? true)
    XCTAssertFalse(sanitized?.contains("/Users/jerry") ?? true)
    XCTAssertFalse(sanitized?.contains("https://example.com") ?? true)
    XCTAssertFalse(sanitized?.contains("sk-proj-abcdefghijklmnop") ?? true)
  }

  func testTelemetryErrorSanitizerRedactsCardTitlesContainingApostrophes() {
    let sanitized = TelemetryErrorSanitizer.sanitize(
      "Card 2 'Don\'t expose customer@example.com' is only 5.0 minutes long"
    )

    XCTAssertEqual(sanitized, "Card 2 is only 5.0 minutes long")
  }

  func testTelemetryErrorSanitizerNormalizesModelSuppliedTimestamps() {
    let sanitized = TelemetryErrorSanitizer.sanitize(
      "Segment end time must be after start time: customer@example.com -> secret project"
    )

    XCTAssertEqual(sanitized, "Segment end time must be after start time.")
  }

  func testClaudeOptimizedProfilesUseNormalAuthSafeMode() {
    assertWrapper(ClaudeProvider.optimizedTranscriptionCLIProfile().wrapperMode, is: .safeMode)
    assertWrapper(ClaudeProvider.optimizedCardGenerationCLIProfile().wrapperMode, is: .safeMode)
    assertWrapper(
      ClaudeProvider.optimizedTranscriptionCorrectionCLIProfile().wrapperMode,
      is: .safeMode
    )
  }

  func testClaudeSessionCleanupRemovesOnlyItsSessionTranscript() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent("Dayflow-Claude-OAuth-Test-\(UUID().uuidString)", isDirectory: true)
    let project = fixture.appendingPathComponent("projects/test-project", isDirectory: true)
    try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let sessionID = UUID().uuidString
    let sessionTranscript = project.appendingPathComponent("\(sessionID).jsonl")
    let unrelatedTranscript = project.appendingPathComponent("unrelated.jsonl")
    try Data("session".utf8).write(to: sessionTranscript)
    try Data("keep".utf8).write(to: unrelatedTranscript)

    let cleanup = ClaudeSessionCleanup(
      sessionID: sessionID,
      claudeConfigDirectory: fixture
    )

    cleanup.cleanup()

    XCTAssertFalse(fileManager.fileExists(atPath: sessionTranscript.path))
    XCTAssertTrue(fileManager.fileExists(atPath: unrelatedTranscript.path))
  }

  private func assertWrapper(
    _ actual: ClaudeCLIWrapperMode,
    is expected: ClaudeCLIWrapperMode,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(actual, expected, "Unexpected Claude CLI wrapper", file: file, line: line)
  }

  private func card(
    start: String,
    end: String,
    category: String = "Focus",
    title: String
  ) -> ActivityCardData {
    ActivityCardData(
      startTime: start,
      endTime: end,
      category: category,
      subcategory: "",
      title: title,
      summary: "Summary",
      detailedSummary: "Details",
      distractions: nil,
      appSites: nil
    )
  }

  private func segment(
    start: String,
    end: String,
    description: String
  ) -> SegmentMergeResponse.Segment {
    SegmentMergeResponse.Segment(start: start, end: end, description: description)
  }
}
