//
//  ProcessingBatch.swift
//  Dayflow
//
//  Created for data migration v2
//

import Foundation
import GRDB

/// ProcessingBatch entity (formerly "analysis_batches")
struct ProcessingBatch: Codable, Sendable {
    let id: Int64?
    let batchStartTs: Int
    let batchEndTs: Int
    let status: String
    let reason: String?
    let llmMetadata: String?
    let detailedTranscription: String?
    let timelineProcessed: Int
    let questionsProcessed: Int
    let summaryProcessed: Int
    let createdAt: Date
    
    init(id: Int64? = nil, batchStartTs: Int, batchEndTs: Int, status: String = "pending", 
         reason: String? = nil, llmMetadata: String? = nil, detailedTranscription: String? = nil, 
         timelineProcessed: Int = 0, questionsProcessed: Int = 0, summaryProcessed: Int = 0, 
         createdAt: Date = Date()) {
        self.id = id
        self.batchStartTs = batchStartTs
        self.batchEndTs = batchEndTs
        self.status = status
        self.reason = reason
        self.llmMetadata = llmMetadata
        self.detailedTranscription = detailedTranscription
        self.timelineProcessed = timelineProcessed
        self.questionsProcessed = questionsProcessed
        self.summaryProcessed = summaryProcessed
        self.createdAt = createdAt
    }
}

// MARK: - GRDB Support
extension ProcessingBatch: TableRecord, FetchableRecord, PersistableRecord {
    static let databaseTableName = "processing_batches"
}