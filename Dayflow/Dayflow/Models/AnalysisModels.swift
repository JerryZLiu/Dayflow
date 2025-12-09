//
//  AnalysisModels.swift
//  Dayflow
//
//  Created on 5/1/2025.
//

import Foundation

/// Represents a recording chunk from the database (legacy - video-based)
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

/// Represents a screenshot capture from the database (new - replaces video chunks)
struct Screenshot: Codable, Sendable {
    let id: Int64
    let capturedAt: Int          // Unix timestamp (instant of capture)
    let filePath: String
    let fileSize: Int64?
    let isDeleted: Bool

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var capturedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(capturedAt))
    }
}
