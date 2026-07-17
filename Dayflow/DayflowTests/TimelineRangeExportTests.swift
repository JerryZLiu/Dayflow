import XCTest

@testable import Dayflow

final class TimelineRangeExportTests: XCTestCase {
  func testSingleDayBuildsOneSectionWithAllCards() {
    let day = normalizedDay("2026-06-10")
    let cards = [
      card(day: "2026-06-10", title: "Email"),
      card(day: "2026-06-10", title: "Coding"),
    ]

    let output = TimelineRangeExport.build(
      startDay: day,
      endDay: day,
      now: day,
      fetch: { _ in cards }
    )

    XCTAssertEqual(output.dayCount, 1)
    XCTAssertEqual(output.activityCount, 2)
    XCTAssertTrue(output.markdown.contains("Email"))
    XCTAssertTrue(output.markdown.contains("Coding"))
    XCTAssertFalse(output.markdown.contains(TimelineRangeExport.dayDivider))
  }

  func testRangeRendersEveryCalendarDayAndSumsActivities() {
    let start = normalizedDay("2026-06-01")
    let end = normalizedDay("2026-06-03")
    let cardsByDay: [String: [TimelineCard]] = [
      "2026-06-01": [card(day: "2026-06-01", title: "Day one")],
      // 2026-06-02 intentionally empty
      "2026-06-03": [
        card(day: "2026-06-03", title: "Day three A"),
        card(day: "2026-06-03", title: "Day three B"),
      ],
    ]

    let output = TimelineRangeExport.build(
      startDay: start,
      endDay: end,
      now: end,
      fetch: { cardsByDay[$0] ?? [] }
    )

    // dayCount counts every calendar day in the range (including the empty one);
    // activityCount sums only the cards that exist.
    XCTAssertEqual(output.dayCount, 3)
    XCTAssertEqual(output.activityCount, 3)
    // Two dividers between three day-sections.
    let dividerCount = output.markdown.components(separatedBy: TimelineRangeExport.dayDivider).count - 1
    XCTAssertEqual(dividerCount, 2)
    XCTAssertTrue(output.markdown.contains("_No timeline activities were recorded for this day._"))
  }

  // MARK: - Default file name

  func testDefaultFileNameSingleDay() {
    let single = normalizedDay("2026-06-10")
    XCTAssertEqual(
      TimelineRangeExport.defaultFileName(startDay: single, endDay: single),
      "Dayflow timeline 2026-06-10.md")
  }

  func testDefaultFileNameRange() {
    XCTAssertEqual(
      TimelineRangeExport.defaultFileName(
        startDay: normalizedDay("2026-06-01"), endDay: normalizedDay("2026-06-03")),
      "Dayflow timeline 2026-06-01 to 2026-06-03.md")
  }

  func testFetchInvokedWithSequentialDayStrings() {
    let start = normalizedDay("2026-06-01")
    let end = normalizedDay("2026-06-03")
    var requestedDays: [String] = []

    _ = TimelineRangeExport.build(
      startDay: start,
      endDay: end,
      now: end,
      fetch: { day in
        requestedDays.append(day)
        return []
      }
    )

    XCTAssertEqual(requestedDays, ["2026-06-01", "2026-06-02", "2026-06-03"])
  }

  // MARK: - Fixtures

  private func normalizedDay(_ string: String) -> Date {
    normalizedTimelineDate(DateFormatter.yyyyMMdd.date(from: string)!)
  }

  private func card(day: String, title: String) -> TimelineCard {
    TimelineCard(
      recordId: nil,
      batchId: nil,
      startTimestamp: "09:00 AM",
      endTimestamp: "09:30 AM",
      category: "Focus",
      subcategory: "Work",
      title: title,
      summary: "Summary for \(title)",
      detailedSummary: "",
      day: day,
      distractions: nil,
      videoSummaryURL: nil,
      otherVideoSummaryURLs: nil,
      appSites: nil
    )
  }
}
