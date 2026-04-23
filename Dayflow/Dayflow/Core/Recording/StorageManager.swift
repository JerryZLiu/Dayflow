//
//  StorageManager.swift
//  Dayflow
//

import Foundation
import GRDB
import Sentry

final class StorageManager: StorageManaging, @unchecked Sendable {
  static let shared = StorageManager()

  enum DatabaseOperationKind: String {
    case read
    case write
  }

  struct ActiveDatabaseOperation {
    let id: Int64
    let kind: DatabaseOperationKind
    let label: String
    let startedAt: CFAbsoluteTime
    let isMainThread: Bool
    let qos: String
    var executionStartedAt: CFAbsoluteTime?
  }

  struct RecentDatabaseOperation {
    let kind: DatabaseOperationKind
    let label: String
    let completedAt: CFAbsoluteTime
    let waitMs: Int
    let execMs: Int
    let failed: Bool
    let slow: Bool
  }

  struct DatabaseContentionSnapshot {
    let activeReadCount: Int
    let activeWriteCount: Int
    let activeReadLabels: String
    let activeWriteLabels: String
    let recentReadLabels: String
    let recentWriteLabels: String
  }

  final class DatabaseContentionTracker {
    let lock = NSLock()
    var nextID: Int64 = 0
    var activeOperations: [Int64: ActiveDatabaseOperation] = [:]
    var recentOperations: [RecentDatabaseOperation] = []
    let recentLimit = 40
    let recentWindowSeconds: CFAbsoluteTime = 10.0

    func begin(kind: DatabaseOperationKind, label: String) -> Int64 {
      lock.lock()
      defer { lock.unlock() }

      nextID += 1
      activeOperations[nextID] = ActiveDatabaseOperation(
        id: nextID,
        kind: kind,
        label: label,
        startedAt: CFAbsoluteTimeGetCurrent(),
        isMainThread: Thread.isMainThread,
        qos: Self.qosLabel(Thread.current.qualityOfService),
        executionStartedAt: nil
      )
      return nextID
    }

    func markExecutionStarted(id: Int64) {
      lock.lock()
      defer { lock.unlock() }
      guard var operation = activeOperations[id], operation.executionStartedAt == nil else {
        return
      }
      operation.executionStartedAt = CFAbsoluteTimeGetCurrent()
      activeOperations[id] = operation
    }

    func complete(
      id: Int64,
      waitMs: Double,
      execMs: Double,
      failed: Bool,
      slowThresholdMs: Double
    ) -> DatabaseContentionSnapshot? {
      lock.lock()
      defer { lock.unlock() }

      guard let completed = activeOperations.removeValue(forKey: id) else { return nil }

      let now = CFAbsoluteTimeGetCurrent()
      let recentOperation = RecentDatabaseOperation(
        kind: completed.kind,
        label: completed.label,
        completedAt: now,
        waitMs: Int(waitMs.rounded()),
        execMs: Int(execMs.rounded()),
        failed: failed,
        slow: failed || waitMs > slowThresholdMs || execMs > slowThresholdMs
      )
      recentOperations.append(recentOperation)
      if recentOperations.count > recentLimit {
        recentOperations.removeFirst(recentOperations.count - recentLimit)
      }

      guard recentOperation.slow else { return nil }

      let activeReads = activeOperations.values
        .filter { $0.kind == .read }
        .sorted { $0.startedAt < $1.startedAt }
      let activeWrites = activeOperations.values
        .filter { $0.kind == .write }
        .sorted { $0.startedAt < $1.startedAt }

      let cutoff = now - recentWindowSeconds
      let recentReads =
        recentOperations
        .filter { $0.kind == .read && $0.completedAt >= cutoff }
        .sorted { $0.completedAt > $1.completedAt }
      let recentWrites =
        recentOperations
        .filter { $0.kind == .write && $0.completedAt >= cutoff }
        .sorted { $0.completedAt > $1.completedAt }

      return DatabaseContentionSnapshot(
        activeReadCount: activeReads.count,
        activeWriteCount: activeWrites.count,
        activeReadLabels: Self.formatActive(activeReads, now: now),
        activeWriteLabels: Self.formatActive(activeWrites, now: now),
        recentReadLabels: Self.formatRecent(recentReads),
        recentWriteLabels: Self.formatRecent(recentWrites)
      )
    }

    static func qosLabel(_ qos: QualityOfService) -> String {
      switch qos {
      case .userInteractive:
        return "userInteractive"
      case .userInitiated:
        return "userInitiated"
      case .utility:
        return "utility"
      case .background:
        return "background"
      case .default:
        return "default"
      @unknown default:
        return "unspecified"
      }
    }

    static func formatActive(_ operations: [ActiveDatabaseOperation], now: CFAbsoluteTime)
      -> String
    {
      guard operations.isEmpty == false else { return "none" }

      return operations.prefix(5).map { operation in
        let ageMs = Int(((now - operation.startedAt) * 1000).rounded())
        let stage = operation.executionStartedAt == nil ? "waiting" : "executing"
        let thread = operation.isMainThread ? "main" : "bg"
        return "\(operation.label) [\(stage), age_ms=\(ageMs), \(thread), qos=\(operation.qos)]"
      }.joined(separator: " | ")
    }

    static func formatRecent(_ operations: [RecentDatabaseOperation]) -> String {
      guard operations.isEmpty == false else { return "none" }

      return operations.prefix(5).map { operation in
        let status = operation.failed ? "failed" : (operation.slow ? "slow" : "ok")
        return
          "\(operation.label) [\(status), wait_ms=\(operation.waitMs), exec_ms=\(operation.execMs)]"
      }.joined(separator: " | ")
    }
  }

  let dbURL: URL
  var db: DatabasePool!  // var to allow recovery reassignment
  let fileMgr = FileManager.default
  let root: URL
  let backupsDir: URL
  var recordingsRoot: URL { root }

  // TEMPORARY DEBUG: Remove after identifying slow queries
  let debugSlowQueries = true
  let slowThresholdMs: Double = 100  // Log anything over 100ms
  let dbMaxReaderCount = 5

  // Dedicated queue for database writes to prevent main thread blocking
  let dbWriteQueue = DispatchQueue(label: "com.dayflow.storage.writes", qos: .utility)
  let dbContentionTracker = DatabaseContentionTracker()

  let purgeQ = DispatchQueue(label: "com.dayflow.storage.purge", qos: .background)
  var purgeTimer: DispatchSourceTimer?
  var checkpointTimer: DispatchSourceTimer?
  var backupTimer: DispatchSourceTimer?

  init() {
    UserDefaultsMigrator.migrateIfNeeded()
    StoragePathMigrator.migrateIfNeeded()

    let appSupport = fileMgr.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let baseDir = appSupport.appendingPathComponent("Dayflow", isDirectory: true)
    let recordingsDir = baseDir.appendingPathComponent("recordings", isDirectory: true)
    let backupDir = baseDir.appendingPathComponent("backups", isDirectory: true)

    // Ensure directories exist before opening database
    try? fileMgr.createDirectory(at: baseDir, withIntermediateDirectories: true)
    try? fileMgr.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    try? fileMgr.createDirectory(at: backupDir, withIntermediateDirectories: true)

    root = recordingsDir
    backupsDir = backupDir
    dbURL = baseDir.appendingPathComponent("chunks.sqlite")

    StorageManager.migrateDatabaseLocationIfNeeded(
      fileManager: fileMgr,
      legacyRecordingsDir: recordingsDir,
      newDatabaseURL: dbURL
    )

    // Configure database with WAL mode for better performance and safety
    var config = Configuration()
    config.maximumReaderCount = dbMaxReaderCount
    config.prepareDatabase { db in
      if !db.configuration.readonly {
        try db.execute(sql: "PRAGMA journal_mode = WAL")
        try db.execute(sql: "PRAGMA synchronous = NORMAL")
      }
      try db.execute(sql: "PRAGMA busy_timeout = 5000")
    }

    // Safe database initialization with automatic recovery from backup
    db = Self.openDatabaseSafely(
      at: dbURL,
      backupsDir: backupDir,
      config: config,
      fileManager: fileMgr
    )

    // TEMPORARY DEBUG: SQL statement tracing (via configuration)
    #if DEBUG
      try? db.write { db in
        db.trace { event in
          if case .profile(let statement, let duration) = event, duration > 0.1 {
            print("📊 SLOW SQL (\(Int(duration * 1000))ms): \(statement)")
          }
        }
      }
    #endif

    // Run integrity check on launch (logs warning if issues found)
    performIntegrityCheck()

    migrate()
    migrateLegacyChunkPathsIfNeeded()

    // Run initial purge, then schedule hourly
    purgeIfNeeded()
    TimelapseStorageManager.shared.purgeIfNeeded()
    startPurgeScheduler()

    // Schedule WAL checkpoints every 5 minutes to prevent data loss
    startCheckpointScheduler()

    // Schedule daily backups
    startBackupScheduler()
  }

  // TEMPORARY DEBUG: Timing helpers for database operations
  func timedWrite<T>(_ label: String, _ block: (Database) throws -> T) throws -> T {
    let callStart = CFAbsoluteTimeGetCurrent()
    var execStart: CFAbsoluteTime = 0
    var execEnd: CFAbsoluteTime = 0
    let operationID = dbContentionTracker.begin(kind: .write, label: label)

    let writeBreadcrumb = Breadcrumb(level: .debug, category: "database")
    writeBreadcrumb.message = "DB write: \(label)"
    writeBreadcrumb.type = "debug"
    SentryHelper.addBreadcrumb(writeBreadcrumb)

    do {
      let result = try db.write { db in
        dbContentionTracker.markExecutionStarted(id: operationID)
        execStart = CFAbsoluteTimeGetCurrent()
        defer { execEnd = CFAbsoluteTimeGetCurrent() }
        return try block(db)
      }

      let waitMs = max(0, (execStart - callStart) * 1000)
      let execMs = max(0, (execEnd - execStart) * 1000)
      let contentionSnapshot = dbContentionTracker.complete(
        id: operationID,
        waitMs: waitMs,
        execMs: execMs,
        failed: false,
        slowThresholdMs: slowThresholdMs
      )

      if debugSlowQueries && (execMs > slowThresholdMs || waitMs > slowThresholdMs) {
        print("⚠️ SLOW WRITE [\(label)]: wait=\(Int(waitMs))ms exec=\(Int(execMs))ms")

        let slowWriteBreadcrumb = Breadcrumb(level: .warning, category: "database")
        slowWriteBreadcrumb.message = "SLOW DB write: \(label)"
        slowWriteBreadcrumb.data = [
          "duration_ms": Int((waitMs + execMs).rounded()),
          "wait_ms": Int(waitMs.rounded()),
          "exec_ms": Int(execMs.rounded()),
          "caller_thread": Thread.isMainThread ? "main" : "background",
          "caller_qos": DatabaseContentionTracker.qosLabel(Thread.current.qualityOfService),
          "pool_max_readers": dbMaxReaderCount,
          "active_reads": contentionSnapshot?.activeReadCount ?? 0,
          "active_writes": contentionSnapshot?.activeWriteCount ?? 0,
          "active_read_labels": contentionSnapshot?.activeReadLabels ?? "none",
          "active_write_labels": contentionSnapshot?.activeWriteLabels ?? "none",
          "recent_read_labels": contentionSnapshot?.recentReadLabels ?? "none",
          "recent_write_labels": contentionSnapshot?.recentWriteLabels ?? "none",
        ]
        slowWriteBreadcrumb.type = "error"
        SentryHelper.addBreadcrumb(slowWriteBreadcrumb)
      }

      return result
    } catch {
      if execStart == 0 {
        execStart = CFAbsoluteTimeGetCurrent()
      }
      if execEnd == 0 {
        execEnd = CFAbsoluteTimeGetCurrent()
      }
      let waitMs = max(0, (execStart - callStart) * 1000)
      let execMs = max(0, (execEnd - execStart) * 1000)
      let contentionSnapshot = dbContentionTracker.complete(
        id: operationID,
        waitMs: waitMs,
        execMs: execMs,
        failed: true,
        slowThresholdMs: slowThresholdMs
      )

      let slowWriteBreadcrumb = Breadcrumb(level: .error, category: "database")
      slowWriteBreadcrumb.message = "FAILED DB write: \(label)"
      slowWriteBreadcrumb.data = [
        "wait_ms": Int(waitMs.rounded()),
        "exec_ms": Int(execMs.rounded()),
        "error": "\(error)",
        "caller_thread": Thread.isMainThread ? "main" : "background",
        "caller_qos": DatabaseContentionTracker.qosLabel(Thread.current.qualityOfService),
        "pool_max_readers": dbMaxReaderCount,
        "active_reads": contentionSnapshot?.activeReadCount ?? 0,
        "active_writes": contentionSnapshot?.activeWriteCount ?? 0,
        "active_read_labels": contentionSnapshot?.activeReadLabels ?? "none",
        "active_write_labels": contentionSnapshot?.activeWriteLabels ?? "none",
        "recent_read_labels": contentionSnapshot?.recentReadLabels ?? "none",
        "recent_write_labels": contentionSnapshot?.recentWriteLabels ?? "none",
      ]
      slowWriteBreadcrumb.type = "error"
      SentryHelper.addBreadcrumb(slowWriteBreadcrumb)
      throw error
    }
  }

  func timedRead<T>(_ label: String, _ block: (Database) throws -> T) throws -> T {
    let callStart = CFAbsoluteTimeGetCurrent()
    var execStart: CFAbsoluteTime = 0
    var execEnd: CFAbsoluteTime = 0
    let operationID = dbContentionTracker.begin(kind: .read, label: label)

    let readBreadcrumb = Breadcrumb(level: .debug, category: "database")
    readBreadcrumb.message = "DB read: \(label)"
    readBreadcrumb.type = "debug"
    SentryHelper.addBreadcrumb(readBreadcrumb)

    do {
      let result = try db.read { db in
        dbContentionTracker.markExecutionStarted(id: operationID)
        execStart = CFAbsoluteTimeGetCurrent()
        defer { execEnd = CFAbsoluteTimeGetCurrent() }
        return try block(db)
      }

      let waitMs = max(0, (execStart - callStart) * 1000)
      let execMs = max(0, (execEnd - execStart) * 1000)
      let contentionSnapshot = dbContentionTracker.complete(
        id: operationID,
        waitMs: waitMs,
        execMs: execMs,
        failed: false,
        slowThresholdMs: slowThresholdMs
      )

      if debugSlowQueries && (execMs > slowThresholdMs || waitMs > slowThresholdMs) {
        print("⚠️ SLOW READ [\(label)]: wait=\(Int(waitMs))ms exec=\(Int(execMs))ms")

        let slowReadBreadcrumb = Breadcrumb(level: .warning, category: "database")
        slowReadBreadcrumb.message = "SLOW DB read: \(label)"
        slowReadBreadcrumb.data = [
          "duration_ms": Int((waitMs + execMs).rounded()),
          "wait_ms": Int(waitMs.rounded()),
          "exec_ms": Int(execMs.rounded()),
          "caller_thread": Thread.isMainThread ? "main" : "background",
          "caller_qos": DatabaseContentionTracker.qosLabel(Thread.current.qualityOfService),
          "pool_max_readers": dbMaxReaderCount,
          "active_reads": contentionSnapshot?.activeReadCount ?? 0,
          "active_writes": contentionSnapshot?.activeWriteCount ?? 0,
          "active_read_labels": contentionSnapshot?.activeReadLabels ?? "none",
          "active_write_labels": contentionSnapshot?.activeWriteLabels ?? "none",
          "recent_read_labels": contentionSnapshot?.recentReadLabels ?? "none",
          "recent_write_labels": contentionSnapshot?.recentWriteLabels ?? "none",
        ]
        slowReadBreadcrumb.type = "error"
        SentryHelper.addBreadcrumb(slowReadBreadcrumb)
      }

      return result
    } catch {
      if execStart == 0 {
        execStart = CFAbsoluteTimeGetCurrent()
      }
      if execEnd == 0 {
        execEnd = CFAbsoluteTimeGetCurrent()
      }
      let waitMs = max(0, (execStart - callStart) * 1000)
      let execMs = max(0, (execEnd - execStart) * 1000)
      let contentionSnapshot = dbContentionTracker.complete(
        id: operationID,
        waitMs: waitMs,
        execMs: execMs,
        failed: true,
        slowThresholdMs: slowThresholdMs
      )

      let slowReadBreadcrumb = Breadcrumb(level: .error, category: "database")
      slowReadBreadcrumb.message = "FAILED DB read: \(label)"
      slowReadBreadcrumb.data = [
        "wait_ms": Int(waitMs.rounded()),
        "exec_ms": Int(execMs.rounded()),
        "error": "\(error)",
        "caller_thread": Thread.isMainThread ? "main" : "background",
        "caller_qos": DatabaseContentionTracker.qosLabel(Thread.current.qualityOfService),
        "pool_max_readers": dbMaxReaderCount,
        "active_reads": contentionSnapshot?.activeReadCount ?? 0,
        "active_writes": contentionSnapshot?.activeWriteCount ?? 0,
        "active_read_labels": contentionSnapshot?.activeReadLabels ?? "none",
        "active_write_labels": contentionSnapshot?.activeWriteLabels ?? "none",
        "recent_read_labels": contentionSnapshot?.recentReadLabels ?? "none",
        "recent_write_labels": contentionSnapshot?.recentWriteLabels ?? "none",
      ]
      slowReadBreadcrumb.type = "error"
      SentryHelper.addBreadcrumb(slowReadBreadcrumb)
      throw error
    }
  }

  func migrate() {
    try? timedWrite("migrate") { db in
      // Create all tables with their final schema
      try db.execute(
        sql: """
              -- Chunks table: stores video recording segments
              CREATE TABLE IF NOT EXISTS chunks (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  start_ts INTEGER NOT NULL,
                  end_ts INTEGER NOT NULL,
                  file_url TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'recording',
                  is_deleted INTEGER DEFAULT 0
              );
              CREATE INDEX IF NOT EXISTS idx_chunks_status ON chunks(status);
              CREATE INDEX IF NOT EXISTS idx_chunks_start_ts ON chunks(start_ts);
              CREATE INDEX IF NOT EXISTS idx_chunks_status_start_ts ON chunks(status, start_ts);
              
              -- Analysis batches: groups chunks for LLM processing
              CREATE TABLE IF NOT EXISTS analysis_batches (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  batch_start_ts INTEGER NOT NULL,
                  batch_end_ts INTEGER NOT NULL,
                  status TEXT NOT NULL DEFAULT 'pending',
                  reason TEXT,
                  llm_metadata TEXT,
                  detailed_transcription TEXT,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
              );
              CREATE INDEX IF NOT EXISTS idx_analysis_batches_status ON analysis_batches(status);
              
              -- Junction table linking batches to chunks
              CREATE TABLE IF NOT EXISTS batch_chunks (
                  batch_id INTEGER NOT NULL REFERENCES analysis_batches(id) ON DELETE CASCADE,
                  chunk_id INTEGER NOT NULL REFERENCES chunks(id) ON DELETE RESTRICT,
                  PRIMARY KEY (batch_id, chunk_id)
              );
              CREATE INDEX IF NOT EXISTS idx_batch_chunks_chunk ON batch_chunks(chunk_id);
              
              -- Timeline cards: stores activity summaries
              CREATE TABLE IF NOT EXISTS timeline_cards (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  batch_id INTEGER REFERENCES analysis_batches(id) ON DELETE CASCADE,
                  start TEXT NOT NULL,       -- Clock time (e.g., "2:30 PM")
                  end TEXT NOT NULL,         -- Clock time (e.g., "3:45 PM")
                  start_ts INTEGER,          -- Unix timestamp
                  end_ts INTEGER,            -- Unix timestamp
                  day DATE NOT NULL,
                  title TEXT NOT NULL,
                  summary TEXT,
                  category TEXT NOT NULL,
                  subcategory TEXT,
                  detailed_summary TEXT,
                  metadata TEXT,             -- For distractions JSON
                  video_summary_url TEXT,    -- Link to video summary on filesystem
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
              );
              CREATE INDEX IF NOT EXISTS idx_timeline_cards_day ON timeline_cards(day);
              CREATE INDEX IF NOT EXISTS idx_timeline_cards_start_ts ON timeline_cards(start_ts);
              CREATE INDEX IF NOT EXISTS idx_timeline_cards_time_range ON timeline_cards(start_ts, end_ts);

              -- Timeline review ratings: stores time-based review segments
              CREATE TABLE IF NOT EXISTS timeline_review_ratings (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  start_ts INTEGER NOT NULL,
                  end_ts INTEGER NOT NULL,
                  rating TEXT NOT NULL
              );
              CREATE INDEX IF NOT EXISTS idx_review_ratings_time ON timeline_review_ratings(start_ts, end_ts);
              
              -- Observations: stores LLM transcription outputs
              CREATE TABLE IF NOT EXISTS observations (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  batch_id INTEGER NOT NULL REFERENCES analysis_batches(id) ON DELETE CASCADE,
                  start_ts INTEGER NOT NULL,
                  end_ts INTEGER NOT NULL,
                  observation TEXT NOT NULL,
                  metadata TEXT,
                  llm_model TEXT,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
              );
              CREATE INDEX IF NOT EXISTS idx_observations_batch_id ON observations(batch_id);
              CREATE INDEX IF NOT EXISTS idx_observations_start_ts ON observations(start_ts);
              CREATE INDEX IF NOT EXISTS idx_observations_time_range ON observations(start_ts, end_ts);

              -- Screenshots table: stores periodic screen captures (replaces video chunks)
              CREATE TABLE IF NOT EXISTS screenshots (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  captured_at INTEGER NOT NULL,
                  file_path TEXT NOT NULL,
                  file_size INTEGER,
                  idle_seconds_at_capture INTEGER,
                  is_deleted INTEGER DEFAULT 0,
                  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
              );
              CREATE INDEX IF NOT EXISTS idx_screenshots_captured_at ON screenshots(captured_at);

              -- Junction table linking batches to screenshots
              CREATE TABLE IF NOT EXISTS batch_screenshots (
                  batch_id INTEGER NOT NULL REFERENCES analysis_batches(id) ON DELETE CASCADE,
                  screenshot_id INTEGER NOT NULL REFERENCES screenshots(id) ON DELETE RESTRICT,
                  PRIMARY KEY (batch_id, screenshot_id)
              );
              CREATE INDEX IF NOT EXISTS idx_batch_screenshots_screenshot ON batch_screenshots(screenshot_id);
          """)

      // Journal entries table: stores daily intentions, reflections, and summaries
      try db.execute(
        sql: """
              CREATE TABLE IF NOT EXISTS journal_entries (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  day TEXT NOT NULL UNIQUE,
                  intentions TEXT,
                  notes TEXT,
                  goals TEXT,
                  reflections TEXT,
                  summary TEXT,
                  status TEXT NOT NULL DEFAULT 'draft',
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
              );
              CREATE INDEX IF NOT EXISTS idx_journal_entries_day ON journal_entries(day);
              CREATE INDEX IF NOT EXISTS idx_journal_entries_status ON journal_entries(status);
          """)

      // Daily standup table: one JSON blob per standup day
      try db.execute(
        sql: """
              CREATE TABLE IF NOT EXISTS daily_standup_entries (
                  standup_day TEXT NOT NULL PRIMARY KEY,
                  payload_json TEXT NOT NULL,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
              );
              CREATE INDEX IF NOT EXISTS idx_daily_standup_entries_created_at ON daily_standup_entries(created_at DESC);
          """)

      // LLM calls logging table
      try db.execute(
        sql: """
              CREATE TABLE IF NOT EXISTS llm_calls (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  batch_id INTEGER NULL,
                  call_group_id TEXT NULL,
                  attempt INTEGER NOT NULL DEFAULT 1,
                  provider TEXT NOT NULL,
                  model TEXT NULL,
                  operation TEXT NOT NULL,
                  status TEXT NOT NULL CHECK(status IN ('success','failure')),
                  latency_ms INTEGER NULL,
                  http_status INTEGER NULL,
                  request_method TEXT NULL,
                  request_url TEXT NULL,
                  request_headers TEXT NULL,
                  request_body TEXT NULL,
                  response_headers TEXT NULL,
                  response_body TEXT NULL,
                  error_domain TEXT NULL,
                  error_code INTEGER NULL,
                  error_message TEXT NULL
              );
              CREATE INDEX IF NOT EXISTS idx_llm_calls_created ON llm_calls(created_at DESC);
              CREATE INDEX IF NOT EXISTS idx_llm_calls_group ON llm_calls(call_group_id, attempt);
              CREATE INDEX IF NOT EXISTS idx_llm_calls_batch ON llm_calls(batch_id);
          """)

      // Migration: Add soft delete column to timeline_cards if it doesn't exist
      let timelineCardsColumns = try db.columns(in: "timeline_cards").map { $0.name }
      if !timelineCardsColumns.contains("is_deleted") {
        try db.execute(
          sql: """
                ALTER TABLE timeline_cards ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;
            """)

        // Create composite partial indexes for common query patterns
        try db.execute(
          sql: """
                CREATE INDEX IF NOT EXISTS idx_timeline_cards_active_start_ts
                ON timeline_cards(start_ts)
                WHERE is_deleted = 0;
            """)

        try db.execute(
          sql: """
                CREATE INDEX IF NOT EXISTS idx_timeline_cards_active_batch
                ON timeline_cards(batch_id)
                WHERE is_deleted = 0;
            """)

        print("✅ Added is_deleted column and composite indexes to timeline_cards")
      }

      let screenshotColumns = try db.columns(in: "screenshots").map { $0.name }
      if !screenshotColumns.contains("idle_seconds_at_capture") {
        try db.execute(
          sql: """
                ALTER TABLE screenshots ADD COLUMN idle_seconds_at_capture INTEGER;
            """)
        print("✅ Added idle_seconds_at_capture column to screenshots")
      }
    }
  }

}
