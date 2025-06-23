import Foundation
import GRDB

struct DailySummary: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    var day_key: String     // PRIMARY KEY
    var summary_md: String?
    var created_at: Date?
    
    var id: String { day_key }   // satisfy Identifiable
}