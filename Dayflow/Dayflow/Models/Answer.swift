import Foundation

struct Answer: Codable, Sendable {
    let question_id: Int64
    let batch_id: Int64
    let value: Double
    let created_at: String?
}
