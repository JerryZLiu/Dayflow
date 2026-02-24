//
//  AnalysisManager.swift
//  Dayflow
//
//  Re‑written 2025‑05‑07 to use the new `GeminiServicing.processBatch` API.
//  • Drops the per‑chunk URL plumbing – the service handles stitching/encoding.
//  • Still handles batching logic + DB status updates.
//  • Keeps the public `AnalysisManaging` contract unchanged.
//
import Foundation
import GRDB
import Sentry

protocol AnalysisManaging {
  func startAnalysisJob()
  func stopAnalysisJob()
  func triggerAnalysisNow()
  func reprocessDay(
    _ day: String, progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void)
  func reprocessSpecificBatches(
    _ batchIds: [Int64], progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void)
  func reprocessBatch(
    _ batchId: Int64, stepHandler: @escaping (LLMProcessingStep) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void)
}

final class AnalysisManager: AnalysisManaging {
  static let shared = AnalysisManager()

  private init() {
    store = StorageManager.shared
    llmService = LLMService.shared
  }

  private let store: any StorageManaging
  private let llmService: any LLMServicing

  // Video Processing Constants - removed old summary generation

  private let checkInterval: TimeInterval = 60  // every minute
  private let maxLookback: TimeInterval = 24 * 60 * 60  // only last 24h
  // Note: target batch duration and max gap are controlled via llmService.batchingConfig.

  private var analysisTimer: Timer?
  private var isProcessing = false
  private let queue = DispatchQueue(label: "com.dayflow.geminianalysis.queue", qos: .utility)

  func startAnalysisJob() {
    stopAnalysisJob()  // ensure single timer
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.analysisTimer = Timer.scheduledTimer(
        timeInterval: self.checkInterval,
        target: self,
        selector: #selector(self.timerFired),
        userInfo: nil,
        repeats: true)
      self.triggerAnalysisNow()  // immediate run
    }
  }

  func stopAnalysisJob() {
    analysisTimer?.invalidate()
    analysisTimer = nil
  }

  func triggerAnalysisNow() {
    guard !isProcessing else { return }
    queue.async { [weak self] in self?.processRecordings() }
  }

  func reprocessDay(
    _ day: String, progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self = self else {
        completion(
          .failure(
            NSError(
              domain: "AnalysisManager", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])))
        return
      }

      let overallStartTime = Date()
      var batchTimings: [(batchId: Int64, duration: TimeInterval)] = []

      DispatchQueue.main.async { progressHandler("Preparing to reprocess day \(day)...") }

      // 1. Delete existing timeline cards and get video paths to clean up
      let videoPaths = self.store.deleteTimelineCards(forDay: day)

      // 2. Clean up video files
      for path in videoPaths {
        if let url = URL(string: path) {
          try? FileManager.default.removeItem(at: url)
        }
      }

      DispatchQueue.main.async { progressHandler("Deleted \(videoPaths.count) video files") }

      // 3. Get all batch IDs for the day before resetting
      let batches = self.store.fetchBatches(forDay: day)
      let batchIds = batches.map { $0.id }

      if batchIds.isEmpty {
        DispatchQueue.main.async {
          progressHandler("No batches found for day \(day)")
          completion(.success(()))
        }
        return
      }

      // 4. Delete observations for these batches
      self.store.deleteObservations(forBatchIds: batchIds)
      DispatchQueue.main.async {
        progressHandler("Deleted observations for \(batchIds.count) batches")
      }

      // 5. Reset batch statuses to pending
      let resetBatchIds = self.store.resetBatchStatuses(forDay: day)
      DispatchQueue.main.async {
        progressHandler("Reset \(resetBatchIds.count) batches to pending status")
      }

      // 6. Process each batch sequentially
      var processedCount = 0

      for (index, batchId) in batchIds.enumerated() {

        let batchStartTime = Date()
        let elapsedTotal = Date().timeIntervalSince(overallStartTime)

        DispatchQueue.main.async {
          progressHandler(
            "Processing batch \(index + 1) of \(batchIds.count)... (Total elapsed: \(self.formatDuration(elapsedTotal)))"
          )
        }

        self.queueLLMRequest(batchId: batchId)

        // Wait for batch to complete (check status periodically)
        var isCompleted = false
        while !isCompleted {
          Thread.sleep(forTimeInterval: 2.0)  // Check every 2 seconds

          let currentBatches = self.store.fetchBatches(forDay: day)
          if let batch = currentBatches.first(where: { $0.id == batchId }) {
            switch batch.status {
            case "completed", "analyzed":
              isCompleted = true
              processedCount += 1
              let batchDuration = Date().timeIntervalSince(batchStartTime)
              batchTimings.append((batchId: batchId, duration: batchDuration))
              DispatchQueue.main.async {
                progressHandler(
                  "✓ Batch \(index + 1) completed in \(self.formatDuration(batchDuration))")
              }
            case "failed", "failed_empty", "skipped_short":
              // These are acceptable end states
              isCompleted = true
              processedCount += 1
              let batchDuration = Date().timeIntervalSince(batchStartTime)
              batchTimings.append((batchId: batchId, duration: batchDuration))
              DispatchQueue.main.async {
                progressHandler(
                  "⚠️ Batch \(index + 1) ended with status '\(batch.status)' after \(self.formatDuration(batchDuration))"
                )
              }
            case "processing":
              // Still processing, continue waiting
              break
            default:
              // Unexpected status, but continue
              break
            }
          }
        }
      }

      let totalDuration = Date().timeIntervalSince(overallStartTime)

      DispatchQueue.main.async {
        // Build summary with timing stats
        var summary = "\n📊 Reprocessing Summary:\n"
        summary += "Total batches: \(batchIds.count)\n"
        summary += "Processed: \(processedCount)\n"
        summary += "Total time: \(self.formatDuration(totalDuration))\n"

        if !batchTimings.isEmpty {
          summary += "\nBatch timings:\n"
          for (index, timing) in batchTimings.enumerated() {
            summary += "  Batch \(index + 1): \(self.formatDuration(timing.duration))\n"
          }

          let avgTime = batchTimings.map { $0.duration }.reduce(0, +) / Double(batchTimings.count)
          summary += "\nAverage time per batch: \(self.formatDuration(avgTime))"
        }

        progressHandler(summary)
        completion(.success(()))
      }
    }
  }

  func reprocessSpecificBatches(
    _ batchIds: [Int64], progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self = self else {
        completion(
          .failure(
            NSError(
              domain: "AnalysisManager", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])))
        return
      }

      let overallStartTime = Date()
      var batchTimings: [(batchId: Int64, duration: TimeInterval)] = []

      DispatchQueue.main.async {
        progressHandler("Preparing to reprocess \(batchIds.count) selected batches...")
      }

      let allBatches = self.store.allBatches()
      let existingBatchIds = Set(allBatches.map { $0.id })
      let orderedBatchIds = batchIds.filter { existingBatchIds.contains($0) }

      guard !orderedBatchIds.isEmpty else {
        completion(
          .failure(
            NSError(
              domain: "AnalysisManager", code: 3,
              userInfo: [NSLocalizedDescriptionKey: "Could not find batch information"])))
        return
      }

      // Delete observations so they can be regenerated
      // Note: We don't delete timeline cards here - LLMService.processBatch's
      // replaceTimelineCardsInRange() handles atomic card replacement, keeping
      // the old card visible until new cards are ready
      self.store.deleteObservations(forBatchIds: orderedBatchIds)

      let resetBatchIdSet = Set(self.store.resetBatchStatuses(forBatchIds: orderedBatchIds))
      let batchesToProcess = orderedBatchIds.filter { resetBatchIdSet.contains($0) }

      guard !batchesToProcess.isEmpty else {
        DispatchQueue.main.async { progressHandler("No eligible batches found to reprocess.") }
        completion(
          .failure(
            NSError(
              domain: "AnalysisManager", code: 4,
              userInfo: [NSLocalizedDescriptionKey: "No eligible batches found to reprocess"])))
        return
      }

      DispatchQueue.main.async {
        progressHandler("Processing \(batchesToProcess.count) batches...")
      }

      // Process batches
      var processedCount = 0

      for (index, batchId) in batchesToProcess.enumerated() {
        let batchStartTime = Date()
        let elapsedTotal = Date().timeIntervalSince(overallStartTime)

        DispatchQueue.main.async {
          progressHandler(
            "Processing batch \(index + 1) of \(batchesToProcess.count)... (Total elapsed: \(self.formatDuration(elapsedTotal)))"
          )
        }

        self.queueLLMRequest(batchId: batchId)

        // Wait for batch to complete (check status periodically)
        var isCompleted = false
        while !isCompleted {
          Thread.sleep(forTimeInterval: 2.0)  // Check every 2 seconds

          let allBatches = self.store.allBatches()
          if let batch = allBatches.first(where: { $0.id == batchId }) {
            switch batch.status {
            case "completed", "analyzed":
              isCompleted = true
              processedCount += 1
              let batchDuration = Date().timeIntervalSince(batchStartTime)
              batchTimings.append((batchId: batchId, duration: batchDuration))
              DispatchQueue.main.async {
                progressHandler(
                  "✓ Batch \(index + 1) completed in \(self.formatDuration(batchDuration))")
              }
            case "failed", "failed_empty", "skipped_short":
              // These are acceptable end states
              isCompleted = true
              processedCount += 1
              let batchDuration = Date().timeIntervalSince(batchStartTime)
              batchTimings.append((batchId: batchId, duration: batchDuration))
              DispatchQueue.main.async {
                progressHandler(
                  "⚠️ Batch \(index + 1) ended with status '\(batch.status)' after \(self.formatDuration(batchDuration))"
                )
              }
            case "processing":
              // Still processing, continue waiting
              break
            default:
              // Unexpected status, but continue
              break
            }
          }
        }
      }

      // Summary
      let totalDuration = Date().timeIntervalSince(overallStartTime)
      let avgDuration =
        batchTimings.isEmpty
        ? 0 : batchTimings.reduce(0) { $0 + $1.duration } / Double(batchTimings.count)

      DispatchQueue.main.async {
        progressHandler(
          """
          ✅ Reprocessing complete!
          • Processed: \(processedCount) of \(batchesToProcess.count) batches
          • Total time: \(self.formatDuration(totalDuration))
          • Average time per batch: \(self.formatDuration(avgDuration))
          """)
      }

      completion(.success(()))
    }
  }

  func reprocessBatch(
    _ batchId: Int64, stepHandler: @escaping (LLMProcessingStep) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async {
          completion(
            .failure(
              NSError(
                domain: "AnalysisManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])))
        }
        return
      }

      // Reset batch state and clear observations
      self.store.deleteObservations(forBatchIds: [batchId])
      let resetBatchIds = Set(self.store.resetBatchStatuses(forBatchIds: [batchId]))
      guard resetBatchIds.contains(batchId) else {
        DispatchQueue.main.async {
          completion(
            .failure(
              NSError(
                domain: "AnalysisManager", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No eligible batches found to reprocess"])))
        }
        return
      }

      self.queueLLMRequest(
        batchId: batchId,
        progressHandler: stepHandler,
        completion: { result in
          DispatchQueue.main.async {
            completion(result)
          }
        }
      )
    }
  }

  @objc private func timerFired() { triggerAnalysisNow() }

  private func processRecordings() {
    guard !isProcessing else { return }
    isProcessing = true
    defer { isProcessing = false }

    // 1. Gather unprocessed screenshots
    let screenshots = fetchUnprocessedScreenshots()
    // 2. Build logical batches (duration based on provider config)
    let batches = createScreenshotBatches(from: screenshots)
    // 3. Persist batch rows & join table
    let batchIDs = batches.compactMap(saveScreenshotBatch)
    // 4. Fire LLM for each batch
    for id in batchIDs { queueLLMRequest(batchId: id) }
  }

  private func queueLLMRequest(
    batchId: Int64,
    progressHandler: ((LLMProcessingStep) -> Void)? = nil,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    let screenshotsInBatch = StorageManager.shared.screenshotsForBatch(batchId)

    guard !screenshotsInBatch.isEmpty else {
      print("Warning: Batch \(batchId) has no screenshots. Marking as 'failed_empty'.")
      self.updateBatchStatus(batchId: batchId, status: "failed_empty")
      completion?(.success(()))
      return
    }

    let itemCount = screenshotsInBatch.count
    let totalDurationSeconds: TimeInterval
    if let first = screenshotsInBatch.first, let last = screenshotsInBatch.last {
      totalDurationSeconds = TimeInterval(last.capturedAt - first.capturedAt)
    } else {
      totalDurationSeconds = 0
    }

    if itemCount == 0 {
      print("Warning: Batch \(batchId) has no data. Marking as 'failed_empty'.")
      self.updateBatchStatus(batchId: batchId, status: "failed_empty")
      completion?(.success(()))
      return
    }

    let minimumDurationSeconds: TimeInterval = 300.0  // 5 minutes

    if totalDurationSeconds < minimumDurationSeconds {
      print(
        "Batch \(batchId) duration (\(totalDurationSeconds)s) is less than \(minimumDurationSeconds)s. Marking as 'skipped_short'."
      )
      self.updateBatchStatus(batchId: batchId, status: "skipped_short")
      completion?(.success(()))
      return
    }

    // Start performance tracking for batch processing
    let transaction = SentrySDK.startTransaction(
      name: "batch_processing",
      operation: "llm.batch"
    )
    transaction.setData(value: batchId, key: "batch_id")
    transaction.setData(value: itemCount, key: "screenshot_count")
    transaction.setData(value: totalDurationSeconds, key: "duration_s")

    // Add breadcrumb for batch processing start
    let breadcrumb = Breadcrumb(level: .info, category: "analysis")
    breadcrumb.message = "Starting batch \(batchId) processing"
    breadcrumb.data = [
      "mode": "screenshots",
      "count": itemCount,
      "duration_s": totalDurationSeconds,
    ]
    SentrySDK.addBreadcrumb(breadcrumb)

    updateBatchStatus(batchId: batchId, status: "processing")

    llmService.processBatch(batchId, progressHandler: progressHandler) {
      [weak self] (result: Result<ProcessedBatchResult, Error>) in
      guard let self else { return }

      let now = Date()
      let currentDayInfo = now.getDayInfoFor4AMBoundary()
      let currentLogicalDayString = currentDayInfo.dayString
      print("Processing batch \(batchId) for logical day: \(currentLogicalDayString)")

      switch result {
      case .success(let processedResult):
        let activityCards = processedResult.cards
        print(
          "LLM succeeded for Batch \(batchId). Processing \(activityCards.count) activity cards for day \(currentLogicalDayString)."
        )

        // Finish performance transaction - LLM processing completed successfully
        transaction.finish(status: .ok)

        // Debug: Check for duplicate cards from LLM
        print("\n🔍 DEBUG: Checking for duplicate cards from LLM:")
        for (i, card1) in activityCards.enumerated() {
          for (j, card2) in activityCards.enumerated() where j > i {
            if card1.startTime == card2.startTime && card1.endTime == card2.endTime
              && card1.title == card2.title
            {
              print(
                "⚠️ DEBUG: Found duplicate cards at indices \(i) and \(j): '\(card1.title)' [\(card1.startTime) - \(card1.endTime)]"
              )
            }
          }
        }
        print("✅ DEBUG: Duplicate check complete\n")

        // Mark batch as completed immediately
        self.updateBatchStatus(batchId: batchId, status: "completed")
        // Timelapses are generated on demand from the UI to avoid background battery drain.

        completion?(.success(()))

      case .failure(let err):
        print(
          "LLM failed for Batch \(batchId). Day \(currentLogicalDayString) may have been cleared. Error: \(err.localizedDescription)"
        )

        // Finish performance transaction - LLM processing failed
        transaction.finish(status: .internalError)

        self.markBatchFailed(batchId: batchId, reason: err.localizedDescription)
        completion?(.failure(err))
      }
    }
  }

  private func markBatchFailed(batchId: Int64, reason: String) {
    store.markBatchFailed(batchId: batchId, reason: reason)
  }

  private func updateBatchStatus(batchId: Int64, status: String) {
    store.updateBatchStatus(batchId: batchId, status: status)
  }

  // MARK: - Screenshot-based Batching

  private struct ScreenshotBatch {
    let screenshots: [Screenshot]
    let start: Int
    let end: Int

    /// Duration covered by this batch (based on timestamp range)
    var duration: TimeInterval {
      TimeInterval(end - start)
    }

    /// Number of screenshots in the batch
    var count: Int { screenshots.count }
  }

  private func fetchUnprocessedScreenshots() -> [Screenshot] {
    let oldest = Int(Date().timeIntervalSince1970) - Int(maxLookback)
    return store.fetchUnprocessedScreenshots(since: oldest)
  }

  private func createScreenshotBatches(from screenshots: [Screenshot]) -> [ScreenshotBatch] {
    guard !screenshots.isEmpty else { return [] }

    let ordered = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    let config = llmService.batchingConfig
    let maxGap: TimeInterval = config.maxGap
    let maxBatchDuration: TimeInterval = config.targetDuration

    var batches: [ScreenshotBatch] = []
    var bucket: [Screenshot] = []

    for screenshot in ordered {
      if bucket.isEmpty {
        bucket.append(screenshot)
        continue
      }

      let prev = bucket.last!
      let gap = TimeInterval(screenshot.capturedAt - prev.capturedAt)
      let currentDuration = TimeInterval(screenshot.capturedAt - bucket.first!.capturedAt)
      let wouldBurst = currentDuration > maxBatchDuration

      if gap > maxGap || wouldBurst {
        // Close current batch
        batches.append(
          ScreenshotBatch(
            screenshots: bucket,
            start: bucket.first!.capturedAt,
            end: bucket.last!.capturedAt
          )
        )
        // Start new bucket
        bucket = [screenshot]
      } else {
        bucket.append(screenshot)
      }
    }

    // Flush any leftover bucket
    if !bucket.isEmpty {
      batches.append(
        ScreenshotBatch(
          screenshots: bucket,
          start: bucket.first!.capturedAt,
          end: bucket.last!.capturedAt
        )
      )
    }

    // Drop the most-recent batch if incomplete (not enough data yet)
    if let last = batches.last {
      if last.duration < maxBatchDuration {
        batches.removeLast()
      }
    }

    return batches
  }

  private func saveScreenshotBatch(_ batch: ScreenshotBatch) -> Int64? {
    let ids = batch.screenshots.map { $0.id }
    return store.saveBatchWithScreenshots(
      startTs: batch.start, endTs: batch.end, screenshotIds: ids)
  }

  // Formats a duration in seconds to a human-readable string
  private func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds) / 60
    let remainingSeconds = Int(seconds) % 60

    if minutes > 0 {
      return "\(minutes)m \(remainingSeconds)s"
    } else {
      return "\(remainingSeconds)s"
    }
  }
}
