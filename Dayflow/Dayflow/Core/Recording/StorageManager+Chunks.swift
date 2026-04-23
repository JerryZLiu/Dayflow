import Foundation
import GRDB
import Sentry

extension StorageManager {
  func nextFileURL() -> URL {
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd_HHmmssSSS"
    return root.appendingPathComponent("\(df.string(from: Date())).mp4")
  }

  func registerChunk(url: URL) {
    let ts = Int(Date().timeIntervalSince1970)
    let path = url.path

    // Perform database write asynchronously to avoid blocking caller thread
    dbWriteQueue.async { [weak self] in
      try? self?.timedWrite("registerChunk") { db in
        try db.execute(
          sql:
            "INSERT INTO chunks(start_ts, end_ts, file_url, status) VALUES (?, ?, ?, 'recording')",
          arguments: [ts, ts + 60, path])
      }
    }
  }

  func markChunkCompleted(url: URL) {
    let end = Int(Date().timeIntervalSince1970)
    let path = url.path

    // Perform database write asynchronously to avoid blocking caller thread
    dbWriteQueue.async { [weak self] in
      try? self?.timedWrite("markChunkCompleted") { db in
        try db.execute(
          sql: "UPDATE chunks SET end_ts = ?, status = 'completed' WHERE file_url = ?",
          arguments: [end, path])
      }
    }
  }

  func markChunkFailed(url: URL) {
    let path = url.path

    // Perform database write and file deletion asynchronously to avoid blocking caller thread
    dbWriteQueue.async { [weak self] in
      guard let self = self else { return }

      try? self.timedWrite("markChunkFailed") { db in
        try db.execute(sql: "DELETE FROM chunks WHERE file_url = ?", arguments: [path])
      }

      try? self.fileMgr.removeItem(at: url)
    }
  }

  func fetchUnprocessedChunks(olderThan oldestAllowed: Int) -> [RecordingChunk] {
    (try? timedRead("fetchUnprocessedChunks") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM chunks
              WHERE start_ts >= ?
                AND status = 'completed'
                AND (is_deleted = 0 OR is_deleted IS NULL)
                AND id NOT IN (SELECT chunk_id FROM batch_chunks)
              ORDER BY start_ts ASC
          """, arguments: [oldestAllowed]
      )
      .map { row in
        RecordingChunk(
          id: row["id"], startTs: row["start_ts"], endTs: row["end_ts"], fileUrl: row["file_url"],
          status: row["status"])
      }
    }) ?? []
  }

  func saveBatch(startTs: Int, endTs: Int, chunkIds: [Int64]) -> Int64? {
    guard !chunkIds.isEmpty else { return nil }
    var batchID: Int64 = 0
    try? timedWrite("saveBatch(\(chunkIds.count)_chunks)") { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts) VALUES (?, ?)",
        arguments: [startTs, endTs])
      batchID = db.lastInsertedRowID
      for id in chunkIds {
        try db.execute(
          sql: "INSERT INTO batch_chunks(batch_id, chunk_id) VALUES (?, ?)",
          arguments: [batchID, id])
      }
    }
    return batchID == 0 ? nil : batchID
  }

  func updateBatchStatus(batchId: Int64, status: String) {
    // Perform database write asynchronously to avoid blocking caller thread
    dbWriteQueue.async { [weak self] in
      try? self?.timedWrite("updateBatchStatus") { db in
        try db.execute(
          sql: "UPDATE analysis_batches SET status = ? WHERE id = ?", arguments: [status, batchId])
      }
    }
  }

  func markBatchFailed(batchId: Int64, reason: String) {
    // Perform database write asynchronously to avoid blocking caller thread
    dbWriteQueue.async { [weak self] in
      try? self?.timedWrite("markBatchFailed") { db in
        try db.execute(
          sql: "UPDATE analysis_batches SET status = 'failed', reason = ? WHERE id = ?",
          arguments: [reason, batchId])
      }
    }
  }

  func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall]) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(calls), let json = String(data: data, encoding: .utf8)
    else { return }
    try? timedWrite("updateBatchLLMMetadata") { db in
      try db.execute(
        sql: "UPDATE analysis_batches SET llm_metadata = ? WHERE id = ?",
        arguments: [json, batchId])
    }
  }

  func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return
      (try? timedRead("fetchBatchLLMMetadata") { db in
        if let row = try Row.fetchOne(
          db, sql: "SELECT llm_metadata FROM analysis_batches WHERE id = ?", arguments: [batchId]),
          let json: String = row["llm_metadata"],
          let data = json.data(using: .utf8)
        {
          return try decoder.decode([LLMCall].self, from: data)
        }
        return []
      }) ?? []
  }

  /// Chunks that belong to one batch, already sorted.
  func chunksForBatch(_ batchId: Int64) -> [RecordingChunk] {
    (try? db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT c.* FROM batch_chunks bc
          JOIN chunks c ON c.id = bc.chunk_id
          WHERE bc.batch_id = ?
            AND (c.is_deleted = 0 OR c.is_deleted IS NULL)
          ORDER BY c.start_ts ASC
          """, arguments: [batchId]
      ).map { r in
        RecordingChunk(
          id: r["id"], startTs: r["start_ts"], endTs: r["end_ts"],
          fileUrl: r["file_url"], status: r["status"])
      }
    }) ?? []
  }

  /// Helper to get the batch start timestamp for date calculations
  func getBatchStartTimestamp(batchId: Int64) -> Int? {
    return try? db.read { db in
      try Int.fetchOne(
        db,
        sql: """
              SELECT batch_start_ts FROM analysis_batches WHERE id = ?
          """, arguments: [batchId])
    }
  }

  /// Fetch chunks that overlap with a specific time range
  func fetchChunksInTimeRange(startTs: Int, endTs: Int) -> [RecordingChunk] {
    (try? timedRead("fetchChunksInTimeRange") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM chunks
              WHERE status = 'completed'
                AND (is_deleted = 0 OR is_deleted IS NULL)
                AND ((start_ts <= ? AND end_ts >= ?)
                     OR (start_ts >= ? AND start_ts <= ?)
                     OR (end_ts >= ? AND end_ts <= ?))
              ORDER BY start_ts ASC
          """, arguments: [endTs, startTs, startTs, endTs, startTs, endTs]
      )
      .map { r in
        RecordingChunk(
          id: r["id"], startTs: r["start_ts"], endTs: r["end_ts"],
          fileUrl: r["file_url"], status: r["status"])
      }
    }) ?? []
  }

}
