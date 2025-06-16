//
//  DailySummary.swift
//  Dayflow
//
//  Created for data migration v2
//

import Foundation
import GRDB

/// DailySummary entity (new in v2)
struct DailySummary: Codable, Sendable {
    let dayKey: String
    let summaryMd: String?
    let createdAt: Date
    
    init(dayKey: String, summaryMd: String? = nil, createdAt: Date = Date()) {
        self.dayKey = dayKey
        self.summaryMd = summaryMd
        self.createdAt = createdAt
    }
}

// MARK: - GRDB Support
extension DailySummary: TableRecord, FetchableRecord, PersistableRecord {
    static let databaseTableName = "daily_summaries"
}