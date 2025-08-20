//
//  AnalysisModels.swift
//  Dayflow
//
//  Created on 5/1/2025.
//

import Foundation

/// Represents a recording chunk from the database
struct RecordingChunk: Codable {
    let id: Int64
    let startTs: Int
    let endTs: Int
    let fileUrl: String
    let status: String
    
    var duration: TimeInterval {
        TimeInterval(endTs - startTs)
    }
}
