import XCTest

@testable import Dayflow

final class IdleCaptureIntervalTests: XCTestCase {
  func testActiveUserGetsBaseInterval() {
    let interval = IdleCaptureInterval.interval(
      baseInterval: 10,
      idleThrottledInterval: 30,
      idleSeconds: 0,
      idleThresholdSeconds: 120
    )
    XCTAssertEqual(interval, 10)
  }

  func testBelowThresholdStaysAtBaseInterval() {
    let interval = IdleCaptureInterval.interval(
      baseInterval: 10,
      idleThrottledInterval: 30,
      idleSeconds: 119,
      idleThresholdSeconds: 120
    )
    XCTAssertEqual(interval, 10)
  }

  func testAtThresholdSwitchesToThrottledInterval() {
    let interval = IdleCaptureInterval.interval(
      baseInterval: 10,
      idleThrottledInterval: 30,
      idleSeconds: 120,
      idleThresholdSeconds: 120
    )
    XCTAssertEqual(interval, 30)
  }

  func testLongIdleStaysAtThrottledInterval() {
    let interval = IdleCaptureInterval.interval(
      baseInterval: 10,
      idleThrottledInterval: 30,
      idleSeconds: 3600,
      idleThresholdSeconds: 120
    )
    XCTAssertEqual(interval, 30)
  }

  func testNilIdleSecondsGetsBaseInterval() {
    // No idle reading available (e.g. CGEventSource unavailable) — never throttle
    // on missing data, since that could silently starve real activity capture.
    let interval = IdleCaptureInterval.interval(
      baseInterval: 10,
      idleThrottledInterval: 30,
      idleSeconds: nil,
      idleThresholdSeconds: 120
    )
    XCTAssertEqual(interval, 10)
  }

  // MARK: - IdleBatchClassifier coverage-gap regression

  /// Mirrors IdleBatchClassifier.mergeCoverageSegments/invertedCoverageSegments
  /// exactly, so this test exercises the real coverage math rather than just
  /// comparing constants. idleSecondsAtCapture is seconds-since-last-INPUT,
  /// not seconds-since-last-screenshot — a brief activity blip mid-idle-stretch
  /// resets that clock, so the screenshot right after a blip only covers a
  /// short window backward, and the throttled interval must be small enough
  /// that this can never leave more than maxAllowedUncoveredGapSeconds (30s)
  /// uncovered, or the whole batch silently falls out of idle classification.
  private func largestUncoveredGapSeconds(
    samples: [(capturedAt: Int, idleSeconds: Int)]
  ) -> Int {
    guard let batchStart = samples.first?.capturedAt, let batchEnd = samples.last?.capturedAt
    else { return 0 }

    var rawSegments: [(start: Int, end: Int)] = []
    for sample in samples {
      let start = max(batchStart, sample.capturedAt - sample.idleSeconds)
      let end = min(batchEnd, sample.capturedAt)
      if end > start { rawSegments.append((start: start, end: end)) }
    }
    let segments = rawSegments.sorted { lhs, rhs in
      lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }

    var merged: [(start: Int, end: Int)] = []
    for segment in segments {
      if var last = merged.last, segment.start <= last.end {
        last.end = max(last.end, segment.end)
        merged[merged.count - 1] = last
      } else {
        merged.append(segment)
      }
    }

    var gaps: [Int] = []
    var cursor = batchStart
    for segment in merged {
      if segment.start > cursor { gaps.append(segment.start - cursor) }
      cursor = max(cursor, segment.end)
    }
    if cursor < batchEnd { gaps.append(batchEnd - cursor) }
    return gaps.max() ?? 0
  }

  func testWorstCaseBlipDuringIdleStaysWithinClassifierGapLimit() {
    // Simulate a full idle batch at the throttled cadence, with one brief
    // input blip landing 1 second before a capture tick — the worst-case
    // placement, since it minimizes the post-blip screenshot's backward
    // coverage while maximizing the uncovered predecessor gap.
    let interval = Int(IdleCaptureDefaults.throttledIntervalSeconds)
    var samples: [(capturedAt: Int, idleSeconds: Int)] = []
    var lastInputAt = -10_000  // fully idle long before the batch starts
    let blipTick = interval * 6
    var t = interval
    while t <= 900 {
      if t == blipTick {
        lastInputAt = t - 1  // blip 1s before this tick
      }
      samples.append((capturedAt: t, idleSeconds: t - lastInputAt))
      t += interval
    }

    let gap = largestUncoveredGapSeconds(samples: samples)
    XCTAssertLessThanOrEqual(
      gap, 30,
      "worst-case blip-during-idle gap (\(gap)s) exceeds IdleBatchClassifier's 30s limit — "
        + "the batch would silently fall out of idle classification"
    )
  }

  func testFullyIdleBatchAtThrottledCadenceHasZeroGap() {
    // Sanity check: with no activity blip, consecutive throttled-cadence
    // screenshots fully cover the batch (each one's idle window reaches
    // back past the previous screenshot).
    let interval = Int(IdleCaptureDefaults.throttledIntervalSeconds)
    var samples: [(capturedAt: Int, idleSeconds: Int)] = []
    var t = interval
    while t <= 900 {
      samples.append((capturedAt: t, idleSeconds: t + 600))  // idle since well before batch start
      t += interval
    }

    XCTAssertEqual(largestUncoveredGapSeconds(samples: samples), 0)
  }

  func testDisabledPreferenceAlwaysReturnsBaseInterval() {
    let interval = IdleCaptureInterval.interval(
      baseInterval: 10,
      idleThrottledInterval: 10,  // caller passes base==throttled when disabled
      idleSeconds: 600,
      idleThresholdSeconds: 120
    )
    XCTAssertEqual(interval, 10)
  }
}
