import Foundation

struct ProcessingBatch: Codable, Sendable {
    let id: Int64
    let batch_start_ts: Int
    let batch_end_ts: Int
    let status: String
    let reason: String?
    let llm_metadata: String?
    let detailed_transcription: String?
    let timeline_processed: Int
    let questions_processed: Int
    let summary_processed: Int
    let created_at: String
}
