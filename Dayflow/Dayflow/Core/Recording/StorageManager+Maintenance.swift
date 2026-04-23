import Foundation
import GRDB
import Sentry

extension StorageManager {
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
        // This is truly fatal - can't even create a fresh database
        fatalError("[StorageManager] Cannot create database: \(error)")
      }
    }
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

      // Clean up if above limit
      if currentSize > limit {
        var freedSpace: Int64 = 0
        var passCount = 0

        while currentSize - freedSpace > limit {
          var deletedThisPass = 0
          var freedThisPass: Int64 = 0

          try timedWrite("purgeScreenshots") { db in
            // Get oldest active screenshots
            let oldScreenshots = try Row.fetchAll(
              db,
              sql: """
                    SELECT id, file_path, file_size
                    FROM screenshots
                    WHERE is_deleted = 0
                    ORDER BY captured_at ASC
                    LIMIT 500
                """)

            guard !oldScreenshots.isEmpty else { return }

            for screenshot in oldScreenshots {
              guard let id: Int64 = screenshot["id"],
                let path: String = screenshot["file_path"]
              else { continue }

              // Mark as deleted in DB first (safer ordering)
              try db.execute(
                sql: """
                      UPDATE screenshots
                      SET is_deleted = 1
                      WHERE id = ?
                  """, arguments: [id])

              // Then delete physical file
              if fileMgr.fileExists(atPath: path) {
                var fileSize: Int64 = 0
                if let storedSize: Int64 = screenshot["file_size"] {
                  fileSize = storedSize
                }
                if fileSize == 0,
                  let attrs = try? fileMgr.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber
                {
                  fileSize = size.int64Value
                }

                do {
                  try fileMgr.removeItem(atPath: path)
                  freedThisPass += fileSize
                  deletedThisPass += 1
                } catch {
                  print("⚠️ Failed to delete screenshot at \(path): \(error)")
                }
              } else {
                deletedThisPass += 1
              }
            }
          }

          if deletedThisPass == 0 {
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
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return }

    let deleteAll = activeScreenshotPaths.isEmpty

    for case let fileURL as URL in enumerator {
      do {
        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true { continue }

        if deleteAll || !activeScreenshotPaths.contains(fileURL.path) {
          try fileMgr.removeItem(at: fileURL)
        }
      } catch {
        print("⚠️ Failed to delete straggler file at \(fileURL.path): \(error)")
      }
    }
  }
}
