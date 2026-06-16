import XCTest

@testable import Dayflow

final class TimelineExportRequestTests: XCTestCase {
  /// Fixed reference "now": 2026-06-15 12:00 local (hour >= 4 so the 4am rollback never fires).
  private let now: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 6
    components.day = 15
    components.hour = 12
    return Calendar.current.date(from: components)!
  }()

  // MARK: - Date selection

  func testDateTodayExportsSingleTimelineDay() {
    let request = try! parse("dayflow://export-timeline?date=today")
    let today = timelineDisplayDate(from: now, now: now)
    XCTAssertEqual(request.startDay, today)
    XCTAssertEqual(request.endDay, today)
  }

  func testDateYesterdayIsOneDayBeforeToday() {
    let request = try! parse("dayflow://export-timeline?date=yesterday")
    let expected = Calendar.current.date(
      byAdding: .day, value: -1, to: timelineDisplayDate(from: now, now: now))!
    XCTAssertEqual(request.startDay, expected)
    XCTAssertEqual(request.endDay, expected)
  }

  func testExplicitDateIsNormalizedToTimelineDay() {
    let request = try! parse("dayflow://export-timeline?date=2026-06-10")
    let expected = normalizedTimelineDate(DateFormatter.yyyyMMdd.date(from: "2026-06-10")!)
    XCTAssertEqual(request.startDay, expected)
    XCTAssertEqual(request.endDay, expected)
  }

  func testRangeUsesStartAndEnd() {
    let request = try! parse("dayflow://export-timeline?start=2026-06-01&end=2026-06-03")
    XCTAssertEqual(request.startDay, normalizedTimelineDate(date("2026-06-01")))
    XCTAssertEqual(request.endDay, normalizedTimelineDate(date("2026-06-03")))
  }

  func testRangeWithOnlyStartFallsBackToStartForEnd() {
    let request = try! parse("dayflow://export-timeline?start=2026-06-01")
    let expected = normalizedTimelineDate(date("2026-06-01"))
    XCTAssertEqual(request.startDay, expected)
    XCTAssertEqual(request.endDay, expected)
  }

  func testNoParametersDefaultsToToday() {
    let request = try! parse("dayflow://export-timeline")
    let today = timelineDisplayDate(from: now, now: now)
    XCTAssertEqual(request.startDay, today)
    XCTAssertEqual(request.endDay, today)
  }

  func testKeysAreCaseInsensitive() {
    let request = try! parse("dayflow://export-timeline?Start=2026-06-01&END=2026-06-02")
    XCTAssertEqual(request.startDay, normalizedTimelineDate(date("2026-06-01")))
    XCTAssertEqual(request.endDay, normalizedTimelineDate(date("2026-06-02")))
  }

  // MARK: - Validation

  func testStartAfterEndFails() {
    let result = TimelineExportRequest.parse(
      url: URL(string: "dayflow://export-timeline?start=2026-06-05&end=2026-06-01")!, now: now)
    XCTAssertEqual(result, .failure(.startAfterEnd))
  }

  func testInvalidCalendarDateFails() {
    let result = TimelineExportRequest.parse(
      url: URL(string: "dayflow://export-timeline?date=2026-13-40")!, now: now)
    XCTAssertEqual(result, .failure(.invalidDate("2026-13-40")))
  }

  func testGarbageDateFails() {
    let result = TimelineExportRequest.parse(
      url: URL(string: "dayflow://export-timeline?date=garbage")!, now: now)
    XCTAssertEqual(result, .failure(.invalidDate("garbage")))
  }

  // MARK: - Destination & flags

  func testDestinationPathCaptured() {
    let request = try! parse("dayflow://export-timeline?date=today&path=~/Reports/x.md")
    XCTAssertEqual(request.destinationPath, "~/Reports/x.md")
  }

  func testDestinationAliasesHonored() {
    let viaTo = try! parse("dayflow://export-timeline?date=today&to=/tmp/a.md")
    XCTAssertEqual(viaTo.destinationPath, "/tmp/a.md")
    let viaDestination = try! parse("dayflow://export-timeline?date=today&destination=/tmp/b.md")
    XCTAssertEqual(viaDestination.destinationPath, "/tmp/b.md")
  }

  func testDestinationDefaultsToNil() {
    let request = try! parse("dayflow://export-timeline?date=today")
    XCTAssertNil(request.destinationPath)
  }

  func testRevealParsing() {
    XCTAssertTrue(try! parse("dayflow://export-timeline?date=today&reveal=true").reveal)
    XCTAssertTrue(try! parse("dayflow://export-timeline?date=today&reveal=1").reveal)
    XCTAssertFalse(try! parse("dayflow://export-timeline?date=today&reveal=false").reveal)
    XCTAssertFalse(try! parse("dayflow://export-timeline?date=today").reveal)
  }

  // MARK: - Helpers

  private func parse(_ string: String) throws -> TimelineExportRequest {
    let result = TimelineExportRequest.parse(url: URL(string: string)!, now: now)
    switch result {
    case .success(let request):
      return request
    case .failure(let error):
      throw error
    }
  }

  private func date(_ string: String) -> Date {
    DateFormatter.yyyyMMdd.date(from: string)!
  }
}
