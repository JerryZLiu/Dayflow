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

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = .current
        return f
    }()
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
    // Recording lifecycle
    func nextFileURL() -> URL
    func registerRecording(url: URL)
    func markRecordingCompleted(url: URL)
    func markRecordingFailed(url: URL)

    // Fetch unprocessed (completed + not yet batched) recordings
    func fetchUnprocessedRecordings(olderThan oldestAllowed: Int) -> [Recording]

    // Batch management
    func createProcessingBatch(startTs: Int, endTs: Int, recordingIds: [Int64]) -> Int64?
    func updateProcessingBatchStatus(_ id: Int64, status: String, reason: String?)
    func flagBatch(_ id: Int64, timelineDone: Bool?, questionsDone: Bool?, summaryDone: Bool?)

    // Record details about all LLM calls for a batch
    func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall])
    func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall]

    // Timeline‑cards
    func saveTimelineCardShell(batchId: Int64, card: TimelineCardShell) -> Int64?
    func updateTimelineCardVideoURL(cardId: Int64, videoSummaryURL: String)
    func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard]

    // Timeline Queries
    func fetchTimelineCards(forDay day: String) -> [TimelineCard]

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

    // Transcript Storage - Updated for ClockTranscriptChunk
    func saveTranscript(batchId: Int64, chunks: [ClockTranscriptChunk])
    func fetchTranscript(batchId: Int64) -> [ClockTranscriptChunk]

    // Helper for GeminiService – map file paths → timestamps
    func getTimestampsForVideoFiles(paths: [String]) -> [String: (startTs: Int, endTs: Int)]

    /// Recordings that belong to one batch, already sorted.
    func recordingsForBatch(_ id: Int64) -> [Recording]

    // Misc
    func purgeIfNeeded()
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
    let startTimestamp: Int
    let endTimestamp: Int
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

        let dbPath = root.appendingPathComponent("storage_v2.sqlite")
        if fileMgr.fileExists(atPath: dbPath.path) {
            try? fileMgr.removeItem(at: dbPath)
        }
        db = try! DatabaseQueue(path: dbPath.path)
        migrateV2()
        purgeIfNeeded()
    }

    // MARK: – Schema / migrations
    private func migrateV2() {
        try? db.write { db in
            try db.execute(sql: """
                -- 1. Recordings
                CREATE TABLE recordings (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    start_ts    INTEGER  NOT NULL,
                    end_ts      INTEGER  NOT NULL,
                    file_url    TEXT     NOT NULL UNIQUE,
                    status      TEXT     NOT NULL DEFAULT "recording"
                );
                CREATE INDEX idx_recordings_status   ON recordings(status);
                CREATE INDEX idx_recordings_start_ts ON recordings(start_ts);
                -- 2. Processing Batches
                CREATE TABLE processing_batches (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    batch_start_ts    INTEGER NOT NULL,
                    batch_end_ts      INTEGER NOT NULL,
                    status            TEXT    NOT NULL DEFAULT "pending",
                    reason            TEXT,
                    llm_metadata      TEXT,
                    detailed_transcription TEXT,
                    timeline_processed   INTEGER NOT NULL DEFAULT 0,
                    questions_processed  INTEGER NOT NULL DEFAULT 0,
                    summary_processed    INTEGER NOT NULL DEFAULT 0,
                    created_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX idx_processing_batches_status ON processing_batches(status);
                -- 3. Batch ↔︎ Recording join
                CREATE TABLE batch_recordings (
                    batch_id     INTEGER NOT NULL REFERENCES processing_batches(id) ON DELETE CASCADE,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id)         ON DELETE RESTRICT,
                    PRIMARY KEY (batch_id, recording_id)
                );
                -- 4. Timeline Entries
                CREATE TABLE timeline_entries (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    batch_id         INTEGER REFERENCES processing_batches(id) ON DELETE CASCADE,
                    start            INTEGER NOT NULL,
                    end              INTEGER NOT NULL,
                    day              DATE    NOT NULL,
                    title            TEXT    NOT NULL,
                    summary          TEXT,
                    category         TEXT    NOT NULL,
                    subcategory      TEXT,
                    detailed_summary TEXT,
                    metadata         TEXT,
                    video_summary_url TEXT,
                    created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX idx_timeline_entries_day ON timeline_entries(day);
                -- 5. Observations
                CREATE TABLE observations (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    batch_id    INTEGER NOT NULL REFERENCES processing_batches(id) ON DELETE CASCADE,
                    start_time  INTEGER NOT NULL,
                    end_time    INTEGER NOT NULL,
                    description TEXT    NOT NULL,
                    llm_source  TEXT    NOT NULL,
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX idx_observations_batch_id ON observations(batch_id);
                CREATE INDEX idx_observations_start    ON observations(start_time);
                -- 6. Questions
                CREATE TABLE questions (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    prompt      TEXT    NOT NULL,
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                -- 7. Answers
                CREATE TABLE answers (
                    question_id INTEGER NOT NULL REFERENCES questions(id)          ON DELETE CASCADE,
                    batch_id    INTEGER NOT NULL REFERENCES processing_batches(id) ON DELETE CASCADE,
                    value       REAL    NOT NULL,
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (question_id, batch_id)
                );
                CREATE INDEX idx_answers_question_batch ON answers(question_id, batch_id);
                -- 8. Daily Summaries
                CREATE TABLE daily_summaries (
                    day_key     TEXT PRIMARY KEY,
                    summary_md  TEXT,
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
            """)
        }
    }
    }

    // MARK: – Recording‑file helpers ------------------------------------------

    func nextFileURL() -> URL {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmssSSS"
        return root.appendingPathComponent("\(df.string(from: Date())).mp4")
    }

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

    // MARK: – Queries used by GeminiAnalysisManager ---------------------------

    func fetchUnprocessedRecordings(olderThan oldestAllowed: Int) -> [Recording] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM recordings
                WHERE start_ts >= ?
                  AND status = 'completed'
                  AND id NOT IN (SELECT recording_id FROM batch_recordings)
                ORDER BY start_ts ASC
            """, arguments: [oldestAllowed])
                .map { row in
                    Recording(id: row["id"], start_ts: row["start_ts"], end_ts: row["end_ts"], file_url: row["file_url"], status: row["status"]) }
        }) ?? []
    }

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
            try db.execute(sql: "UPDATE processing_batches SET status = ?, reason = ? WHERE id = ?", arguments: [status, reason, id])
        }
    }

    func flagBatch(_ id: Int64, timelineDone: Bool?, questionsDone: Bool?, summaryDone: Bool?) {
        try? db.write { db in
            if let t = timelineDone {
                try db.execute(sql: "UPDATE processing_batches SET timeline_processed = ? WHERE id = ?", arguments: [t ? 1 : 0, id])
            }
            if let q = questionsDone {
                try db.execute(sql: "UPDATE processing_batches SET questions_processed = ? WHERE id = ?", arguments: [q ? 1 : 0, id])
            }
            if let s = summaryDone {
                try db.execute(sql: "UPDATE processing_batches SET summary_processed = ? WHERE id = ?", arguments: [s ? 1 : 0, id])
            }
        }
    }

    func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(calls), let json = String(data: data, encoding: .utf8) else { return }
        try? db.write { db in
            try db.execute(sql: "UPDATE processing_batches SET llm_metadata = ? WHERE id = ?", arguments: [json, batchId])
        }
    }

    func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? db.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT llm_metadata FROM processing_batches WHERE id = ?", arguments: [batchId]),
               let json: String = row["llm_metadata"],
               let data = json.data(using: .utf8) {
                return try decoder.decode([LLMCall].self, from: data)
            }
            return []
        }) ?? []
    }

    /// Recordings that belong to one batch, already sorted.
    func recordingsForBatch(_ id: Int64) -> [Recording] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.* FROM batch_recordings br
                JOIN recordings r ON r.id = br.recording_id
                WHERE br.batch_id = ?
                ORDER BY r.start_ts ASC
                """, arguments: [id]
            ).map { r in
                Recording(id: r["id"], start_ts: r["start_ts"], end_ts: r["end_ts"],
                          file_url: r["file_url"], status: r["status"])
            }
        }) ?? []
    }

    // MARK: – Observations ----------------------------------------------------

    func saveObservations(batchId: Int64, observations: [Observation]) {
        guard !observations.isEmpty else { return }
        try? db.write { db in
            for o in observations {
                try db.execute(sql: """
                    INSERT INTO observations(batch_id, start_time, end_time, description, llm_source)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [batchId, o.start_time, o.end_time, o.description, o.llm_source])
            }
        }
    }

    func fetchObservations(batchId: Int64) -> [Observation] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM observations WHERE batch_id = ? ORDER BY start_time ASC", arguments: [batchId]).map { row in
                Observation(id: row["id"], batch_id: row["batch_id"], start_time: row["start_time"], end_time: row["end_time"], description: row["description"], llm_source: row["llm_source"], created_at: row["created_at"])
            }
        }) ?? []
    }

    // MARK: – Questions & Answers -------------------------------------------

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
            for a in answers {
                try db.execute(sql: "INSERT OR REPLACE INTO answers(question_id, batch_id, value) VALUES (?, ?, ?)", arguments: [a.question_id, a.batch_id, a.value])
            }
        }
    }

    func fetchAnswers(questionId: Int64, dayKey: String) -> [Answer] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.question_id, a.batch_id, a.value, a.created_at
                FROM answers a
                JOIN processing_batches pb ON pb.id = a.batch_id
                WHERE a.question_id = ? AND strftime('%Y-%m-%d', pb.batch_start_ts, 'unixepoch') = ?
            """, arguments: [questionId, dayKey]).map { row in
                Answer(question_id: row["question_id"], batch_id: row["batch_id"], value: row["value"], created_at: row["created_at"])
            }
        }) ?? []
    }

    // MARK: – Daily Summaries -----------------------------------------------

    func saveDailySummary(_ summary: DailySummary) {
        try? db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO daily_summaries(day_key, summary_md) VALUES (?, ?)", arguments: [summary.day_key, summary.summary_md])
        }
    }

    func fetchDailySummary(dayKey: String) -> DailySummary? {
        return try? db.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM daily_summaries WHERE day_key = ?", arguments: [dayKey]) {
                return DailySummary(day_key: row["day_key"], summary_md: row["summary_md"], created_at: row["created_at"])
            }
            return nil
        }
    }

    private func clockString(from ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        return DateFormatter.clock.string(from: date)
    }

    // MARK: – Timeline --------------------------------------------------------

    func saveTimelineEntry(batchId: Int64, entry: TimelineEntry) -> Int64? {
        let encoder = JSONEncoder()
        var lastId: Int64? = nil
        try? db.write {
            db in
            var distractionsString: String? = nil
            if let metadata = entry.metadata, !metadata.isEmpty {
                distractionsString = metadata
            }

            try db.execute(sql: """
                INSERT INTO timeline_entries(
                    batch_id, start, end, day, title,
                    summary, category, subcategory, detailed_summary, metadata
                    -- video_summary_url is omitted here
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                batchId, entry.start, entry.end, entry.day, entry.title,
                entry.summary ?? "", entry.category, entry.subcategory ?? "", entry.detailed_summary ?? "", distractionsString
            ])
            lastId = db.lastInsertedRowID
        }
        return lastId
    }

    func updateTimelineEntryVideoURL(id: Int64, url: String) {
        try? db.write {
            db in
            try db.execute(sql: """
                UPDATE timeline_entries
                SET video_summary_url = ?
                WHERE id = ?
            """, arguments: [url, id])
        }
    }
    // All batches, newest first
       func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)] {
            (try? db.read { db in
                try Row.fetchAll(db, sql:
                    "SELECT id, batch_start_ts, batch_end_ts, status FROM processing_batches ORDER BY id DESC"
                ).map { row in
                    (row["id"], row["batch_start_ts"], row["batch_end_ts"], row["status"])
                }
            }) ?? []
        }

    // MARK: - Timeline Queries -----------------------------------------------

    func fetchTimelineEntries(dayKey: String) -> [TimelineEntry] {
        return (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM timeline_entries WHERE day = ? ORDER BY start ASC", arguments: [dayKey]).map { row in
                TimelineEntry(
                    id: row["id"],
                    batch_id: row["batch_id"],
                    start: row["start"],
                    end: row["end"],
                    day: row["day"],
                    title: row["title"],
                    summary: row["summary"],
                    category: row["category"],
                    subcategory: row["subcategory"],
                    detailed_summary: row["detailed_summary"],
                    metadata: row["metadata"],
                    video_summary_url: row["video_summary_url"],
                    created_at: row["created_at"]
                )
            }
        }) ?? []
    }

    // Temporary wrapper for old API
    func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard] {
        let entries = (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM timeline_entries WHERE batch_id = ? ORDER BY start ASC", arguments: [batchId])
                .map { row in
                    TimelineEntry(
                        id: row["id"], batch_id: row["batch_id"], start: row["start"], end: row["end"], day: row["day"], title: row["title"], summary: row["summary"], category: row["category"], subcategory: row["subcategory"], detailed_summary: row["detailed_summary"], metadata: row["metadata"], video_summary_url: row["video_summary_url"], created_at: row["created_at"])
                }
        }) ?? []
        // Map to old TimelineCard structure
        return entries.map { e in
            TimelineCard(startTimestamp: clockString(from: e.start), endTimestamp: clockString(from: e.end), category: e.category, subcategory: e.subcategory ?? "", title: e.title, summary: e.summary ?? "", detailedSummary: e.detailed_summary ?? "", day: e.day, distractions: nil, videoSummaryURL: e.video_summary_url, otherVideoSummaryURLs: nil)
        }
    }

    func fetchTimelineCards(forDay day: String) -> [TimelineCard] {
        let entries = fetchTimelineEntries(dayKey: day)
        return entries.map { e in
            TimelineCard(startTimestamp: clockString(from: e.start), endTimestamp: clockString(from: e.end), category: e.category, subcategory: e.subcategory ?? "", title: e.title, summary: e.summary ?? "", detailedSummary: e.detailed_summary ?? "", day: e.day, distractions: nil, videoSummaryURL: e.video_summary_url, otherVideoSummaryURLs: nil)
        }
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
                    UPDATE processing_batches
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
            if let row = try Row.fetchOne(db, sql: "SELECT detailed_transcription FROM processing_batches WHERE id = ?", arguments: [batchId]),
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
        let sql = "SELECT file_url, start_ts, end_ts FROM recordings WHERE file_url IN (\(placeholders))"
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
