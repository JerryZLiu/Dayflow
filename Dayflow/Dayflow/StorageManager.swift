//
//  StorageManager.swift
//  Dayflow
//
//  Created by Jerry Liu on 4/26/25.
//  Revised 5/1/25 – remove @MainActor isolation so callers from background
//  queues/Swift concurrency contexts can access the API without "MainActor"
//  hops.  All GRDB work is already serialized internally via `DatabaseQueue`,
//  so thread‑safety is preserved.
//

import Foundation
import GRDB

// Helper DateFormatter (can be static var in an extension or class)
extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        // Using current time zone. Consider UTC if needed for absolute consistency.
        formatter.timeZone = Calendar.current.timeZone
        return formatter
    }()

    // Add ISO8601 formatter if needed for parsing Gemini strings elsewhere
    // Example:
    // static let iso8601Full: ISO8601DateFormatter = {
    //     let formatter = ISO8601DateFormatter()
    //     formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    //     return formatter
    // }()
}

// MARK: - Date Helper Extension
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

// MARK: - Protocol ------------------------------------------------------------

/// File + database persistence used by screen‑recorder & Gemini pipeline.
///
/// _No_ `@MainActor` isolation ⇒ can be called from any thread/actor.
/// If you add UI‑touching methods later, isolate **those** individually.
protocol StorageManaging: Sendable {
    // MARK: - V2 API (New Methods)
    
    // Recording lifecycle
    func nextFileURL() -> URL
    func registerRecording(url: URL)
    func markRecordingCompleted(url: URL)
    func markRecordingFailed(url: URL)

    // Batch management
    func createProcessingBatch(startTs: Int, endTs: Int, recordingIds: [Int64]) -> Int64?
    func updateProcessingBatchStatus(_ id: Int64, status: String, reason: String?)
    func flagBatch(_ id: Int64, timelineDone: Bool?, questionsDone: Bool?, summaryDone: Bool?)

    // Observations
    func saveObservations(batchId: Int64, observations: [Observation])
    func fetchObservations(batchId: Int64) -> [Observation]

    // Timeline
    func saveTimelineEntry(batchId: Int64, entry: TimelineEntry) -> Int64?
    func updateTimelineEntryVideoURL(id: Int64, url: String)
    func fetchTimelineEntries(dayKey: String) -> [TimelineEntry]

    // Questions
    func saveQuestions(_ qs: [Question]) -> [Int64]
    func saveAnswers(_ answers: [Answer])
    func fetchAnswers(questionId: Int64, dayKey: String) -> [Answer]

    // Daily Summaries
    func saveDailySummary(_ summary: DailySummary)
    func fetchDailySummary(dayKey: String) -> DailySummary?

    // Misc
    func recordingsForBatch(_ id: Int64) -> [Recording]
    func purgeIfNeeded()
    
    // MARK: - V1 API (Legacy Methods - Deprecated)
    
    // Recording‑chunk lifecycle (deprecated - use v2 methods above)
    func registerChunk(url: URL)
    func markChunkCompleted(url: URL)
    func markChunkFailed(url: URL)

    // Fetch unprocessed (completed + not yet batched) chunks (deprecated)
    func fetchUnprocessedChunks(olderThan oldestAllowed: Int) -> [RecordingChunk]

    // Analysis‑batch management (deprecated)
    func saveBatch(startTs: Int, endTs: Int, chunkIds: [Int64]) -> Int64?
    func updateBatchStatus(batchId: Int64, status: String)
    func markBatchFailed(batchId: Int64, reason: String)

    // Record details about all LLM calls for a batch (deprecated)
    func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall])
    func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall]

    // Timeline‑cards (deprecated)
    func saveTimelineCardShell(batchId: Int64, card: TimelineCardShell) -> Int64?
    func updateTimelineCardVideoURL(cardId: Int64, videoSummaryURL: String)
    func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard]

    // Timeline Queries (deprecated)
    func fetchTimelineCards(forDay day: String) -> [TimelineCard]

    // Transcript Storage - Updated for ClockTranscriptChunk (deprecated)
    func saveTranscript(batchId: Int64, chunks: [ClockTranscriptChunk])
    func fetchTranscript(batchId: Int64) -> [ClockTranscriptChunk]

    // Helper for GeminiService – map file paths → timestamps (deprecated)
    func getTimestampsForVideoFiles(paths: [String]) -> [String: (startTs: Int, endTs: Int)]

    /// Chunks that belong to one batch, already sorted. (deprecated)
    func chunksForBatch(_ batchId: Int64) -> [RecordingChunk]
}

// MARK: - Data Structures -----------------------------------------------------

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
}

/// Metadata about a single LLM request/response cycle
struct LLMCall: Codable, Sendable {
    let timestamp: Date?
    let latency: TimeInterval?
    let input: String?
    let output: String?
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
    let day: String
    let distractions: [Distraction]? // Keep this, it's part of the initial save
    // No videoSummaryURL here, as it's added later
    // No batchId here, as it's passed as a separate parameter to the save function
}

// MARK: - Implementation ------------------------------------------------------

final class StorageManager: StorageManaging, @unchecked Sendable {
    static let shared = StorageManager()

    private let db: DatabaseQueue
    private let fileMgr = FileManager.default
    private let root: URL
    private let quota = 5 * 1024 * 1024 * 1024  // 5 GB
    var recordingsRoot: URL { root }

    private init() {
        root = fileMgr.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dayflow/recordings", isDirectory: true)
        try? fileMgr.createDirectory(at: root, withIntermediateDirectories: true)

        // Delete old DB file for v2 migration (no migration path required)
        let dbPath = root.appendingPathComponent("chunks.sqlite").path
        let dbURL = URL(fileURLWithPath: dbPath)
        if fileMgr.fileExists(atPath: dbPath) {
            try? fileMgr.removeItem(at: dbURL)
            print("StorageManager: Deleted old v1 database for v2 migration")
        }

        db = try! DatabaseQueue(path: dbPath)
        migrateV2()
        purgeIfNeeded()
    }

    // MARK: – Schema / migrations
    private func migrateV2() {
        try? db.write { db in
            // 1. Recordings (formerly "chunks")
            try db.execute(sql: """
                CREATE TABLE recordings (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    start_ts    INTEGER  NOT NULL,
                    end_ts      INTEGER  NOT NULL,
                    file_url    TEXT     NOT NULL UNIQUE,
                    status      TEXT     NOT NULL DEFAULT 'recording'
                );
                CREATE INDEX idx_recordings_status   ON recordings(status);
                CREATE INDEX idx_recordings_start_ts ON recordings(start_ts);
            """)

            // 2. Processing Batches (formerly "analysis_batches")
            try db.execute(sql: """
                CREATE TABLE processing_batches (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    batch_start_ts    INTEGER NOT NULL,
                    batch_end_ts      INTEGER NOT NULL,
                    status            TEXT    NOT NULL DEFAULT 'pending',
                    reason            TEXT,
                    llm_metadata      TEXT,
                    detailed_transcription TEXT,
                    timeline_processed   INTEGER NOT NULL DEFAULT 0,
                    questions_processed  INTEGER NOT NULL DEFAULT 0,
                    summary_processed    INTEGER NOT NULL DEFAULT 0,
                    created_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX idx_processing_batches_status ON processing_batches(status);
            """)

            // 3. Batch ↔︎ Recording join (formerly "batch_chunks")
            try db.execute(sql: """
                CREATE TABLE batch_recordings (
                    batch_id     INTEGER NOT NULL REFERENCES processing_batches(id) ON DELETE CASCADE,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id)         ON DELETE RESTRICT,
                    PRIMARY KEY (batch_id, recording_id)
                );
            """)

            // 4. Timeline Entries (formerly "timeline_cards")
            try db.execute(sql: """
                CREATE TABLE timeline_entries (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    batch_id         INTEGER REFERENCES processing_batches(id) ON DELETE CASCADE,
                    start            TEXT    NOT NULL,
                    end              TEXT    NOT NULL,
                    day              DATE    NOT NULL,
                    title            TEXT    NOT NULL,
                    summary          TEXT,
                    category         TEXT    NOT NULL,
                    subcategory      TEXT,
                    detailed_summary TEXT,
                    metadata         TEXT,     -- JSON distractions
                    video_summary_url TEXT,
                    created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX idx_timeline_entries_day ON timeline_entries(day);
            """)

            // 5. Observations (new)
            try db.execute(sql: """
                CREATE TABLE observations (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    batch_id    INTEGER NOT NULL REFERENCES processing_batches(id) ON DELETE CASCADE,
                    start_time  TEXT    NOT NULL,
                    end_time    TEXT    NOT NULL,
                    description TEXT    NOT NULL,
                    llm_source  TEXT    NOT NULL,
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX idx_observations_batch_id ON observations(batch_id);
                CREATE INDEX idx_observations_start    ON observations(start_time);
            """)

            // 6. Questions (new)
            try db.execute(sql: """
                CREATE TABLE questions (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    prompt      TEXT    NOT NULL,
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
            """)

            // 7. Answers (new)
            try db.execute(sql: """
                CREATE TABLE answers (
                    question_id INTEGER NOT NULL REFERENCES questions(id)          ON DELETE CASCADE,
                    batch_id    INTEGER NOT NULL REFERENCES processing_batches(id) ON DELETE CASCADE,
                    value       REAL    NOT NULL,
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (question_id, batch_id)
                );
                CREATE INDEX idx_answers_question_batch ON answers(question_id, batch_id);
            """)

            // 8. Daily Summaries (new)
            try db.execute(sql: """
                CREATE TABLE daily_summaries (
                    day_key     TEXT PRIMARY KEY,
                    summary_md  TEXT,
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
            """)
        }
    }

    // MARK: – V2 API Implementation -------------------------------------------
    
    // MARK: Recording lifecycle (v2)
    func registerRecording(url: URL) {
        let ts = Int(Date().timeIntervalSince1970)
        try? db.write { db in
            try db.execute(sql: "INSERT INTO recordings(start_ts, end_ts, file_url, status) VALUES (?, ?, ?, 'recording')",
                           arguments: [ts, ts + 60, url.path])
        }
        purgeIfNeeded()
    }
    
    func markRecordingCompleted(url: URL) {
        let end = Int(Date().timeIntervalSince1970)
        try? db.write { db in
            try db.execute(sql: "UPDATE recordings SET end_ts = ?, status = 'completed' WHERE file_url = ?",
                           arguments: [end, url.path])
        }
    }
    
    func markRecordingFailed(url: URL) {
        try? db.write { db in
            try db.execute(sql: "DELETE FROM recordings WHERE file_url = ?", arguments: [url.path])
        }
        try? fileMgr.removeItem(at: url)
    }
    
    // MARK: Batch management (v2)
    func createProcessingBatch(startTs: Int, endTs: Int, recordingIds: [Int64]) -> Int64? {
        guard !recordingIds.isEmpty else { return nil }
        var batchID: Int64 = 0
        try? db.write { db in
            try db.execute(sql: "INSERT INTO processing_batches(batch_start_ts, batch_end_ts) VALUES (?, ?)",
                           arguments: [startTs, endTs])
            batchID = db.lastInsertedRowID
            for id in recordingIds {
                try db.execute(sql: "INSERT INTO batch_recordings(batch_id, recording_id) VALUES (?, ?)", arguments: [batchID, id])
            }
        }
        return batchID == 0 ? nil : batchID
    }
    
    func updateProcessingBatchStatus(_ id: Int64, status: String, reason: String?) {
        try? db.write { db in
            try db.execute(sql: "UPDATE processing_batches SET status = ?, reason = ? WHERE id = ?", 
                           arguments: [status, reason, id])
        }
    }
    
    func flagBatch(_ id: Int64, timelineDone: Bool?, questionsDone: Bool?, summaryDone: Bool?) {
        try? db.write { db in
            var updates: [String] = []
            var args: [DatabaseValueConvertible] = []
            
            if let timelineDone = timelineDone {
                updates.append("timeline_processed = ?")
                args.append(timelineDone ? 1 : 0)
            }
            if let questionsDone = questionsDone {
                updates.append("questions_processed = ?")
                args.append(questionsDone ? 1 : 0)
            }
            if let summaryDone = summaryDone {
                updates.append("summary_processed = ?")
                args.append(summaryDone ? 1 : 0)
            }
            
            if !updates.isEmpty {
                args.append(id)
                let sql = "UPDATE processing_batches SET \(updates.joined(separator: ", ")) WHERE id = ?"
                try db.execute(sql: sql, arguments: StatementArguments(args))
            }
        }
    }
    
    // MARK: Observations (v2)
    func saveObservations(batchId: Int64, observations: [Observation]) {
        guard !observations.isEmpty else { return }
        try? db.write { db in
            for obs in observations {
                try db.execute(sql: """
                    INSERT INTO observations(batch_id, start_time, end_time, description, llm_source)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [batchId, obs.startTime, obs.endTime, obs.description, obs.llmSource])
            }
        }
    }
    
    func fetchObservations(batchId: Int64) -> [Observation] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM observations WHERE batch_id = ? ORDER BY start_time ASC", 
                             arguments: [batchId]).map { row in
                Observation(
                    id: row["id"],
                    batchId: row["batch_id"],
                    startTime: row["start_time"],
                    endTime: row["end_time"],
                    description: row["description"],
                    llmSource: row["llm_source"],
                    createdAt: row["created_at"]
                )
            }
        }) ?? []
    }
    
    // MARK: Timeline (v2)
    func saveTimelineEntry(batchId: Int64, entry: TimelineEntry) -> Int64? {
        var lastId: Int64? = nil
        try? db.write { db in
            try db.execute(sql: """
                INSERT INTO timeline_entries(
                    batch_id, start, end, day, title, summary, category, subcategory, 
                    detailed_summary, metadata, video_summary_url
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                batchId, entry.start, entry.end, entry.day, entry.title, entry.summary,
                entry.category, entry.subcategory, entry.detailedSummary, entry.metadata, entry.videoSummaryUrl
            ])
            lastId = db.lastInsertedRowID
        }
        return lastId
    }
    
    func updateTimelineEntryVideoURL(id: Int64, url: String) {
        try? db.write { db in
            try db.execute(sql: "UPDATE timeline_entries SET video_summary_url = ? WHERE id = ?", 
                           arguments: [url, id])
        }
    }
    
    func fetchTimelineEntries(dayKey: String) -> [TimelineEntry] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM timeline_entries WHERE day = ? ORDER BY start ASC", 
                             arguments: [dayKey]).map { row in
                TimelineEntry(
                    id: row["id"],
                    batchId: row["batch_id"],
                    start: row["start"],
                    end: row["end"],
                    day: row["day"],
                    title: row["title"],
                    summary: row["summary"],
                    category: row["category"],
                    subcategory: row["subcategory"],
                    detailedSummary: row["detailed_summary"],
                    metadata: row["metadata"],
                    videoSummaryUrl: row["video_summary_url"],
                    createdAt: row["created_at"]
                )
            }
        }) ?? []
    }
    
    // MARK: Questions (v2)
    func saveQuestions(_ qs: [Question]) -> [Int64] {
        guard !qs.isEmpty else { return [] }
        var ids: [Int64] = []
        try? db.write { db in
            for q in qs {
                try db.execute(sql: "INSERT INTO questions(prompt) VALUES (?)", arguments: [q.prompt])
                ids.append(db.lastInsertedRowID)
            }
        }
        return ids
    }
    
    func saveAnswers(_ answers: [Answer]) {
        guard !answers.isEmpty else { return }
        try? db.write { db in
            for answer in answers {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO answers(question_id, batch_id, value) VALUES (?, ?, ?)
                """, arguments: [answer.questionId, answer.batchId, answer.value])
            }
        }
    }
    
    func fetchAnswers(questionId: Int64, dayKey: String) -> [Answer] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.* FROM answers a
                JOIN processing_batches pb ON a.batch_id = pb.id
                JOIN batch_recordings br ON pb.id = br.batch_id
                JOIN recordings r ON br.recording_id = r.id
                WHERE a.question_id = ? AND DATE(r.start_ts, 'unixepoch') = ?
            """, arguments: [questionId, dayKey]).map { row in
                Answer(
                    questionId: row["question_id"],
                    batchId: row["batch_id"],
                    value: row["value"],
                    createdAt: row["created_at"]
                )
            }
        }) ?? []
    }
    
    // MARK: Daily Summaries (v2)
    func saveDailySummary(_ summary: DailySummary) {
        try? db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO daily_summaries(day_key, summary_md) VALUES (?, ?)
            """, arguments: [summary.dayKey, summary.summaryMd])
        }
    }
    
    func fetchDailySummary(dayKey: String) -> DailySummary? {
        try? db.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM daily_summaries WHERE day_key = ?", 
                                          arguments: [dayKey]) {
                return DailySummary(
                    dayKey: row["day_key"],
                    summaryMd: row["summary_md"],
                    createdAt: row["created_at"]
                )
            }
            return nil
        }
    }
    
    // MARK: Misc (v2)
    func recordingsForBatch(_ id: Int64) -> [Recording] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.* FROM batch_recordings br
                JOIN recordings r ON r.id = br.recording_id
                WHERE br.batch_id = ?
                ORDER BY r.start_ts ASC
            """, arguments: [id]).map { row in
                Recording(
                    id: row["id"],
                    startTs: row["start_ts"],
                    endTs: row["end_ts"],
                    fileUrl: row["file_url"],
                    status: row["status"]
                )
            }
        }) ?? []
    }

    // MARK: – V1 Legacy Methods (Recording‑file helpers) ----------------------

    func nextFileURL() -> URL {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmssSSS"
        return root.appendingPathComponent("\(df.string(from: Date())).mp4")
    }

    func registerChunk(url: URL) {
        let ts = Int(Date().timeIntervalSince1970)
        try? db.write { db in
            try db.execute(sql: "INSERT INTO chunks(start_ts, end_ts, file_url, status) VALUES (?, ?, ?, 'recording')",
                           arguments: [ts, ts + 60, url.path])
        }
        purgeIfNeeded()
    }

    func markChunkCompleted(url: URL) {
        let end = Int(Date().timeIntervalSince1970)
        try? db.write { db in
            try db.execute(sql: "UPDATE chunks SET end_ts = ?, status = 'completed' WHERE file_url = ?",
                           arguments: [end, url.path])
        }
    }

    func markChunkFailed(url: URL) {
        try? db.write { db in
            try db.execute(sql: "DELETE FROM chunks WHERE file_url = ?", arguments: [url.path])
        }
        try? fileMgr.removeItem(at: url)
    }

    // MARK: – Queries used by GeminiAnalysisManager ---------------------------

    func fetchUnprocessedChunks(olderThan oldestAllowed: Int) -> [RecordingChunk] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM chunks
                WHERE start_ts >= ?
                  AND status = 'completed'
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
        try? db.write { db in
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
        try? db.write { db in
            try db.execute(sql: "UPDATE analysis_batches SET status = ? WHERE id = ?", arguments: [status, batchId])
        }
    }

    func markBatchFailed(batchId: Int64, reason: String) {
        try? db.write { db in
            try db.execute(sql: "UPDATE analysis_batches SET status = 'failed', reason = ? WHERE id = ?", arguments: [reason, batchId])
        }
    }

    func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(calls), let json = String(data: data, encoding: .utf8) else { return }
        try? db.write { db in
            try db.execute(sql: "UPDATE analysis_batches SET llm_metadata = ? WHERE id = ?", arguments: [json, batchId])
        }
    }

    func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? db.read { db in
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
                ORDER BY c.start_ts ASC
                """, arguments: [batchId]
            ).map { r in
                RecordingChunk(id: r["id"], startTs: r["start_ts"], endTs: r["end_ts"],
                               fileUrl: r["file_url"], status: r["status"])
            }
        }) ?? []
    }

    // MARK: – Timeline‑cards --------------------------------------------------

    func saveTimelineCardShell(batchId: Int64, card: TimelineCardShell) -> Int64? {
        let encoder = JSONEncoder()
        var lastId: Int64? = nil
        try? db.write {
            db in
            var distractionsString: String? = nil
            if let distractions = card.distractions, !distractions.isEmpty {
                if let jsonData = try? encoder.encode(distractions) {
                    distractionsString = String(data: jsonData, encoding: .utf8)
                }
            }

            try db.execute(sql: """
                INSERT INTO timeline_cards(
                    batch_id, start, end, day, title,
                    summary, category, subcategory, detailed_summary, metadata
                    -- video_summary_url is omitted here
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                batchId, card.startTimestamp, card.endTimestamp, card.day, card.title,
                card.summary, card.category, card.subcategory, card.detailedSummary, distractionsString
            ])
            lastId = db.lastInsertedRowID
        }
        return lastId
    }

    func updateTimelineCardVideoURL(cardId: Int64, videoSummaryURL: String) {
        try? db.write {
            db in
            try db.execute(sql: """
                UPDATE timeline_cards
                SET video_summary_url = ?
                WHERE id = ?
            """, arguments: [videoSummaryURL, cardId])
        }
    }

    func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard] {
        let decoder = JSONDecoder()
        return (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM timeline_cards WHERE batch_id = ? ORDER BY start ASC", arguments: [batchId]).map { row in
                var distractions: [Distraction]? = nil
                if let metadataString: String = row["metadata"],
                   let jsonData = metadataString.data(using: .utf8) {
                    distractions = try? decoder.decode([Distraction].self, from: jsonData)
                }
                return TimelineCard(
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
                    otherVideoSummaryURLs: nil
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

    // MARK: - Timeline Queries -----------------------------------------------

    func fetchTimelineCards(forDay day: String) -> [TimelineCard] {
        let decoder = JSONDecoder()
        let cards: [TimelineCard]? = try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM timeline_cards
                WHERE day = ?
                ORDER BY start ASC -- Order by renamed column 'start'
            """, arguments: [day])
            .map { row in
                // Decode distractions from metadata JSON
                var distractions: [Distraction]? = nil
                if let metadataString: String = row["metadata"],
                   let jsonData = metadataString.data(using: .utf8) {
                    distractions = try? decoder.decode([Distraction].self, from: jsonData)
                }

                // Create TimelineCard instance using renamed columns
                return TimelineCard(
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
                    otherVideoSummaryURLs: nil
                )
            }
        }
        return cards ?? []
    }

    // MARK: - Transcript Storage (Updated) --------------------------------------

    func saveTranscript(batchId: Int64, chunks: [ClockTranscriptChunk]) {
        guard !chunks.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601 // Encode Dates as ISO8601 strings
        do {
            let jsonData = try encoder.encode(chunks)
            let jsonString = String(data: jsonData, encoding: .utf8)
            try db.write { db in
                try db.execute(sql: """
                    UPDATE analysis_batches
                    SET detailed_transcription = ?
                    WHERE id = ?
                """, arguments: [jsonString, batchId])
            }
        } catch {
            print("Error saving clock-time transcript for batch \(batchId): \(error.localizedDescription)")
        }
    }

    func fetchTranscript(batchId: Int64) -> [ClockTranscriptChunk] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601 // Decode Dates from ISO8601 strings
        return (try? db.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT detailed_transcription FROM analysis_batches WHERE id = ?", arguments: [batchId]),
               let jsonString: String = row["detailed_transcription"],
               let jsonData = jsonString.data(using: .utf8) {
                return try decoder.decode([ClockTranscriptChunk].self, from: jsonData)
            }
            return []
        }) ?? []
    }

    // MARK: - Helper for GeminiService – map file paths → timestamps
    func getTimestampsForVideoFiles(paths: [String]) -> [String: (startTs: Int, endTs: Int)] {
        guard !paths.isEmpty else { return [:] }
        var out: [String: (Int, Int)] = [:]
        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
        let sql = "SELECT file_url, start_ts, end_ts FROM chunks WHERE file_url IN (\(placeholders))"
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

    // MARK: – Purging Logic --------------------------------------------------

    private let purgeQ = DispatchQueue(label: "com.dayflow.storage.purge", qos: .background)

    private func purgeIfNeeded() {
        purgeQ.async {
            guard let size = try? self.fileMgr.allocatedSizeOfDirectory(at: self.root), size > self.quota else { return }
            try? self.db.write { db in
                let old = try Row.fetchAll(db, sql: "SELECT id, file_url FROM recordings WHERE status = 'completed' ORDER BY start_ts ASC LIMIT 20")
                for r in old {
                    guard let id: Int64 = r["id"], let path: String = r["file_url"] else { continue }
                    try? self.fileMgr.removeItem(atPath: path)
                    try db.execute(sql: "DELETE FROM recordings WHERE id = ?", arguments: [id])
                }
            }
        }
    }
}

// MARK: - File‑size helper -----------------------------------------------------

private extension FileManager {
    func allocatedSizeOfDirectory(at url: URL) throws -> Int {
        try contentsOfDirectory(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            .reduce(0) { sum, file in
                sum + (try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
            }
    }
}
