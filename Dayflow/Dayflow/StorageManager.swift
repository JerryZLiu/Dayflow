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
    // Recording‑chunk lifecycle
    func nextFileURL() -> URL
    func registerChunk(url: URL)
    func markChunkCompleted(url: URL)
    func markChunkFailed(url: URL)

    // Fetch unprocessed (completed + not yet batched) chunks
    func fetchUnprocessedChunks(olderThan oldestAllowed: Int) -> [RecordingChunk]

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

    // Timeline Queries
    func fetchTimelineCards(forDay day: String) -> [TimelineCard]

    // Transcript Storage - Updated for ClockTranscriptChunk
    func saveTranscript(batchId: Int64, chunks: [ClockTranscriptChunk])
    func fetchTranscript(batchId: Int64) -> [ClockTranscriptChunk]
    func fetchAllTranscriptsForDay(_ dayString: String) -> [ClockTranscriptChunk]

    // Dashboard question tracking
    func saveDashboardQuestion(question: DashboardQuestionDB) -> Int64?
    func fetchDashboardQuestions() -> [DashboardQuestionDB]
    func updateDashboardQuestionValue(questionId: Int64, day: String, newValue: Double)
    func fetchDashboardAnswerForDay(questionId: Int64, day: String) -> DashboardAnswerDB?
    func fetchAllDashboardAnswersForDay(day: String) -> [DashboardAnswerDB]
    func markQuestionForReprocess(questionId: Int64, day: String)
    func saveBatchQuestionResult(questionId: Int64, batchId: Int64, value: Double)
    func deleteDashboardQuestion(questionId: Int64)
    func updateDashboardQuestion(questionId: Int64, question: String, type: String)
    func updateDashboardAnswerWithBatch(questionId: Int64, day: String, newValue: Double, batchId: Int64)
    func updateDashboardAnswerIncremental(questionId: Int64, day: String, newValue: Double, batchId: Int64)

    // Todo tracking
    func fetchTodosForDay(day: String) -> [TodoItemDB]
    func saveTodoForDay(todo: TodoItemDB, day: String) -> Int64?
    func updateTodoCompletion(todoId: Int64, day: String, isCompleted: Bool)

    // Helper for GeminiService – map file paths → timestamps
    func getTimestampsForVideoFiles(paths: [String]) -> [String: (startTs: Int, endTs: Int)]

    /// Chunks that belong to one batch, already sorted.
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

// Dashboard Question Database Structures
struct DashboardQuestionDB: Codable, Sendable, Identifiable {
    let id: Int64?
    let question: String
    let type: String // "count", "time", "boolean" - user hint, LLM can override
    let createdAt: Date
    let isActive: Bool
    
    init(id: Int64? = nil, question: String, type: String, createdAt: Date = Date(), isActive: Bool = true) {
        self.id = id
        self.question = question
        self.type = type
        self.createdAt = createdAt
        self.isActive = isActive
    }
}

struct DashboardAnswerDB: Codable, Sendable {
    let questionId: Int64
    let day: String // yyyy-MM-dd format using 4AM boundary
    let currentValue: Double
    let lastProcessedBatchId: Int64? // Track which batch was last processed
    let needsReprocess: Bool // Flag for full day reprocessing
    let llmDeterminedType: String? // What LLM thinks the type is
    let updatedAt: Date
    
    init(questionId: Int64, day: String, currentValue: Double, lastProcessedBatchId: Int64? = nil, needsReprocess: Bool = false, llmDeterminedType: String? = nil, updatedAt: Date = Date()) {
        self.questionId = questionId
        self.day = day
        self.currentValue = currentValue
        self.lastProcessedBatchId = lastProcessedBatchId
        self.needsReprocess = needsReprocess
        self.llmDeterminedType = llmDeterminedType
        self.updatedAt = updatedAt
    }
}

struct BatchQuestionResult: Codable, Sendable {
    let questionId: Int64
    let batchId: Int64
    let value: Double // Incremental value from this batch only
    let processedAt: Date
    
    init(questionId: Int64, batchId: Int64, value: Double, processedAt: Date = Date()) {
        self.questionId = questionId
        self.batchId = batchId
        self.value = value
        self.processedAt = processedAt
    }
}

// Todo Database Structure
struct TodoItemDB: Codable, Sendable, Identifiable {
    let id: Int64?
    let title: String
    let isCompleted: Bool
    let createdAt: Date
    
    init(id: Int64? = nil, title: String, isCompleted: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
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

        db = try! DatabaseQueue(path: root.appendingPathComponent("chunks.sqlite").path)
        migrate()
        purgeIfNeeded()
    }

    // MARK: – Schema / migrations
    private func migrate() {
        try? db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chunks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    start_ts INTEGER NOT NULL,
                    end_ts   INTEGER NOT NULL,
                    file_url TEXT    NOT NULL UNIQUE,
                    status   TEXT    NOT NULL DEFAULT 'recording'
                );
                CREATE INDEX IF NOT EXISTS idx_chunks_status   ON chunks(status);
                CREATE INDEX IF NOT EXISTS idx_chunks_start_ts ON chunks(start_ts);
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS analysis_batches (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    batch_start_ts INTEGER NOT NULL,
                    batch_end_ts   INTEGER NOT NULL,
                    status         TEXT    NOT NULL DEFAULT 'pending',
                    reason         TEXT,
                    llm_metadata   TEXT,
                    detailed_transcription TEXT,
                    created_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX IF NOT EXISTS idx_analysis_batches_status ON analysis_batches(status);
            """)

            // Attempt to add the new column if the table pre-dates it
            try? db.execute(sql: "ALTER TABLE analysis_batches ADD COLUMN llm_metadata TEXT")
            try? db.execute(sql: "ALTER TABLE analysis_batches ADD COLUMN detailed_transcription TEXT")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS batch_chunks (
                    batch_id INTEGER NOT NULL REFERENCES analysis_batches(id) ON DELETE CASCADE,
                    chunk_id INTEGER NOT NULL REFERENCES chunks(id)          ON DELETE RESTRICT,
                    PRIMARY KEY (batch_id, chunk_id)
                );
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS timeline_cards (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    batch_id   INTEGER REFERENCES analysis_batches(id) ON DELETE CASCADE,
                    start   TEXT NOT NULL, -- Renamed from start_ts
                    end     TEXT NOT NULL, -- Renamed from end_ts
                    day        DATE    NOT NULL,
                    title      TEXT    NOT NULL,
                    summary TEXT,
                    category    TEXT    NOT NULL,
                    subcategory TEXT,
                    detailed_summary TEXT,
                    metadata    TEXT, -- For distractions JSON
                    video_summary_url TEXT, -- Link to video summary on filesystem
                    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                 CREATE INDEX IF NOT EXISTS idx_timeline_cards_day ON timeline_cards(day);
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS dashboard_questions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    question TEXT NOT NULL,
                    type TEXT NOT NULL,
                    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    is_active BOOLEAN NOT NULL DEFAULT 1
                );
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS dashboard_answers (
                    question_id INTEGER NOT NULL REFERENCES dashboard_questions(id) ON DELETE CASCADE,
                    day DATE NOT NULL,
                    current_value REAL NOT NULL DEFAULT 0,
                    last_processed_batch_id INTEGER REFERENCES analysis_batches(id),
                    needs_reprocess BOOLEAN NOT NULL DEFAULT 0,
                    llm_determined_type TEXT,
                    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (question_id, day)
                );
                CREATE INDEX IF NOT EXISTS idx_dashboard_answers_day ON dashboard_answers(day);
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS batch_question_results (
                    question_id INTEGER NOT NULL REFERENCES dashboard_questions(id) ON DELETE CASCADE,
                    batch_id INTEGER NOT NULL REFERENCES analysis_batches(id) ON DELETE CASCADE,
                    value REAL NOT NULL,
                    processed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (question_id, batch_id)
                );
                CREATE INDEX IF NOT EXISTS idx_batch_question_results_batch ON batch_question_results(batch_id);
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS dashboard_todos (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    day DATE NOT NULL,
                    title TEXT NOT NULL,
                    is_completed BOOLEAN NOT NULL DEFAULT 0,
                    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX IF NOT EXISTS idx_dashboard_todos_day ON dashboard_todos(day);
            """)
        }
    }

    // MARK: – Recording‑file helpers ------------------------------------------

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
    
    func fetchAllTranscriptsForDay(_ dayString: String) -> [ClockTranscriptChunk] {
        // Parse the day string and calculate 4AM boundaries
        guard let dayDate = DateFormatter.yyyyMMdd.date(from: dayString) else { return [] }
        
        let calendar = Calendar.current
        guard let fourAM = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: dayDate) else { return [] }
        
        let startOfDay = fourAM
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let startTs = Int(startOfDay.timeIntervalSince1970)
        let endTs = Int(endOfDay.timeIntervalSince1970)
        
        var allTranscripts: [ClockTranscriptChunk] = []
        
        try? db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, detailed_transcription
                FROM analysis_batches 
                WHERE detailed_transcription IS NOT NULL 
                  AND detailed_transcription != ''
                  AND status = 'completed'
                  AND (
                    (batch_start_ts >= ? AND batch_start_ts < ?) OR
                    (batch_end_ts > ? AND batch_end_ts <= ?) OR
                    (batch_start_ts < ? AND batch_end_ts > ?)
                  )
                ORDER BY batch_start_ts ASC
            """, arguments: [startTs, endTs, startTs, endTs, startTs, endTs])
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            for row in rows {
                if let jsonString: String = row["detailed_transcription"],
                   let jsonData = jsonString.data(using: .utf8),
                   let transcripts = try? decoder.decode([ClockTranscriptChunk].self, from: jsonData) {
                    allTranscripts.append(contentsOf: transcripts)
                }
            }
        }
        
        // Sort by actual clock time
        return allTranscripts.sorted { $0.clockStartTime < $1.clockStartTime }
    }

    // MARK: - Dashboard question tracking

    func saveDashboardQuestion(question: DashboardQuestionDB) -> Int64? {
        var questionId: Int64? = nil
        try? db.write { db in
            try db.execute(sql: """
                INSERT INTO dashboard_questions(question, type, created_at, is_active)
                VALUES (?, ?, ?, ?)
            """, arguments: [question.question, question.type, question.createdAt.timeIntervalSince1970, question.isActive])
            questionId = db.lastInsertedRowID
        }
        return questionId
    }

    func fetchDashboardQuestions() -> [DashboardQuestionDB] {
        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM dashboard_questions 
                WHERE is_active = 1 
                ORDER BY created_at ASC
            """).map { row in
                DashboardQuestionDB(
                    id: row["id"],
                    question: row["question"],
                    type: row["type"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    isActive: row["is_active"]
                )
            }
        }) ?? []
    }

    func updateDashboardQuestionValue(questionId: Int64, day: String, newValue: Double) {
        try? db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO dashboard_answers(question_id, day, current_value, updated_at)
                VALUES (?, ?, ?, ?)
            """, arguments: [questionId, day, newValue, Date().timeIntervalSince1970])
        }
    }

    func fetchDashboardAnswerForDay(questionId: Int64, day: String) -> DashboardAnswerDB? {
        return try? db.read { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT * FROM dashboard_answers 
                WHERE question_id = ? AND day = ?
            """, arguments: [questionId, day]) {
                return DashboardAnswerDB(
                    questionId: row["question_id"],
                    day: row["day"],
                    currentValue: row["current_value"],
                    lastProcessedBatchId: row["last_processed_batch_id"],
                    needsReprocess: row["needs_reprocess"],
                    llmDeterminedType: row["llm_determined_type"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
            return nil
        }
    }

    func fetchAllDashboardAnswersForDay(day: String) -> [DashboardAnswerDB] {
        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM dashboard_answers 
                WHERE day = ?
            """, arguments: [day]).map { row in
                DashboardAnswerDB(
                    questionId: row["question_id"],
                    day: row["day"],
                    currentValue: row["current_value"],
                    lastProcessedBatchId: row["last_processed_batch_id"],
                    needsReprocess: row["needs_reprocess"],
                    llmDeterminedType: row["llm_determined_type"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }) ?? []
    }

    func markQuestionForReprocess(questionId: Int64, day: String) {
        try? db.write { db in
            try db.execute(sql: """
                UPDATE dashboard_answers 
                SET needs_reprocess = 1, last_processed_batch_id = NULL, updated_at = ?
                WHERE question_id = ? AND day = ?
            """, arguments: [Date().timeIntervalSince1970, questionId, day])
        }
    }

    func saveBatchQuestionResult(questionId: Int64, batchId: Int64, value: Double) {
        try? db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO batch_question_results(question_id, batch_id, value, processed_at)
                VALUES (?, ?, ?, ?)
            """, arguments: [questionId, batchId, value, Date().timeIntervalSince1970])
        }
    }

    func deleteDashboardQuestion(questionId: Int64) {
        try? db.write { db in
            try db.execute(sql: """
                UPDATE dashboard_questions 
                SET is_active = 0 
                WHERE id = ?
            """, arguments: [questionId])
        }
    }

    func updateDashboardQuestion(questionId: Int64, question: String, type: String) {
        try? db.write { db in
            try db.execute(sql: """
                UPDATE dashboard_questions 
                SET question = ?, type = ? 
                WHERE id = ?
            """, arguments: [question, type, questionId])
        }
    }

    func updateTodoCompletion(todoId: Int64, day: String, isCompleted: Bool) {
        try? db.write { db in
            try db.execute(sql: """
                UPDATE dashboard_todos 
                SET is_completed = ? 
                WHERE id = ? AND day = ?
            """, arguments: [isCompleted, todoId, day])
        }
    }

    func updateDashboardAnswerWithBatch(questionId: Int64, day: String, newValue: Double, batchId: Int64) {
        try? db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO dashboard_answers(
                    question_id, day, current_value, last_processed_batch_id, 
                    needs_reprocess, updated_at
                ) VALUES (?, ?, ?, ?, 0, ?)
            """, arguments: [questionId, day, newValue, batchId, Date().timeIntervalSince1970])
        }
    }

    func updateDashboardAnswerIncremental(questionId: Int64, day: String, newValue: Double, batchId: Int64) {
        try? db.write { db in
            try db.execute(sql: """
                UPDATE dashboard_answers 
                SET current_value = ?, last_processed_batch_id = ?, updated_at = ?
                WHERE question_id = ? AND day = ?
            """, arguments: [newValue, batchId, Date().timeIntervalSince1970, questionId, day])
        }
    }

    // MARK: - Todo tracking

    func fetchTodosForDay(day: String) -> [TodoItemDB] {
        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM dashboard_todos 
                WHERE day = ? 
                ORDER BY created_at ASC
            """, arguments: [day]).map { row in
                TodoItemDB(
                    id: row["id"],
                    title: row["title"],
                    isCompleted: row["is_completed"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"])
                )
            }
        }) ?? []
    }

    func saveTodoForDay(todo: TodoItemDB, day: String) -> Int64? {
        var todoId: Int64? = nil
        try? db.write { db in
            try db.execute(sql: """
                INSERT INTO dashboard_todos(day, title, is_completed, created_at)
                VALUES (?, ?, ?, ?)
            """, arguments: [day, todo.title, todo.isCompleted, todo.createdAt.timeIntervalSince1970])
            todoId = db.lastInsertedRowID
        }
        return todoId
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
                let old = try Row.fetchAll(db, sql: "SELECT id, file_url FROM chunks WHERE status = 'completed' ORDER BY start_ts ASC LIMIT 20")
                for r in old {
                    guard let id: Int64 = r["id"], let path: String = r["file_url"] else { continue }
                    try? self.fileMgr.removeItem(atPath: path)
                    try db.execute(sql: "DELETE FROM chunks WHERE id = ?", arguments: [id])
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
