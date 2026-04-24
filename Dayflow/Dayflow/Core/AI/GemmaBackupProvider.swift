//
//  GemmaBackupProvider.swift
//  Dayflow
//

import AppKit
import Foundation

final class GemmaBackupProvider {
  let apiKey: String
  let model: String
  let screenshotInterval: TimeInterval = 10
  let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

  init(apiKey: String, model: String = "gemma-4-31b-it") {
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

  func appendCard(
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

}
