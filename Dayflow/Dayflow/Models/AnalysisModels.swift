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
  let filePath: String
  let fileSize: Int64?
  let idleSecondsAtCapture: Int?
  let isDeleted: Bool
  let captureId: String?
  let deviceId: String
  let platform: CapturePlatform
  let sessionId: String?
  let sequence: Int64?
  let timezoneId: String?
  let utcOffsetSeconds: Int?
  let foregroundAppId: String?
  let foregroundAppName: String?
  let orientation: CaptureOrientation
  let pixelWidth: Int?
  let pixelHeight: Int?
  let kind: CaptureKind
  let contentSHA256: String?

  init(
    id: Int64,
    capturedAt: Int,
    filePath: String,
    fileSize: Int64?,
    idleSecondsAtCapture: Int?,
    isDeleted: Bool,
    captureId: String? = nil,
    deviceId: String = LocalCaptureDevice.id,
    platform: CapturePlatform = .macOS,
    sessionId: String? = nil,
    sequence: Int64? = nil,
    timezoneId: String? = nil,
    utcOffsetSeconds: Int? = nil,
    foregroundAppId: String? = nil,
    foregroundAppName: String? = nil,
    orientation: CaptureOrientation = .unknown,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil,
    kind: CaptureKind = .image,
    contentSHA256: String? = nil
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.filePath = filePath
    self.fileSize = fileSize
    self.idleSecondsAtCapture = idleSecondsAtCapture
    self.isDeleted = isDeleted
    self.captureId = captureId
    self.deviceId = deviceId
    self.platform = platform
    self.sessionId = sessionId
    self.sequence = sequence
    self.timezoneId = timezoneId
    self.utcOffsetSeconds = utcOffsetSeconds
    self.foregroundAppId = foregroundAppId
    self.foregroundAppName = foregroundAppName
    self.orientation = orientation
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.kind = kind
    self.contentSHA256 = contentSHA256
  }

  var fileURL: URL {
    URL(fileURLWithPath: filePath)
  }

  var capturedDate: Date {
    Date(timeIntervalSince1970: TimeInterval(capturedAt))
  }
}
