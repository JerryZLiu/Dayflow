//
//  StorageManager.swift
//  Dayflow
//

import Foundation
import GRDB
import Sentry

extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter
    }()
}

extension Date {
    /// Calculates the "day" based on a 4 AM start time.
    /// Returns the date string (YYYY-MM-DD) and the Date objects for the start and end of that day.
    func getDayInfoFor4AMBoundary() -> (dayString: String, startOfDay: Date, endOfDay: Date) {
        let calendar = Calendar.current
        guard let fourAMToday = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: self) else {
            print("Error: Could not calculate 4 AM for date \(self). Falling back to standard day.")
            let start = calendar.startOfDay(for: self)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return (DateFormatter.yyyyMMdd.string(from: start), start, end)
        }

        let startOfDay: Date
        if self < fourAMToday {
            startOfDay = calendar.date(byAdding: .day, value: -1, to: fourAMToday)!
        } else {
            startOfDay = fourAMToday
        }
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let dayString = DateFormatter.yyyyMMdd.string(from: startOfDay)
        return (dayString, startOfDay, endOfDay)
    }
}


/// File + database persistence used by screen‑recorder & Gemini pipeline.
///
/// _No_ `@MainActor` isolation ⇒ can be called from any thread/actor.
/// If you add UI‑touching methods later, isolate **those** individually.
protocol StorageManaging: Sendable {
    // Recording‑chunk lifecycle
    func nextFileURL() -> URL
    func registerChunk(url: URL)
    func markChunkCompleted(url: URL)
    func markChunkFailed(url: URL)

    // Fetch unprocessed (completed + not yet batched) chunks
    func fetchUnprocessedChunks(olderThan oldestAllowed: Int) -> [RecordingChunk]
    func fetchChunksInTimeRange(startTs: Int, endTs: Int) -> [RecordingChunk]

    // Analysis‑batch management
    func saveBatch(startTs: Int, endTs: Int, chunkIds: [Int64]) -> Int64?
    func updateBatchStatus(batchId: Int64, status: String)
    func markBatchFailed(batchId: Int64, reason: String)

    // Record details about all LLM calls for a batch
    func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall])
    func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall]

    // Timeline‑cards
    func saveTimelineCardShell(batchId: Int64, card: TimelineCardShell) -> Int64?
    func updateTimelineCardVideoURL(cardId: Int64, videoSummaryURL: String)
    func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard]
    func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps?

    // Timeline Queries
    func fetchTimelineCards(forDay day: String) -> [TimelineCard]
    func fetchTimelineCardsByTimeRange(from: Date, to: Date) -> [TimelineCard]
    func replaceTimelineCardsInRange(from: Date, to: Date, with: [TimelineCardShell], batchId: Int64) -> (insertedIds: [Int64], deletedVideoPaths: [String])
    func fetchRecentTimelineCardsForDebug(limit: Int) -> [TimelineCardDebugEntry]

    func updateTimelineCardCategory(cardId: Int64, category: String)

    func fetchRecentLLMCallsForDebug(limit: Int) -> [LLMCallDebugEntry]
    func fetchRecentAnalysisBatchesForDebug(limit: Int) -> [AnalysisBatchDebugEntry]
    func fetchLLMCallsForBatches(batchIds: [Int64], limit: Int) -> [LLMCallDebugEntry]

    // Note: Transcript storage methods removed in favor of Observations
    
    // NEW: Observations Storage
    func saveObservations(batchId: Int64, observations: [Observation])
    func fetchObservations(batchId: Int64) -> [Observation]
    func fetchObservations(startTs: Int, endTs: Int) -> [Observation]
    func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation]

    // Helper for GeminiService – map file paths → timestamps
    func getTimestampsForVideoFiles(paths: [String]) -> [String: (startTs: Int, endTs: Int)]
    
    // Reprocessing Methods
    func deleteTimelineCards(forDay day: String) -> [String]  // Returns video paths to clean up
    func deleteTimelineCards(forBatchIds batchIds: [Int64]) -> [String]
    func deleteObservations(forBatchIds batchIds: [Int64])
    func resetBatchStatuses(forDay day: String) -> [Int64]  // Returns affected batch IDs
    func resetBatchStatuses(forBatchIds batchIds: [Int64]) -> [Int64]
    func fetchBatches(forDay day: String) -> [(id: Int64, startTs: Int, endTs: Int, status: String)]

    /// Chunks that belong to one batch, already sorted.
    func chunksForBatch(_ batchId: Int64) -> [RecordingChunk]
    
    /// All batches, newest first
    func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)]
}


// NEW: Observation struct for first-class transcript storage
struct Observation: Codable, Sendable {
    let id: Int64?
    let batchId: Int64
    let startTs: Int
    let endTs: Int
    let observation: String
    let metadata: String?
    let llmModel: String?
    let createdAt: Date?
}

// Re-add Distraction struct, as it's used by TimelineCard
struct Distraction: Codable, Sendable, Identifiable {
    let id: UUID
    let startTime: String
    let endTime: String
    let title: String
    let summary: String
    let videoSummaryURL: String? // Optional link to video summary for the distraction

    // Custom decoder to handle missing 'id'
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try to decode 'id', if not found or nil, assign a new UUID
        self.id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.startTime = try container.decode(String.self, forKey: .startTime)
        self.endTime = try container.decode(String.self, forKey: .endTime)
        self.title = try container.decode(String.self, forKey: .title)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.videoSummaryURL = try container.decodeIfPresent(String.self, forKey: .videoSummaryURL)
    }

    // Add explicit init to maintain memberwise initializer if needed elsewhere,
    // though Codable synthesis might handle this. It's good practice.
    init(id: UUID = UUID(), startTime: String, endTime: String, title: String, summary: String, videoSummaryURL: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.summary = summary
        self.videoSummaryURL = videoSummaryURL
    }

    // CodingKeys needed for custom decoder
    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, title, summary, videoSummaryURL
    }
}

struct TimelineCard: Codable, Sendable, Identifiable {
    var id = UUID()
    let recordId: Int64?
    let batchId: Int64? // Tracks source batch for retry functionality
    let startTimestamp: String
    let endTimestamp: String
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
    let day: String
    let distractions: [Distraction]?
    let videoSummaryURL: String? // Optional link to primary video summary
    let otherVideoSummaryURLs: [String]? // For merged cards, subsequent video URLs
    let appSites: AppSites?
}

/// Metadata about a single LLM request/response cycle
struct LLMCall: Codable, Sendable {
    let timestamp: Date?
    let latency: TimeInterval?
    let input: String?
    let output: String?
}

// DB record for llm_calls table
struct LLMCallDBRecord: Sendable {
    let batchId: Int64?
    let callGroupId: String?
    let attempt: Int
    let provider: String
    let model: String?
    let operation: String
    let status: String // "success" | "failure"
    let latencyMs: Int?
    let httpStatus: Int?
    let requestMethod: String?
    let requestURL: String?
    let requestHeadersJSON: String?
    let requestBody: String?
    let responseHeadersJSON: String?
    let responseBody: String?
    let errorDomain: String?
    let errorCode: Int?
    let errorMessage: String?
}

struct TimelineCardDebugEntry: Sendable {
    let createdAt: Date?
    let batchId: Int64?
    let day: String
    let startTime: String
    let endTime: String
    let category: String
    let subcategory: String?
    let title: String
    let summary: String?
    let detailedSummary: String?
}

struct LLMCallDebugEntry: Sendable {
    let createdAt: Date?
    let batchId: Int64?
    let callGroupId: String?
    let attempt: Int
    let provider: String
    let model: String?
    let operation: String
    let status: String
    let latencyMs: Int?
    let httpStatus: Int?
    let requestMethod: String?
    let requestURL: String?
    let requestBody: String?
    let responseBody: String?
    let errorMessage: String?
}

// Add TimelineCardShell struct for the new save function
struct TimelineCardShell: Sendable {
    let startTimestamp: String
    let endTimestamp: String
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
    let distractions: [Distraction]? // Keep this, it's part of the initial save
    let appSites: AppSites?
    // No videoSummaryURL here, as it's added later
    // No batchId here, as it's passed as a separate parameter to the save function
}

// New metadata envelope to support multiple fields under one JSON column
private struct TimelineMetadata: Codable {
    let distractions: [Distraction]?
    let appSites: AppSites?
}

struct AnalysisBatchDebugEntry: Sendable {
    let id: Int64
    let status: String
    let startTs: Int
    let endTs: Int
    let createdAt: Date?
    let reason: String?
}

// Extended TimelineCard with timestamp fields for internal use
struct TimelineCardWithTimestamps {
    let id: Int64
    let startTimestamp: String
    let endTimestamp: String
    let startTs: Int
    let endTs: Int
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
    let day: String
    let distractions: [Distraction]?
    let videoSummaryURL: String?
}


final class StorageManager: StorageManaging, @unchecked Sendable {
    static let shared = StorageManager()

    private let dbURL: URL
    private let db: DatabasePool
    private let fileMgr = FileManager.default
    private let root: URL
    var recordingsRoot: URL { root }

    // TEMPORARY DEBUG: Remove after identifying slow queries
    private let debugSlowQueries = true
    private let slowThresholdMs: Double = 100  // Log anything over 100ms

    // Dedicated queue for database writes to prevent main thread blocking
    private let dbWriteQueue = DispatchQueue(label: "com.dayflow.storage.writes", qos: .utility)

    private init() {
        UserDefaultsMigrator.migrateIfNeeded()
        StoragePathMigrator.migrateIfNeeded()

        let appSupport = fileMgr.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseDir = appSupport.appendingPathComponent("Dayflow", isDirectory: true)
        let recordingsDir = baseDir.appendingPathComponent("recordings", isDirectory: true)

        // Ensure directories exist before opening database
        try? fileMgr.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fileMgr.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        root = recordingsDir
        dbURL = baseDir.appendingPathComponent("chunks.sqlite")

        StorageManager.migrateDatabaseLocationIfNeeded(
            fileManager: fileMgr,
            legacyRecordingsDir: recordingsDir,
            newDatabaseURL: dbURL
        )

        // Configure database with WAL mode for better performance and safety
        var config = Configuration()
        config.maximumReaderCount = 5
        config.prepareDatabase { db in
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        db = try! DatabasePool(path: dbURL.path, configuration: config)

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

        migrate()
        migrateLegacyChunkPathsIfNeeded()

        // Run initial purge, then schedule hourly
        purgeIfNeeded()
        TimelapseStorageManager.shared.purgeIfNeeded()
        startPurgeScheduler()
    }

    // TEMPORARY DEBUG: Timing helpers for database operations
    private func timedWrite<T>(_ label: String, _ block: (Database) throws -> T) throws -> T {
        let callStart = CFAbsoluteTimeGetCurrent()
        var execStart: CFAbsoluteTime = 0
        var execEnd: CFAbsoluteTime = 0

        let writeBreadcrumb = Breadcrumb(level: .debug, category: "database")
        writeBreadcrumb.message = "DB write: \(label)"
        writeBreadcrumb.type = "debug"
        SentryHelper.addBreadcrumb(writeBreadcrumb)

        do {
            let result = try db.write { db in
                execStart = CFAbsoluteTimeGetCurrent()
                defer { execEnd = CFAbsoluteTimeGetCurrent() }
                return try block(db)
            }

            let waitMs = max(0, (execStart - callStart) * 1000)
            let execMs = max(0, (execEnd - execStart) * 1000)

            if debugSlowQueries && (execMs > slowThresholdMs || waitMs > slowThresholdMs) {
                print("⚠️ SLOW WRITE [\(label)]: wait=\(Int(waitMs))ms exec=\(Int(execMs))ms")

                let slowWriteBreadcrumb = Breadcrumb(level: .warning, category: "database")
                slowWriteBreadcrumb.message = "SLOW DB write: \(label)"
                slowWriteBreadcrumb.data = [
                    "duration_ms": Int((waitMs + execMs).rounded()),
                    "wait_ms": Int(waitMs.rounded()),
                    "exec_ms": Int(execMs.rounded())
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

            let slowWriteBreadcrumb = Breadcrumb(level: .error, category: "database")
            slowWriteBreadcrumb.message = "FAILED DB write: \(label)"
            slowWriteBreadcrumb.data = [
                "wait_ms": Int(waitMs.rounded()),
                "exec_ms": Int(execMs.rounded()),
                "error": "\(error)"
            ]
            slowWriteBreadcrumb.type = "error"
            SentryHelper.addBreadcrumb(slowWriteBreadcrumb)
            throw error
        }
    }

    private func timedRead<T>(_ label: String, _ block: (Database) throws -> T) throws -> T {
        let callStart = CFAbsoluteTimeGetCurrent()
        var execStart: CFAbsoluteTime = 0
        var execEnd: CFAbsoluteTime = 0

        let readBreadcrumb = Breadcrumb(level: .debug, category: "database")
        readBreadcrumb.message = "DB read: \(label)"
        readBreadcrumb.type = "debug"
        SentryHelper.addBreadcrumb(readBreadcrumb)

        do {
            let result = try db.read { db in
                execStart = CFAbsoluteTimeGetCurrent()
                defer { execEnd = CFAbsoluteTimeGetCurrent() }
                return try block(db)
            }

            let waitMs = max(0, (execStart - callStart) * 1000)
            let execMs = max(0, (execEnd - execStart) * 1000)

            if debugSlowQueries && (execMs > slowThresholdMs || waitMs > slowThresholdMs) {
                print("⚠️ SLOW READ [\(label)]: wait=\(Int(waitMs))ms exec=\(Int(execMs))ms")

                let slowReadBreadcrumb = Breadcrumb(level: .warning, category: "database")
                slowReadBreadcrumb.message = "SLOW DB read: \(label)"
                slowReadBreadcrumb.data = [
                    "duration_ms": Int((waitMs + execMs).rounded()),
                    "wait_ms": Int(waitMs.rounded()),
                    "exec_ms": Int(execMs.rounded())
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

            let slowReadBreadcrumb = Breadcrumb(level: .error, category: "database")
            slowReadBreadcrumb.message = "FAILED DB read: \(label)"
            slowReadBreadcrumb.data = [
                "wait_ms": Int(waitMs.rounded()),
                "exec_ms": Int(execMs.rounded()),
                "error": "\(error)"
            ]
            slowReadBreadcrumb.type = "error"
            SentryHelper.addBreadcrumb(slowReadBreadcrumb)
            throw error
        }
    }

    private func migrate() {
        try? timedWrite("migrate") { db in
            // Create all tables with their final schema
            try db.execute(sql: """
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
            """)

            // LLM calls logging table
            try db.execute(sql: """
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
                try db.execute(sql: """
                    ALTER TABLE timeline_cards ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;
                """)

                // Create composite partial indexes for common query patterns
                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS idx_timeline_cards_active_start_ts
                    ON timeline_cards(start_ts)
                    WHERE is_deleted = 0;
                """)

                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS idx_timeline_cards_active_batch
                    ON timeline_cards(batch_id)
                    WHERE is_deleted = 0;
                """)

                print("✅ Added is_deleted column and composite indexes to timeline_cards")
            }
        }
    }


    func nextFileURL() -> URL {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmssSSS"
        return root.appendingPathComponent("\(df.string(from: Date())).mp4")
    }

    func registerChunk(url: URL) {
        let ts = Int(Date().timeIntervalSince1970)
        let path = url.path

        // Perform database write asynchronously to avoid blocking caller thread
        dbWriteQueue.async { [weak self] in
            try? self?.timedWrite("registerChunk") { db in
                try db.execute(sql: "INSERT INTO chunks(start_ts, end_ts, file_url, status) VALUES (?, ?, ?, 'recording')",
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
                try db.execute(sql: "UPDATE chunks SET end_ts = ?, status = 'completed' WHERE file_url = ?",
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
            try Row.fetchAll(db, sql: """
                SELECT * FROM chunks
                WHERE start_ts >= ?
                  AND status = 'completed'
                  AND (is_deleted = 0 OR is_deleted IS NULL)
                  AND id NOT IN (SELECT chunk_id FROM batch_chunks)
                ORDER BY start_ts ASC
            """, arguments: [oldestAllowed])
                .map { row in
                    RecordingChunk(id: row["id"], startTs: row["start_ts"], endTs: row["end_ts"], fileUrl: row["file_url"], status: row["status"]) }
        }) ?? []
    }

    func saveBatch(startTs: Int, endTs: Int, chunkIds: [Int64]) -> Int64? {
        guard !chunkIds.isEmpty else { return nil }
        var batchID: Int64 = 0
        try? timedWrite("saveBatch(\(chunkIds.count)_chunks)") { db in
            try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts) VALUES (?, ?)",
                           arguments: [startTs, endTs])
            batchID = db.lastInsertedRowID
            for id in chunkIds {
                try db.execute(sql: "INSERT INTO batch_chunks(batch_id, chunk_id) VALUES (?, ?)", arguments: [batchID, id])
            }
        }
        return batchID == 0 ? nil : batchID
    }

    func updateBatchStatus(batchId: Int64, status: String) {
        // Perform database write asynchronously to avoid blocking caller thread
        dbWriteQueue.async { [weak self] in
            try? self?.timedWrite("updateBatchStatus") { db in
                try db.execute(sql: "UPDATE analysis_batches SET status = ? WHERE id = ?", arguments: [status, batchId])
            }
        }
    }

    func markBatchFailed(batchId: Int64, reason: String) {
        // Perform database write asynchronously to avoid blocking caller thread
        dbWriteQueue.async { [weak self] in
            try? self?.timedWrite("markBatchFailed") { db in
                try db.execute(sql: "UPDATE analysis_batches SET status = 'failed', reason = ? WHERE id = ?", arguments: [reason, batchId])
            }
        }
    }

    func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(calls), let json = String(data: data, encoding: .utf8) else { return }
        try? timedWrite("updateBatchLLMMetadata") { db in
            try db.execute(sql: "UPDATE analysis_batches SET llm_metadata = ? WHERE id = ?", arguments: [json, batchId])
        }
    }

    func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? timedRead("fetchBatchLLMMetadata") { db in
            if let row = try Row.fetchOne(db, sql: "SELECT llm_metadata FROM analysis_batches WHERE id = ?", arguments: [batchId]),
               let json: String = row["llm_metadata"],
               let data = json.data(using: .utf8) {
                return try decoder.decode([LLMCall].self, from: data)
            }
            return []
        }) ?? []
    }

    /// Chunks that belong to one batch, already sorted.
    func chunksForBatch(_ batchId: Int64) -> [RecordingChunk] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.* FROM batch_chunks bc
                JOIN chunks c ON c.id = bc.chunk_id
                WHERE bc.batch_id = ?
                  AND (c.is_deleted = 0 OR c.is_deleted IS NULL)
                ORDER BY c.start_ts ASC
                """, arguments: [batchId]
            ).map { r in
                RecordingChunk(id: r["id"], startTs: r["start_ts"], endTs: r["end_ts"],
                               fileUrl: r["file_url"], status: r["status"])
            }
        }) ?? []
    }

    /// Helper to get the batch start timestamp for date calculations
    private func getBatchStartTimestamp(batchId: Int64) -> Int? {
        return try? db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT batch_start_ts FROM analysis_batches WHERE id = ?
            """, arguments: [batchId])
        }
    }
    
    /// Fetch chunks that overlap with a specific time range
    func fetchChunksInTimeRange(startTs: Int, endTs: Int) -> [RecordingChunk] {
        (try? timedRead("fetchChunksInTimeRange") { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM chunks
                WHERE status = 'completed'
                  AND (is_deleted = 0 OR is_deleted IS NULL)
                  AND ((start_ts <= ? AND end_ts >= ?)
                       OR (start_ts >= ? AND start_ts <= ?)
                       OR (end_ts >= ? AND end_ts <= ?))
                ORDER BY start_ts ASC
            """, arguments: [endTs, startTs, startTs, endTs, startTs, endTs])
            .map { r in
                RecordingChunk(id: r["id"], startTs: r["start_ts"], endTs: r["end_ts"],
                              fileUrl: r["file_url"], status: r["status"])
            }
        }) ?? []
    }


    func saveTimelineCardShell(batchId: Int64, card: TimelineCardShell) -> Int64? {
        let encoder = JSONEncoder()
        var lastId: Int64? = nil

        // Get the batch's actual start timestamp to use as the base date
        guard let batchStartTs = getBatchStartTimestamp(batchId: batchId) else {
            return nil
        }
        let baseDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        guard let startTime = timeFormatter.date(from: card.startTimestamp),
              let endTime = timeFormatter.date(from: card.endTimestamp) else {
            return nil
        }

        let calendar = Calendar.current

        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        guard let startHour = startComponents.hour, let startMinute = startComponents.minute else { return nil }

        var startDate = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: baseDate) ?? baseDate

        // If the parsed time is between midnight and 4 AM, and it's earlier than baseDate,
        // disambiguate whether it's same day (before batch) or next day (after midnight crossing)
        if startHour < 4 && startDate < baseDate {
            let nextDayStartDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate

            // Pick whichever is closer to batch start time
            let sameDayDistance = abs(startDate.timeIntervalSince(baseDate))
            let nextDayDistance = abs(nextDayStartDate.timeIntervalSince(baseDate))

            if nextDayDistance < sameDayDistance {
                // Next day is closer - legitimate midnight crossing
                startDate = nextDayStartDate
            }
            // Otherwise keep same day (LLM provided time before batch started)
        }

        let startTs = Int(startDate.timeIntervalSince1970)

        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
        guard let endHour = endComponents.hour, let endMinute = endComponents.minute else { return nil }

        var endDate = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: baseDate) ?? baseDate

        // Disambiguate end time day using same logic as start time
        if endHour < 4 && endDate < baseDate {
            let nextDayEndDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate

            let sameDayDistance = abs(endDate.timeIntervalSince(baseDate))
            let nextDayDistance = abs(nextDayEndDate.timeIntervalSince(baseDate))

            if nextDayDistance < sameDayDistance {
                endDate = nextDayEndDate
            }
        }

        // Handle midnight crossing: if end time is before start time, it must be the next day
        if endDate < startDate {
            endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        }

        let endTs = Int(endDate.timeIntervalSince1970)

        try? timedWrite("saveTimelineCardShell") {
            db in
            // Encode metadata as an object for forward-compatibility
            let meta = TimelineMetadata(distractions: card.distractions, appSites: card.appSites)
            let metadataString: String? = (try? encoder.encode(meta)).flatMap { String(data: $0, encoding: .utf8) }

            // Calculate the day string using 4 AM boundary rules
            let (dayString, _, _) = startDate.getDayInfoFor4AMBoundary()

            try db.execute(sql: """
                INSERT INTO timeline_cards(
                    batch_id, start, end, start_ts, end_ts, day, title,
                    summary, category, subcategory, detailed_summary, metadata
                    -- video_summary_url is omitted here
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                batchId, card.startTimestamp, card.endTimestamp, startTs, endTs, dayString, card.title,
                card.summary, card.category, card.subcategory, card.detailedSummary, metadataString
            ])
            lastId = db.lastInsertedRowID
        }
        return lastId
    }

    func updateTimelineCardVideoURL(cardId: Int64, videoSummaryURL: String) {
        try? timedWrite("updateTimelineCardVideoURL") {
            db in
            try db.execute(sql: """
                UPDATE timeline_cards
                SET video_summary_url = ?
                WHERE id = ?
            """, arguments: [videoSummaryURL, cardId])
        }
    }

    func updateTimelineCardCategory(cardId: Int64, category: String) {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        try? timedWrite("updateTimelineCardCategory") { db in
            try db.execute(sql: """
                UPDATE timeline_cards
                SET category = ?
                WHERE id = ?
            """, arguments: [trimmed, cardId])
        }
    }

    func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard] {
        let decoder = JSONDecoder()
        return (try? timedRead("fetchTimelineCards(forBatch)") { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM timeline_cards
                WHERE batch_id = ?
                  AND is_deleted = 0
                ORDER BY start ASC
            """, arguments: [batchId]).map { row in
                var distractions: [Distraction]? = nil
                var appSites: AppSites? = nil
                if let metadataString: String = row["metadata"],
                   let jsonData = metadataString.data(using: .utf8) {
                    if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
                        distractions = meta.distractions
                        appSites = meta.appSites
                    } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
                        distractions = legacy
                    }
                }
                return TimelineCard(
                    recordId: row["id"],
                    batchId: batchId,
                    startTimestamp: row["start"] ?? "",
                    endTimestamp: row["end"] ?? "",
                    category: row["category"],
                    subcategory: row["subcategory"],
                    title: row["title"],
                    summary: row["summary"],
                    detailedSummary: row["detailed_summary"],
                    day: row["day"],
                    distractions: distractions,
                    videoSummaryURL: row["video_summary_url"],
                    otherVideoSummaryURLs: nil,
                    appSites: appSites
                )
            }
        }) ?? []
    }

    // All batches, newest first
       func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)] {
            (try? db.read { db in
                try Row.fetchAll(db, sql:
                    "SELECT id, batch_start_ts, batch_end_ts, status FROM analysis_batches ORDER BY id DESC"
                ).map { row in
                    (row["id"], row["batch_start_ts"], row["batch_end_ts"], row["status"])
                }
            }) ?? []
        }

    func fetchRecentAnalysisBatchesForDebug(limit: Int) -> [AnalysisBatchDebugEntry] {
        guard limit > 0 else { return [] }

        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, status, batch_start_ts, batch_end_ts, created_at, reason
                FROM analysis_batches
                ORDER BY id DESC
                LIMIT ?
            """, arguments: [limit]).map { row in
                AnalysisBatchDebugEntry(
                    id: row["id"],
                    status: row["status"] ?? "unknown",
                    startTs: row["batch_start_ts"] ?? 0,
                    endTs: row["batch_end_ts"] ?? 0,
                    createdAt: row["created_at"],
                    reason: row["reason"]
                )
            }
        }) ?? []
    }


    func fetchTimelineCards(forDay day: String) -> [TimelineCard] {
        let decoder = JSONDecoder()
        
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

        let cards: [TimelineCard]? = try? timedRead("fetchTimelineCards(forDay:\(day))") { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM timeline_cards
                WHERE start_ts >= ? AND start_ts < ?
                  AND is_deleted = 0
                ORDER BY start_ts ASC, start ASC
            """, arguments: [startTs, endTs])
            .map { row in
                // Decode metadata JSON (supports object or legacy array)
                var distractions: [Distraction]? = nil
                var appSites: AppSites? = nil
                if let metadataString: String = row["metadata"],
                   let jsonData = metadataString.data(using: .utf8) {
                    if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
                        distractions = meta.distractions
                        appSites = meta.appSites
                    } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
                        distractions = legacy
                    }
                }

                // Create TimelineCard instance using renamed columns
                return TimelineCard(
                    recordId: row["id"],
                    batchId: row["batch_id"],
                    startTimestamp: row["start"] ?? "", // Use row["start"]
                    endTimestamp: row["end"] ?? "",   // Use row["end"]
                    category: row["category"],
                    subcategory: row["subcategory"],
                    title: row["title"],
                    summary: row["summary"],
                    detailedSummary: row["detailed_summary"],
                    day: row["day"],
                    distractions: distractions,
                    videoSummaryURL: row["video_summary_url"],
                    otherVideoSummaryURLs: nil,
                    appSites: appSites
                )
            }
        }
        return cards ?? []
    }

    func fetchTimelineCardsByTimeRange(from: Date, to: Date) -> [TimelineCard] {
        let decoder = JSONDecoder()
        let fromTs = Int(from.timeIntervalSince1970)
        let toTs = Int(to.timeIntervalSince1970)


        let cards: [TimelineCard]? = try? timedRead("fetchTimelineCardsByTimeRange") { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM timeline_cards
                WHERE ((start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?))
                  AND is_deleted = 0
                ORDER BY start_ts ASC
            """, arguments: [toTs, fromTs, fromTs, toTs])
            .map { row in
                // Decode metadata JSON (supports object or legacy array)
                var distractions: [Distraction]? = nil
                var appSites: AppSites? = nil
                if let metadataString: String = row["metadata"],
                   let jsonData = metadataString.data(using: .utf8) {
                    if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
                        distractions = meta.distractions
                        appSites = meta.appSites
                    } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
                        distractions = legacy
                    }
                }

                // Create TimelineCard instance using renamed columns
                return TimelineCard(
                    recordId: row["id"],
                    batchId: row["batch_id"],
                    startTimestamp: row["start"] ?? "",
                    endTimestamp: row["end"] ?? "",
                    category: row["category"],
                    subcategory: row["subcategory"],
                    title: row["title"],
                    summary: row["summary"],
                    detailedSummary: row["detailed_summary"],
                    day: row["day"],
                    distractions: distractions,
                    videoSummaryURL: row["video_summary_url"],
                    otherVideoSummaryURLs: nil,
                    appSites: appSites
                )
            }
        }
        let result = cards ?? []
        return result
    }

    func fetchRecentTimelineCardsForDebug(limit: Int) -> [TimelineCardDebugEntry] {
        guard limit > 0 else { return [] }

        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT batch_id, day, start, end, category, subcategory, title, summary, detailed_summary, created_at
                FROM timeline_cards
                WHERE is_deleted = 0
                ORDER BY created_at DESC, id DESC
                LIMIT ?
            """, arguments: [limit]).map { row in
                TimelineCardDebugEntry(
                    createdAt: row["created_at"],
                    batchId: row["batch_id"],
                    day: row["day"] ?? "",
                    startTime: row["start"] ?? "",
                    endTime: row["end"] ?? "",
                    category: row["category"],
                    subcategory: row["subcategory"],
                    title: row["title"],
                    summary: row["summary"],
                    detailedSummary: row["detailed_summary"]
                )
            }
        }) ?? []
    }

    func fetchRecentLLMCallsForDebug(limit: Int) -> [LLMCallDebugEntry] {
        guard limit > 0 else { return [] }

        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT created_at, batch_id, call_group_id, attempt, provider, model, operation, status, latency_ms, http_status, request_method, request_url, request_body, response_body, error_message
                FROM llm_calls
                ORDER BY created_at DESC, id DESC
                LIMIT ?
            """, arguments: [limit]).map { row in
                LLMCallDebugEntry(
                    createdAt: row["created_at"],
                    batchId: row["batch_id"],
                    callGroupId: row["call_group_id"],
                    attempt: row["attempt"] ?? 0,
                    provider: row["provider"] ?? "",
                    model: row["model"],
                    operation: row["operation"] ?? "",
                    status: row["status"] ?? "",
                    latencyMs: row["latency_ms"],
                    httpStatus: row["http_status"],
                    requestMethod: row["request_method"],
                    requestURL: row["request_url"],
                    requestBody: row["request_body"],
                    responseBody: row["response_body"],
                    errorMessage: row["error_message"]
                )
            }
        }) ?? []
    }

    func updateStorageLimit(bytes: Int64) {
        let previous = StoragePreferences.recordingsLimitBytes
        StoragePreferences.recordingsLimitBytes = bytes

        if bytes < previous {
            purgeIfNeeded()
        }
    }

    func fetchLLMCallsForBatches(batchIds: [Int64], limit: Int) -> [LLMCallDebugEntry] {
        guard !batchIds.isEmpty, limit > 0 else { return [] }

        // Create SQL placeholders for batch IDs
        let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ",")

        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT created_at, batch_id, call_group_id, attempt, provider, model, operation, status, latency_ms, http_status, request_method, request_url, request_body, response_body, error_message
                FROM llm_calls
                WHERE batch_id IN (\(placeholders))
                ORDER BY created_at DESC, id DESC
                LIMIT ?
            """, arguments: StatementArguments(batchIds + [Int64(limit)])).map { row in
                LLMCallDebugEntry(
                    createdAt: row["created_at"],
                    batchId: row["batch_id"],
                    callGroupId: row["call_group_id"],
                    attempt: row["attempt"] ?? 0,
                    provider: row["provider"] ?? "",
                    model: row["model"],
                    operation: row["operation"] ?? "",
                    status: row["status"] ?? "",
                    latencyMs: row["latency_ms"],
                    httpStatus: row["http_status"],
                    requestMethod: row["request_method"],
                    requestURL: row["request_url"],
                    requestBody: row["request_body"],
                    responseBody: row["response_body"],
                    errorMessage: row["error_message"]
                )
            }
        }) ?? []
    }

    /// Fetch a specific timeline card by ID including timestamp fields
    func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? {
        let decoder = JSONDecoder()

        return try? timedRead("fetchTimelineCard(byId)") { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM timeline_cards
                WHERE id = ?
                  AND is_deleted = 0
            """, arguments: [id]) else { return nil }
            
            // Decode distractions from metadata JSON
            var distractions: [Distraction]? = nil
            if let metadataString: String = row["metadata"],
               let jsonData = metadataString.data(using: .utf8) {
                if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
                    distractions = meta.distractions
                } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
                    distractions = legacy
                }
            }
            
            return TimelineCardWithTimestamps(
                id: id,
                startTimestamp: row["start"] ?? "",
                endTimestamp: row["end"] ?? "",
                startTs: row["start_ts"] ?? 0,
                endTs: row["end_ts"] ?? 0,
                category: row["category"],
                subcategory: row["subcategory"],
                title: row["title"],
                summary: row["summary"],
                detailedSummary: row["detailed_summary"],
                day: row["day"],
                distractions: distractions,
                videoSummaryURL: row["video_summary_url"]
            )
        }
    }
    
    func replaceTimelineCardsInRange(from: Date, to: Date, with newCards: [TimelineCardShell], batchId: Int64) -> (insertedIds: [Int64], deletedVideoPaths: [String]) {
        let fromTs = Int(from.timeIntervalSince1970)
        let toTs = Int(to.timeIntervalSince1970)
        
        
        let encoder = JSONEncoder()
        var insertedIds: [Int64] = []
        var videoPaths: [String] = []
        
        // Setup date formatter for parsing clock times
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        try? timedWrite("replaceTimelineCardsInRange(\(newCards.count)_cards)") { db in
            // First, fetch the video paths that will be soft-deleted
            let videoRows = try Row.fetchAll(db, sql: """
                SELECT video_summary_url FROM timeline_cards
                WHERE ((start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?))
                   AND video_summary_url IS NOT NULL
                   AND is_deleted = 0
            """, arguments: [toTs, fromTs, fromTs, toTs])

            videoPaths = videoRows.compactMap { $0["video_summary_url"] as? String }

            // Fetch the cards that will be deleted for debugging
            let cardsToDelete = try Row.fetchAll(db, sql: """
                SELECT id, start, end, title FROM timeline_cards
                WHERE ((start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?))
                   AND is_deleted = 0
            """, arguments: [toTs, fromTs, fromTs, toTs])

            for card in cardsToDelete {
                let id: Int64 = card["id"]
                let start: String = card["start"]
                let end: String = card["end"]
                let title: String = card["title"]
            }

            // Soft delete existing cards in the range using timestamp columns
            try db.execute(sql: """
                UPDATE timeline_cards
                SET is_deleted = 1
                WHERE ((start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?))
                   AND is_deleted = 0
            """, arguments: [toTs, fromTs, fromTs, toTs])

            // Verify soft deletion (count remaining active cards)
            let remainingCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM timeline_cards
                WHERE ((start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?))
                   AND is_deleted = 0
            """, arguments: [toTs, fromTs, fromTs, toTs]) ?? 0
            
            if remainingCount > 0 {
            } else {
            }
            
            // Insert new cards
            for card in newCards {
                // Encode metadata object with distractions and appSites
                let meta = TimelineMetadata(distractions: card.distractions, appSites: card.appSites)
                let metadataString: String? = (try? encoder.encode(meta)).flatMap { String(data: $0, encoding: .utf8) }

                // Resolve clock-only timestamps by picking the nearest day to the window midpoint
                let calendar = Calendar.current
                let anchor = from.addingTimeInterval(to.timeIntervalSince(from) / 2.0)

                let resolveClock: (Int, Int) -> Date = { hour, minute in
                    guard let sameDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: anchor) else {
                        return anchor
                    }
                    let previousDay = calendar.date(byAdding: .day, value: -1, to: sameDay) ?? sameDay
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: sameDay) ?? sameDay

                    let candidates = [previousDay, sameDay, nextDay]
                    return candidates.min { lhs, rhs in
                        abs(lhs.timeIntervalSince(anchor)) < abs(rhs.timeIntervalSince(anchor))
                    } ?? sameDay
                }

                guard let startTime = timeFormatter.date(from: card.startTimestamp),
                      let endTime = timeFormatter.date(from: card.endTimestamp) else {
                    continue
                }

                let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
                guard let startHour = startComponents.hour, let startMinute = startComponents.minute else { continue }

                var startDate = resolveClock(startHour, startMinute)

                let startTs = Int(startDate.timeIntervalSince1970)

                let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
                guard let endHour = endComponents.hour, let endMinute = endComponents.minute else { continue }

                var endDate = resolveClock(endHour, endMinute)

                // Handle midnight crossing: if end time is before start time, it must be the next day
                if endDate < startDate {
                    endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
                }

                let endTs = Int(endDate.timeIntervalSince1970)

                // Calculate the day string using 4 AM boundary rules
                let (dayString, _, _) = startDate.getDayInfoFor4AMBoundary()

                try db.execute(sql: """
                    INSERT INTO timeline_cards(
                        batch_id, start, end, start_ts, end_ts, day, title,
                        summary, category, subcategory, detailed_summary, metadata
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    batchId, card.startTimestamp, card.endTimestamp, startTs, endTs, dayString, card.title,
                    card.summary, card.category, card.subcategory, card.detailedSummary, metadataString
                ])
                
                // Capture the ID of the inserted card
                let insertedId = db.lastInsertedRowID
                insertedIds.append(insertedId)
            }
        }
        
        return (insertedIds, videoPaths)
    }

    // Note: Transcript storage methods removed in favor of Observations table
    
    
    func saveObservations(batchId: Int64, observations: [Observation]) {
        guard !observations.isEmpty else { return }
        try? timedWrite("saveObservations(\(observations.count)_items)") { db in
            for obs in observations {
                try db.execute(sql: """
                    INSERT INTO observations(
                        batch_id, start_ts, end_ts, observation, metadata, llm_model
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    batchId, obs.startTs, obs.endTs, obs.observation, 
                    obs.metadata, obs.llmModel
                ])
            }
        }
    }
    
    func fetchObservations(batchId: Int64) -> [Observation] {
        (try? timedRead("fetchObservations(batchId)") { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM observations 
                WHERE batch_id = ? 
                ORDER BY start_ts ASC
            """, arguments: [batchId]).map { row in
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
        
        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM observations 
                WHERE (start_ts < ? AND end_ts > ?) 
                   OR (start_ts >= ? AND start_ts < ?)
                ORDER BY start_ts ASC
            """, arguments: [toTs, fromTs, fromTs, toTs]).map { row in
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
    
    
    func getChunkFilesForBatch(batchId: Int64) -> [String] {
        return (try? db.read { db in
            let sql = """
                SELECT c.file_url
                FROM chunks c
                JOIN batch_chunks bc ON c.id = bc.chunk_id
                WHERE bc.batch_id = ?
                  AND (c.is_deleted = 0 OR c.is_deleted IS NULL)
                ORDER BY c.start_ts
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [batchId])
            return rows.compactMap { $0["file_url"] as? String }
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
    
    func updateBatchMetadata(_ batchId: Int64, metadata: String) {
        try? db.write { db in
            let sql = """
                UPDATE analysis_batches
                SET llm_metadata = ?
                WHERE id = ?
            """
            try db.execute(sql: sql, arguments: [metadata, batchId])
        }
    }
    
    var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    func insertLLMCall(_ rec: LLMCallDBRecord) {
        try? db.write { db in
            try db.execute(sql: """
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
                rec.errorMessage
            ])
        }
    }
    
    func fetchObservations(startTs: Int, endTs: Int) -> [Observation] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM observations 
                WHERE start_ts >= ? AND end_ts <= ?
                ORDER BY start_ts ASC
            """, arguments: [startTs, endTs]).map { row in
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
        let sql = "SELECT file_url, start_ts, end_ts FROM chunks WHERE file_url IN (\(placeholders)) AND (is_deleted = 0 OR is_deleted IS NULL)"
        try? db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(paths))
            for row in rows {
                if let path: String = row["file_url"],
                   let start: Int  = row["start_ts"],
                   let end:   Int  = row["end_ts"] {
                    out[path] = (start, end)
                }
            }
        }
        return out
    }

    
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
            let rows = try Row.fetchAll(db, sql: """
                SELECT video_summary_url FROM timeline_cards
                WHERE start_ts >= ? AND start_ts < ?
                  AND video_summary_url IS NOT NULL
                  AND is_deleted = 0
            """, arguments: [startTs, endTs])

            videoPaths = rows.compactMap { $0["video_summary_url"] as? String }

            // Soft delete the timeline cards by setting is_deleted = 1
            try db.execute(sql: """
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
            try db.execute(sql: """
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
        guard let startOfDay = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: dayDate) else { return [] }
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let startTs = Int(startOfDay.timeIntervalSince1970)
        let endTs = Int(endOfDay.timeIntervalSince1970)
        
        try? db.write { db in
            // Fetch batch IDs first
            let rows = try Row.fetchAll(db, sql: """
                SELECT id FROM analysis_batches
                WHERE batch_start_ts >= ? AND batch_end_ts <= ?
                  AND status IN ('completed', 'failed', 'processing', 'analyzed')
            """, arguments: [startTs, endTs])
            
            affectedBatchIds = rows.compactMap { $0["id"] as? Int64 }
            
            // Reset their status to pending
            if !affectedBatchIds.isEmpty {
                let placeholders = Array(repeating: "?", count: affectedBatchIds.count).joined(separator: ",")
                try db.execute(sql: """
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

                let affectedPlaceholders = Array(repeating: "?", count: affectedBatchIds.count).joined(separator: ",")
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
        guard let startOfDay = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: dayDate) else { return [] }
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let startTs = Int(startOfDay.timeIntervalSince1970)
        let endTs = Int(endOfDay.timeIntervalSince1970)
        
        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, batch_start_ts, batch_end_ts, status FROM analysis_batches
                WHERE batch_start_ts >= ? AND batch_end_ts <= ?
                ORDER BY batch_start_ts ASC
            """, arguments: [startTs, endTs]).map { row in
                (
                    id: row["id"] as? Int64 ?? 0,
                    startTs: Int(row["batch_start_ts"] as? Int64 ?? 0),
                    endTs: Int(row["batch_end_ts"] as? Int64 ?? 0),
                    status: row["status"] as? String ?? ""
                )
            }
        }) ?? []
    }
    
    func resetSpecificBatchStatuses(batchIds: [Int64]) {
        guard !batchIds.isEmpty else { return }
        
        try? db.write { db in
            let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ",")
            try db.execute(sql: """
                UPDATE analysis_batches
                SET status = 'pending', reason = NULL, llm_metadata = NULL
                WHERE id IN (\(placeholders))
            """, arguments: StatementArguments(batchIds))
        }
    }


    private let purgeQ = DispatchQueue(label: "com.dayflow.storage.purge", qos: .background)
    private var purgeTimer: DispatchSourceTimer?

    private func startPurgeScheduler() {
        let timer = DispatchSource.makeTimerSource(queue: purgeQ)
        timer.schedule(deadline: .now() + 3600, repeating: 3600) // Every hour
        timer.setEventHandler { [weak self] in
            self?.purgeIfNeeded()
            TimelapseStorageManager.shared.purgeIfNeeded()
        }
        timer.resume()
        purgeTimer = timer
    }

    private func purgeIfNeeded() {
        purgeQ.async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Check current size and user-defined limit
                let currentSize = try self.fileMgr.allocatedSizeOfDirectory(at: self.root)
                let limit = StoragePreferences.recordingsLimitBytes

                if limit == Int64.max {
                    return // Unlimited storage - skip purge
                }
                
                // 3 days cutoff for all chunks
                let cutoffDate = Date().addingTimeInterval(-3 * 24 * 60 * 60)
                let cutoffTimestamp = Int(cutoffDate.timeIntervalSince1970)
                
                // Clean up if above limit
                if currentSize > limit {

                    try self.timedWrite("purgeIfNeeded") { db in
                        // Get chunks older than 3 days with file paths still set
                        let oldChunks = try Row.fetchAll(db, sql: """
                            SELECT id, file_url, start_ts 
                            FROM chunks 
                            WHERE start_ts < ?
                            AND file_url IS NOT NULL
                            AND file_url != ''
                            AND (is_deleted = 0 OR is_deleted IS NULL)
                            ORDER BY start_ts ASC 
                            LIMIT 500
                        """, arguments: [cutoffTimestamp])
                        
                        var deletedCount = 0
                        var freedSpace: Int64 = 0
                        
                        for chunk in oldChunks {
                            guard let id: Int64 = chunk["id"],
                                  let path: String = chunk["file_url"] else { continue }

                            // Get file size before deletion
                            var fileSize: Int64 = 0
                            if FileManager.default.fileExists(atPath: path) {
                                if let attrs = try? self.fileMgr.attributesOfItem(atPath: path),
                                   let size = attrs[.size] as? NSNumber {
                                    fileSize = size.int64Value
                                }
                            }

                            // Mark as deleted in DB first (safer ordering)
                            try db.execute(sql: """
                                UPDATE chunks
                                SET is_deleted = 1
                                WHERE id = ?
                            """, arguments: [id])

                            // Then delete physical file
                            if FileManager.default.fileExists(atPath: path) {
                                do {
                                    try self.fileMgr.removeItem(atPath: path)
                                    freedSpace += fileSize
                                    deletedCount += 1
                                } catch {
                                    print("⚠️ Failed to delete chunk file at \(path): \(error)")
                                    // Don't count as freed space if deletion failed
                                }
                            } else {
                                // File already gone, still count the DB cleanup
                                deletedCount += 1
                            }

                            // Stop if we've freed enough space (under 10GB)
                            if currentSize - freedSpace < limit {
                                break
                            }
                        }
                        
                        // freedGB retained for future use if needed
                    }
                }
            } catch {
                print("❌ Purge error: \(error)")
            }
        }
    }
}


private extension StorageManager {
    func migrateLegacyChunkPathsIfNeeded() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        guard let appSupport = fileMgr.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let legacyBase = fileMgr.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/Dayflow", isDirectory: true)
        let newBase = appSupport.appendingPathComponent("Dayflow", isDirectory: true)

        guard legacyBase.path != newBase.path else { return }

        func normalizedPrefix(_ path: String) -> String {
            path.hasSuffix("/") ? path : path + "/"
        }

        let legacyRecordings = normalizedPrefix(legacyBase.appendingPathComponent("recordings", isDirectory: true).path)
        let newRecordings = normalizedPrefix(root.path)

        let legacyTimelapses = normalizedPrefix(legacyBase.appendingPathComponent("timelapses", isDirectory: true).path)
        let newTimelapses = normalizedPrefix(newBase.appendingPathComponent("timelapses", isDirectory: true).path)

        let replacements: [(label: String, table: String, column: String, legacyPrefix: String, newPrefix: String)] = [
            ("chunk file paths", "chunks", "file_url", legacyRecordings, newRecordings),
            ("timelapse video paths", "timeline_cards", "video_summary_url", legacyTimelapses, newTimelapses)
        ]

        do {
            try timedWrite("migrateLegacyFileURLs") { db in
                for replacement in replacements {
                    guard replacement.legacyPrefix != replacement.newPrefix else { continue }

                    let pattern = replacement.legacyPrefix + "%"
                    let count = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM \(replacement.table) WHERE \(replacement.column) LIKE ?",
                        arguments: [pattern]
                    ) ?? 0

                    guard count > 0 else { continue }

                    try db.execute(
                        sql: """
                            UPDATE \(replacement.table)
                            SET \(replacement.column) = REPLACE(\(replacement.column), ?, ?)
                            WHERE \(replacement.column) LIKE ?
                        """,
                        arguments: [replacement.legacyPrefix, replacement.newPrefix, pattern]
                    )

                    let updated = db.changesCount
                    print("ℹ️ StorageManager: migrated \(updated) \(replacement.label) to \(replacement.newPrefix)")
                }
            }
        } catch {
            print("⚠️ StorageManager: failed to migrate legacy file URLs: \(error)")
        }
    }

    static func migrateDatabaseLocationIfNeeded(
        fileManager: FileManager,
        legacyRecordingsDir: URL,
        newDatabaseURL: URL
    ) {
        let destinationDir = newDatabaseURL.deletingLastPathComponent()
        let filenames = ["chunks.sqlite", "chunks.sqlite-wal", "chunks.sqlite-shm"]

        guard filenames.contains(where: { fileManager.fileExists(atPath: legacyRecordingsDir.appendingPathComponent($0).path) }) else {
            return
        }

        if !fileManager.fileExists(atPath: destinationDir.path) {
            try? fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }

        for name in filenames {
            let legacyURL = legacyRecordingsDir.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: legacyURL.path) else { continue }

            let destinationURL = destinationDir.appendingPathComponent(name)
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: legacyURL, to: destinationURL)
                print("ℹ️ StorageManager: migrated \(name) to \(destinationURL.path)")
            } catch {
                print("⚠️ StorageManager: failed to migrate \(name): \(error)")
            }
        }
    }
}


extension FileManager {
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])
                if values.isDirectory == true {
                    // Directories report 0, rely on enumerator to traverse contents
                    continue
                }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            } catch {
                continue
            }
        }
        return total
    }
}
