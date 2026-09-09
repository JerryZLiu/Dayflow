import AppKit
import Foundation
import GRDB
import Sentry

extension StorageManager {
  private static let maxStoredLLMBodyCharacters = 64 * 1024
  private static let llmBodyTruncationBatchSize = 100
  private static let llmBodyTruncationMaxBatches = 50

  // MARK: - WAL Checkpoint

  /// Checkpoint the WAL file to merge changes into the main database.
  /// This prevents WAL from growing unbounded and reduces data loss risk on crash.
  /// - Parameter mode: .passive (non-blocking), .full, .restart, or .truncate (resets WAL to zero)
  func checkpoint(mode: Database.CheckpointMode = .passive) {
    do {
      _ = try db.writeWithoutTransaction { db in
        try db.checkpoint(mode)
      }
      print("✅ [StorageManager] WAL checkpoint completed (mode: \(mode))")
    } catch {
      print("⚠️ [StorageManager] WAL checkpoint failed: \(error)")
      // Log to Sentry for visibility
      let breadcrumb = Breadcrumb(level: .warning, category: "database")
      breadcrumb.message = "WAL checkpoint failed"
      breadcrumb.data = ["mode": "\(mode)", "error": "\(error)"]
      SentryHelper.addBreadcrumb(breadcrumb)
    }
  }

  func startCheckpointScheduler() {
    let timer = DispatchSource.makeTimerSource(queue: dbWriteQueue)
    timer.schedule(deadline: .now() + 300, repeating: 300)  // Every 5 minutes
    timer.setEventHandler { [weak self] in
      self?.checkpoint(mode: .passive)
    }
    timer.resume()
    checkpointTimer = timer
  }

  // MARK: - Safe Database Initialization

  /// Opens the database with automatic recovery from backup if corrupted.
  /// Order of attempts: 1) Normal open, 2) Restore from most recent backup, 3) Fresh database
  /// Recovery only runs for corruption errors. Environmental failures (disk full,
  /// file locked/permissions) leave an intact database on disk — deleting it would
  /// destroy user data — so those show an alert and quit instead.
  static func openDatabaseSafely(
    at dbURL: URL,
    backupsDir: URL,
    config: Configuration,
    fileManager: FileManager
  ) -> DatabasePool {
    // Attempt 1: Normal open
    do {
      let pool = try DatabasePool(path: dbURL.path, configuration: config)
      print("✅ [StorageManager] Database opened successfully")
      return pool
    } catch {
      print("⚠️ [StorageManager] Failed to open database: \(error)")

      let breadcrumb = Breadcrumb(level: .error, category: "database")
      breadcrumb.message = "Database open failed, attempting recovery"
      breadcrumb.data = ["error": "\(error)"]
      SentryHelper.addBreadcrumb(breadcrumb)

      guard isCorruptionError(error) else {
        showDatabaseUnavailableAlertAndQuit(error: error)
      }

      // Attempt 2: Restore from most recent backup
      if let backupURL = findMostRecentBackup(in: backupsDir, fileManager: fileManager) {
        print("🔄 [StorageManager] Attempting recovery from backup: \(backupURL.lastPathComponent)")

        // Remove corrupted database files
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
        try? fileManager.removeItem(at: dbURL)
        try? fileManager.removeItem(at: walURL)
        try? fileManager.removeItem(at: shmURL)

        // Copy backup to database location
        do {
          try fileManager.copyItem(at: backupURL, to: dbURL)
          let pool = try DatabasePool(path: dbURL.path, configuration: config)
          print("✅ [StorageManager] Successfully recovered from backup")

          let recoveryBreadcrumb = Breadcrumb(level: .info, category: "database")
          recoveryBreadcrumb.message = "Database recovered from backup"
          recoveryBreadcrumb.data = ["backup": backupURL.lastPathComponent]
          SentryHelper.addBreadcrumb(recoveryBreadcrumb)

          return pool
        } catch {
          print("❌ [StorageManager] Backup recovery failed: \(error)")
        }
      }

      // Attempt 3: Start fresh (last resort)
      print("🆕 [StorageManager] Starting with fresh database")
      let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
      let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
      try? fileManager.removeItem(at: dbURL)
      try? fileManager.removeItem(at: walURL)
      try? fileManager.removeItem(at: shmURL)

      do {
        let pool = try DatabasePool(path: dbURL.path, configuration: config)

        let freshBreadcrumb = Breadcrumb(level: .warning, category: "database")
        freshBreadcrumb.message = "Started with fresh database after all recovery attempts failed"
        SentryHelper.addBreadcrumb(freshBreadcrumb)

        return pool
      } catch {
        // Even a fresh database can't be created — the environment is broken.
        showDatabaseUnavailableAlertAndQuit(error: error)
      }
    }
  }

  /// True only for SQLite errors that mean the database file itself is damaged.
  /// Everything else (disk full, unable to open, I/O errors) is environmental.
  private static func isCorruptionError(_ error: Error) -> Bool {
    guard let dbError = error as? DatabaseError else { return false }
    let primary = dbError.resultCode.primaryResultCode
    return primary == .SQLITE_CORRUPT || primary == .SQLITE_NOTADB
  }

  /// Tells the user the database is unavailable (most commonly a full disk) and
  /// quits cleanly instead of crashing.
  private static func showDatabaseUnavailableAlertAndQuit(error: Error) -> Never {
    if SentryHelper.isEnabled {
      SentrySDK.capture(message: "Database unavailable, quitting: \(error)")
      SentrySDK.flush(timeout: 2)
    }

    let presentAlert = {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "Dayflow Can't Open Its Database"
      alert.informativeText = """
        Dayflow couldn't open its database and has to quit. This usually happens \
        when the disk is full — free up some space and open Dayflow again.

        Error: \(error)
        """
      alert.addButton(withTitle: "Quit")
      alert.runModal()
    }

    if Thread.isMainThread {
      presentAlert()
    } else {
      // StorageManager.shared can be first touched from a background thread while
      // the main thread is blocked waiting on the same init — a sync hop would
      // deadlock. Show the alert async and time out if it never gets dismissed.
      let dismissed = DispatchSemaphore(value: 0)
      DispatchQueue.main.async {
        presentAlert()
        dismissed.signal()
      }
      _ = dismissed.wait(timeout: .now() + 60)
    }
    exit(1)
  }

  /// Finds the most recent backup file in the backups directory
  static func findMostRecentBackup(in backupsDir: URL, fileManager: FileManager) -> URL? {
    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: backupsDir,
        includingPropertiesForKeys: [.creationDateKey],
        options: .skipsHiddenFiles
      )
    else {
      return nil
    }

    let sqliteBackups = contents.filter { $0.pathExtension == "sqlite" }

    // Sort by creation date, newest first
    let sorted = sqliteBackups.sorted { url1, url2 in
      let date1 =
        (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      let date2 =
        (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      return date1 > date2
    }

    return sorted.first
  }

  // MARK: - Integrity Check

  /// Performs a quick integrity check on the database.
  /// Logs a warning if issues are found but doesn't stop app launch.
  func performIntegrityCheck() {
    do {
      let result = try db.read { db -> String? in
        try String.fetchOne(db, sql: "PRAGMA quick_check")
      }

      if result == "ok" {
        print("✅ [StorageManager] Database integrity check passed")
      } else {
        print("⚠️ [StorageManager] Database integrity issues: \(result ?? "unknown")")

        let breadcrumb = Breadcrumb(level: .warning, category: "database")
        breadcrumb.message = "Database integrity check found issues"
        breadcrumb.data = ["result": result ?? "unknown"]
        SentryHelper.addBreadcrumb(breadcrumb)
      }
    } catch {
      print("⚠️ [StorageManager] Integrity check failed: \(error)")

      let breadcrumb = Breadcrumb(level: .error, category: "database")
      breadcrumb.message = "Database integrity check error"
      breadcrumb.data = ["error": "\(error)"]
      SentryHelper.addBreadcrumb(breadcrumb)
    }
  }

  // MARK: - Backup System

  /// Creates a backup of the database using GRDB's native backup API.
  /// Backups are stored with timestamp in filename and old backups are pruned.
  func createBackup() {
    dbWriteQueue.async { [weak self] in
      guard let self = self else { return }

      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd_HHmmss"
      let timestamp = formatter.string(from: Date())
      let backupName = "chunks-\(timestamp).sqlite"
      let backupURL = self.backupsDir.appendingPathComponent(backupName)

      do {
        // Create destination database for backup
        let destination = try DatabaseQueue(path: backupURL.path)

        // Use GRDB's native backup API
        try self.db.backup(to: destination)

        print("✅ [StorageManager] Backup created: \(backupName)")

        let breadcrumb = Breadcrumb(level: .info, category: "database")
        breadcrumb.message = "Database backup created"
        breadcrumb.data = ["filename": backupName]
        SentryHelper.addBreadcrumb(breadcrumb)

        // Prune old backups, keeping last 3
        self.pruneOldBackups(keeping: 3)

      } catch {
        print("❌ [StorageManager] Backup failed: \(error)")

        let breadcrumb = Breadcrumb(level: .error, category: "database")
        breadcrumb.message = "Database backup failed"
        breadcrumb.data = ["error": "\(error)"]
        SentryHelper.addBreadcrumb(breadcrumb)
      }
    }
  }

  /// Removes old backups, keeping only the most recent `count` backups.
  func pruneOldBackups(keeping count: Int) {
    guard
      let contents = try? fileMgr.contentsOfDirectory(
        at: backupsDir,
        includingPropertiesForKeys: [.creationDateKey],
        options: .skipsHiddenFiles
      )
    else {
      return
    }

    let sqliteBackups = contents.filter { $0.pathExtension == "sqlite" }

    // Sort by creation date, newest first
    let sorted = sqliteBackups.sorted { url1, url2 in
      let date1 =
        (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      let date2 =
        (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      return date1 > date2
    }

    // Remove all but the newest `count` backups
    if sorted.count > count {
      let toDelete = sorted.dropFirst(count)
      for url in toDelete {
        try? fileMgr.removeItem(at: url)
        print("🗑️ [StorageManager] Pruned old backup: \(url.lastPathComponent)")
      }
    }
  }

  /// Schedules daily backups (every 24 hours, starting 1 hour after launch)
  func startBackupScheduler() {
    let timer = DispatchSource.makeTimerSource(queue: dbWriteQueue)
    // First backup 1 hour after launch, then every 24 hours
    timer.schedule(deadline: .now() + 3600, repeating: 86400)
    timer.setEventHandler { [weak self] in
      self?.createBackup()
    }
    timer.resume()
    backupTimer = timer

    // Also create an immediate backup on first launch if none exists
    if Self.findMostRecentBackup(in: backupsDir, fileManager: fileMgr) == nil {
      createBackup()
    }
  }

  func startPurgeScheduler() {
    let timer = DispatchSource.makeTimerSource(queue: purgeQ)
    timer.schedule(deadline: .now() + 3600, repeating: 3600)  // Every hour
    timer.setEventHandler { [weak self] in
      self?.purgeIfNeeded()
      TimelapseStorageManager.shared.purgeIfNeeded()
    }
    timer.resume()
    purgeTimer = timer
  }

  func truncateOversizedLLMCallBodiesIfNeeded() {
    dbWriteQueue.async { [weak self] in
      guard let self else { return }

      do {
        var totalUpdated = 0

        for _ in 0..<Self.llmBodyTruncationMaxBatches {
          let updated = try self.truncateOversizedLLMCallBodyBatch()
          guard updated > 0 else { break }
          totalUpdated += updated
        }

        if totalUpdated > 0 {
          print("✅ [StorageManager] Truncated oversized LLM call bodies: \(totalUpdated) fields")

          let breadcrumb = Breadcrumb(level: .info, category: "database")
          breadcrumb.message = "Truncated oversized LLM call bodies"
          breadcrumb.data = ["fields_updated": totalUpdated]
          SentryHelper.addBreadcrumb(breadcrumb)

          self.checkpoint(mode: .passive)
        }
      } catch {
        print("⚠️ [StorageManager] Failed to truncate oversized LLM call bodies: \(error)")

        let breadcrumb = Breadcrumb(level: .warning, category: "database")
        breadcrumb.message = "Failed to truncate oversized LLM call bodies"
        breadcrumb.data = ["error": "\(error)"]
        SentryHelper.addBreadcrumb(breadcrumb)
      }
    }
  }

  private func truncateOversizedLLMCallBodyBatch() throws -> Int {
    let limit = Self.maxStoredLLMBodyCharacters
    let batchSize = Self.llmBodyTruncationBatchSize
    let markerPrefix = "<truncated llm body: original_chars="
    let markerSuffix = ", stored_prefix_chars=\(limit)>\n"

    return try timedWrite("truncateOversizedLLMCallBodyBatch") { db in
      var updated = 0

      try db.execute(
        sql: """
              UPDATE llm_calls
              SET request_body = ? || length(request_body) || ? || substr(request_body, 1, ?)
              WHERE id IN (
                SELECT id
                FROM llm_calls
                WHERE request_body IS NOT NULL
                  AND length(request_body) > ?
                  AND request_body NOT LIKE '<truncated llm body:%'
                LIMIT ?
              )
          """,
        arguments: [markerPrefix, markerSuffix, limit, limit, batchSize])
      updated += db.changesCount

      try db.execute(
        sql: """
              UPDATE llm_calls
              SET response_body = ? || length(response_body) || ? || substr(response_body, 1, ?)
              WHERE id IN (
                SELECT id
                FROM llm_calls
                WHERE response_body IS NOT NULL
                  AND length(response_body) > ?
                  AND response_body NOT LIKE '<truncated llm body:%'
                LIMIT ?
              )
          """,
        arguments: [markerPrefix, markerSuffix, limit, limit, batchSize])
      updated += db.changesCount

      return updated
    }
  }

  func purgeIfNeeded() {
    purgeQ.async { [weak self] in
      guard let self = self else { return }
      self.performPurgeIfNeeded()
    }
  }

  func purgeNow(completion: (() -> Void)? = nil) {
    purgeQ.async { [weak self] in
      guard let self = self else {
        if let completion {
          DispatchQueue.main.async { completion() }
        }
        return
      }
      self.performPurgeIfNeeded()
      if let completion {
        DispatchQueue.main.async { completion() }
      }
    }
  }

  func performPurgeIfNeeded() {
    do {
      let limit = StoragePreferences.recordingsLimitBytes

      if limit == Int64.max {
        return  // Unlimited storage - skip purge
      }

      cleanupRecordingStragglers()

      // Check current size after cleaning orphans
      let currentSize = try fileMgr.allocatedSizeOfDirectory(at: root)

      // Soft-delete whole segments, oldest first, until the estimated size fits.
      // Files are removed by cleanupRecordingStragglers once none of their frames are live.
      if currentSize > limit {
        let activeSegmentPath = FrameStore.shared.activeSegmentPath
        var freedSpace: Int64 = 0
        var passCount = 0

        while currentSize - freedSpace > limit {
          var freedThisPass: Int64 = 0
          var markedThisPass = 0

          try timedWrite("purgeScreenshots") { db in
            let oldSegments = try Row.fetchAll(
              db,
              sql: """
                    SELECT file_path, SUM(file_size) AS bytes
                    FROM screenshots
                    WHERE is_deleted = 0
                    GROUP BY file_path
                    ORDER BY MIN(captured_at) ASC
                    LIMIT 20
                """)

            for segment in oldSegments {
              guard let path: String = segment["file_path"], path != activeSegmentPath else {
                continue
              }
              let bytes: Int64? = segment["bytes"]
              try db.execute(
                sql: "UPDATE screenshots SET is_deleted = 1 WHERE file_path = ? AND is_deleted = 0",
                arguments: [path])
              freedThisPass += bytes ?? 0
              markedThisPass += 1
            }
          }

          if markedThisPass == 0 {
            break
          }

          freedSpace += freedThisPass
          passCount += 1

          if passCount > 200 {
            break
          }
        }
      }

      cleanupRecordingStragglers()
    } catch {
      print("❌ Purge error: \(error)")
    }
  }

  func cleanupRecordingStragglers() {
    // Delete any recordings that are not referenced by active screenshots.
    // Read the active segment before the row snapshot so a segment opened in between is covered.
    let activeSegmentPath = FrameStore.shared.activeSegmentPath
    let activeScreenshotPaths: Set<String> = Set(
      (try? timedRead("activeScreenshotPaths") { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT file_path
                FROM screenshots
                WHERE is_deleted = 0
            """
        )
        .compactMap { $0["file_path"] as? String }
      }) ?? [])

    guard
      let enumerator = fileMgr.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return }

    let deleteAll = activeScreenshotPaths.isEmpty
    // A segment written after the row snapshot has no rows yet; never touch anything that young.
    let youngestDeletableDate = Date().addingTimeInterval(-(FrameStore.segmentDuration + 60))

    for case let fileURL as URL in enumerator {
      do {
        let values = try fileURL.resourceValues(forKeys: [
          .isDirectoryKey, .contentModificationDateKey,
        ])
        if values.isDirectory == true { continue }
        if fileURL.path == activeSegmentPath { continue }
        if let modified = values.contentModificationDate, modified > youngestDeletableDate {
          continue
        }

        if deleteAll || !activeScreenshotPaths.contains(fileURL.path) {
          try fileMgr.removeItem(at: fileURL)
        }
      } catch {
        print("⚠️ Failed to delete straggler file at \(fileURL.path): \(error)")
      }
    }
  }
}
