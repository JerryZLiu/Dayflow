import XCTest

@testable import Dayflow

final class TimelineClipboardFormatterTests: XCTestCase {
  func testWeekMarkdownUsesExportStyleSections() {
    let weekRange = TimelineWeekRange.containing(date("2026-01-07 12:00")!)
    let cardDay = weekRange.days[2].dayString
    let cards = [
      timelineCard(day: cardDay, title: "Built export flow", category: "Work")
    ]

    let markdown = TimelineClipboardFormatter.makeMarkdown(
      for: weekRange,
      cards: cards,
      now: date("2026-01-07 12:00")!
    )

    XCTAssertTrue(markdown.hasPrefix("# Dayflow timeline · "))
    XCTAssertTrue(markdown.contains("## Dayflow timeline · "))
    XCTAssertTrue(markdown.contains("1. **09:00 AM – 10:00 AM — Built export flow**"))
    XCTAssertTrue(markdown.contains("   - _Work_"))
  }

  private func timelineCard(day: String, title: String, category: String) -> TimelineCard {
    TimelineCard(
      recordId: nil,
      batchId: nil,
      startTimestamp: "09:00 AM",
      endTimestamp: "10:00 AM",
      category: category,
      subcategory: "",
      title: title,
      summary: "Copied timeline output",
      detailedSummary: "",
      day: day,
      distractions: nil,
      videoSummaryURL: nil,
      otherVideoSummaryURLs: nil,
      appSites: nil
    )
  }

  private func date(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: value)
  }
}
