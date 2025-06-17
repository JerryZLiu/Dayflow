import Foundation

struct TimelineEntry: Codable, Sendable {
    let id: Int64?
    let batch_id: Int64?
    let start: Int
    let end: Int
    let day: String
    let title: String
    let summary: String?
    let category: String
    let subcategory: String?
    let detailed_summary: String?
    let metadata: String?
    let video_summary_url: String?
    let created_at: String?
}
