//
//  Observation.swift
//  Dayflow
//
//  Created for data migration v2
//

import Foundation
import GRDB

/// Observation entity (new in v2)
struct Observation: Codable, Sendable {
    let id: Int64?
    let batchId: Int64
    let startTime: String
    let endTime: String
    let description: String
    let llmSource: String
    let createdAt: Date
    
    init(id: Int64? = nil, batchId: Int64, startTime: String, endTime: String, 
         description: String, llmSource: String, createdAt: Date = Date()) {
        self.id = id
        self.batchId = batchId
        self.startTime = startTime
        self.endTime = endTime
        self.description = description
        self.llmSource = llmSource
        self.createdAt = createdAt
    }
}

// MARK: - GRDB Support
extension Observation: TableRecord, FetchableRecord, PersistableRecord {
    static let databaseTableName = "observations"
}