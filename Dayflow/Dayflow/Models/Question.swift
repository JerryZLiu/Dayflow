import Foundation

struct Question: Codable, Sendable {
    let id: Int64?
    let prompt: String
    let created_at: String?
}
