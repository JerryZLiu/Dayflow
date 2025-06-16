//
//  TimelineEntry.swift
//  Dayflow
//
//  Created for data migration v2
//

import Foundation
import GRDB

/// TimelineEntry entity (formerly "timeline_cards")
struct TimelineEntry: Codable, Sendable, Identifiable {
    let id: Int64?
    let batchId: Int64?
    let start: String
    let end: String
    let day: String
    let title: String
    let summary: String?
    let category: String
    let subcategory: String?
    let detailedSummary: String?
    let metadata: String? // JSON distractions
    let videoSummaryUrl: String?
    let createdAt: Date
    
    init(id: Int64? = nil, batchId: Int64? = nil, start: String, end: String, day: String, 
         title: String, summary: String? = nil, category: String, subcategory: String? = nil, 
         detailedSummary: String? = nil, metadata: String? = nil, videoSummaryUrl: String? = nil, 
         createdAt: Date = Date()) {
        self.id = id
        self.batchId = batchId
        self.start = start
        self.end = end
        self.day = day
        self.title = title
        self.summary = summary
        self.category = category
        self.subcategory = subcategory
        self.detailedSummary = detailedSummary
        self.metadata = metadata
        self.videoSummaryUrl = videoSummaryUrl
        self.createdAt = createdAt
    }
}

// MARK: - GRDB Support
extension TimelineEntry: TableRecord, FetchableRecord, PersistableRecord {
    static let databaseTableName = "timeline_entries"
}