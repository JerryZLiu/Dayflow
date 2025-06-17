import Foundation

struct Observation: Codable, Sendable {
    let id: Int64?
    let batch_id: Int64
    let start_time: String
    let end_time: String
    let description: String
    let llm_source: String
    let created_at: String?
}
