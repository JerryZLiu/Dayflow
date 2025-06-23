import Foundation
import GRDB

struct Question: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var prompt: String
    var created_at: Date?
}