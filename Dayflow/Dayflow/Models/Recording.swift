import Foundation

struct Recording: Codable, Sendable {
    let id: Int64
    let start_ts: Int
    let end_ts: Int
    let file_url: String
    let status: String
}
