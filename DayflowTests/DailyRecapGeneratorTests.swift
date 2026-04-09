import XCTest

@testable import Dayflow

final class DailyRecapGeneratorTests: XCTestCase {
  override func tearDown() {
    super.tearDown()
    LLMOutputLanguagePreferences.override = ""
  }

  func testMakeLocalPromptPlacesLanguageSectionBeforeOutputFormat() {
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
}
