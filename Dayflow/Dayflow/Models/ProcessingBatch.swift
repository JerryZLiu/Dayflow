import Foundation
import GRDB

struct ProcessingBatch: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var batch_start_ts: Int
    var batch_end_ts: Int
    var status: String
    var reason: String?
    var llm_metadata: String?
    var detailed_transcription: String?
    var timeline_processed: Int
    var questions_processed: Int
    var summary_processed: Int
    var created_at: Date?
}