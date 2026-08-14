//
//  MiniMaxProvider+Transcription.swift
//  Dayflow
//
//  Screenshot / frame transcription for the MiniMax provider.
//  Logic mirrors OllamaProvider+Transcription.swift, adapted for MiniMax M3.
//

import AppKit
import Foundation

extension MiniMaxProvider {
  fileprivate struct FrameData {
    let image: Data  // Base64 encoded image
    let timestamp: TimeInterval  // Seconds from batch start
  }

  fileprivate struct VideoSegment: Codable {
    let startTimestamp: String  // MM:SS format
    let endTimestamp: String  // MM:SS format
    let description: String
  }

  fileprivate struct SegmentGroupingResponse: Codable {
    let reasoning: String
    let segments: [VideoSegment]
  }

  fileprivate struct SegmentCoverageError: LocalizedError {
    let coverageRatio: Double
    let durationString: String

    var percentage: Int { max(0, min(100, Int(coverageRatio * 100))) }

    var errorDescription: String? {
      "Segments only cover \(percentage)% of video (expected >80%). Video is \(durationString) long."
    }
  }

  fileprivate func parseVideoTimestamp(_ timestamp: String) -> Int {
    let components = timestamp.components(separatedBy: ":")
    if components.count == 3 {
      guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]) else {
        return 0
      }
      return h * 3600 + m * 60 + s
    } else if components.count == 2 {
      guard let m = Int(components[0]), let s = Int(components[1]) else { return 0 }
      return m * 60 + s
    }
    return 0
  }

  fileprivate func getSimpleFrameDescription(_ frame: FrameData, batchId: Int64?) async -> String? {
    let prompt = """
      Describe what you see on this computer screen in 1-2 sentences.
      Focus on: what application/site is open, what the user is doing, and any relevant details visible.
      Be specific and factual.

      GOOD EXAMPLES:
      ✓ "VS Code open with index.js file, writing a React component for user authentication."
      ✓ "Gmail compose window writing email to client@company.com about project timeline."
      ✓ "Slack conversation in #engineering channel discussing API rate limiting issues."

      BAD EXAMPLES:
      ✗ "User is coding" (too vague)
      ✗ "Looking at a website" (doesn't identify which site)
      ✗ "Working on computer" (completely non-specific)
      """

    guard let base64String = String(data: frame.image, encoding: .utf8) else {
      print("[MINIMAX] ⚠️ Failed to decode frame image — skipping frame")
      return nil
    }

    let content: [MessageContent] = [
      MessageContent(type: "text", text: prompt, image_url: nil),
      MessageContent(
        type: "image_url", text: nil,
        image_url: MessageContent.ImageURL(url: "data:image/jpeg;base64,\(base64String)")),
    ]

    let request = ChatRequest(
      model: savedModelId,
      messages: [ChatMessage(role: "user", content: content)]
    )

    do {
      let response = try await callChatAPI(
        request, operation: "describe_frame", batchId: batchId, maxRetries: 1)
      let raw = response.choices.first?.message.content ?? ""
      return MiniMaxReasoning.stripThinkTags(in: raw)
    } catch {
      print(
        "[MINIMAX] ⚠️ describe_frame failed at \(frame.timestamp)s — skipping frame: \(error.localizedDescription)"
      )
      return nil
    }
  }

  fileprivate func decodeSegmentResponse(_ response: String) throws -> (
    segments: [VideoSegment], reasoning: String
  ) {
    guard let rawData = response.data(using: .utf8) else {
      throw NSError(
        domain: "MiniMaxProvider", code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Failed to parse segment response"])
    }

    if let object = try? parseJSONResponse(SegmentGroupingResponse.self, from: rawData) {
      return (object.segments, object.reasoning)
    }
    if let array = try? parseJSONResponse([VideoSegment].self, from: rawData) {
      return (array, "")
    }
    if let start = response.firstIndex(of: "{"),
      let end = response.lastIndex(of: "}")
    {
      let substring = response[start...end]
      if let data = substring.data(using: .utf8),
        let object = try? parseJSONResponse(SegmentGroupingResponse.self, from: data)
      {
        return (object.segments, object.reasoning)
      }
    }
    if let start = response.firstIndex(of: "["),
      let end = response.lastIndex(of: "]")
    {
      let substring = response[start...end]
      if let data = substring.data(using: .utf8),
        let array = try? parseJSONResponse([VideoSegment].self, from: data)
      {
        return (array, "")
      }
    }
    throw NSError(
      domain: "MiniMaxProvider", code: 9,
      userInfo: [NSLocalizedDescriptionKey: "Could not parse segment response as JSON"])
  }

  fileprivate func convertSegmentsToObservations(
    _ segments: [VideoSegment],
    batchStartTime: Date,
    videoDuration: TimeInterval,
    durationString: String
  ) throws -> (observations: [Observation], coverage: Double) {
    var observations: [Observation] = []
    var totalDuration: TimeInterval = 0
    var lastEndTime: TimeInterval?

    for (index, segment) in segments.enumerated() {
      let startSeconds = TimeInterval(parseVideoTimestamp(segment.startTimestamp))
      let endSeconds = TimeInterval(parseVideoTimestamp(segment.endTimestamp))

      let tolerance: TimeInterval = 30.0
      if startSeconds < -tolerance || endSeconds > videoDuration + tolerance {
        print(
          "[MINIMAX] ❌ Segment \(index + 1) exceeds video duration: \(segment.startTimestamp)-\(segment.endTimestamp) (video is \(durationString))"
        )
        continue
      }

      let clampedDuration = max(0, endSeconds - startSeconds)
      totalDuration += clampedDuration
      lastEndTime = endSeconds

      let startDate = batchStartTime.addingTimeInterval(startSeconds)
      let endDate = batchStartTime.addingTimeInterval(endSeconds)

      observations.append(
        Observation(
          id: nil,
          batchId: 0,
          startTs: Int(startDate.timeIntervalSince1970),
          endTs: Int(endDate.timeIntervalSince1970),
          observation: segment.description,
          metadata: nil,
          llmModel: savedModelId,
          createdAt: Date()
        )
      )
    }

    if observations.isEmpty {
      throw NSError(
        domain: "MiniMaxProvider", code: 11,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Screenshots failed to process - check MiniMax API configuration or report a bug."
        ])
    }

    if observations.count > 5 {
      throw NSError(
        domain: "MiniMaxProvider", code: 13,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Generated \(observations.count) observations, but expected 2-5. The LLM must follow the instruction to create EXACTLY 2-5 segments."
        ])
    }

    let coverage = videoDuration > 0 ? totalDuration / videoDuration : 0
    return (observations, coverage)
  }

  fileprivate func observationsFromFrames(
    _ frameDescriptions: [(timestamp: TimeInterval, description: String)],
    batchStartTime: Date,
    videoDuration: TimeInterval
  ) throws -> [Observation] {
    guard !frameDescriptions.isEmpty else {
      throw NSError(
        domain: "MiniMaxProvider",
        code: 11,
        userInfo: [
          NSLocalizedDescriptionKey:
            "It looks like the MiniMax API is not responding. Please check your API key and network connection in settings."
        ]
      )
    }

    let sortedFrames = frameDescriptions.sorted { $0.timestamp < $1.timestamp }
    let durationCap = videoDuration > 0 ? videoDuration : nil
    var observations: [Observation] = []

    for (index, frame) in sortedFrames.enumerated() {
      let startSeconds = max(0, frame.timestamp)
      var endSeconds = startSeconds + screenshotInterval

      if index + 1 < sortedFrames.count {
        endSeconds = min(endSeconds, sortedFrames[index + 1].timestamp)
      }
      if let cap = durationCap {
        endSeconds = min(endSeconds, cap)
      }
      if endSeconds <= startSeconds {
        endSeconds = startSeconds + max(1, screenshotInterval)
        if let cap = durationCap { endSeconds = min(endSeconds, cap) }
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
          llmModel: nil,
          createdAt: Date()
        )
      )
    }
    return observations
  }

  fileprivate func mergeFrameDescriptions(
    _ frameDescriptions: [(timestamp: TimeInterval, description: String)],
    batchStartTime: Date,
    videoDuration: TimeInterval,
    batchId: Int64?
  ) async throws -> [Observation] {
    var formattedDescriptions = ""
    for frame in frameDescriptions {
      let minutes = Int(frame.timestamp) / 60
      let seconds = Int(frame.timestamp) % 60
      let timeStr = String(format: "%02d:%02d", minutes, seconds)
      formattedDescriptions += "[\(timeStr)] \(frame.description)\n"
    }

    let durationMinutes = Int(videoDuration / 60)
    let durationSeconds = Int(videoDuration.truncatingRemainder(dividingBy: 60))
    let durationString = String(format: "%02d:%02d", durationMinutes, durationSeconds)

    let basePrompt = """
      You have \(frameDescriptions.count) snapshots from a \(durationString) screen recording.

      CRITICAL TASK: Group these snapshots into EXACTLY 2-5 coherent segments that collectively explain \(durationString) of activity. Brief interruptions (< 2 minutes) should be absorbed into the surrounding segment.

      Here are the snapshots (timestamp → description):
      \(formattedDescriptions)

      Respond with a JSON object using this exact shape:
      {
        "reasoning": "Use this space to think through how you're going to construct the segments",
        "segments": [
          {
            "startTimestamp": "MM:SS",
            "endTimestamp": "MM:SS",
            "description": "Natural language summary of what happened"
          }
        ]
      }

      HARD REQUIREMENTS:
      - "segments" MUST contain between 2 and 5 items.
      - Every timestamp must stay within 00:00 and \(durationString).
      - Segments should cover at least 80% of the video (ideally 100%) without inventing events.
      - Merge small gaps instead of creating tiny standalone segments.
      - Never output additional text outside the JSON object.
      """

    let maxAttempts = 2
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callTextAPI(
          prompt, operation: "segment_video_activity", expectJSON: true, batchId: batchId)
        let (segments, _) = try decodeSegmentResponse(response)
        let (observations, coverage) = try convertSegmentsToObservations(
          segments,
          batchStartTime: batchStartTime,
          videoDuration: videoDuration,
          durationString: durationString
        )

        if coverage < 0.8 {
          throw SegmentCoverageError(coverageRatio: coverage, durationString: durationString)
        }
        return observations
      } catch let coverageError as SegmentCoverageError {
        lastError = coverageError
        if attempt == maxAttempts {
          print("[MINIMAX] ❌ segment_video_activity retries exhausted (coverage)")
          return try observationsFromFrames(
            frameDescriptions,
            batchStartTime: batchStartTime,
            videoDuration: videoDuration
          )
        }
        prompt =
          basePrompt + """


            PREVIOUS ATTEMPT FAILED — Your segments only covered \(coverageError.percentage)% of the \(durationString) video.
            Merge adjacent snapshots or extend segment boundaries so the segments cover at least 80% of the runtime without inventing events.
            """
      } catch {
        lastError = error
        if attempt == maxAttempts {
          print("[MINIMAX] ❌ segment_video_activity retries exhausted (error: \(error.localizedDescription))")
          return try observationsFromFrames(
            frameDescriptions,
            batchStartTime: batchStartTime,
            videoDuration: videoDuration
          )
        }
        prompt =
          basePrompt + """


            PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
            Respond with ONLY the JSON object described above. Ensure it contains a "reasoning" string and a "segments" array with 2-5 items covering at least 80% of the video.
            """
      }
    }

    throw lastError
      ?? NSError(
        domain: "MiniMaxProvider", code: 9,
        userInfo: [NSLocalizedDescriptionKey: "Failed to generate merged observations after multiple attempts"])
  }
}

// MARK: - Public transcription entry point

extension MiniMaxProvider {
  /// Transcribe observations from screenshots.
  func transcribeScreenshots(
    _ screenshots: [Screenshot],
    batchStartTime: Date,
    batchId: Int64?
  ) async throws -> (observations: [Observation], log: LLMCall) {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "MiniMaxProvider", code: 12,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
    }

    let callStart = Date()
    let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

    // Sample ~15 evenly spaced screenshots to keep the request bounded.
    let targetSamples = 15
    let strideAmount = max(1, sortedScreenshots.count / targetSamples)
    let sampledScreenshots = Swift.stride(from: 0, to: sortedScreenshots.count, by: strideAmount)
      .map { sortedScreenshots[$0] }

    let firstTs = sampledScreenshots.first!.capturedAt
    let lastTs = sampledScreenshots.last!.capturedAt
    let durationSeconds = TimeInterval(lastTs - firstTs)

    var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []
    for screenshot in sampledScreenshots {
      guard let frameData = loadScreenshotAsFrameData(screenshot, relativeTo: firstTs) else {
        print("[MINIMAX] ⚠️ Failed to load screenshot: \(screenshot.filePath)")
        continue
      }
      if let description = await getSimpleFrameDescription(frameData, batchId: batchId) {
        frameDescriptions.append((timestamp: frameData.timestamp, description: description))
      }
    }

    guard !frameDescriptions.isEmpty else {
      throw NSError(
        domain: "MiniMaxProvider",
        code: 11,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Failed to describe any screenshots. Please verify your MiniMax API key and that the model is available."
        ]
      )
    }

    let observations = try await mergeFrameDescriptions(
      frameDescriptions,
      batchStartTime: batchStartTime,
      videoDuration: durationSeconds,
      batchId: batchId
    )

    let totalTime = Date().timeIntervalSince(callStart)
    let log = LLMCall(
      timestamp: callStart,
      latency: totalTime,
      input: "Screenshot transcription: \(screenshots.count) screenshots → \(observations.count) observations",
      output: "Processed \(screenshots.count) screenshots in \(String(format: "%.2f", totalTime))s"
    )

    return (observations, log)
  }

  fileprivate func loadScreenshotAsFrameData(
    _ screenshot: Screenshot, relativeTo baseTimestamp: Int
  ) -> FrameData? {
    guard let imageData = loadScreenshotDataForMiniMax(screenshot) else {
      return nil
    }
    let base64String = imageData.base64EncodedString()
    let base64Data = Data(base64String.utf8)
    let relativeTimestamp = TimeInterval(screenshot.capturedAt - baseTimestamp)
    return FrameData(image: base64Data, timestamp: relativeTimestamp)
  }

  private func loadScreenshotDataForMiniMax(
    _ screenshot: Screenshot, maxHeight: Double = 720, jpegQuality: CGFloat = 0.85
  ) -> Data? {
    let url = URL(fileURLWithPath: screenshot.filePath)
    guard let image = NSImage(contentsOf: url) else {
      return try? Data(contentsOf: url)
    }
    let rep =
      image.representations.compactMap { $0 as? NSBitmapImageRep }.first
      ?? image.representations.first
    let pixelsWide = rep?.pixelsWide ?? Int(image.size.width)
    let pixelsHigh = rep?.pixelsHigh ?? Int(image.size.height)

    if pixelsHigh <= Int(maxHeight) {
      return try? Data(contentsOf: url)
    }

    let scale = maxHeight / Double(pixelsHigh)
    let targetW = max(2, Int((Double(pixelsWide) * scale).rounded(.toNearestOrAwayFromZero)))
    let targetH = Int(maxHeight)

    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: targetW,
        pixelsHigh: targetH,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return nil }

    bitmap.size = NSSize(width: targetW, height: targetH)
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
      NSGraphicsContext.restoreGraphicsState()
      return nil
    }
    NSGraphicsContext.current = ctx
    image.draw(
      in: NSRect(x: 0, y: 0, width: CGFloat(targetW), height: CGFloat(targetH)),
      from: NSRect(origin: .zero, size: image.size),
      operation: .copy,
      fraction: 1.0,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: jpegQuality]
    return bitmap.representation(using: NSBitmapImageRep.FileType.jpeg, properties: props)
  }
}
