import Foundation
import GRDB
import Sentry

extension StorageManager {
  func fetchReviewRatingSegments(overlapping startTs: Int, endTs: Int)
    -> [TimelineReviewRatingSegment]
  {
    guard endTs > startTs else { return [] }

    return
      (try? timedRead("fetchReviewRatingSegments") { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT id, start_ts, end_ts, rating
                FROM timeline_review_ratings
                WHERE NOT (end_ts <= ? OR start_ts >= ?)
                ORDER BY start_ts ASC
            """, arguments: [startTs, endTs]
        ).map { row in
          TimelineReviewRatingSegment(
            id: row["id"],
            startTs: row["start_ts"],
            endTs: row["end_ts"],
            rating: row["rating"]
          )
        }
      }) ?? []
  }

  func applyReviewRating(startTs: Int, endTs: Int, rating: String) {
    guard endTs > startTs else { return }

    try? timedWrite("applyReviewRating") { db in
      let overlappingRows = try Row.fetchAll(
        db,
        sql: """
              SELECT id, start_ts, end_ts, rating
              FROM timeline_review_ratings
              WHERE NOT (end_ts <= ? OR start_ts >= ?)
              ORDER BY start_ts ASC
          """, arguments: [startTs, endTs])

      var deleteIds: [Int64] = []
      var fragments: [(start: Int, end: Int, rating: String)] = []

      for row in overlappingRows {
        let id: Int64 = row["id"]
        let existingStart: Int = row["start_ts"]
        let existingEnd: Int = row["end_ts"]
        let existingRating: String = row["rating"]

        deleteIds.append(id)

        if existingStart < startTs {
          let fragmentEnd = min(startTs, existingEnd)
          if fragmentEnd > existingStart {
            fragments.append((start: existingStart, end: fragmentEnd, rating: existingRating))
          }
        }

        if existingEnd > endTs {
          let fragmentStart = max(endTs, existingStart)
          if existingEnd > fragmentStart {
            fragments.append((start: fragmentStart, end: existingEnd, rating: existingRating))
          }
        }
      }

      if deleteIds.isEmpty == false {
        let placeholders = Array(repeating: "?", count: deleteIds.count).joined(separator: ",")
        try db.execute(
          sql: """
                DELETE FROM timeline_review_ratings
                WHERE id IN (\(placeholders))
            """, arguments: StatementArguments(deleteIds))
      }

      for fragment in fragments {
        try db.execute(
          sql: """
                INSERT INTO timeline_review_ratings (start_ts, end_ts, rating)
                VALUES (?, ?, ?)
            """, arguments: [fragment.start, fragment.end, fragment.rating])
      }

      try db.execute(
        sql: """
              INSERT INTO timeline_review_ratings (start_ts, end_ts, rating)
              VALUES (?, ?, ?)
          """, arguments: [startTs, endTs, rating])
    }
  }

  func hasAnyTimelineReviewRating() -> Bool {
    (try? timedRead("hasAnyTimelineReviewRating") { db in
      let match = try Int.fetchOne(
        db,
        sql: """
              SELECT 1
              FROM timeline_review_ratings
              LIMIT 1
          """)
      return match != nil
    }) ?? false
  }

  func hasReviewRatingInRecentTimelineDays(days: Int = 7) -> Bool {
    guard days > 0 else { return false }

    let now = Date()
    guard let windowStart = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
      return false
    }

    let windowStartTs = Int(windowStart.timeIntervalSince1970)
    let windowEndTs = Int(now.timeIntervalSince1970)

    return
      (try? timedRead("hasReviewRatingInRecentTimelineDays") { db in
        let match = try Int.fetchOne(
          db,
          sql: """
                SELECT 1
                FROM timeline_review_ratings
                WHERE end_ts > ?
                  AND start_ts < ?
                LIMIT 1
            """, arguments: [windowStartTs, windowEndTs])
        return match != nil
      }) ?? false
  }

  func fetchUnreviewedTimelineCardCount(forDay day: String, coverageThreshold: Double = 0.8) -> Int
  {
    guard let dayDate = dateFormatter.date(from: day) else { return 0 }
    let calendar = Calendar.current
    guard let dayStart = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: dayDate) else {
      return 0
    }
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    let dayStartTs = Int(dayStart.timeIntervalSince1970)
    let dayEndTs = Int(dayEnd.timeIntervalSince1970)

    let cardFetch =
      (try? timedRead("fetchUnreviewedTimelineCardCount.cards") {
        db -> (cards: [(start: Int, end: Int)], invalidCount: Int) in
        var invalidCount = 0
        let rows = try Row.fetchAll(
          db,
          sql: """
                SELECT start_ts, end_ts, category
                FROM timeline_cards
                WHERE start_ts >= ? AND start_ts < ?
                  AND is_deleted = 0
            """, arguments: [dayStartTs, dayEndTs])
        let cards = rows.compactMap { row -> (start: Int, end: Int)? in
          let category: String = row["category"]
          if category.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("System") == .orderedSame
          {
            return nil
          }
          guard let start: Int = row["start_ts"], let end: Int = row["end_ts"], end > start else {
            invalidCount += 1
            return nil
          }
          return (start: start, end: end)
        }
        return (cards, invalidCount)
      })

    let cards = cardFetch?.cards ?? []
    var unreviewedCount = cardFetch?.invalidCount ?? 0

    if cards.isEmpty {
      return unreviewedCount
    }

    let ratingSegments = fetchReviewRatingSegments(overlapping: dayStartTs, endTs: dayEndTs)
    let mergedSegments = mergeCoverageSegments(
      segments: ratingSegments,
      dayStartTs: dayStartTs,
      dayEndTs: dayEndTs
    )

    let sortedCards = cards.sorted { $0.start < $1.start }
    var segmentIndex = 0

    for card in sortedCards {
      let duration = card.end - card.start
      if duration <= 0 { continue }

      let covered = overlapSeconds(
        start: card.start,
        end: card.end,
        segments: mergedSegments,
        segmentIndex: &segmentIndex
      )
      let coverageRatio = Double(covered) / Double(duration)
      if coverageRatio < coverageThreshold {
        unreviewedCount += 1
      }
    }

    return unreviewedCount
  }

  func mergeCoverageSegments(
    segments: [TimelineReviewRatingSegment],
    dayStartTs: Int,
    dayEndTs: Int
  ) -> [(start: Int, end: Int)] {
    var clipped: [(start: Int, end: Int)] = []
    clipped.reserveCapacity(segments.count)

    for segment in segments {
      let start = max(segment.startTs, dayStartTs)
      let end = min(segment.endTs, dayEndTs)
      if end > start {
        clipped.append((start: start, end: end))
      }
    }

    guard clipped.isEmpty == false else { return [] }
    clipped.sort { $0.start < $1.start }

    var merged: [(start: Int, end: Int)] = [clipped[0]]
    for segment in clipped.dropFirst() {
      var last = merged[merged.count - 1]
      if segment.start <= last.end {
        last.end = max(last.end, segment.end)
        merged[merged.count - 1] = last
      } else {
        merged.append(segment)
      }
    }
    return merged
  }

  func overlapSeconds(
    start: Int,
    end: Int,
    segments: [(start: Int, end: Int)],
    segmentIndex: inout Int
  ) -> Int {
    guard end > start else { return 0 }

    while segmentIndex < segments.count, segments[segmentIndex].end <= start {
      segmentIndex += 1
    }

    var covered = 0
    var index = segmentIndex

    while index < segments.count, segments[index].start < end {
      let overlapStart = max(start, segments[index].start)
      let overlapEnd = min(end, segments[index].end)
      if overlapEnd > overlapStart {
        covered += overlapEnd - overlapStart
      }
      if segments[index].end <= end {
        index += 1
      } else {
        break
      }
    }

    return covered
  }

}
