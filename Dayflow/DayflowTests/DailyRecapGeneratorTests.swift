import XCTest

@testable import Dayflow

final class DailyRecapGeneratorTests: XCTestCase {
  override func tearDown() {
    super.tearDown()
    LLMOutputLanguagePreferences.override = ""
  }

  func testMakeLocalPromptPlacesLanguageSectionBeforeOutputFormat() throws {
    LLMOutputLanguagePreferences.override = "Japanese"

    let prompt = DailyRecapGenerator.makeLocalPrompt(
      day: "2026-04-08",
      cards: [sampleCard()]
    )

    let languageInstruction = try XCTUnwrap(
      LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
    )
    let languageRange = try XCTUnwrap(prompt.range(of: "## Language"))
    let instructionRange = try XCTUnwrap(prompt.range(of: languageInstruction))
    let outputFormatRange = try XCTUnwrap(prompt.range(of: "## Output format"))

    XCTAssertLessThan(languageRange.lowerBound, outputFormatRange.lowerBound)
    XCTAssertLessThan(instructionRange.lowerBound, outputFormatRange.lowerBound)
    XCTAssertTrue(prompt.contains("Return exactly one JSON object and nothing before or after it."))
  }

  func testDailyGenerationRequestEncodesPreferredOutputLanguage() throws {
    let request = DayflowDailyGenerationRequest(
      day: "2026-04-08",
      cardsText: "Cards",
      observationsText: "Observations",
      priorDailyText: "Prior",
      preferencesText: "{}",
      preferredOutputLanguage: "Japanese"
    )

    let data = try JSONEncoder().encode(request)
    let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(jsonObject["preferred_output_language"] as? String, "Japanese")
  }

  func testSourceResolverAllowsFridayForMondayWhenWeekendHasNoActivity() throws {
    let mondayStart = try dayStart("2026-06-01")
    let sourceDay = DailyRecapSourceDayResolver.sourceDay(
      before: mondayStart,
      lookbackWindowDays: 3,
      consumedSourceDays: [],
      hasMinimumActivity: { $0 == "2026-05-29" }
    )

    XCTAssertEqual(sourceDay?.dayString, "2026-05-29")
  }

  func testSourceResolverSkipsConsumedActivityDays() throws {
    let targetStart = try dayStart("2026-05-29")
    let sourceDay = DailyRecapSourceDayResolver.sourceDay(
      before: targetStart,
      lookbackWindowDays: 3,
      consumedSourceDays: ["2026-05-26"],
      hasMinimumActivity: { $0 == "2026-05-26" }
    )

    XCTAssertNil(sourceDay)
  }

  func testConsumedSourceDaysReadsGenerationMetadata() throws {
    let consumed = DailyRecapSourceDayResolver.consumedSourceDays(
      from: [
        try sampleDailyEntry(targetDay: "2026-05-29", sourceDay: "2026-05-28"),
        try sampleDailyEntry(targetDay: "2026-05-28", sourceDay: "2026-05-27"),
        sampleLegacyDailyEntry(targetDay: "2026-05-27"),
      ]
    )

    XCTAssertEqual(consumed, ["2026-05-28", "2026-05-27"])
  }

  private func sampleCard() -> TimelineCard {
    TimelineCard(
      recordId: nil,
      batchId: nil,
      startTimestamp: "9:00 AM",
      endTimestamp: "10:00 AM",
      category: "Work",
      subcategory: "Coding",
      title: "Shipped prompt updates",
      summary: "Updated Daily recap prompt",
      detailedSummary: "",
      day: "2026-04-08",
      distractions: nil,
      videoSummaryURL: nil,
      otherVideoSummaryURLs: nil,
      appSites: nil
    )
  }

  private func dayStart(_ day: String) throws -> Date {
    let date = try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: day))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current

    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = 4
    components.minute = 0
    components.second = 0
    return try XCTUnwrap(calendar.date(from: components))
  }

  private func sampleDailyEntry(targetDay: String, sourceDay: String) throws -> DailyStandupEntry {
    let draft = DailyStandupDraft(
      highlightsTitle: "Yesterday's highlights",
      highlights: [DailyBulletItem(text: "Finished a useful change.")],
      tasksTitle: "Today's tasks",
      tasks: [DailyBulletItem(text: "Ship it.")],
      blockersTitle: "Blockers",
      blockersBody: "",
      generation: DailyStandupGenerationMetadata(provider: .dayflow, sourceDay: sourceDay)
    )
    let data = try JSONEncoder().encode(draft)
    let payload = try XCTUnwrap(String(data: data, encoding: .utf8))
    return DailyStandupEntry(
      standupDay: targetDay,
      payloadJSON: payload,
      createdAt: nil,
      updatedAt: nil
    )
  }

  private func sampleLegacyDailyEntry(targetDay: String) -> DailyStandupEntry {
    DailyStandupEntry(
      standupDay: targetDay,
      payloadJSON: #"{"highlights":[],"tasks":[],"blockersBody":""}"#,
      createdAt: nil,
      updatedAt: nil
    )
  }
}
