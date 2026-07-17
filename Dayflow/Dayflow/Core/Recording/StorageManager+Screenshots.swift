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

  func importedScreenshotURL(for metadata: CaptureImportMetadata) throws -> URL {
    let safeDeviceId = safeCapturePathComponent(metadata.deviceId)
    let safeCaptureId = safeCapturePathComponent(metadata.captureId)
    guard !safeDeviceId.isEmpty, !safeCaptureId.isEmpty else {
      throw CocoaError(.fileWriteInvalidFileName)
    }

    let date = Date(timeIntervalSince1970: TimeInterval(metadata.capturedAtUTCMS) / 1000)
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: metadata.timezoneId) ?? .current
    formatter.dateFormat = "yyyy-MM-dd"
    let day = formatter.string(from: date)

    formatter.dateFormat = "yyyyMMdd_HHmmssSSS"
    let timestamp = formatter.string(from: date)
    let sequenceSuffix = metadata.sequence.map { String(format: "s%06lld", $0) }
      ?? "c\(safeCaptureId)"

    let directory = root
      .appendingPathComponent("android", isDirectory: true)
      .appendingPathComponent(safeDeviceId, isDirectory: true)
      .appendingPathComponent(day, isDirectory: true)
    try fileMgr.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(timestamp)_\(sequenceSuffix).jpg")
  }

  func existingCaptureIds(deviceId: String, captureIds: [String]) -> Set<String> {
    guard !captureIds.isEmpty else { return [] }
    return (try? timedRead("existingCaptureIds") { db in
      let placeholders = Array(repeating: "?", count: captureIds.count).joined(separator: ",")
      var arguments: [(any DatabaseValueConvertible)?] = [deviceId]
      arguments.append(contentsOf: captureIds)
      let values = try String.fetchAll(
        db,
        sql: """
              SELECT capture_id FROM screenshots
              WHERE device_id = ? AND capture_id IN (\(placeholders))
          """,
        arguments: StatementArguments(arguments)
      )
      return Set(values)
    }) ?? []
  }

  private func safeCapturePathComponent(_ value: String) -> String {
    value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
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
              INSERT INTO screenshots(
                captured_at, file_path, file_size, idle_seconds_at_capture,
                device_id, source_platform, timezone_id, utc_offset_seconds,
                orientation, capture_kind
              )
              VALUES (?, ?, ?, ?, ?, 'macos', ?, ?, 'unknown', 'image')
          """,
        arguments: [
          timestamp, path, fileSize, idleSecondsAtCapture, LocalCaptureDevice.id,
          TimeZone.current.identifier, TimeZone.current.secondsFromGMT(for: capturedAt),
        ])
      screenshotId = db.lastInsertedRowID
    }
    return screenshotId
  }

  func saveImportedScreenshot(url: URL, metadata: CaptureImportMetadata) throws -> Int64 {
    let storedFileSize = metadata.byteLength ?? {
      let attributes = try? fileMgr.attributesOfItem(atPath: url.path)
      return (attributes?[.size] as? NSNumber)?.int64Value
    }()

    return try insertImportedCapture(
      filePath: url.path,
      fileSize: storedFileSize,
      metadata: metadata
    )
  }

  func saveImportedCapture(metadata: CaptureImportMetadata) throws -> Int64 {
    guard metadata.kind == .redacted else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return try insertImportedCapture(filePath: "", fileSize: nil, metadata: metadata)
  }

  private func insertImportedCapture(
    filePath: String,
    fileSize: Int64?,
    metadata: CaptureImportMetadata
  ) throws -> Int64 {
    let timestamp = Int(metadata.capturedAtUTCMS / 1000)

    return try timedWrite("saveImportedScreenshot") { db in
      if let existing = try Int64.fetchOne(
        db,
        sql: "SELECT id FROM screenshots WHERE device_id = ? AND capture_id = ?",
        arguments: [metadata.deviceId, metadata.captureId]
      ) {
        return existing
      }

      try db.execute(
        sql: """
              INSERT INTO screenshots(
                captured_at, file_path, file_size, idle_seconds_at_capture,
                capture_id, device_id, source_platform, session_id, sequence,
                timezone_id, utc_offset_seconds, foreground_app_id, foreground_app_name,
                orientation, pixel_width, pixel_height, capture_kind, content_sha256,
                received_at
              ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          timestamp, filePath, fileSize, metadata.captureId, metadata.deviceId,
          metadata.platform.rawValue, metadata.sessionId, metadata.sequence,
          metadata.timezoneId, metadata.utcOffsetSeconds, metadata.foregroundAppId,
          metadata.foregroundAppName, metadata.orientation.rawValue, metadata.pixelWidth,
          metadata.pixelHeight, metadata.kind.rawValue, metadata.sha256,
          Int(Date().timeIntervalSince1970),
        ]
      )
      return db.lastInsertedRowID
    }
  }

  func screenshot(from row: Row) -> Screenshot {
    let platformRaw: String = row["source_platform"] ?? CapturePlatform.macOS.rawValue
    let orientationRaw: String = row["orientation"] ?? CaptureOrientation.unknown.rawValue
    let kindRaw: String = row["capture_kind"] ?? CaptureKind.image.rawValue
    return Screenshot(
      id: row["id"],
      capturedAt: row["captured_at"],
      filePath: row["file_path"],
      fileSize: row["file_size"],
      idleSecondsAtCapture: row["idle_seconds_at_capture"],
      isDeleted: (row["is_deleted"] as? Int ?? 0) != 0,
      captureId: row["capture_id"],
      deviceId: row["device_id"] ?? LocalCaptureDevice.id,
      platform: CapturePlatform(rawValue: platformRaw) ?? .macOS,
      sessionId: row["session_id"],
      sequence: row["sequence"],
      timezoneId: row["timezone_id"],
      utcOffsetSeconds: row["utc_offset_seconds"],
      foregroundAppId: row["foreground_app_id"],
      foregroundAppName: row["foreground_app_name"],
      orientation: CaptureOrientation(rawValue: orientationRaw) ?? .unknown,
      pixelWidth: row["pixel_width"],
      pixelHeight: row["pixel_height"],
      kind: CaptureKind(rawValue: kindRaw) ?? .image,
      contentSHA256: row["content_sha256"]
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
      let placeholders = Array(repeating: "?", count: screenshotIds.count).joined(separator: ",")
      let sources = try Row.fetchAll(
        db,
        sql: """
              SELECT DISTINCT device_id, source_platform
              FROM screenshots
              WHERE id IN (\(placeholders))
          """,
        arguments: StatementArguments(screenshotIds)
      )
      guard sources.count == 1,
        let deviceId: String = sources[0]["device_id"],
        let sourcePlatform: String = sources[0]["source_platform"]
      else {
        return
      }

      try db.execute(
        sql: """
              INSERT INTO analysis_batches(
                batch_start_ts, batch_end_ts, device_id, source_platform
              ) VALUES (?, ?, ?, ?)
          """, arguments: [startTs, endTs, deviceId, sourcePlatform])
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

  func deviceIdForBatch(_ batchId: Int64) -> String? {
    try? timedRead("deviceIdForBatch") { db in
      try String.fetchOne(
        db,
        sql: "SELECT device_id FROM analysis_batches WHERE id = ?",
        arguments: [batchId]
      )
    }
  }

  func fetchScreenshotsInTimeRange(startTs: Int, endTs: Int) -> [Screenshot] {
    fetchScreenshotsInTimeRange(startTs: startTs, endTs: endTs, deviceId: nil)
  }

  func fetchScreenshotsInTimeRange(startTs: Int, endTs: Int, deviceId: String?) -> [Screenshot] {
    (try? timedRead("fetchScreenshotsInTimeRange") { db in
      let deviceClause = deviceId == nil ? "" : "AND device_id = ?"
      var arguments: [(any DatabaseValueConvertible)?] = [startTs, endTs]
      if let deviceId { arguments.append(deviceId) }
      return try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM screenshots
              WHERE captured_at >= ? AND captured_at <= ?
                AND is_deleted = 0
                \(deviceClause)
              ORDER BY captured_at ASC
          """, arguments: StatementArguments(arguments)
      )
      .map(screenshot(from:))
    }) ?? []
  }

}
