import Foundation
import GRDB
import Sentry

extension StorageManager {
  func deleteTimelineCards(forDay day: String) -> [String] {
    var videoPaths: [String] = []

    guard let dayDate = dateFormatter.date(from: day) else {
      return []
    }

    let calendar = Calendar.current

    // Get 4 AM of the given day as the start
    var startComponents = calendar.dateComponents([.year, .month, .day], from: dayDate)
    startComponents.hour = 4
    startComponents.minute = 0
    startComponents.second = 0
    guard let dayStart = calendar.date(from: startComponents) else { return [] }

    // Get 4 AM of the next day as the end
    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayDate) else { return [] }
    var endComponents = calendar.dateComponents([.year, .month, .day], from: nextDay)
    endComponents.hour = 4
    endComponents.minute = 0
    endComponents.second = 0
    guard let dayEnd = calendar.date(from: endComponents) else { return [] }

    let startTs = Int(dayStart.timeIntervalSince1970)
    let endTs = Int(dayEnd.timeIntervalSince1970)

    try? timedWrite("deleteTimelineCards(forDay:\(day))") { db in
      // First fetch all video paths before soft deletion
      let rows = try Row.fetchAll(
        db,
        sql: """
              SELECT video_summary_url FROM timeline_cards
              WHERE start_ts >= ? AND start_ts < ?
                AND video_summary_url IS NOT NULL
                AND is_deleted = 0
          """, arguments: [startTs, endTs])

      videoPaths = rows.compactMap { $0["video_summary_url"] as? String }

      // Soft delete the timeline cards by setting is_deleted = 1
      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET is_deleted = 1
              WHERE start_ts >= ? AND start_ts < ?
                AND is_deleted = 0
          """, arguments: [startTs, endTs])
    }

    return videoPaths
  }

  func deleteTimelineCards(forBatchIds batchIds: [Int64]) -> [String] {
    guard !batchIds.isEmpty else { return [] }
    var videoPaths: [String] = []
    let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ",")

    do {
      try timedWrite("deleteTimelineCards(forBatchIds:\(batchIds.count))") { db in
        // Fetch video paths for active records only
        let rows = try Row.fetchAll(
          db,
          sql: """
                SELECT video_summary_url
                FROM timeline_cards
                WHERE batch_id IN (\(placeholders))
                  AND video_summary_url IS NOT NULL
                  AND is_deleted = 0
            """,
          arguments: StatementArguments(batchIds)
        )

        videoPaths = rows.compactMap { $0["video_summary_url"] as? String }

        // Soft delete the records
        try db.execute(
          sql: """
                UPDATE timeline_cards
                SET is_deleted = 1
                WHERE batch_id IN (\(placeholders))
                  AND is_deleted = 0
            """,
          arguments: StatementArguments(batchIds)
        )
      }
    } catch {
      print("deleteTimelineCards(forBatchIds:) failed: \(error)")
    }

    return videoPaths
  }

  func deleteObservations(forBatchIds batchIds: [Int64]) {
    guard !batchIds.isEmpty else { return }

    try? db.write { db in
      let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ",")
      try db.execute(
        sql: """
              DELETE FROM observations WHERE batch_id IN (\(placeholders))
          """, arguments: StatementArguments(batchIds))
    }
  }

  func resetBatchStatuses(forDay day: String) -> [Int64] {
    var affectedBatchIds: [Int64] = []

    // Calculate day boundaries (4 AM to 4 AM)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    guard let dayDate = formatter.date(from: day) else { return [] }

    let calendar = Calendar.current
    guard let startOfDay = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: dayDate) else {
      return []
    }
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

    let startTs = Int(startOfDay.timeIntervalSince1970)
    let endTs = Int(endOfDay.timeIntervalSince1970)

    try? db.write { db in
      // Fetch batch IDs first
      let rows = try Row.fetchAll(
        db,
        sql: """
              SELECT id FROM analysis_batches
              WHERE batch_start_ts >= ? AND batch_end_ts <= ?
                AND status IN ('completed', 'failed', 'processing', 'analyzed')
          """, arguments: [startTs, endTs])

      affectedBatchIds = rows.compactMap { $0["id"] as? Int64 }

      // Reset their status to pending
      if !affectedBatchIds.isEmpty {
        let placeholders = Array(repeating: "?", count: affectedBatchIds.count).joined(
          separator: ",")
        try db.execute(
          sql: """
                UPDATE analysis_batches
                SET status = 'pending', reason = NULL, llm_metadata = NULL
                WHERE id IN (\(placeholders))
            """, arguments: StatementArguments(affectedBatchIds))
      }
    }

    return affectedBatchIds
  }

  func resetBatchStatuses(forBatchIds batchIds: [Int64]) -> [Int64] {
    guard !batchIds.isEmpty else { return [] }
    var affectedBatchIds: [Int64] = []
    let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ",")

    do {
      try timedWrite("resetBatchStatuses(forBatchIds:\(batchIds.count))") { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
                SELECT id FROM analysis_batches
                WHERE id IN (\(placeholders))
            """,
          arguments: StatementArguments(batchIds)
        )

        affectedBatchIds = rows.compactMap { $0["id"] as? Int64 }
        guard !affectedBatchIds.isEmpty else { return }

        let affectedPlaceholders = Array(repeating: "?", count: affectedBatchIds.count).joined(
          separator: ",")
        try db.execute(
          sql: """
                UPDATE analysis_batches
                SET status = 'pending', reason = NULL, llm_metadata = NULL
                WHERE id IN (\(affectedPlaceholders))
            """,
          arguments: StatementArguments(affectedBatchIds)
        )
      }
    } catch {
      print("resetBatchStatuses(forBatchIds:) failed: \(error)")
    }

    return affectedBatchIds
  }

  func fetchBatches(forDay day: String) -> [(id: Int64, startTs: Int, endTs: Int, status: String)] {
    // Calculate day boundaries (4 AM to 4 AM)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    guard let dayDate = formatter.date(from: day) else { return [] }

    let calendar = Calendar.current
    guard let startOfDay = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: dayDate) else {
      return []
    }
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

    let startTs = Int(startOfDay.timeIntervalSince1970)
    let endTs = Int(endOfDay.timeIntervalSince1970)

    return
      (try? db.read { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT id, batch_start_ts, batch_end_ts, status FROM analysis_batches
                WHERE batch_start_ts >= ? AND batch_end_ts <= ?
                ORDER BY batch_start_ts ASC
            """, arguments: [startTs, endTs]
        ).map { row in
          (
            id: row["id"] as? Int64 ?? 0,
            startTs: Int(row["batch_start_ts"] as? Int64 ?? 0),
            endTs: Int(row["batch_end_ts"] as? Int64 ?? 0),
            status: row["status"] as? String ?? ""
          )
        }
      }) ?? []
  }

}
