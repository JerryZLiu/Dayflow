//
//  AnalysisModels.swift
//  Dayflow
//
//  Created on 5/1/2025.
//

import Foundation

/// Represents a recording from the database
struct Recording: Codable {
    let id: Int64
    let start_ts: Int
    let end_ts: Int
    let file_url: String
    let status: String
    
    var duration: TimeInterval {
        TimeInterval(end_ts - start_ts)
    }
}
