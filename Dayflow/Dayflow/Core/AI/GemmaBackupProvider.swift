//
//  GemmaBackupProvider.swift
//  Dayflow
//

import AppKit
import Foundation

final class GemmaBackupProvider {
  private let apiKey: String
  private let model: String
  private let screenshotInterval: TimeInterval = 10
  private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

  init(apiKey: String, model: String = "gemma-3-27b-it") {
    self.apiKey = apiKey
    self.model = model
  }

  // MARK: - Public API

  func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?)
    async throws -> (observations: [Observation], log: LLMCall)
  {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "GemmaBackupProvider", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
    }

    let callStart = Date()
    let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

    let firstTs = sortedScreenshots.first?.capturedAt ?? 0
    let lastTs = sortedScreenshots.last?.capturedAt ?? firstTs
    let durationSeconds = TimeInterval(max(0, lastTs - firstTs))

    let targetSamples = min(15, sortedScreenshots.count)
    let strideAmount = max(1, sortedScreenshots.count / targetSamples)
    let sampledScreenshots = Swift.stride(from: 0, to: sortedScreenshots.count, by: strideAmount)
      .map { sortedScreenshots[$0] }

    let frameData = sampledScreenshots.enumerated().compactMap { index, screenshot -> FrameData? in
      guard let imageData = loadScreenshotData(screenshot) else { return nil }
      let base64String = imageData.base64EncodedString()
      let relativeTimestamp = TimeInterval(screenshot.capturedAt - firstTs)
      return FrameData(index: index + 1, base64Image: base64String, timestamp: relativeTimestamp)
    }

    guard !frameData.isEmpty else {
      throw NSError(
        domain: "GemmaBackupProvider", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Failed to load any screenshots for Gemma fallback"])
    }

    let frameDescriptions = try await describeFrames(frameData, batchId: batchId)

    let mergedObservations: [Observation]
    if durationSeconds > 20 * 60 {
      let midpoint = durationSeconds / 2
      let firstHalf = frameDescriptions.filter { $0.timestamp <= midpoint }
      let secondHalf = frameDescriptions.filter { $0.timestamp > midpoint }

      if firstHalf.isEmpty || secondHalf.isEmpty {
        mergedObservations = try await mergeFrameDescriptions(
          frameDescriptions,
          batchStartTime: batchStartTime,
          videoDuration: durationSeconds,
          batchId: batchId,
          timeOffset: 0,
          targetSegments: 1
        )
      } else {
        let firstRebased = firstHalf.map { (timestamp: $0.timestamp, description: $0.description) }
        let secondRebased = secondHalf.map {
          (timestamp: $0.timestamp - midpoint, description: $0.description)
        }

        let firstObservations = try await mergeFrameDescriptions(
          firstRebased,
          batchStartTime: batchStartTime,
          videoDuration: midpoint,
          batchId: batchId,
          timeOffset: 0,
          targetSegments: 1
        )

        let secondObservations = try await mergeFrameDescriptions(
          secondRebased,
          batchStartTime: batchStartTime,
          videoDuration: durationSeconds - midpoint,
          batchId: batchId,
          timeOffset: midpoint,
          targetSegments: 1
        )

        mergedObservations = firstObservations + secondObservations
      }
    } else {
      mergedObservations = try await mergeFrameDescriptions(
        frameDescriptions,
        batchStartTime: batchStartTime,
        videoDuration: durationSeconds,
        batchId: batchId,
        timeOffset: 0,
        targetSegments: 1
      )
    }

    let log = LLMCall(
      timestamp: callStart,
      latency: Date().timeIntervalSince(callStart),
      input: "Gemma fallback transcription",
      output:
        "Generated \(mergedObservations.count) observations from \(frameDescriptions.count) frames"
    )

    return (mergedObservations, log)
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let callStart = Date()
    var logs: [String] = []

    let sortedObservations = observations.sorted { $0.startTs < $1.startTs }

    guard let firstObservation = sortedObservations.first,
      let lastObservation = sortedObservations.last
    else {
      throw NSError(
        domain: "GemmaBackupProvider", code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "Cannot generate activity cards: no observations provided"
        ])
    }

    var allCards = context.existingCards

    let totalDuration = TimeInterval(max(0, lastObservation.endTs - firstObservation.startTs))
    if totalDuration > 20 * 60 {
      let midpoint = firstObservation.startTs + Int(totalDuration / 2)
      let firstSlice = sortedObservations.filter { $0.startTs <= midpoint }
      let secondSlice = sortedObservations.filter { $0.startTs > midpoint }

      if !firstSlice.isEmpty {
        try await appendCard(
          for: firstSlice, to: &allCards, categories: context.categories, batchId: batchId,
          logs: &logs)
      }

      if !secondSlice.isEmpty {
        try await appendCard(
          for: secondSlice, to: &allCards, categories: context.categories, batchId: batchId,
          logs: &logs)
      }
    } else {
      try await appendCard(
        for: sortedObservations, to: &allCards, categories: context.categories, batchId: batchId,
        logs: &logs)
    }

    let log = LLMCall(
      timestamp: callStart,
      latency: Date().timeIntervalSince(callStart),
      input: "Gemma fallback card generation",
      output: logs.joined(separator: "\n\n---\n\n")
    )

    return (allCards, log)
  }

  private func appendCard(
    for observations: [Observation],
    to cards: inout [ActivityCardData],
    categories: [LLMCategoryDescriptor],
    batchId: Int64?,
    logs: inout [String]
  ) async throws {
    guard let firstObservation = observations.first,
      let lastObservation = observations.last
    else { return }

    let (titleSummary, summaryLog) = try await generateTitleAndSummary(
      observations: observations,
      categories: categories,
      batchId: batchId
    )
    logs.append(summaryLog)

    let normalizedCategory = normalizeCategory(titleSummary.category, categories: categories)

    let newCard = ActivityCardData(
      startTime: formatTimestampForPrompt(firstObservation.startTs),
      endTime: formatTimestampForPrompt(lastObservation.endTs),
      category: normalizedCategory,
      subcategory: "",
      title: titleSummary.title,
      summary: titleSummary.summary,
      detailedSummary: "",
      distractions: nil,
      appSites: titleSummary.appSites
    )

    if !cards.isEmpty, let lastExistingCard = cards.last {
      let lastCardDuration = calculateDurationInMinutes(
        from: lastExistingCard.startTime, to: lastExistingCard.endTime)
      if lastCardDuration >= 40 {
        cards.append(newCard)
        return
      }

      let gapMinutes = calculateDurationInMinutes(
        from: lastExistingCard.endTime, to: newCard.startTime)
      if gapMinutes > 5 {
        cards.append(newCard)
        return
      }

      let candidateDuration = calculateDurationInMinutes(
        from: lastExistingCard.startTime, to: newCard.endTime)
      if candidateDuration > 60 {
        cards.append(newCard)
        return
      }

      let (shouldMerge, mergeLog) = try await checkShouldMerge(
        previousCard: lastExistingCard,
        newCard: newCard,
        batchId: batchId
      )
      logs.append(mergeLog)

      if shouldMerge {
        let (mergedCard, mergeCreateLog) = try await mergeTwoCards(
          previousCard: lastExistingCard,
          newCard: newCard,
          batchId: batchId
        )

        let mergedDuration = calculateDurationInMinutes(
          from: mergedCard.startTime, to: mergedCard.endTime)
        if mergedDuration > 60 {
          cards.append(newCard)
        } else {
          logs.append(mergeCreateLog)
          cards[cards.count - 1] = mergedCard
        }
      } else {
        cards.append(newCard)
      }
    } else {
      cards.append(newCard)
    }
  }

  // MARK: - Frame Description + Segmentation

  private struct FrameData {
    let index: Int
    let base64Image: String
    let timestamp: TimeInterval
  }

  private struct FrameDescriptionEnvelope: Codable {
    struct Item: Codable {
      let index: Int
      let description: String
    }
    let frames: [Item]
  }

  private struct SegmentEnvelope: Codable {
    struct Item: Codable {
      let start: String
      let end: String
      let description: String
    }
    let segments: [Item]
  }

  private struct SegmentCoverageError: Error {
    let coverageRatio: Double
    let durationString: String
  }

  private func describeFrames(_ frames: [FrameData], batchId: Int64?) async throws -> [(
    timestamp: TimeInterval, description: String
  )] {
    do {
      return try await describeFramesInSingleBatch(frames, batchId: batchId)
    } catch {
      // Retry with smaller batches to avoid size limits.
      return try await describeFramesInBatches(frames, batchSize: 5, batchId: batchId)
    }
  }

  private func describeFramesInSingleBatch(_ frames: [FrameData], batchId: Int64?) async throws
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

  private func describeFramesInBatches(_ frames: [FrameData], batchSize: Int, batchId: Int64?)
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

  private func mapFrameDescriptions(_ items: [FrameDescriptionEnvelope.Item], frames: [FrameData])
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

  private func mergeFrameDescriptions(
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

  private func convertSegmentsToObservations(
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

  private func observationsFromFrames(
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

  // MARK: - Summaries + Titles

  private struct SummaryResponse: Codable {
    struct AppSitesResponse: Codable {
      let primary: String?
      let secondary: String?
    }
    let apps: [String]
    let people: [String]
    let main_task: String
    let summary: String
    let category: String
    let app_sites: AppSitesResponse?
  }

  private struct TitleResponse: Codable {
    let title: String
  }

  private struct MergeDecision: Codable {
    let combine: Bool
    let confidence: Double
    let reason: String
  }

  private struct MergedContent: Codable {
    let title: String
    let summary: String
  }

  private struct TitleSummaryPayload {
    let title: String
    let summary: String
    let category: String
    let appSites: AppSites?
  }

  private func generateTitleAndSummary(
    observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?
  ) async throws -> (TitleSummaryPayload, String) {
    let (summaryResult, summaryLog) = try await generateSummary(
      observations: observations, categories: categories, batchId: batchId)
    let (titleResult, titleLog) = try await generateTitle(
      summary: summaryResult.summary, batchId: batchId)

    let appSites = buildAppSites(from: summaryResult.app_sites)

    let payload = TitleSummaryPayload(
      title: titleResult.title,
      summary: summaryResult.summary,
      category: summaryResult.category,
      appSites: appSites
    )

    let combinedLog =
      "=== SUMMARY GENERATION ===\n\(summaryLog)\n\n=== TITLE GENERATION ===\n\(titleLog)"
    return (payload, combinedLog)
  }

  private func generateSummary(
    observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?
  ) async throws -> (SummaryResponse, String) {
    let observationLines: [String] = observations.map { obs in
      let startTime = formatTimestampForPrompt(obs.startTs)
      let endTime = formatTimestampForPrompt(obs.endTs)
      return "[\(startTime) - \(endTime)]: \(obs.observation)"
    }
    let observationsText = observationLines.joined(separator: "\n")

    let descriptorList = categories.isEmpty ? CategoryStore.descriptorsForLLM() : categories
    let categoryLines: [String] = descriptorList.enumerated().map { index, descriptor in
      var description =
        descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if descriptor.isIdle && description.isEmpty {
        description = "Use when the user is idle for most of the period."
      }
      let suffix = description.isEmpty ? "" : " — \(description)"
      return "\(index + 1). \"\(descriptor.name)\"\(suffix)"
    }
    let allowedValues = descriptorList.map { "\"\($0.name)\"" }.joined(separator: ", ")

    let basePrompt = """
      First extract key information, then summarize.

      Observations:
      \(observationsText)

      Step 1 - Extract from the text:
      - Apps/sites used: (list exact names)
      - People mentioned: (list names)
      - Main task: (one phrase)
      - Secondary activities: (brief list)

      Step 2 - Choose EXACTLY ONE category from the list below. Use the label exactly as written.
      \(categoryLines.joined(separator: "\n"))
      Allowed values: [\(allowedValues)]

      Step 3 - Identify appSites from the observations.
      Rules:
      - primary: canonical domain/product path of the main app used
      - secondary: another meaningful app or enclosing app (like browser)
      - Format: lower-case, no protocol, no query or fragments
      - Be specific (docs.google.com over google.com)
      - If unknown, use null

      Step 4 - Write 2-3 sentence summary focusing on main task, using extracted names. first person, without "I".

      Return JSON:
      {
        \"apps\": [\"app1\", \"app2\"],
        \"people\": [\"person1\"],
        \"main_task\": \"what they primarily did\",
        \"summary\": \"2-3 sentence summary using exact names\",
        \"category\": \"one of the allowed values above\",
        \"app_sites\": {\"primary\": \"domain.com\", \"secondary\": \"domain.com\"}
      }
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.generate_summary",
          batchId: batchId,
          temperature: 0.3,
          maxOutputTokens: 1024,
          logRequestBody: true
        )

        let result = try parseJSONResponse(SummaryResponse.self, from: response)
        return (result, response)
      } catch {
        lastError = error
        if attempt == maxAttempts {
          throw error
        }
        prompt =
          basePrompt
          + "\n\nPREVIOUS ATTEMPT FAILED — Respond with ONLY the JSON object described above. Ensure it contains apps, people, main_task, summary, category, and app_sites."
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 9,
        userInfo: [NSLocalizedDescriptionKey: "Failed to generate summary"])
  }

  private func generateTitle(summary: String, batchId: Int64?) async throws -> (
    TitleResponse, String
  ) {
    let basePrompt = """
      Create a title for the given summary

      SUMMARY: "\(summary)"

      TITLE GUIDELINES
      Core principle: If you read this title next week, would you know what you actually did?
      Be specific, but concise:
      Every title needs concrete details. Name the actual thing—the show, the person, the feature, the file, the game. But keep it scannable—aim for roughly 5-10 words. Extra details belong in the summary.

      Bad: "Watched videos" → Good: "The Office bloopers on YouTube"
      Bad: "Worked on UI" → Good: "Fixed navbar overlap on mobile"
      Bad: "Had a call" → Good: "Call with James about venue options"
      Bad: "Did research" → Good: "Comparing gyms near the new apartment"
      Bad: "Debugged issues" → Good: "Tracked down Stripe webhook failures"
      Bad: "Played games" → Good: "Civilization VI — finally beat Deity difficulty"
      Bad: "Browsed YouTube" → Good: "Veritasium video on turbulence"
      Bad: "Chatted with team" → Good: "Slack debate about monorepo vs multirepo"
      Bad: "Made a reservation" → Good: "Booked Nobu for Saturday 7pm"
      Bad: "Coded" → Good: "Built CSV export for transactions"

      Don't overload the title:
      If you're using em-dashes, parentheses, or listing 3+ things—you're probably cramming summary content into the title.

      Bad: "Apartment hunting — Zillow listings in Brooklyn, StreetEasy saved searches, and broker fee research"
      Good: "Apartment hunting in Brooklyn"
      Bad: "Weekly metrics review — signups, churn rate, MRR growth, and cohort retention"
      Good: "Weekly metrics review"
      Bad: "Call with Mom — talked about Dad's birthday, her knee surgery, and Aunt Linda's visit"
      Good: "Call with Mom"

      Avoid vague words:
      These words hide what actually happened:

      "worked on" → doing what to it?
      "looked at" → reviewing? debugging? reading?
      "handled" → fixed? ignored? escalated?
      "dealt with" → means nothing
      "various" / "some" / "multiple" → name them or pick the main one
      "deep dive" / "rabbit hole" → just say what you researched
      "sync" / "aligned" / "circled back" → say what you discussed or decided
      "browsing" / "iterations" / "analytics" → what specifically?

      Avoid repetitive structure:
      Don't start every title with a verb. Mix it up naturally:

      "Fixed the infinite scroll bug on search results"
      "Breaking Bad rewatch — season 3 finale"
      "Call with recruiter about the Stripe role"
      "AWS cost spike investigation"
      "Planning the bachelor party itinerary"
      "Stardew Valley — finished the community center"
      "iPhone vs Pixel camera comparison for Mom"
      "Morning coffee + Hacker News catch-up"

      If several titles in a row start with "Fixed... Debugged... Built... Reviewed..." — vary the structure.
      Use "and" sparingly:
      Don't use "and" to connect unrelated things. Pick the main activity for the title; the rest goes in the summary.

      Bad: "Fixed bug and replied to emails" → Good: "Fixed pagination crash" (emails in summary)
      Bad: "YouTube then coded" → Good: "Built the settings modal" (YouTube is a distraction)
      Bad: "Read articles, watched TikTok, checked Discord" → Good: "Scattered browsing" (it was scattered, just say that)

      "And" is okay when both parts serve the same goal:

      OK: "Designed and prototyped the onboarding flow"
      OK: "Researched and booked the Airbnb in Lisbon"
      OK: "Drafted and sent the investor update"

      When it's genuinely scattered:
      If there was no main focus—just bouncing between tabs—don't force a fake throughline:

      "YouTube and Twitter browsing"
      "Scattered browsing break"
      "Catching up on Reddit and Discord"

      Before finalizing: would this title help you remember what you actually did?

      Return JSON:
      {"title": "single-activity title"}
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.generate_title",
          batchId: batchId,
          temperature: 0.3,
          maxOutputTokens: 256,
          logRequestBody: true
        )

        let result = try parseJSONResponse(TitleResponse.self, from: response)
        return (result, response)
      } catch {
        lastError = error
        if attempt == maxAttempts {
          throw error
        }
        prompt =
          basePrompt
          + "\n\nPREVIOUS ATTEMPT FAILED — Respond with ONLY the JSON object described above."
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 10,
        userInfo: [NSLocalizedDescriptionKey: "Failed to generate title"])
  }

  private func checkShouldMerge(
    previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?
  ) async throws -> (Bool, String) {
    let basePrompt = """
      Are these two activities part of the SAME task or DIFFERENT tasks?

      PREVIOUS (\(previousCard.startTime) - \(previousCard.endTime)):
      \(previousCard.title)

      NEXT (\(newCard.startTime) - \(newCard.endTime)):
      \(newCard.title)

      SAME TASK (combine=true, confidence 0.85+):
      - Continuing the exact same work
      - Same project AND same type of work
      - Would naturally be one story

      DIFFERENT TASKS (combine=false):
      - Different projects
      - Different mental modes (coding vs browsing vs gaming)
      - Context switch happened

      Return JSON:
      {"combine": true/false, "confidence": 0.0-1.0, "reason": "why"}
      """

    let confidenceThreshold = 0.85
    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.merge_check",
          batchId: batchId,
          temperature: 0.2,
          maxOutputTokens: 256,
          logRequestBody: true
        )

        let decision = try parseJSONResponse(MergeDecision.self, from: response)
        let shouldMerge = decision.combine && decision.confidence >= confidenceThreshold
        return (shouldMerge, response)
      } catch {
        lastError = error
        if attempt == maxAttempts {
          throw error
        }
        prompt =
          basePrompt
          + "\n\nPREVIOUS ATTEMPT FAILED — Respond with ONLY the JSON object described above."
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Failed to evaluate merge decision"])
  }

  private func mergeTwoCards(
    previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?
  ) async throws -> (ActivityCardData, String) {
    let basePrompt = """
      Combine these two cards into one.

      CARD 1 (\(previousCard.startTime) - \(previousCard.endTime)): \(previousCard.title)
      \(previousCard.summary)

      CARD 2 (\(newCard.startTime) - \(newCard.endTime)): \(newCard.title)
      \(newCard.summary)

      Create ONE title and summary for the full period.
      Title: 5-8 words, main throughline, past tense verb
      Summary: 2-3 sentences

      Return JSON:
      {"title": "merged title", "summary": "merged summary"}
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.merge_cards",
          batchId: batchId,
          temperature: 0.2,
          maxOutputTokens: 512,
          logRequestBody: true
        )

        let merged = try parseJSONResponse(MergedContent.self, from: response)

        let mergedCard = ActivityCardData(
          startTime: previousCard.startTime,
          endTime: newCard.endTime,
          category: previousCard.category,
          subcategory: "",
          title: merged.title,
          summary: merged.summary,
          detailedSummary: "",
          distractions: previousCard.distractions,
          appSites: previousCard.appSites ?? newCard.appSites
        )

        return (mergedCard, response)
      } catch {
        lastError = error
        if attempt == maxAttempts {
          throw error
        }
        prompt =
          basePrompt
          + "\n\nPREVIOUS ATTEMPT FAILED — Respond with ONLY the JSON object described above."
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 12,
        userInfo: [NSLocalizedDescriptionKey: "Failed to merge cards"])
  }

  // MARK: - Networking

  private func callGenerateContent(
    parts: [[String: Any]],
    operation: String,
    batchId: Int64?,
    temperature: Double,
    maxOutputTokens: Int,
    logRequestBody: Bool
  ) async throws -> String {
    let url = URL(string: "\(baseURL)/\(model):generateContent?key=\(apiKey)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120

    let requestBody: [String: Any] = [
      "contents": [["parts": parts]],
      "generationConfig": [
        "temperature": temperature,
        "maxOutputTokens": maxOutputTokens,
      ],
    ]

    let requestData = try JSONSerialization.data(withJSONObject: requestBody)
    request.httpBody = requestData

    let requestStart = Date()
    let logBody = logRequestBody ? requestData : nil

    let ctx = LLMCallContext(
      batchId: batchId,
      callGroupId: UUID().uuidString,
      attempt: 1,
      provider: "gemma",
      model: model,
      operation: operation,
      requestMethod: request.httpMethod,
      requestURL: request.url,
      requestHeaders: request.allHTTPHeaderFields,
      requestBody: logBody,
      startedAt: requestStart
    )

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      LLMLogger.logFailure(
        ctx: ctx,
        http: nil,
        finishedAt: Date(),
        errorDomain: (error as NSError).domain,
        errorCode: (error as NSError).code,
        errorMessage: (error as NSError).localizedDescription
      )
      throw error
    }

    let httpResponse = response as? HTTPURLResponse
    let status = httpResponse?.statusCode
    let responseHeaders: [String: String]? = httpResponse?.allHeaderFields.reduce(into: [:]) {
      acc, kv in
      if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
        acc[k] = v.description
      }
    }

    if let status, status >= 400 {
      let errorMessage = extractErrorMessage(from: data, fallback: "HTTP \(status) error")
      LLMLogger.logFailure(
        ctx: ctx,
        http: LLMHTTPInfo(httpStatus: status, responseHeaders: responseHeaders, responseBody: data),
        finishedAt: Date(),
        errorDomain: "GemmaBackupProvider",
        errorCode: status,
        errorMessage: errorMessage
      )
      throw NSError(
        domain: "GemmaBackupProvider", code: status,
        userInfo: [NSLocalizedDescriptionKey: errorMessage])
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let firstCandidate = candidates.first,
      let content = firstCandidate["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let text = parts.first?["text"] as? String
    else {
      LLMLogger.logFailure(
        ctx: ctx,
        http: LLMHTTPInfo(httpStatus: status, responseHeaders: responseHeaders, responseBody: data),
        finishedAt: Date(),
        errorDomain: "GemmaBackupProvider",
        errorCode: 0,
        errorMessage: "Failed to parse response"
      )
      throw NSError(
        domain: "GemmaBackupProvider", code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Failed to parse response"])
    }

    LLMLogger.logSuccess(
      ctx: ctx,
      http: LLMHTTPInfo(httpStatus: status, responseHeaders: responseHeaders, responseBody: data),
      finishedAt: Date()
    )

    return text
  }

  private func extractErrorMessage(from data: Data, fallback: String) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = json["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      return message
    }
    return fallback
  }

  // MARK: - Utilities

  private func parseJSONResponse<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
    guard let data = text.data(using: .utf8) else {
      throw NSError(
        domain: "GemmaBackupProvider", code: 14,
        userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
    }

    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      // Attempt to extract JSON object
      guard let responseString = String(data: data, encoding: .utf8) else {
        throw error
      }
      if let startIndex = responseString.firstIndex(of: "{"),
        let endIndex = responseString.lastIndex(of: "}")
      {
        let jsonSubstring = responseString[startIndex...endIndex]
        if let jsonData = jsonSubstring.data(using: .utf8) {
          return try JSONDecoder().decode(type, from: jsonData)
        }
      }
      throw error
    }
  }

  private func frameDescriptionPrompt(frameCount: Int) -> String {
    """
    You are a precise activity logger analyzing screenshots from a screen recording. For each screenshot, describe EXACTLY what the user is doing with hyper-specific detail.

    REQUIRED DETAILS FOR EACH FRAME:
    1. EXACT APP/SITE: Name the specific application (e.g., "VS Code", "Xcode", "Safari on twitter.com", "Terminal running npm")
    2. SPECIFIC ACTION: What is the user actively doing? (e.g., "typing code", "reading article", "scrolling feed", "debugging error", "running command")
    3. VISIBLE CONTENT: What specific content is shown? (e.g., "Swift function called fetchUserData", "PostHog dashboard showing DAU chart", "Google search for 'tokyo restaurants'")
    4. UI STATE: Any relevant UI details (e.g., "error dialog visible", "loading spinner", "dropdown menu open", "cursor in search bar")

    BAD (too vague): "User is using a code editor"
    GOOD (specific): "VS Code with Swift file AuthManager.swift open, cursor on line 45 inside fetchToken() function, yellow warning on line 42"

    BAD: "User is browsing the web"
    GOOD: "Safari on tabelog.com restaurant page for 'Haidilao Shibuya', scrolling through reviews section, 4.2 star rating visible"

    Output ONLY valid JSON:
    {
      "frames": [
        {"index": 1, "description": "Hyper-specific description"},
        {"index": 2, "description": "Hyper-specific description"}
      ]
    }

    Analyze these \(frameCount) screenshots with maximum specificity:
    """
  }

  private func segmentPrompt(
    frameDescriptions: [(timestamp: TimeInterval, description: String)], durationString: String,
    targetSegments: Int
  ) -> String {
    var lines: [String] = []
    for frame in frameDescriptions {
      let minutes = Int(frame.timestamp) / 60
      let seconds = Int(frame.timestamp) % 60
      let timeStr = String(format: "%02d:%02d", minutes, seconds)
      lines.append("- \(timeStr): \(frame.description)")
    }
    let framesText = lines.joined(separator: "\n")

    return """
      Create an activity log from \(durationString) of screen recording.

      Frame descriptions:
      \(framesText)

      TARGET: Create EXACTLY \(targetSegments) segment(s). Not more, not less.

      MERGING RULES (CRITICAL):
      - Same app + same activity = ONE segment (even if 10+ minutes)
      - Same game session = ONE segment (don't split by in-game events)
      - Same video = ONE segment (don't split by video timestamps)
      - Same conversation = ONE segment (don't split by messages)
      - Quick app switches serving same goal = ONE segment

      FORBIDDEN SEGMENTS:
      - "Transition" or "Shifted focus" segments (just end previous, start next)
      - Segments under 2 minutes (merge with adjacent)
      - Segments describing nothing specific

      DESCRIPTION FORMAT:
      "[App]: [Specific task] - [key details: files, URLs, names, outcomes]"

      GOOD: "YouTube: Watching 'Ninja CREAMi: Pacojet Killer?' review by Chris Young, evaluating ice cream makers"
      GOOD: "Kingdom Two Crowns: Playing snowy biome campaign, building settlement, survived multiple nights (+100 coins rewards)"
      BAD: "Transition: Shifted from YouTube to restaurant search" (FORBIDDEN)
      BAD: "YouTube: Watching video" then "YouTube: Continued watching" (should be ONE segment)

      Output JSON only:
      {"segments": [{"start": "00:00", "end": "MM:SS", "description": "..."}]}
      """
  }

  private func normalizeCategory(_ raw: String, categories: [LLMCategoryDescriptor]) -> String {
    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return categories.first?.name ?? "" }
    let normalized = cleaned.lowercased()
    if let match = categories.first(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }) {
      return match.name
    }
    if let idle = categories.first(where: { $0.isIdle }) {
      let idleLabels = [
        "idle", "idle time", idle.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      ]
      if idleLabels.contains(normalized) {
        return idle.name
      }
    }
    return categories.first?.name ?? cleaned
  }

  private func buildAppSites(from response: SummaryResponse.AppSitesResponse?) -> AppSites? {
    guard let response else { return nil }
    let primary = response.primary?.trimmingCharacters(in: .whitespacesAndNewlines)
    let secondary = response.secondary?.trimmingCharacters(in: .whitespacesAndNewlines)

    let cleanedPrimary = primary?.isEmpty == false ? primary : nil
    let cleanedSecondary = secondary?.isEmpty == false ? secondary : nil

    if cleanedPrimary == nil && cleanedSecondary == nil {
      return nil
    }

    return AppSites(primary: cleanedPrimary, secondary: cleanedSecondary)
  }

  private func formatTimestampForPrompt(_ timestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  private func parseVideoTimestamp(_ timestamp: String) -> Int {
    let components = timestamp.components(separatedBy: ":")
    if components.count == 2 {
      let minutes = Int(components[0]) ?? 0
      let seconds = Int(components[1]) ?? 0
      return minutes * 60 + seconds
    } else if components.count == 3 {
      let hours = Int(components[0]) ?? 0
      let minutes = Int(components[1]) ?? 0
      let seconds = Int(components[2]) ?? 0
      return hours * 3600 + minutes * 60 + seconds
    }
    return 0
  }

  private func calculateDurationInMinutes(from startTime: String, to endTime: String) -> Int {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    guard let start = formatter.date(from: startTime),
      let end = formatter.date(from: endTime)
    else {
      return 0
    }

    var duration = end.timeIntervalSince(start)
    if duration < 0 {
      duration += 24 * 60 * 60
    }

    return Int(duration / 60)
  }

  private func loadScreenshotData(
    _ screenshot: Screenshot, maxDimension: CGFloat = 1280, compression: CGFloat = 0.7
  ) -> Data? {
    let url = URL(fileURLWithPath: screenshot.filePath)
    guard let image = NSImage(contentsOf: url) else { return nil }

    let originalSize = image.size
    let maxSide = max(originalSize.width, originalSize.height)
    let scale = maxSide > maxDimension ? (maxDimension / maxSide) : 1.0
    let targetSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

    let resized = NSImage(size: targetSize)
    resized.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: originalSize),
      operation: .copy, fraction: 1.0)
    resized.unlockFocus()

    guard let tiff = resized.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff)
    else { return nil }

    let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    return jpegData
  }
}
