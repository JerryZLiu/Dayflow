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
}
