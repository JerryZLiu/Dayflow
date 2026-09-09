import AppKit
import Foundation

extension GemmaBackupProvider {
  // MARK: - Frame Description + Segmentation

  struct FrameData {
    let index: Int
    let base64Image: String
    let timestamp: TimeInterval
  }

  struct FrameDescriptionEnvelope: Codable {
    struct Item: Codable {
      let index: Int
      let description: String
    }
    let frames: [Item]
  }

  struct SegmentEnvelope: Codable {
    struct Item: Codable {
      let start: String
      let end: String
      let description: String
    }
    let segments: [Item]
  }

  struct SegmentCoverageError: Error {
    let coverageRatio: Double
    let durationString: String
  }

  func describeFrames(_ frames: [FrameData], batchId: Int64?) async throws -> [(
    timestamp: TimeInterval, description: String
  )] {
    do {
      return try await describeFramesInSingleBatch(frames, batchId: batchId)
    } catch {
      // Retry with smaller batches to avoid size limits.
      return try await describeFramesInBatches(frames, batchSize: 5, batchId: batchId)
    }
  }

  func describeFramesInSingleBatch(_ frames: [FrameData], batchId: Int64?) async throws
    -> [(timestamp: TimeInterval, description: String)]
  {
    let prompt = frameDescriptionPrompt(frameCount: frames.count)
    var parts: [[String: Any]] = [["text": prompt]]
    for frame in frames {
      parts.append([
        "inline_data": [
          "mime_type": "image/jpeg",
          "data": frame.base64Image,
        ]
      ])
    }

    let response = try await callGenerateContent(
      parts: parts,
      operation: "gemma.describe_frames",
      batchId: batchId,
      temperature: 0.2,
      maxOutputTokens: 2048,
      logRequestBody: false
    )

    let envelope = try parseJSONResponse(FrameDescriptionEnvelope.self, from: response)
    return mapFrameDescriptions(envelope.frames, frames: frames)
  }

  func describeFramesInBatches(_ frames: [FrameData], batchSize: Int, batchId: Int64?)
    async throws -> [(timestamp: TimeInterval, description: String)]
  {
    var results: [(timestamp: TimeInterval, description: String)] = []
    var startIndex = 0

    while startIndex < frames.count {
      let endIndex = min(frames.count, startIndex + batchSize)
      let subset = Array(frames[startIndex..<endIndex])
      let prompt = frameDescriptionPrompt(frameCount: subset.count)
      var parts: [[String: Any]] = [["text": prompt]]
      for frame in subset {
        parts.append([
          "inline_data": [
            "mime_type": "image/jpeg",
            "data": frame.base64Image,
          ]
        ])
      }

      let response = try await callGenerateContent(
        parts: parts,
        operation: "gemma.describe_frames",
        batchId: batchId,
        temperature: 0.2,
        maxOutputTokens: 2048,
        logRequestBody: false
      )

      let envelope = try parseJSONResponse(FrameDescriptionEnvelope.self, from: response)
      let mapped = mapFrameDescriptions(envelope.frames, frames: subset)
      results.append(contentsOf: mapped)
      startIndex = endIndex
    }

    return results
  }

  func mapFrameDescriptions(_ items: [FrameDescriptionEnvelope.Item], frames: [FrameData])
    -> [(timestamp: TimeInterval, description: String)]
  {
    let indexed = Dictionary(
      uniqueKeysWithValues: items.map {
        ($0.index, $0.description.trimmingCharacters(in: .whitespacesAndNewlines))
      })
    var output: [(timestamp: TimeInterval, description: String)] = []

    for (localIndex, frame) in frames.enumerated() {
      let lookupIndex = localIndex + 1
      let description = indexed[lookupIndex] ?? ""
      if !description.isEmpty {
        output.append((timestamp: frame.timestamp, description: description))
      }
    }

    if output.isEmpty {
      // As a last resort, return the frames in order with empty placeholders.
      output = frames.map { (timestamp: $0.timestamp, description: "") }
    }

    return output
  }

  func mergeFrameDescriptions(
    _ frameDescriptions: [(timestamp: TimeInterval, description: String)],
    batchStartTime: Date,
    videoDuration: TimeInterval,
    batchId: Int64?,
    timeOffset: TimeInterval,
    targetSegments: Int
  ) async throws -> [Observation] {
    let durationMinutes = Int(videoDuration / 60)
    let durationSeconds = Int(videoDuration.truncatingRemainder(dividingBy: 60))
    let durationString = String(format: "%02d:%02d", durationMinutes, durationSeconds)

    let prompt = segmentPrompt(
      frameDescriptions: frameDescriptions, durationString: durationString,
      targetSegments: targetSegments)

    let maxAttempts = 2
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.segment_frames",
          batchId: batchId,
          temperature: 0.2,
          maxOutputTokens: 2048,
          logRequestBody: true
        )

        let envelope = try parseJSONResponse(SegmentEnvelope.self, from: response)
        let (observations, coverage) = try convertSegmentsToObservations(
          envelope.segments,
          batchStartTime: batchStartTime,
          videoDuration: videoDuration,
          durationString: durationString,
          timeOffset: timeOffset,
          expectedSegments: targetSegments
        )

        if coverage < 0.8 {
          throw SegmentCoverageError(coverageRatio: coverage, durationString: durationString)
        }

        return observations
      } catch let coverageError as SegmentCoverageError {
        lastError = coverageError
        if attempt == maxAttempts {
          return try observationsFromFrames(
            frameDescriptions, batchStartTime: batchStartTime, videoDuration: videoDuration,
            timeOffset: timeOffset)
        }
      } catch {
        lastError = error
        if attempt == maxAttempts {
          return try observationsFromFrames(
            frameDescriptions, batchStartTime: batchStartTime, videoDuration: videoDuration,
            timeOffset: timeOffset)
        }
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Failed to merge frame descriptions"])
  }

  func convertSegmentsToObservations(
    _ segments: [SegmentEnvelope.Item],
    batchStartTime: Date,
    videoDuration: TimeInterval,
    durationString: String,
    timeOffset: TimeInterval,
    expectedSegments: Int
  ) throws -> (observations: [Observation], coverage: Double) {
    var observations: [Observation] = []
    var totalDuration: TimeInterval = 0
    var lastEndTime: TimeInterval?

    for (index, segment) in segments.enumerated() {
      let startSeconds = TimeInterval(parseVideoTimestamp(segment.start))
      let endSeconds = TimeInterval(parseVideoTimestamp(segment.end))

      let tolerance: TimeInterval = 5
      if startSeconds < -tolerance || endSeconds > videoDuration + tolerance {
        print(
          "[GEMMA] ❌ Segment \(index + 1) exceeds video duration: \(segment.start)-\(segment.end) (video is \(durationString))"
        )
        continue
      }

      if let prevEnd = lastEndTime {
        let gap = startSeconds - prevEnd
        if gap > 60 {
          print("[GEMMA] ⚠️ Gap of \(Int(gap))s between segments")
        }
      }

      let clampedDuration = max(0, endSeconds - startSeconds)
      totalDuration += clampedDuration
      lastEndTime = endSeconds

      let startDate = batchStartTime.addingTimeInterval(startSeconds + timeOffset)
      let endDate = batchStartTime.addingTimeInterval(endSeconds + timeOffset)

      observations.append(
        Observation(
          id: nil,
          batchId: 0,
          startTs: Int(startDate.timeIntervalSince1970),
          endTs: Int(endDate.timeIntervalSince1970),
          observation: segment.description,
          metadata: nil,
          llmModel: model,
          createdAt: Date()
        )
      )
    }

    if observations.isEmpty {
      throw NSError(
        domain: "GemmaBackupProvider", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "Gemma segmentation produced no observations"])
    }

    if observations.count != expectedSegments {
      throw NSError(
        domain: "GemmaBackupProvider", code: 7,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Generated \(observations.count) observations, expected \(expectedSegments)"
        ])
    }

    let coverage = videoDuration > 0 ? totalDuration / videoDuration : 0
    return (observations, coverage)
  }

  func observationsFromFrames(
    _ frameDescriptions: [(timestamp: TimeInterval, description: String)],
    batchStartTime: Date,
    videoDuration: TimeInterval,
    timeOffset: TimeInterval
  ) throws -> [Observation] {
    guard !frameDescriptions.isEmpty else {
      throw NSError(
        domain: "GemmaBackupProvider", code: 8,
        userInfo: [NSLocalizedDescriptionKey: "No frame descriptions to fall back on"])
    }

    let sortedFrames = frameDescriptions.sorted { $0.timestamp < $1.timestamp }
    let durationCap = videoDuration > 0 ? videoDuration : nil
    var observations: [Observation] = []

    for (index, frame) in sortedFrames.enumerated() {
      let startSeconds = max(0, frame.timestamp) + timeOffset
      var endSeconds = startSeconds + screenshotInterval

      if index + 1 < sortedFrames.count {
        endSeconds = min(endSeconds, sortedFrames[index + 1].timestamp + timeOffset)
      }

      if let cap = durationCap {
        endSeconds = min(endSeconds, cap + timeOffset)
      }

      if endSeconds <= startSeconds {
        endSeconds = startSeconds + max(1, screenshotInterval)
        if let cap = durationCap {
          endSeconds = min(endSeconds, cap + timeOffset)
        }
      }

      let startDate = batchStartTime.addingTimeInterval(startSeconds)
      let endDate = batchStartTime.addingTimeInterval(endSeconds)

      observations.append(
        Observation(
          id: nil,
          batchId: 0,
          startTs: Int(startDate.timeIntervalSince1970),
          endTs: Int(endDate.timeIntervalSince1970),
          observation: frame.description,
          metadata: nil,
          llmModel: model,
          createdAt: Date()
        )
      )
    }

    return observations
  }

}
