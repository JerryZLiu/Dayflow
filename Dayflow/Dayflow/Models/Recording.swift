import Foundation
import GRDB

struct Recording: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var start_ts: Int
    var end_ts: Int
    var file_url: String
    var status: String
}