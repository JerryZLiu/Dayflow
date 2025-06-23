import Foundation
import GRDB

struct TimelineEntry: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var batch_id: Int64?
    var start: String
    var end: String
    var day: String
    var title: String
    var summary: String?
    var category: String
    var subcategory: String?
    var detailed_summary: String?
    var metadata: String?
    var video_summary_url: String?
    var created_at: Date?
}