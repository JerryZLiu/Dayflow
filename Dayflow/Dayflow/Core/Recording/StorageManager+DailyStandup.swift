import Foundation
import GRDB
import Sentry

extension StorageManager {
  // MARK: - Daily Standup Methods

  /// Locale-safe standup day key in YYYY-MM-DD format.
  /// Uses Gregorian calendar + POSIX locale to avoid locale/calendar-induced drift.
  func dailyStandupDayKey(for date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent)
    -> String
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  func fetchDailyStandup(forDay standupDay: String) -> DailyStandupEntry? {
    return try? timedRead("fetchDailyStandup(forDay:\(standupDay))") { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT standup_day, payload_json, created_at, updated_at
                FROM daily_standup_entries
                WHERE standup_day = ?
            """, arguments: [standupDay])
      else {
        return nil
      }

      return DailyStandupEntry(
        standupDay: row["standup_day"],
        payloadJSON: row["payload_json"],
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
      )
    }
  }

  /// Returns the maximum standup_day currently stored, or nil when no standups exist.
  /// Uses standup_day ordering (yyyy-MM-dd), not updated_at, to avoid old-day regenerations
  /// affecting the scheduler anchor.
  func fetchLatestDailyStandupDay() -> String? {
    return try? timedRead("fetchLatestDailyStandupDay") { db in
      try String.fetchOne(
        db,
        sql: """
              SELECT standup_day
              FROM daily_standup_entries
              ORDER BY standup_day DESC
              LIMIT 1
          """)
    }
  }

  func fetchRecentDailyStandups(limit: Int, excludingDay: String? = nil) -> [DailyStandupEntry] {
    guard limit > 0 else { return [] }

    return
      (try? timedRead("fetchRecentDailyStandups(limit:\(limit))") { db in
        let rows: [Row]
        if let excludingDay, !excludingDay.isEmpty {
          rows = try Row.fetchAll(
            db,
            sql: """
                  SELECT standup_day, payload_json, created_at, updated_at
                  FROM daily_standup_entries
                  WHERE standup_day != ?
                  ORDER BY updated_at DESC
                  LIMIT ?
              """, arguments: [excludingDay, limit])
        } else {
          rows = try Row.fetchAll(
            db,
            sql: """
                  SELECT standup_day, payload_json, created_at, updated_at
                  FROM daily_standup_entries
                  ORDER BY updated_at DESC
                  LIMIT ?
              """, arguments: [limit])
        }

        return rows.map { row in
          DailyStandupEntry(
            standupDay: row["standup_day"],
            payloadJSON: row["payload_json"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
          )
        }
      }) ?? []
  }

  func saveDailyStandup(forDay standupDay: String, payloadJSON: String) {
    try? timedWrite("saveDailyStandup") { db in
      try db.execute(
        sql: """
              INSERT INTO daily_standup_entries (standup_day, payload_json, updated_at)
              VALUES (?, ?, CURRENT_TIMESTAMP)
              ON CONFLICT(standup_day) DO UPDATE SET
                  payload_json = excluded.payload_json,
                  updated_at = CURRENT_TIMESTAMP
          """, arguments: [standupDay, payloadJSON])
    }
  }

}
