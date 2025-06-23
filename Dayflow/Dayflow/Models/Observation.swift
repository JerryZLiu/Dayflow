import Foundation
import GRDB

struct Observation: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var batch_id: Int64
    var start_time: String
    var end_time: String
    var description: String
    var llm_source: String
    var created_at: Date?
}