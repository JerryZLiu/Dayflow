//
//  Question.swift
//  Dayflow
//
//  Created for data migration v2
//

import Foundation
import GRDB

/// Question entity (new in v2)
struct Question: Codable, Sendable {
    let id: Int64?
    let prompt: String
    let createdAt: Date
    
    init(id: Int64? = nil, prompt: String, createdAt: Date = Date()) {
        self.id = id
        self.prompt = prompt
        self.createdAt = createdAt
    }
}

// MARK: - GRDB Support
extension Question: TableRecord, FetchableRecord, PersistableRecord {
    static let databaseTableName = "questions"
}