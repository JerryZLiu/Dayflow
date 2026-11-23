import XCTest

@testable import Dayflow

/// Timezone and daylight saving behaviour of the timeline. Cards are shown in the zone they were
/// recorded in, and nothing may drift when the Mac's timezone changes or clocks change.
///
/// Changing the Mac's timezone is simulated by setting `NSTimeZone.default`, which
/// `Calendar.current` and formatters with no timezone set follow. `tearDown` restores it.
///
/// `TimeZone.autoupdatingCurrent` does NOT follow `NSTimeZone.default`, so a fix that sets a
/// formatter's zone to `.autoupdatingCurrent` would fail these tests. Leave the formatter's
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

  /// The day formatter used to keep the zone it had when first used, so after flying from Los
  /// Angeles to Tokyo without relaunching, Tokyo's Tuesday was saved as Monday.
  func testDayKeyFollowsTimezoneChangeWhileAppIsRunning() {
    NSTimeZone.default = zone("America/Los_Angeles")
    _ = DateFormatter.yyyyMMdd.string(from: Date())
    let tokyo = zone("Asia/Tokyo")
    let tenAMTuesday = date(2026, 11, 17, hour: 10, minute: 0, in: tokyo)

    NSTimeZone.default = tokyo

    XCTAssertEqual(tenAMTuesday.getDayInfoFor4AMBoundary().dayString, "2026-11-17")
  }

  /// After moving west without relaunching, the timeline used to read the card's stored day with
  /// the old zone and draw the card on the previous day.
  func testTimelineDrawsCardOnItsStoredDayAfterMovingWest() throws {
    NSTimeZone.default = zone("America/Los_Angeles")
    _ = DateFormatter.yyyyMMdd.string(from: Date())
    let honolulu = zone("Pacific/Honolulu")

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

  /// On the day clocks fall back, labels after 2 AM used to resolve one hour early, because the
  /// code added elapsed minutes to midnight instead of setting the clock time.
  func testClockLabelResolvesExactlyOnFallBackDay() {
    // Sunday Nov 1, 2026, 3:00 PM in Los Angeles (PST, after falling back).
    let anchor = epoch("2026-11-01T23:00:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "3:00 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// On the day clocks spring forward, labels after 3 AM used to resolve one hour late.
  func testClockLabelResolvesExactlyOnSpringForwardDay() {
    // Sunday Mar 8, 2026, 3:00 PM in Los Angeles (PDT, after springing forward).
    let anchor = epoch("2026-03-08T22:00:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "3:00 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// 1:30 AM happens twice on fall-back night. A batch recorded during the second
  /// 1:30 AM should resolve to that one, not the first one an hour earlier.
  func testClockLabelInTheRepeatedHourResolvesToTheNearestOne() {
    // Second 1:30 AM on Nov 1, 2026 in Los Angeles (PST).
    let anchor = epoch("2026-11-01T09:30:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "1:30 AM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// The other half of the repeated hour: always picking the second 1:30 AM would break batches
  /// recorded during the first one.
  func testClockLabelInTheFirstRepeatedHourStaysOnTheFirstOne() {
    // First 1:30 AM on Nov 1, 2026 in Los Angeles (PDT, before falling back).
    let anchor = epoch("2026-11-01T08:30:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "1:30 AM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor)
  }

  /// A label from the evening of a fall-back day, resolved from a batch just after midnight,
  /// used to land an hour early.
  func testClockLabelJustBeforeMidnightResolvesToThePreviousDayAfterFallBack() {
    // Batch starts 12:05 AM Monday Nov 2 in Los Angeles (PST); the label is 10 minutes earlier,
    // 11:55 PM on Sunday Nov 1, the day clocks fell back.
    let anchor = epoch("2026-11-02T08:05:00Z")

    let resolved = OneStepTimelineObservations.timelineEpoch(
      forClock: "11:55 PM", nearest: anchor, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(resolved, anchor - 10 * 60)
  }

  // MARK: - Observations

  /// On spring-forward day every detail line used to resolve an hour late, land after the batch
  /// window and be dropped.
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

  /// On fall-back day every detail line used to resolve an hour early, land outside the batch
  /// window and be dropped, so the day ended up with no observations at all.
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

  /// A card from 1:30 AM before clocks fall back to 1:05 AM after it lasts 35 minutes, not a day.
  func testCardEndInTheRepeatedHourLandsAfterItsStart() {
    let start = Date(timeIntervalSince1970: TimeInterval(epoch("2026-11-01T08:30:00Z")))

    let end = ClockTime.resolve(
      hour: 1, minute: 5, onOrAfter: start, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(end.map { Int($0.timeIntervalSince(start)) }, 35 * 60)
  }

  func testCardEndAfterMidnightLandsOnTheNextDay() {
    // 11:50 PM to 12:10 AM in Los Angeles.
    let start = Date(timeIntervalSince1970: TimeInterval(epoch("2026-11-03T07:50:00Z")))

    let end = ClockTime.resolve(
      hour: 0, minute: 10, onOrAfter: start, calendar: calendar(zone("America/Los_Angeles")))

    XCTAssertEqual(end.map { Int($0.timeIntervalSince(start)) }, 20 * 60)
  }

  /// A 2:15 AM card on the night after clocks spring forward used to be placed in the skipped hour
  /// of the day before and drawn at 3:00 AM with no length.
  func testCardAfterSpringForwardNightKeepsItsEarlyMorningTime() throws {
    NSTimeZone.default = zone("America/Los_Angeles")
    // Logical day Sunday Mar 8, 2026; the card is at 2:15 AM on Monday Mar 9.
    let card = timelineCard(day: "2026-03-08", start: "2:15 AM", end: "2:45 AM")

    let activity = try XCTUnwrap(TimelineActivityLoader.buildActivities(from: [card]).first)
    let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: activity.startTime)

    XCTAssertEqual(parts.day, 9)
    XCTAssertEqual(parts.hour, 2)
    XCTAssertEqual(parts.minute, 15)
    XCTAssertEqual(activity.endTime.timeIntervalSince(activity.startTime), 30 * 60)
  }

  // MARK: - Recorded-local display

  func testDayKeyCanBeWorkedOutInTheRecordedZone() {
    // 10 AM Tuesday in Tokyo is still Monday evening in Los Angeles.
    NSTimeZone.default = zone("America/Los_Angeles")
    let tokyo = zone("Asia/Tokyo")
    let tenAMTuesday = date(2026, 11, 17, hour: 10, minute: 0, in: tokyo)

    let inTokyo = tenAMTuesday.getDayInfoFor4AMBoundary(in: ClockTime.calendar(in: tokyo))

    XCTAssertEqual(inTokyo.dayString, "2026-11-17")
    XCTAssertEqual(tenAMTuesday.getDayInfoFor4AMBoundary().dayString, "2026-11-16")
  }

  func testCardFromTokyoKeepsItsTokyoClockTimesWhenViewedFromLosAngeles() throws {
    NSTimeZone.default = zone("America/Los_Angeles")
    // Recorded 3:34 to 3:49 PM on Sep 29 in Tokyo.
    let card = timelineCard(
      day: "2026-09-29", start: "3:34 PM", end: "3:49 PM",
      startTs: epoch("2026-09-29T06:34:00Z"), endTs: epoch("2026-09-29T06:49:00Z"),
      utcOffset: 9 * 3600)

    let activity = try XCTUnwrap(TimelineActivityLoader.buildActivities(from: [card]).first)
    let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: activity.startTime)

    XCTAssertEqual(parts.day, 29)
    XCTAssertEqual(parts.hour, 15)
    XCTAssertEqual(parts.minute, 34)
  }

  /// A card processed after landing was labelled in the new zone. On a day mostly recorded in
  /// New York it's drawn at its New York time, not overlapping the cards around it.
  func testCardLabelledInAnotherZoneIsDrawnInTheDaysMainZone() throws {
    NSTimeZone.default = zone("America/Los_Angeles")
    let newYorkCard = timelineCard(
      day: "2026-10-31", start: "12:25 PM", end: "1:18 PM",
      startTs: epoch("2026-10-31T16:25:00Z"), endTs: epoch("2026-10-31T17:18:00Z"),
      utcOffset: -4 * 3600)
    // Recorded 1:33 PM in New York, labelled 10:33 AM after processing in Los Angeles.
    let relabelledCard = timelineCard(
      day: "2026-10-31", start: "10:33 AM", end: "10:47 AM",
      startTs: epoch("2026-10-31T17:33:00Z"), endTs: epoch("2026-10-31T17:47:00Z"),
      utcOffset: -7 * 3600)

    let activities = TimelineActivityLoader.buildActivities(from: [newYorkCard, relabelledCard])
    let relabelled = try XCTUnwrap(activities.last)
    let parts = Calendar.current.dateComponents([.hour, .minute], from: relabelled.startTime)

    XCTAssertEqual(parts.hour, 13)
    XCTAssertEqual(parts.minute, 33)
  }

  /// On the night clocks fall back, cards one hour apart in offset keep their own clock times.
  func testDaylightSavingNightKeepsEachCardsOwnClockTime() throws {
    NSTimeZone.default = zone("America/Los_Angeles")
    // Logical day Oct 31: 1:30 AM PDT, then 3:00 to 3:45 AM PST, both on the morning of Nov 1.
    let beforeChange = timelineCard(
      day: "2026-10-31", start: "1:30 AM", end: "1:45 AM",
      startTs: epoch("2026-11-01T08:30:00Z"), endTs: epoch("2026-11-01T08:45:00Z"),
      utcOffset: -7 * 3600)
    let afterChange = timelineCard(
      day: "2026-10-31", start: "3:00 AM", end: "3:45 AM",
      startTs: epoch("2026-11-01T11:00:00Z"), endTs: epoch("2026-11-01T11:45:00Z"),
      utcOffset: -8 * 3600)

    let activities = TimelineActivityLoader.buildActivities(from: [beforeChange, afterChange])
    let hours = activities.map { Calendar.current.component(.hour, from: $0.startTime) }

    XCTAssertEqual(hours, [1, 3])
  }

  func testOffsetOfAnOlderCardIsWorkedOutFromItsLabel() {
    // 3:34 PM in Tokyo is 6:34 AM UTC.
    XCTAssertEqual(
      ClockTime.inferredUTCOffset(
        label: "3:34 PM", startTs: epoch("2026-09-29T06:34:00Z"), day: "2026-09-29"),
      9 * 3600)
  }

  func testOffsetOfAnOlderCardUsesItsDayToTellPlusThirteenFromMinusEleven() {
    // 9:00 AM on Nov 17 in Auckland (UTC+13) is 8:00 PM Nov 16 UTC. UTC-11 would give the same
    // clock time, but on Nov 16.
    XCTAssertEqual(
      ClockTime.inferredUTCOffset(
        label: "9:00 AM", startTs: epoch("2026-11-16T20:00:00Z"), day: "2026-11-17"),
      13 * 3600)
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

  private func timelineCard(
    day: String, start: String, end: String,
    startTs: Int? = nil, endTs: Int? = nil, utcOffset: Int? = nil
  ) -> TimelineCard {
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
      appSites: nil,
      startTs: startTs,
      endTs: endTs,
      utcOffset: utcOffset
    )
  }
}
