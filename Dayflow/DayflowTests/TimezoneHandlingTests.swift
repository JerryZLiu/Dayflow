import XCTest

@testable import Dayflow

/// Timezone and daylight saving behaviour of the timeline.
///
/// Tests marked "Fails today" describe the behaviour we want and fail until the timezone fix
/// lands. The others guard behaviour that already works and must keep working.
///
/// Changing the Mac's timezone is simulated by setting `NSTimeZone.default`, which
/// `Calendar.current` and formatters with no timezone set follow. `tearDown` restores it.
///
/// `TimeZone.autoupdatingCurrent` does NOT follow `NSTimeZone.default`, so a fix that sets a
/// formatter's zone to `.autoupdatingCurrent` still fails these tests. Leave the formatter's
/// zone unset, or take it from `Calendar.current` on every call; both follow real system changes.
final class TimezoneHandlingTests: XCTestCase {
  private var originalDefaultZone: TimeZone!

  override func setUp() {
    super.setUp()
    originalDefaultZone = NSTimeZone.default
  }

  override func tearDown() {
    NSTimeZone.default = originalDefaultZone
    super.tearDown()
  }

  // MARK: - Logical day (4 AM boundary)

  func testLateNightWorkBelongsToThePreviousDay() {
    // Use the zone the shared day formatter already has, so this test only checks the 4 AM rule.
    let zone = DateFormatter.yyyyMMdd.timeZone!
    NSTimeZone.default = zone

    let oneThirtyAM = date(2026, 11, 17, hour: 1, minute: 30, in: zone)
    let fourAM = date(2026, 11, 17, hour: 4, minute: 0, in: zone)

    XCTAssertEqual(oneThirtyAM.getDayInfoFor4AMBoundary().dayString, "2026-11-16")
    XCTAssertEqual(fourAM.getDayInfoFor4AMBoundary().dayString, "2026-11-17")
  }

  /// Fails today: `DateFormatter.yyyyMMdd` keeps the timezone it had when first used, so after
  /// flying from Los Angeles to Tokyo without relaunching, Tokyo's Tuesday is saved as Monday.
  func testDayKeyFollowsTimezoneChangeWhileAppIsRunning() throws {
    // The trip starts in Los Angeles. Once fixed, the formatter follows this zone too.
    NSTimeZone.default = zone("America/Los_Angeles")
    let tokyo = zone("Asia/Tokyo")
    let tenAMTuesday = date(2026, 11, 17, hour: 10, minute: 0, in: tokyo)

    // Today the formatter is stuck on the zone the app host launched in, which may be anywhere.
    let formatterZone = DateFormatter.yyyyMMdd.timeZone!
    guard formatterZone.secondsFromGMT(for: tenAMTuesday) <= 4 * 3600 else {
      throw XCTSkip("Needs the formatter's zone to be at least 5 hours behind Tokyo.")
    }

    NSTimeZone.default = tokyo

    XCTAssertEqual(tenAMTuesday.getDayInfoFor4AMBoundary().dayString, "2026-11-17")
  }

  /// Fails today: after moving west without relaunching, the timeline reads the card's stored
  /// day with the old zone and draws the card on the previous day.
  func testTimelineDrawsCardOnItsStoredDayAfterMovingWest() throws {
    // The trip starts in Los Angeles. Once fixed, the formatter follows this zone too.
    NSTimeZone.default = zone("America/Los_Angeles")
    let honolulu = zone("Pacific/Honolulu")
    let cardDay = date(2026, 11, 16, hour: 12, minute: 0, in: honolulu)

    // Today the formatter is stuck on the zone the app host launched in, which may be anywhere.
    let formatterZone = DateFormatter.yyyyMMdd.timeZone!
    guard formatterZone.secondsFromGMT(for: cardDay) > honolulu.secondsFromGMT(for: cardDay) else {
      throw XCTSkip("Needs the formatter's zone to be east of Honolulu.")
    }

    NSTimeZone.default = honolulu
    let card = timelineCard(day: "2026-11-16", start: "3:34 PM", end: "3:49 PM")

    let activity = try XCTUnwrap(TimelineActivityLoader.buildActivities(from: [card]).first)
    let parts = calendar(honolulu).dateComponents([.day, .hour, .minute], from: activity.startTime)

    XCTAssertEqual(parts.day, 16)
    XCTAssertEqual(parts.hour, 15)
    XCTAssertEqual(parts.minute, 34)
  }

  // MARK: - Clock label to timestamp

  func testClockLabelResolvesExactlyOnAnOrdinaryDay() {
    // Monday Nov 2, 2026, 3:00 PM in Los Angeles (PST).
    let anchor = epoch("2026-11-02T23:00:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "3:00 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  func testClockLabelJustAfterMidnightResolvesToTheNextDay() {
    // Batch starts 11:55 PM Nov 2 in Los Angeles; the label is 10 minutes later.
    let anchor = epoch("2026-11-03T07:55:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "12:05 AM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor + 10 * 60)
  }

  /// Fails today: on the day clocks fall back, labels after 2 AM resolve one hour early,
  /// because the code adds elapsed minutes to midnight instead of setting the clock time.
  func testClockLabelResolvesExactlyOnFallBackDay() {
    // Sunday Nov 1, 2026, 3:00 PM in Los Angeles (PST, after falling back).
    let anchor = epoch("2026-11-01T23:00:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "3:00 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// Fails today: on the day clocks spring forward, labels after 3 AM resolve one hour late.
  func testClockLabelResolvesExactlyOnSpringForwardDay() {
    // Sunday Mar 8, 2026, 3:00 PM in Los Angeles (PDT, after springing forward).
    let anchor = epoch("2026-03-08T22:00:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "3:00 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// Fails today: 1:30 AM happens twice on fall-back night. A batch recorded during the second
  /// 1:30 AM should resolve to that one, not the first one an hour earlier.
  func testClockLabelInTheRepeatedHourResolvesToTheNearestOne() {
    // Second 1:30 AM on Nov 1, 2026 in Los Angeles (PST).
    let anchor = epoch("2026-11-01T09:30:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "1:30 AM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// Passes today. Guards the other half of the repeated hour: a fix that always picks the
  /// second 1:30 AM would break batches recorded during the first one.
  func testClockLabelInTheFirstRepeatedHourStaysOnTheFirstOne() {
    // First 1:30 AM on Nov 1, 2026 in Los Angeles (PDT, before falling back).
    let anchor = epoch("2026-11-01T08:30:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "1:30 AM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// Fails today: a label from the evening before a fall-back night, resolved from a batch just
  /// after midnight, lands an hour early.
  func testClockLabelJustBeforeMidnightResolvesToThePreviousDayAfterFallBack() {
    // Batch starts 12:05 AM Monday Nov 2 in Los Angeles (PST); the label is 10 minutes earlier,
    // 11:55 PM on Sunday Nov 1, the day clocks fell back.
    let anchor = epoch("2026-11-02T08:05:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "11:55 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor - 10 * 60)
  }

  // MARK: - Observations

  /// Fails today: on spring-forward day every detail line resolves an hour late, lands after
  /// the batch window and is dropped.
  func testObservationsAreKeptOnSpringForwardDay() {
    NSTimeZone.default = zone("America/Los_Angeles")
    // 3:00 to 3:15 PM PDT on Sunday Mar 8, 2026.
    let windowStart = epoch("2026-03-08T22:00:00Z")
    let windowEnd = windowStart + 15 * 60
    let card = codeReviewCard()

    let observations = OneStepTimelineObservations.make(
      from: [card], windowStart: windowStart, windowEnd: windowEnd, batchId: 1, model: "test")

    XCTAssertEqual(observations.count, 2)
    XCTAssertEqual(observations.first?.startTs, windowStart)
    XCTAssertEqual(observations.last?.endTs, windowEnd)
  }

  /// Fails today: on fall-back day every detail line resolves an hour early, lands outside the
  /// batch window and is dropped, so the day ends up with no observations at all.
  func testObservationsAreKeptOnFallBackDay() {
    NSTimeZone.default = zone("America/Los_Angeles")
    // 3:00 to 3:15 PM PST on Sunday Nov 1, 2026.
    let windowStart = epoch("2026-11-01T23:00:00Z")
    let windowEnd = windowStart + 15 * 60
    let card = codeReviewCard()

    let observations = OneStepTimelineObservations.make(
      from: [card], windowStart: windowStart, windowEnd: windowEnd, batchId: 1, model: "test")

    XCTAssertEqual(observations.count, 2)
    XCTAssertEqual(observations.first?.startTs, windowStart)
    XCTAssertEqual(observations.last?.endTs, windowEnd)
  }

  // MARK: - Helpers

  private func zone(_ identifier: String) -> TimeZone {
    TimeZone(identifier: identifier)!
  }

  private func calendar(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }

  private func date(
    _ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int, in zone: TimeZone
  )
    -> Date
  {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    return calendar(zone).date(from: components)!
  }

  private func epoch(_ iso8601: String) -> Int {
    Int(ISO8601DateFormatter().date(from: iso8601)!.timeIntervalSince1970)
  }

  /// A 3:00 to 3:15 PM card with two detail lines.
  private func codeReviewCard() -> ActivityCardData {
    ActivityCardData(
      startTime: "3:00 PM",
      endTime: "3:15 PM",
      category: "Work",
      subcategory: "",
      title: "Code review",
      summary: "Reviewed a pull request.",
      detailedSummary: "3:00 PM - 3:05 PM: Read the pull request\n3:05 PM - 3:15 PM: Left comments",
      distractions: nil,
      appSites: nil
    )
  }

  private func timelineCard(day: String, start: String, end: String) -> TimelineCard {
    TimelineCard(
      recordId: 1,
      batchId: 1,
      startTimestamp: start,
      endTimestamp: end,
      category: "Work",
      subcategory: "",
      title: "Review PR",
      summary: "",
      detailedSummary: "",
      day: day,
      distractions: nil,
      videoSummaryURL: nil,
      otherVideoSummaryURLs: nil,
      appSites: nil
    )
  }
}
