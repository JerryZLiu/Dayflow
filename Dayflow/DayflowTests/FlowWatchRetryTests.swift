import XCTest

@testable import Dayflow

final class FlowWatchRetryTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }()

  private func date(_ hour: Int, _ minute: Int, day: Int = 10) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
  }

  private var formatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "h:mm a"
    return formatter
  }

  // The error Codex printed for the customer in ticket 351.
  private let codexUsageLimit =
    "ERROR: You’ve hit your usage limit. Upgrade to Pro (<redacted-url> visit <redacted-url> to purchase more credits or try again at 2:11 PM."

  func testCodexUsageLimitErrorIsClassifiedAsUsageLimit() {
    let error = NSError(
      domain: "FlowAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: codexUsageLimit])
    XCTAssertEqual(TimelineFailureClassifier.classify(error).kind, .usageLimitHit)
  }

  func testResetTimeLaterTodayIsToday() {
    let reset = FlowWatchRetry.resetTime(in: codexUsageLimit, now: date(12, 47), calendar: calendar)
    XCTAssertEqual(reset, date(14, 11))
  }

  func testResetTimeAlreadyPassedTodayIsTomorrow() {
    let text = "You've hit your usage limit. Try again at 11:22 PM."
    XCTAssertEqual(
      FlowWatchRetry.resetTime(in: text, now: date(23, 40), calendar: calendar),
      date(23, 22, day: 11))
    XCTAssertEqual(
      FlowWatchRetry.resetTime(in: "try again at 12:05 AM", now: date(22, 0), calendar: calendar),
      date(0, 5, day: 11))
  }

  func testNoResetTimeInOtherErrors() {
    XCTAssertNil(FlowWatchRetry.resetTime(in: "exit 1", now: date(12, 0), calendar: calendar))
    XCTAssertNil(
      FlowWatchRetry.resetTime(in: "try again at 13:61 PM", now: date(12, 0), calendar: calendar))
  }

  func testUsageLimitWaitsUntilJustAfterTheReset() {
    let now = date(12, 47)
    let next = FlowWatchRetry.nextAttempt(
      kind: .usageLimitHit, resetsAt: date(14, 11), round: 1, now: now)
    XCTAssertEqual(next, date(14, 12))
  }

  private func waits(_ kind: TimelineFailureKind, rounds: Int) -> [TimeInterval] {
    let now = date(12, 0)
    var result: [TimeInterval] = []
    for round in 1...rounds {
      let next = FlowWatchRetry.nextAttempt(kind: kind, resetsAt: nil, round: round, now: now)
      result.append(next.timeIntervalSince(now))
    }
    return result
  }

  func testUsageLimitWithoutResetTimeBacksOffInLongSteps() {
    XCTAssertEqual(waits(.usageLimitHit, rounds: 4), [900, 1800, 3600, 3600])
  }

  func testOtherFailuresRetryWithinMinutes() {
    XCTAssertEqual(waits(.transient, rounds: 5), [60, 120, 300, 600, 600])
  }

  func testProblemSentenceForUsageLimitThatOutlastedTheSession() {
    let outage = FlowWatchOutage(
      kind: .usageLimitHit, providerName: "ChatGPT", startedAt: date(13, 17),
      resetsAt: date(14, 11), endedAt: nil)
    XCTAssertEqual(
      FlowWatchRetry.problemSentence(outage, formatter: formatter),
      "You ran out of ChatGPT usage at 1:17 PM, so Flow couldn't watch after that. It resets at 2:11 PM."
    )
    XCTAssertEqual(FlowWatchRetry.awayReason(outage), "ChatGPT usage limit reached")
  }

  func testProblemSentenceWhenWatchingResumed() {
    let outage = FlowWatchOutage(
      kind: .usageLimitHit, providerName: "ChatGPT", startedAt: date(13, 17),
      resetsAt: date(14, 11), endedAt: date(14, 12))
    XCTAssertEqual(
      FlowWatchRetry.problemSentence(outage, formatter: formatter),
      "You ran out of ChatGPT usage at 1:17 PM, so Flow couldn't watch until 2:12 PM.")
  }

  func testProblemSentenceForOtherFailures() {
    let outage = FlowWatchOutage(
      kind: .transient, providerName: "Claude", startedAt: date(9, 5), resetsAt: nil,
      endedAt: nil)
    XCTAssertEqual(
      FlowWatchRetry.problemSentence(outage, formatter: formatter),
      "Flow couldn't reach Claude at 9:05 AM, so it couldn't watch after that.")
    XCTAssertEqual(FlowWatchRetry.awayReason(outage), "couldn't reach Claude")
  }

  func testMainOutageIsTheLongest() {
    let short = FlowWatchOutage(
      kind: .transient, providerName: "ChatGPT", startedAt: date(9, 0), resetsAt: nil,
      endedAt: date(9, 3))
    let open = FlowWatchOutage(
      kind: .usageLimitHit, providerName: "ChatGPT", startedAt: date(9, 30), resetsAt: nil,
      endedAt: nil)
    XCTAssertEqual(FlowWatchRetry.mainOutage([short, open], sessionEnd: date(10, 0)), open)
    XCTAssertNil(FlowWatchRetry.mainOutage([], sessionEnd: date(10, 0)))
  }
}
