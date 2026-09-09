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
  let capturedAt: Int  // Unix timestamp (instant of capture)
  /// HEVC segment file (or a legacy .jpg for rows written before segments existed).
  let filePath: String
  /// Share of the segment's bytes attributed to this frame; nil until the segment is finalized.
  let fileSize: Int64?
  let idleSecondsAtCapture: Int?
  let isDeleted: Bool
  /// Frame position inside the segment. nil means `filePath` is a standalone JPEG.
  let frameIndex: Int?

  init(
    id: Int64,
    capturedAt: Int,
    filePath: String,
    fileSize: Int64?,
    idleSecondsAtCapture: Int?,
    isDeleted: Bool,
    frameIndex: Int? = nil
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.filePath = filePath
    self.fileSize = fileSize
    self.idleSecondsAtCapture = idleSecondsAtCapture
    self.isDeleted = isDeleted
    self.frameIndex = frameIndex
  }

  var fileURL: URL {
    URL(fileURLWithPath: filePath)
  }

  var capturedDate: Date {
    Date(timeIntervalSince1970: TimeInterval(capturedAt))
  }
}
