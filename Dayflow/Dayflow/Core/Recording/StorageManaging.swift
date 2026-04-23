import Foundation

/// File + database persistence used by screen‑recorder & Gemini pipeline.
///
/// _No_ `@MainActor` isolation ⇒ can be called from any thread/actor.
/// If you add UI‑touching methods later, isolate **those** individually.
protocol StorageManaging: Sendable {
  // Recording‑chunk lifecycle
  func nextFileURL() -> URL
  func registerChunk(url: URL)
  func markChunkCompleted(url: URL)
  func markChunkFailed(url: URL)

  // Fetch unprocessed (completed + not yet batched) chunks
  func fetchUnprocessedChunks(olderThan oldestAllowed: Int) -> [RecordingChunk]
  func fetchChunksInTimeRange(startTs: Int, endTs: Int) -> [RecordingChunk]

  // Analysis‑batch management
  func saveBatch(startTs: Int, endTs: Int, chunkIds: [Int64]) -> Int64?
  func updateBatchStatus(batchId: Int64, status: String)
  func markBatchFailed(batchId: Int64, reason: String)

  // Record details about all LLM calls for a batch
  func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall])
  func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall]

  // Timeline‑cards
  func saveTimelineCardShell(batchId: Int64, card: TimelineCardShell) -> Int64?
  func updateTimelineCardVideoURL(cardId: Int64, videoSummaryURL: String)
  func deleteTimelineCard(recordId: Int64) -> String?
  func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard]
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps?
  func fetchLastTimelineCard(endingBefore: Date) -> TimelineCardWithTimestamps?

  // Timeline Queries
  func fetchTimelineCards(forDay day: String) -> [TimelineCard]
  func fetchTimelineCardsByTimeRange(from: Date, to: Date) -> [TimelineCard]
  func fetchTotalMinutesTracked(from: Date, to: Date) -> Double
  func fetchTotalMinutesTrackedForWeek(containing date: Date) -> Double
  func replaceTimelineCardsInRange(from: Date, to: Date, with: [TimelineCardShell], batchId: Int64)
    -> (insertedIds: [Int64], deletedVideoPaths: [String])
  func fetchRecentTimelineCardsForDebug(limit: Int) -> [TimelineCardDebugEntry]

  func updateTimelineCardCategory(cardId: Int64, category: String)

  // Timeline review ratings (time-based)
  func fetchReviewRatingSegments(overlapping startTs: Int, endTs: Int)
    -> [TimelineReviewRatingSegment]
  func applyReviewRating(startTs: Int, endTs: Int, rating: String)
  func fetchUnreviewedTimelineCardCount(forDay day: String, coverageThreshold: Double) -> Int

  func fetchRecentLLMCallsForDebug(limit: Int) -> [LLMCallDebugEntry]
  func fetchRecentAnalysisBatchesForDebug(limit: Int) -> [AnalysisBatchDebugEntry]
  func fetchLLMCallsForBatches(batchIds: [Int64], limit: Int) -> [LLMCallDebugEntry]

  // Note: Transcript storage methods removed in favor of Observations

  // NEW: Observations Storage
  func saveObservations(batchId: Int64, observations: [Observation])
  func fetchObservations(batchId: Int64) -> [Observation]
  func fetchObservations(startTs: Int, endTs: Int) -> [Observation]
  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation]

  // Helper for GeminiService – map file paths → timestamps
  func getTimestampsForVideoFiles(paths: [String]) -> [String: (startTs: Int, endTs: Int)]

  // Reprocessing Methods
  func deleteTimelineCards(forDay day: String) -> [String]  // Returns video paths to clean up
  func deleteTimelineCards(forBatchIds batchIds: [Int64]) -> [String]
  func deleteObservations(forBatchIds batchIds: [Int64])
  func resetBatchStatuses(forDay day: String) -> [Int64]  // Returns affected batch IDs
  func resetBatchStatuses(forBatchIds batchIds: [Int64]) -> [Int64]
  func fetchBatches(forDay day: String) -> [(id: Int64, startTs: Int, endTs: Int, status: String)]

  /// Chunks that belong to one batch, already sorted.
  func chunksForBatch(_ batchId: Int64) -> [RecordingChunk]

  /// All batches, newest first
  func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)]

  // MARK: - Screenshot Management (new - replaces video chunks)

  /// Returns the next screenshot file URL (.jpg)
  func nextScreenshotURL() -> URL

  /// Save a screenshot to the database, returns the screenshot ID
  func saveScreenshot(url: URL, capturedAt: Date, idleSecondsAtCapture: Int?) -> Int64?

  /// Fetch screenshots that haven't been assigned to a batch yet
  func fetchUnprocessedScreenshots(since oldestTimestamp: Int) -> [Screenshot]

  /// Create a batch from screenshots, returns batch ID
  func saveBatchWithScreenshots(startTs: Int, endTs: Int, screenshotIds: [Int64]) -> Int64?

  /// Screenshots that belong to one batch, sorted by capture time
  func screenshotsForBatch(_ batchId: Int64) -> [Screenshot]

  /// Fetch screenshots within a time range (for timelapse generation)
  func fetchScreenshotsInTimeRange(startTs: Int, endTs: Int) -> [Screenshot]
}
