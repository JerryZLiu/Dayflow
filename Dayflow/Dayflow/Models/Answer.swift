import Foundation
import GRDB

struct Answer: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    // composite PK → no single `id`
    var question_id: Int64
    var batch_id: Int64
    var value: Double
    var created_at: Date?
}

extension Answer {
    var id: String { "\(question_id)-\(batch_id)" }
}
