import XCTest

@testable import Dayflow

final class TimelineReviewQueueTests: XCTestCase {
  func testQueueKeepsOnlyPendingEligibleCardsAndRetainsHistoricalRatings() {
    let activities = [
      activity("work", "Engineering", 500, 600),
      activity("idle", " \tIDLE\n", 200, 300),
      activity("system", "sYsTeM", 300, 400),
      activity("rated", "Study", 400, 500),
      activity("research", "Research", 100, 200),
    ]
    let ratings = [rating(200, 300, "neutral"), rating(400, 480, "focused")]
    let queue = TimelineReviewQueue.make(
      from: activities, dayStart: date(100), dayEnd: date(1000)
    ) { _, _ in ratings }

    XCTAssertTrue(queue.hasEligibleActivities)
    XCTAssertEqual(queue.pendingActivities.map(\.id), ["research", "work"])
    XCTAssertEqual(queue.ratingSegments.map(\.rating), ["neutral", "focused"])
    XCTAssertEqual(activities.map(\.id), ["work", "idle", "system", "rated", "research"])
  }

  func testIdleAndSystemOnlyDayHasNoEligibleCards() {
    let queue = TimelineReviewQueue.make(
      from: [activity("idle", "Idle", 200, 300), activity("system", "System", 300, 400)],
      dayStart: date(100), dayEnd: date(1000)
    ) { _, _ in [] }

    XCTAssertFalse(queue.hasEligibleActivities)
    XCTAssertTrue(queue.pendingActivities.isEmpty)
  }

  func testRatedCardCrossingDayBoundaryDoesNotReappear() {
    let queue = TimelineReviewQueue.make(
      from: [activity("late", "Study", 990, 1050)],
      dayStart: date(100), dayEnd: date(1000)
    ) { start, end in
      XCTAssertEqual(start, 100)
      XCTAssertEqual(end, 1050)
      return [rating(990, 1050, "focused")]
    }

    XCTAssertTrue(queue.hasEligibleActivities)
    XCTAssertTrue(queue.pendingActivities.isEmpty)
  }

  private func activity(_ id: String, _ category: String, _ start: Int, _ end: Int)
    -> TimelineActivity
  {
    TimelineActivity(
      id: id, recordId: nil, batchId: nil, startTime: date(start), endTime: date(end),
      title: id, summary: "", detailedSummary: "", category: category, subcategory: "",
      distractions: nil, videoSummaryURL: nil, screenshot: nil, appSites: nil,
      isBackupGenerated: false)
  }

  private func rating(_ start: Int, _ end: Int, _ value: String) -> TimelineReviewRatingSegment {
    TimelineReviewRatingSegment(id: Int64(start), startTs: start, endTs: end, rating: value)
  }

  private func date(_ seconds: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds))
  }
}
