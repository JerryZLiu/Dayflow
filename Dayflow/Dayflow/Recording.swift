//
//  Recording.swift
//  Dayflow
//
//  Created for data migration v2
//

import Foundation
import GRDB

/// Recording entity (formerly "chunks")
struct Recording: Codable, Sendable {
    let id: Int64?
    let startTs: Int
    let endTs: Int
    let fileUrl: String
    let status: String
    
    var duration: TimeInterval {
        TimeInterval(endTs - startTs)
    }
}

// MARK: - GRDB Support
extension Recording: TableRecord, FetchableRecord, PersistableRecord {
    static let databaseTableName = "recordings"
}