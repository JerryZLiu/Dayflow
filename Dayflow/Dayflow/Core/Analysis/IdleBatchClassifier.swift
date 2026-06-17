//
//  IdleBatchClassifier.swift
//  Dayflow
//
//  Pure classification of screenshot batches as fully idle, so the analysis
//  pipeline can skip the LLM and write an Idle card directly.
//

import Foundation

enum IdleBatchRules {
  static let classifierVersion = "idle_v1"
  static let minimumEligibleBatchDurationSeconds = 12 * 60
  static let requiredCoverageRatio = 0.95
  static let requiredQualifiedIdleRatio = 0.90
  static let requiredIdleSampleAvailabilityRatio = 0.90
  static let qualifyingIdleSecondsAtCapture = 60
  static let maxAllowedUncoveredGapSeconds = 30
  static let mergeGapSeconds = 5 * 60
}

struct IdleBatchAssessment {
  let classifierVersion: String
  let coverageRatio: Double
  let coveredSeconds: Int
  let batchDurationSeconds: Int
  let largestUncoveredGapSeconds: Int
  let screenshotCount: Int
  let sampledIdleScreenshotCount: Int
  let qualifiedIdleScreenshotCount: Int
  let qualifiedIdleRatio: Double
  let idleSampleAvailabilityRatio: Double
  let minIdleSecondsAtCapture: Int
  let medianIdleSecondsAtCapture: Int
  let averageIdleSecondsAtCapture: Double
  let maxIdleSecondsAtCapture: Int
}

enum IdleBatchClassifier {
  static func assess(_ screenshots: [Screenshot]) -> IdleBatchAssessment? {
    let ordered = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    guard let first = ordered.first, let last = ordered.last else { return nil }

    let batchStartTs = first.capturedAt
    let batchEndTs = last.capturedAt
    let batchDurationSeconds = batchEndTs - batchStartTs
    guard
      batchDurationSeconds >= IdleBatchRules.minimumEligibleBatchDurationSeconds
    else { return nil }

    let idleSamples = ordered.compactMap { screenshot -> (capturedAt: Int, idleSeconds: Int)? in
      guard let idleSeconds = screenshot.idleSecondsAtCapture, idleSeconds > 0 else { return nil }
      return (capturedAt: screenshot.capturedAt, idleSeconds: idleSeconds)
    }

    guard idleSamples.isEmpty == false else { return nil }

    let mergedCoverage = mergeCoverageSegments(
      idleSamples: idleSamples,
      batchStartTs: batchStartTs,
      batchEndTs: batchEndTs
    )
    let coveredSeconds = mergedCoverage.reduce(0) { partial, segment in
      partial + max(0, segment.end - segment.start)
    }
    let uncoveredSegments = invertedCoverageSegments(
      mergedCoverage,
      batchStartTs: batchStartTs,
      batchEndTs: batchEndTs
    )
    let largestUncoveredGapSeconds = uncoveredSegments.map { max(0, $0.end - $0.start) }.max() ?? 0
    let coverageRatio = Double(coveredSeconds) / Double(batchDurationSeconds)
    let idleValues = idleSamples.map(\.idleSeconds)
    let qualifiedIdleScreenshotCount = idleValues.filter {
      $0 >= IdleBatchRules.qualifyingIdleSecondsAtCapture
    }.count
    let qualifiedIdleRatio = Double(qualifiedIdleScreenshotCount) / Double(ordered.count)
    let idleSampleAvailabilityRatio = Double(idleValues.count) / Double(ordered.count)

    guard
      coverageRatio >= IdleBatchRules.requiredCoverageRatio,
      qualifiedIdleRatio >= IdleBatchRules.requiredQualifiedIdleRatio,
      idleSampleAvailabilityRatio >= IdleBatchRules.requiredIdleSampleAvailabilityRatio,
      largestUncoveredGapSeconds <= IdleBatchRules.maxAllowedUncoveredGapSeconds
    else {
      return nil
    }

    let sortedIdleValues = idleValues.sorted()
    let averageIdleSeconds = Double(idleValues.reduce(0, +)) / Double(idleValues.count)

    return IdleBatchAssessment(
      classifierVersion: IdleBatchRules.classifierVersion,
      coverageRatio: coverageRatio,
      coveredSeconds: coveredSeconds,
      batchDurationSeconds: batchDurationSeconds,
      largestUncoveredGapSeconds: largestUncoveredGapSeconds,
      screenshotCount: ordered.count,
      sampledIdleScreenshotCount: idleSamples.count,
      qualifiedIdleScreenshotCount: qualifiedIdleScreenshotCount,
      qualifiedIdleRatio: qualifiedIdleRatio,
      idleSampleAvailabilityRatio: idleSampleAvailabilityRatio,
      minIdleSecondsAtCapture: sortedIdleValues.first ?? 0,
      medianIdleSecondsAtCapture: sortedIdleValues[sortedIdleValues.count / 2],
      averageIdleSecondsAtCapture: averageIdleSeconds,
      maxIdleSecondsAtCapture: idleValues.max() ?? 0
    )
  }

  static func makeIdleCard(
    from startDate: Date,
    to endDate: Date,
    metadata: IdleCardMetadata
  ) -> TimelineCardShell {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    let detailedSummary =
      "Idle period. Dayflow skipped activity summarization for this block."

    return TimelineCardShell(
      startTimestamp: formatter.string(from: startDate),
      endTimestamp: formatter.string(from: endDate),
      category: "Idle",
      subcategory: "",
      title: "Idle",
      summary: "You were idle during this period.",
      detailedSummary: detailedSummary,
      distractions: nil,
      appSites: nil,
      idleMetadata: metadata
    )
  }

  private static func mergeCoverageSegments(
    idleSamples: [(capturedAt: Int, idleSeconds: Int)],
    batchStartTs: Int,
    batchEndTs: Int
  ) -> [(start: Int, end: Int)] {
    let clipped = idleSamples.compactMap { sample -> (start: Int, end: Int)? in
      let start = max(batchStartTs, sample.capturedAt - sample.idleSeconds)
      let end = min(batchEndTs, sample.capturedAt)
      guard end > start else { return nil }
      return (start, end)
    }.sorted { lhs, rhs in
      if lhs.start == rhs.start {
        return lhs.end < rhs.end
      }
      return lhs.start < rhs.start
    }

    guard let first = clipped.first else { return [] }

    var merged: [(start: Int, end: Int)] = [first]
    for segment in clipped.dropFirst() {
      var last = merged.removeLast()
      if segment.start <= last.end {
        last.end = max(last.end, segment.end)
        merged.append(last)
      } else {
        merged.append(last)
        merged.append(segment)
      }
    }
    return merged
  }

  private static func invertedCoverageSegments(
    _ mergedCoverage: [(start: Int, end: Int)],
    batchStartTs: Int,
    batchEndTs: Int
  ) -> [(start: Int, end: Int)] {
    guard batchEndTs > batchStartTs else { return [] }
    guard mergedCoverage.isEmpty == false else { return [(batchStartTs, batchEndTs)] }

    var gaps: [(start: Int, end: Int)] = []
    var cursor = batchStartTs

    for segment in mergedCoverage {
      if segment.start > cursor {
        gaps.append((cursor, segment.start))
      }
      cursor = max(cursor, segment.end)
    }

    if cursor < batchEndTs {
      gaps.append((cursor, batchEndTs))
    }

    return gaps
  }
}
