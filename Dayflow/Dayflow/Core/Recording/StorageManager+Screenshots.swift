import Foundation
import GRDB
import Sentry

extension StorageManager {
  // MARK: - Screenshot Management (new - replaces video chunks)

  func nextScreenshotURL() -> URL {
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd_HHmmssSSS"
    return root.appendingPathComponent("\(df.string(from: Date())).jpg")
  }

  func saveScreenshot(url: URL, capturedAt: Date, idleSecondsAtCapture: Int?) -> Int64? {
    let timestamp = Int(capturedAt.timeIntervalSince1970)
    let path = url.path
    let fileSize: Int64? = {
      if let attrs = try? fileMgr.attributesOfItem(atPath: path),
        let size = attrs[.size] as? NSNumber
      {
        return size.int64Value
      }
      return nil
    }()

    var screenshotId: Int64?
    try? timedWrite("saveScreenshot") { db in
      try db.execute(
        sql: """
              INSERT INTO screenshots(captured_at, file_path, file_size, idle_seconds_at_capture)
              VALUES (?, ?, ?, ?)
          """, arguments: [timestamp, path, fileSize, idleSecondsAtCapture])
      screenshotId = db.lastInsertedRowID
    }
    return screenshotId
  }

  func screenshot(from row: Row) -> Screenshot {
    Screenshot(
      id: row["id"],
      capturedAt: row["captured_at"],
      filePath: row["file_path"],
      fileSize: row["file_size"],
      idleSecondsAtCapture: row["idle_seconds_at_capture"],
      isDeleted: (row["is_deleted"] as? Int ?? 0) != 0
    )
  }

  func fetchUnprocessedScreenshots(since oldestTimestamp: Int) -> [Screenshot] {
    (try? timedRead("fetchUnprocessedScreenshots") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM screenshots
              WHERE captured_at >= ?
                AND is_deleted = 0
                AND id NOT IN (SELECT screenshot_id FROM batch_screenshots)
              ORDER BY captured_at ASC
          """, arguments: [oldestTimestamp]
      )
      .map(screenshot(from:))
    }) ?? []
  }

  func saveBatchWithScreenshots(startTs: Int, endTs: Int, screenshotIds: [Int64]) -> Int64? {
    guard !screenshotIds.isEmpty else { return nil }
    var batchId: Int64 = 0

    try? timedWrite("saveBatchWithScreenshots(\(screenshotIds.count))") { db in
      try db.execute(
        sql: """
              INSERT INTO analysis_batches(batch_start_ts, batch_end_ts)
              VALUES (?, ?)
          """, arguments: [startTs, endTs])
      batchId = db.lastInsertedRowID

      for id in screenshotIds {
        try db.execute(
          sql: """
                INSERT INTO batch_screenshots(batch_id, screenshot_id)
                VALUES (?, ?)
            """, arguments: [batchId, id])
      }
    }
    return batchId == 0 ? nil : batchId
  }

  func screenshotsForBatch(_ batchId: Int64) -> [Screenshot] {
    (try? timedRead("screenshotsForBatch") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT s.* FROM batch_screenshots bs
              JOIN screenshots s ON s.id = bs.screenshot_id
              WHERE bs.batch_id = ?
                AND s.is_deleted = 0
              ORDER BY s.captured_at ASC
          """, arguments: [batchId]
      )
      .map(screenshot(from:))
    }) ?? []
  }

  func fetchScreenshotsInTimeRange(startTs: Int, endTs: Int) -> [Screenshot] {
    (try? timedRead("fetchScreenshotsInTimeRange") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM screenshots
              WHERE captured_at >= ? AND captured_at <= ?
                AND is_deleted = 0
              ORDER BY captured_at ASC
          """, arguments: [startTs, endTs]
      )
      .map(screenshot(from:))
    }) ?? []
  }

}
