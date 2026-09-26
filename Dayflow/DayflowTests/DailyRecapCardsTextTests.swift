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

  func testEmptyCardListReturnsNoActivitiesMessage() {
    let text = DailyRecapGenerator.makeCardsText(day: "2026-06-16", cards: [])
    XCTAssertEqual(text, "No timeline activities were recorded for 2026-06-16.")
  }

  func testIncludesDistinctSummaryButNotSummaryEqualToTitle() {
    let withSummary = DailyRecapGenerator.makeCardsText(
      day: "2026-06-16",
      cards: [card(title: "Wrote the report", minute: 0, summary: "Drafted Q2 numbers")]
    )
    XCTAssertTrue(withSummary.contains("Drafted Q2 numbers"))

    // A summary identical to the title is redundant and must be dropped, not
    // printed twice.
    let redundant = DailyRecapGenerator.makeCardsText(
      day: "2026-06-16",
      cards: [card(title: "Wrote the report", minute: 0, summary: "Wrote the report")]
    )
    let occurrences = redundant.components(separatedBy: "Wrote the report").count - 1
    XCTAssertEqual(occurrences, 1)
  }

  // Filtering "Processing failed" and character-budget truncation must compose:
  // failed cards are removed BEFORE the budget is measured, so they never
  // consume budget or count toward the "omitted" tally.
  func testFilterAndTruncationCompose() {
    var cards: [TimelineCard] = []
    for i in 0..<20 {
      cards.append(card(title: "Processing failed", minute: i))
      cards.append(card(title: "Real activity \(i)", minute: i))
    }
    let text = DailyRecapGenerator.makeCardsText(
      day: "2026-06-16", cards: cards, maxCharacters: 300
    )
    XCTAssertFalse(text.contains("Processing failed"))
    if text.contains("omitted") {
      // The omitted count must reference only the 20 real cards, never the 40 total.
      let omittedReal = (1...20).contains { text.contains("... and \($0) more") }
      XCTAssertTrue(omittedReal, "omitted count should be <= 20 real activities, not include filtered cards")
    }
  }

  // Boundary: when everything fits, there must be NO truncation notice
  // (off-by-one guard on the `includedCount < ordered.count` check).
  func testNoOmissionNoticeWhenAllCardsFit() {
    let cards = (0..<3).map { card(title: "Task \($0)", minute: $0) }
    let text = DailyRecapGenerator.makeCardsText(
      day: "2026-06-16", cards: cards, maxCharacters: 10_000
    )
    XCTAssertFalse(text.contains("omitted"))
    XCTAssertTrue(text.contains("3. 9:02am - 9:03am: Task 2"))
  }

  private func card(title: String, minute: Int, summary: String = "") -> TimelineCard {
    TimelineCard(
      recordId: nil, batchId: nil,
      startTimestamp: String(format: "9:%02d AM", minute),
      endTimestamp: String(format: "9:%02d AM", minute + 1),
      category: "Work", subcategory: "Coding",
      title: title, summary: summary, detailedSummary: "", day: "2026-06-16",
      distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil, appSites: nil
    )
  }
}
