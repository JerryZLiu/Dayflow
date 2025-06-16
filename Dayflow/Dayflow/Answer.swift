//
//  Answer.swift
//  Dayflow
//
//  Created for data migration v2
//

import Foundation
import GRDB

/// Answer entity (new in v2)
struct Answer: Codable, Sendable {
    let questionId: Int64
    let batchId: Int64
    let value: Double
    let createdAt: Date
    
    init(questionId: Int64, batchId: Int64, value: Double, createdAt: Date = Date()) {
        self.questionId = questionId
        self.batchId = batchId
        self.value = value
        self.createdAt = createdAt
    }
}

// MARK: - GRDB Support
extension Answer: TableRecord, FetchableRecord, PersistableRecord {
    static let databaseTableName = "answers"
}