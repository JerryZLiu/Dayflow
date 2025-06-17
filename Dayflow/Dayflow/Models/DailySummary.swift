import Foundation

struct DailySummary: Codable, Sendable {
    let day_key: String
    let summary_md: String
    let created_at: String?
}
