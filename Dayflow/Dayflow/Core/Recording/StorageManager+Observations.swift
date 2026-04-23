import Foundation
import GRDB
import Sentry

extension StorageManager {
  func saveObservations(batchId: Int64, observations: [Observation]) {
    guard !observations.isEmpty else { return }
    try? timedWrite("saveObservations(\(observations.count)_items)") { db in
      for obs in observations {
        try db.execute(
          sql: """
                INSERT INTO observations(
                    batch_id, start_ts, end_ts, observation, metadata, llm_model
                )
                VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            batchId, obs.startTs, obs.endTs, obs.observation,
            obs.metadata, obs.llmModel,
          ])
      }
    }
  }

  func fetchObservations(batchId: Int64) -> [Observation] {
    (try? timedRead("fetchObservations(batchId)") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM observations 
              WHERE batch_id = ? 
              ORDER BY start_ts ASC
          """, arguments: [batchId]
      ).map { row in
        Observation(
          id: row["id"],
          batchId: row["batch_id"],
          startTs: row["start_ts"],
          endTs: row["end_ts"],
          observation: row["observation"],
          metadata: row["metadata"],
          llmModel: row["llm_model"],
          createdAt: row["created_at"]
        )
      }
    }) ?? []
  }

  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation] {
    let fromTs = Int(from.timeIntervalSince1970)
    let toTs = Int(to.timeIntervalSince1970)

    return
      (try? db.read { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT * FROM observations 
                WHERE (start_ts < ? AND end_ts > ?) 
                   OR (start_ts >= ? AND start_ts < ?)
                ORDER BY start_ts ASC
            """, arguments: [toTs, fromTs, fromTs, toTs]
        ).map { row in
          Observation(
            id: row["id"],
            batchId: row["batch_id"],
            startTs: row["start_ts"],
            endTs: row["end_ts"],
            observation: row["observation"],
            metadata: row["metadata"],
            llmModel: row["llm_model"],
            createdAt: row["created_at"]
          )
        }
      }) ?? []
  }

  func updateBatch(_ batchId: Int64, status: String, reason: String? = nil) {
    try? db.write { db in
      let sql = """
            UPDATE analysis_batches
            SET status = ?, reason = ?
            WHERE id = ?
        """
      try db.execute(sql: sql, arguments: [status, reason, batchId])
    }
  }

  var dateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  func insertLLMCall(_ rec: LLMCallDBRecord) {
    try? db.write { db in
      try db.execute(
        sql: """
              INSERT INTO llm_calls (
                  batch_id, call_group_id, attempt, provider, model, operation,
                  status, latency_ms, http_status, request_method, request_url,
                  request_headers, request_body, response_headers, response_body,
                  error_domain, error_code, error_message
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          rec.batchId,
          rec.callGroupId,
          rec.attempt,
          rec.provider,
          rec.model,
          rec.operation,
          rec.status,
          rec.latencyMs,
          rec.httpStatus,
          rec.requestMethod,
          rec.requestURL,
          rec.requestHeadersJSON,
          rec.requestBody,
          rec.responseHeadersJSON,
          rec.responseBody,
          rec.errorDomain,
          rec.errorCode,
          rec.errorMessage,
        ])
    }
  }

  func fetchObservations(startTs: Int, endTs: Int) -> [Observation] {
    (try? db.read { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM observations 
              WHERE start_ts >= ? AND end_ts <= ?
              ORDER BY start_ts ASC
          """, arguments: [startTs, endTs]
      ).map { row in
        Observation(
          id: row["id"],
          batchId: row["batch_id"],
          startTs: row["start_ts"],
          endTs: row["end_ts"],
          observation: row["observation"],
          metadata: row["metadata"],
          llmModel: row["llm_model"],
          createdAt: row["created_at"]
        )
      }
    }) ?? []
  }

  func getTimestampsForVideoFiles(paths: [String]) -> [String: (startTs: Int, endTs: Int)] {
    guard !paths.isEmpty else { return [:] }
    var out: [String: (Int, Int)] = [:]
    let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
    let sql =
      "SELECT file_url, start_ts, end_ts FROM chunks WHERE file_url IN (\(placeholders)) AND (is_deleted = 0 OR is_deleted IS NULL)"
    try? db.read { db in
      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(paths))
      for row in rows {
        if let path: String = row["file_url"],
          let start: Int = row["start_ts"],
          let end: Int = row["end_ts"]
        {
          out[path] = (start, end)
        }
      }
    }
    return out
  }

}
