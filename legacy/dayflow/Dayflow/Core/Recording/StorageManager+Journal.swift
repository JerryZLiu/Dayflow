import Foundation
import GRDB
import Sentry

extension StorageManager {
  // MARK: - Journal Entry Methods

  /// Fetch journal entry for a specific day (using 4AM boundary format)
  func fetchJournalEntry(forDay day: String) -> JournalEntry? {
    return try? timedRead("fetchJournalEntry(forDay:\(day))") { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT * FROM journal_entries WHERE day = ?
            """, arguments: [day])
      else { return nil }

      return JournalEntry(
        id: row["id"],
        day: row["day"],
        intentions: row["intentions"],
        notes: row["notes"],
        goals: row["goals"],
        reflections: row["reflections"],
        summary: row["summary"],
        status: row["status"] ?? "draft",
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
      )
    }
  }

  /// Save or update a journal entry (upsert)
  func saveJournalEntry(_ entry: JournalEntry) {
    try? timedWrite("saveJournalEntry") { db in
      try db.execute(
        sql: """
              INSERT INTO journal_entries (day, intentions, notes, goals, reflections, summary, status, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
              ON CONFLICT(day) DO UPDATE SET
                  intentions = excluded.intentions,
                  notes = excluded.notes,
                  goals = excluded.goals,
                  reflections = excluded.reflections,
                  summary = excluded.summary,
                  status = excluded.status,
                  updated_at = CURRENT_TIMESTAMP
          """,
        arguments: [
          entry.day,
          entry.intentions,
          entry.notes,
          entry.goals,
          entry.reflections,
          entry.summary,
          entry.status,
        ])
    }
  }

  /// Update just the intentions/notes/goals fields (morning form)
  func updateJournalIntentions(day: String, intentions: String?, notes: String?, goals: String?) {
    try? timedWrite("updateJournalIntentions") { db in
      // Check if entry exists
      let exists =
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM journal_entries WHERE day = ?", arguments: [day]) ?? 0

      if exists > 0 {
        try db.execute(
          sql: """
                UPDATE journal_entries
                SET intentions = ?, notes = ?, goals = ?, status = 'intentions_set', updated_at = CURRENT_TIMESTAMP
                WHERE day = ?
            """, arguments: [intentions, notes, goals, day])
      } else {
        try db.execute(
          sql: """
                INSERT INTO journal_entries (day, intentions, notes, goals, status)
                VALUES (?, ?, ?, ?, 'intentions_set')
            """, arguments: [day, intentions, notes, goals])
      }
    }
  }

  /// Update just the reflections field (evening reflection)
  func updateJournalReflections(day: String, reflections: String?) {
    try? timedWrite("updateJournalReflections") { db in
      let exists =
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM journal_entries WHERE day = ?", arguments: [day]) ?? 0

      if exists > 0 {
        try db.execute(
          sql: """
                UPDATE journal_entries
                SET reflections = ?, updated_at = CURRENT_TIMESTAMP
                WHERE day = ?
            """, arguments: [reflections, day])
      } else {
        try db.execute(
          sql: """
                INSERT INTO journal_entries (day, reflections, status)
                VALUES (?, ?, 'draft')
            """, arguments: [day, reflections])
      }
    }
  }

  /// Update just the AI summary field
  func updateJournalSummary(day: String, summary: String?) {
    try? timedWrite("updateJournalSummary") { db in
      let exists =
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM journal_entries WHERE day = ?", arguments: [day]) ?? 0

      if exists > 0 {
        try db.execute(
          sql: """
                UPDATE journal_entries
                SET summary = ?, status = 'complete', updated_at = CURRENT_TIMESTAMP
                WHERE day = ?
            """, arguments: [summary, day])
      } else {
        try db.execute(
          sql: """
                INSERT INTO journal_entries (day, summary, status)
                VALUES (?, ?, 'complete')
            """, arguments: [day, summary])
      }
    }
  }

  /// Fetch the most recent journal summary within the last N days
  /// Returns the day string and summary text, or nil if none found
  func fetchRecentJournalSummary(withinDays days: Int) -> (day: String, summary: String)? {
    let calendar = Calendar.current
    let today = Date()
    guard let cutoffDate = calendar.date(byAdding: .day, value: -days, to: today) else {
      return nil
    }
    let cutoffDay = DateFormatter.yyyyMMdd.string(from: cutoffDate)

    return try? timedRead("fetchRecentJournalSummary") { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT day, summary FROM journal_entries
                WHERE summary IS NOT NULL AND summary != ''
                  AND day >= ?
                ORDER BY day DESC
                LIMIT 1
            """, arguments: [cutoffDay])
      else { return nil }

      guard let day: String = row["day"],
        let summary: String = row["summary"]
      else { return nil }

      return (day, summary)
    }
  }

  /// Fetch the most recent N journal summaries, optionally excluding a specific day
  /// Returns array of (day, summary) tuples ordered by most recent first
  func fetchRecentJournalSummaries(count: Int, excludingDay: String? = nil) -> [(
    day: String, summary: String
  )] {
    return
      (try? timedRead("fetchRecentJournalSummaries") { db in
        var sql = """
              SELECT day, summary FROM journal_entries
              WHERE summary IS NOT NULL AND summary != ''
          """
        var arguments: [String] = []

        if let excludeDay = excludingDay {
          sql += " AND day != ?"
          arguments.append(excludeDay)
        }

        sql += " ORDER BY day DESC LIMIT ?"
        arguments.append(String(count))

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        return rows.compactMap { row -> (day: String, summary: String)? in
          guard let day: String = row["day"],
            let summary: String = row["summary"]
          else { return nil }
          return (day, summary)
        }
      }) ?? []
  }

  /// Check if a day has intentions set (not just draft)
  func hasIntentionsForDay(_ day: String) -> Bool {
    return
      (try? timedRead("hasIntentionsForDay") { db in
        let count =
          try Int.fetchOne(
            db,
            sql: """
                  SELECT COUNT(*) FROM journal_entries
                  WHERE day = ? AND status IN ('intentions_set', 'complete')
              """, arguments: [day]) ?? 0
        return count > 0
      }) ?? false
  }

  /// Fetch the most recent long-term goals from any previous journal entry
  func fetchMostRecentGoals() -> String? {
    return try? timedRead("fetchMostRecentGoals") { db in
      let row = try Row.fetchOne(
        db,
        sql: """
              SELECT goals FROM journal_entries
              WHERE goals IS NOT NULL AND goals != ''
              ORDER BY day DESC
              LIMIT 1
          """)
      return row?["goals"]
    }
  }

  /// Check if a day has at least 1 hour of timeline activity
  func hasMinimumTimelineActivity(forDay day: String, minimumMinutes: Int = 60) -> Bool {
    guard let dayDate = dateFormatter.date(from: day) else { return false }

    let calendar = Calendar.current

    // Get 4 AM boundaries
    var startComponents = calendar.dateComponents([.year, .month, .day], from: dayDate)
    startComponents.hour = 4
    startComponents.minute = 0
    startComponents.second = 0
    guard let dayStart = calendar.date(from: startComponents) else { return false }

    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayDate) else { return false }
    var endComponents = calendar.dateComponents([.year, .month, .day], from: nextDay)
    endComponents.hour = 4
    endComponents.minute = 0
    endComponents.second = 0
    guard let dayEnd = calendar.date(from: endComponents) else { return false }

    let startTs = Int(dayStart.timeIntervalSince1970)
    let endTs = Int(dayEnd.timeIntervalSince1970)

    // Sum total duration of timeline cards for the day
    let totalMinutes: Int? = try? timedRead("hasMinimumTimelineActivity") { db in
      // Calculate sum of (end_ts - start_ts) for all cards, converted to minutes
      let result = try Int.fetchOne(
        db,
        sql: """
              SELECT COALESCE(SUM(end_ts - start_ts), 0) / 60 as total_minutes
              FROM timeline_cards
              WHERE start_ts >= ? AND start_ts < ?
                AND is_deleted = 0
          """, arguments: [startTs, endTs])
      return result
    }

    return (totalMinutes ?? 0) >= minimumMinutes
  }

  /// Fetch list of days that have journal entries (for navigation)
  func fetchJournalDays(limit: Int = 30) -> [String] {
    return
      (try? timedRead("fetchJournalDays") { db in
        try String.fetchAll(
          db,
          sql: """
                SELECT day FROM journal_entries
                ORDER BY day DESC
                LIMIT ?
            """, arguments: [limit])
      }) ?? []
  }

}
