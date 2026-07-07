import XCTest

@testable import Dayflow

final class DailyRecapCardsTextTests: XCTestCase {
  func testExcludesProcessingFailedCardsFromPrompt() {
    let text = DailyRecapGenerator.makeCardsText(
      day: "2026-06-16",
      cards: [card(title: "Processing failed", minute: 0), card(title: "Wrote the report", minute: 30)]
    )

    XCTAssertFalse(text.contains("Processing failed"))
    XCTAssertTrue(text.contains("1. 9:30am - 9:31am: Wrote the report"))

    let onlyFailed = DailyRecapGenerator.makeCardsText(
      day: "2026-06-16", cards: [card(title: "Processing failed", minute: 0)]
    )
    XCTAssertEqual(onlyFailed, "No timeline activities were recorded for 2026-06-16.")
  }

  func testTruncatesDeterministicallyWhenOverCharacterBudget() {
    let cards = (0..<50).map { card(title: "Activity number \($0)", minute: $0) }
    let makeText = {
      DailyRecapGenerator.makeCardsText(day: "2026-06-16", cards: cards, maxCharacters: 400)
    }

    let text = makeText()
    let includedCount = text.split(separator: "\n").filter { $0.contains(": Activity") }.count
    XCTAssertTrue((1..<50).contains(includedCount))
    XCTAssertTrue(text.contains("1. 9:00am - 9:01am: Activity number 0"))
    XCTAssertTrue(text.contains("... and \(50 - includedCount) more activities omitted"))
    XCTAssertLessThan(text.count, 500)
    XCTAssertEqual(text, makeText())
  }

  private func card(title: String, minute: Int) -> TimelineCard {
    TimelineCard(
      recordId: nil, batchId: nil,
      startTimestamp: String(format: "9:%02d AM", minute),
      endTimestamp: String(format: "9:%02d AM", minute + 1),
      category: "Work", subcategory: "Coding",
      title: title, summary: "", detailedSummary: "", day: "2026-06-16",
      distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil, appSites: nil
    )
  }
}
