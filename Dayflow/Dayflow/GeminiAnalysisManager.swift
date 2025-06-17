//
//  GeminiAnalysisManager.swift
//  Dayflow
//
//  Re‑written 2025‑05‑07 to use the new `GeminiServicing.processBatch` API.
//  • Drops the per‑chunk URL plumbing – the service handles stitching/encoding.
//  • Still handles batching logic + DB status updates.
//  • Keeps the public `AnalysisManaging` contract unchanged.
//
import Foundation
import AVFoundation
import GRDB

// MARK: – Public protocol ---------------------------------------------------

protocol AnalysisManaging {
    func startAnalysisJob()
    func stopAnalysisJob()
    func triggerAnalysisNow()
}

// MARK: – Manager -----------------------------------------------------------

final class GeminiAnalysisManager: AnalysisManaging {
    static let shared = GeminiAnalysisManager()
    private let videoProcessingService: VideoProcessingService
    
    private init() {
        store = StorageManager.shared
        geminiService = GeminiService.shared
        videoProcessingService = VideoProcessingService()
        print("GeminiAnalysisManager: Initialized")
    }

    // MARK: – Private state
    private let store: any StorageManaging
    private let geminiService: any GeminiServicing
    
    // Added Video Processing Constants
    private let MAIN_EVENT_SUMMARY_PICK_INTERVAL_N = 30
    private let DISTRACTION_SUMMARY_PICK_INTERVAL_N = 15

    private let checkInterval: TimeInterval = 60          // every minute
    private let targetBatchDuration: TimeInterval = 15*60 // ≈15‑min logical batches
    private let maxLookback: TimeInterval   = 24*60*60    // only last 24h

    private var analysisTimer: Timer?
    private var isProcessing = false
    private let queue = DispatchQueue(label: "com.dayflow.geminianalysis.queue", qos: .utility)

    // MARK: – Public API -----------------------------------------------------

    func startAnalysisJob() {
        stopAnalysisJob()               // ensure single timer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.analysisTimer = Timer.scheduledTimer(timeInterval: self.checkInterval,
                                                       target: self,
                                                       selector: #selector(self.timerFired),
                                                       userInfo: nil,
                                                       repeats: true)
            self.triggerAnalysisNow()   // immediate run
        }
    }

    func stopAnalysisJob() {
        analysisTimer?.invalidate(); analysisTimer = nil
    }

    func triggerAnalysisNow() {
        guard !isProcessing else { return }
        queue.async { [weak self] in self?.processRecordings() }
    }

    // MARK: – Timer
    @objc private func timerFired() { triggerAnalysisNow() }

    // MARK: – Core work ------------------------------------------------------

    private func processRecordings() {
        guard !isProcessing else { return }; isProcessing = true
        defer { isProcessing = false }

        // 1. Gather unprocessed recordings
        let recs = fetchUnprocessedRecordings()
        // 2. Build logical batches (~15‑min)
        let batches = createBatches(from: recs)
        // 3. Persist batch rows & join table
        let batchIDs = batches.compactMap(saveBatch)
        // 4. Fire Gemini for each batch
        for id in batchIDs { queueGeminiRequest(batchId: id) }
    }

    // MARK: – Gemini kick‑off ----------------------------------------------

    private func queueGeminiRequest(batchId: Int64) {
        let chunksInBatch = StorageManager.shared.recordingsForBatch(batchId)

        if chunksInBatch.isEmpty {
            print("Warning: Batch \\(batchId) has no chunks. Marking as 'failed_empty'.")
            self.updateBatchStatus(batchId: batchId, status: "failed_empty")
            return
        }

        let totalVideoDurationSeconds = chunksInBatch.reduce(0.0) { acc, rec -> TimeInterval in
            let duration = TimeInterval(rec.end_ts - rec.start_ts)
            return acc + duration
        }

        let minimumDurationSeconds: TimeInterval = 300.0 // 5 minutes

        if totalVideoDurationSeconds < minimumDurationSeconds {
            print("Batch \\(batchId) duration (\\(totalVideoDurationSeconds)s) is less than \\(minimumDurationSeconds)s. Marking as 'skipped_short'.")
            self.updateBatchStatus(batchId: batchId, status: "skipped_short")
            return
        }

        updateBatchStatus(batchId: batchId, status: "processing")

        // Prepare file URLs for video processing
        let chunkFileURLs: [URL] = chunksInBatch.compactMap { chunk in
            // Assuming recording file path is a String path, convert to URL
            // Ensure this path is accessible. If it's a relative path, resolve it.
            // For now, assuming it's an absolute file path string.
            URL(fileURLWithPath: chunk.file_url)
        }

        geminiService.processBatch(batchId) { [weak self] result in
            guard let self else { return }

            let now = Date()
            let currentDayInfo = now.getDayInfoFor4AMBoundary()
            let currentLogicalDayString = currentDayInfo.dayString
            print("Processing batch \(batchId) for logical day: \(currentLogicalDayString)")

            switch result {
            case .success(let activityCards):
                print("Gemini succeeded for Batch \\\\(batchId). Processing \\\\(activityCards.count) activity cards for day \\\\(currentLogicalDayString).")
                
                guard let firstChunk = chunksInBatch.first else {
                    print("Error: No chunks found for batch \\\\(batchId) during timestamp conversion")
                    self.markBatchFailed(batchId: batchId, reason: "No chunks found for timestamp conversion")
                    return
                }
                let firstChunkStartDate = Date(timeIntervalSince1970: TimeInterval(firstChunk.start_ts))
                print("First chunk starts at real time: \\\\(firstChunkStartDate)")

                // --- Asynchronous Video Processing Task ---
                Task { [weak self] in
                    guard let self else { return }
                    var temporaryFilesToDelete: [URL] = []
                    var mainBatchVideoURL: URL? = nil
                    
                    struct ProcessedCardInfo {
                        let activityCard: ActivityCard
                        let dbCardId: Int64? // To store the database ID
                        var activityCardSummaryPath: String?
                        var processedDistractions: [ProcessedDistractionInfo]
                    }
                    struct ProcessedDistractionInfo {
                        let originalDistraction: Distraction // The one from ActivityCard
                        let clockStartTime: String
                        let clockEndTime: String
                        var videoSummaryPath: String?
                    }
                    var allProcessedCardInfo: [ProcessedCardInfo] = []

                    do {
                        if !chunkFileURLs.isEmpty {
                            print("Starting video preparation for batch \(batchId)...")
                            let preparedVideoURL = try await self.videoProcessingService.prepareVideoForProcessing(urls: chunkFileURLs)
                            temporaryFilesToDelete.append(preparedVideoURL)
                            mainBatchVideoURL = preparedVideoURL
                            print("Main batch video prepared for batch \(batchId) at: \(preparedVideoURL.path)")
                        } else {
                            print("Warning: No chunk file URLs to process for video summaries for batch \(batchId).")
                        }

                        for activityCard in activityCards {
                            var activitySpecificSummaryPath: String? = nil
                            var processedDistractionInfos: [ProcessedDistractionInfo] = []
                            var currentDbCardId: Int64? = nil

                            // Calculate actual start and end timestamps first
                            guard let videoStartInterval = self.parseVideoTimestamp(activityCard.startTime),
                                  let videoEndInterval = self.parseVideoTimestamp(activityCard.endTime) else {
                                print("Error: Could not parse video timestamps (shell creation): start=\(activityCard.startTime), end=\(activityCard.endTime) for card '\(activityCard.title)'. Skipping card.")
                                // If we can't determine timestamps, we can't reliably save or process the card.
                                continue
                            }
                            let actualStartDate = firstChunkStartDate.addingTimeInterval(videoStartInterval)
                            let actualEndDate = firstChunkStartDate.addingTimeInterval(videoEndInterval)
                            let finalStartTimestamp = self.formatAsClockTime(actualStartDate)
                            let finalEndTimestamp = self.formatAsClockTime(actualEndDate)

                            // 1. Create and save TimelineCardShell to get its DB ID
                            let cardShell = TimelineCardShell(
                                startTimestamp: finalStartTimestamp, // Use calculated timestamp
                                endTimestamp: finalEndTimestamp,   // Use calculated timestamp
                                category: activityCard.category,
                                subcategory: activityCard.subcategory,
                                title: activityCard.title,
                                summary: activityCard.summary,
                                detailedSummary: activityCard.detailedSummary,
                                day: currentLogicalDayString,
                                distractions: activityCard.distractions
                            )
                            
                            currentDbCardId = self.store.saveTimelineCardShell(batchId: batchId, card: cardShell)

                            if let dbId = currentDbCardId {
                                print("Saved TimelineCard shell for '\(activityCard.title)' with DB ID: \(dbId) (Timestamps: \(finalStartTimestamp) - \(finalEndTimestamp))")
                                
                                // Video processing (cardStartInterval and cardEndInterval are already parsed above)
                                if let fullBatchVideo = mainBatchVideoURL {
                                    let cardDuration = videoEndInterval - videoStartInterval // Use already parsed intervals
                                    if cardDuration > 0 {
                                        print("Processing summary for ActivityCard DB ID: \(dbId) ('\(activityCard.title)')")
                                        let cardSegmentURL = try await self.videoProcessingService.extractSegment(
                                            from: fullBatchVideo,
                                            startTime: videoStartInterval,
                                            duration: cardDuration
                                        )
                                        temporaryFilesToDelete.append(cardSegmentURL)

                                        // Use dbId for the filename
                                        let cardOriginalFileName = String(dbId)
                                        let persistentCardSummaryURL = await self.videoProcessingService.generatePersistentSummaryURL(for: now, originalFileName: cardOriginalFileName)
                                        
                                        try await self.videoProcessingService.generateVideoSummary(
                                            sourceVideoURL: cardSegmentURL,
                                            outputSummaryFileURL: persistentCardSummaryURL,
                                            inputFramePickIntervalFactorN: self.MAIN_EVENT_SUMMARY_PICK_INTERVAL_N
                                        )
                                        activitySpecificSummaryPath = persistentCardSummaryURL.path
                                        print("Summary generated for ActivityCard DB ID: \(dbId) at: \(activitySpecificSummaryPath ?? "nil")")
                                        
                                        // 3. Update the TimelineCard record with the video summary URL
                                        self.store.updateTimelineCardVideoURL(cardId: dbId, videoSummaryURL: activitySpecificSummaryPath!)
                                        print("Updated TimelineCard DB ID: \(dbId) with video path.")
                                    } else {
                                        print("Warning: ActivityCard '\(activityCard.title)' (DB ID: \(dbId)) has non-positive duration based on parsed intervals. Skipping summary generation.")
                                        activitySpecificSummaryPath = nil
                                    }
                                } else {
                                    print("Warning: No main batch video. Cannot generate summary for ActivityCard '\(activityCard.title)' (DB ID: \(dbId))")
                                    activitySpecificSummaryPath = nil
                                }
                            } else {
                                print("Error: Failed to save TimelineCard shell for '\(activityCard.title)'. Cannot generate video summary or save full card.")
                                // Skip this card if shell couldn't be saved, as we need the ID
                                continue
                            }

                            // 4. Process distractions for this activity card (using the full batch video as source)
                            if let fullBatchVideo = mainBatchVideoURL, let originalDistractions = activityCard.distractions {
                                for dist in originalDistractions {
                                    // ... (distraction processing remains largely the same, using fullBatchVideo)
                                    // It generates names like batch_X_dist_Y_summary.mp4 - this is acceptable for now.
                                    // Ensure PDistractionInfo is populated correctly for later TimelineCard construction
                                    guard let distStartInterval = self.parseVideoTimestamp(dist.startTime),
                                          let distEndInterval = self.parseVideoTimestamp(dist.endTime) else {
                                        print("Error: Could not parse distraction video timestamps for summary: start=\(dist.startTime), end=\(dist.endTime)")
                                        let distClockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(self.parseVideoTimestamp(dist.startTime) ?? 0.0))
                                        let distClockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(self.parseVideoTimestamp(dist.endTime) ?? 0.0))
                                        processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: distClockStart, clockEndTime: distClockEnd, videoSummaryPath: nil))
                                        continue
                                    }
                                    let distractionDuration = distEndInterval - distStartInterval
                                    if distractionDuration <= 0 {
                                        print("Warning: Distraction '\(dist.title)' has non-positive duration. Skipping summary generation.")
                                        let distClockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distStartInterval))
                                        let distClockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distEndInterval))
                                        processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: distClockStart, clockEndTime: distClockEnd, videoSummaryPath: nil))
                                        continue
                                    }
                                    // ... (rest of distraction video generation, path assigned to distractionSummaryPath)
                                    let distractionSegmentURL = try await self.videoProcessingService.extractSegment(
                                        from: fullBatchVideo,
                                        startTime: distStartInterval,
                                        duration: distractionDuration
                                    )
                                    temporaryFilesToDelete.append(distractionSegmentURL)
                                    let distractionOriginalFileName = "batch_\(batchId)_dist_\(dist.title.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression))"
                                    let persistentDistractionSummaryURL = await self.videoProcessingService.generatePersistentSummaryURL(for: now, originalFileName: distractionOriginalFileName)
                                    try await self.videoProcessingService.generateVideoSummary(
                                        sourceVideoURL: distractionSegmentURL,
                                        outputSummaryFileURL: persistentDistractionSummaryURL,
                                        inputFramePickIntervalFactorN: self.DISTRACTION_SUMMARY_PICK_INTERVAL_N
                                    )
                                    let distractionSummaryPath = persistentDistractionSummaryURL.path
                                    let distClockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distStartInterval))
                                    let distClockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distEndInterval))
                                    processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: distClockStart, clockEndTime: distClockEnd, videoSummaryPath: distractionSummaryPath))
                                }
                            } else if let originalDistractions = activityCard.distractions {
                                for dist in originalDistractions {
                                    let distClockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(self.parseVideoTimestamp(dist.startTime) ?? 0.0))
                                    let distClockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(self.parseVideoTimestamp(dist.endTime) ?? 0.0))
                                    processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: distClockStart, clockEndTime: distClockEnd, videoSummaryPath: nil))
                                }
                            }
                            allProcessedCardInfo.append(ProcessedCardInfo(activityCard: activityCard, dbCardId: currentDbCardId, activityCardSummaryPath: activitySpecificSummaryPath, processedDistractions: processedDistractionInfos))
                        } // End of for activityCard in activityCards

                    } catch {
                        print("Error during video processing for batch \(batchId): \(error.localizedDescription). Some summaries may be missing.")
                        if allProcessedCardInfo.isEmpty && !activityCards.isEmpty {
                             for activityCard in activityCards {
                                var processedDistractionInfos: [ProcessedDistractionInfo] = []
                                if let originalDistractions = activityCard.distractions {
                                    for dist in originalDistractions {
                                        let parsedDistStartInterval = self.parseVideoTimestamp(dist.startTime)
                                        let parsedDistEndInterval = self.parseVideoTimestamp(dist.endTime)
                                        let distClockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(parsedDistStartInterval ?? 0.0))
                                        let distClockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(parsedDistEndInterval ?? 0.0))
                                        processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: distClockStart, clockEndTime: distClockEnd, videoSummaryPath: nil))
                                    }
                                }
                                allProcessedCardInfo.append(ProcessedCardInfo(activityCard: activityCard, dbCardId: nil, activityCardSummaryPath: nil, processedDistractions: processedDistractionInfos))
                            }
                        }
                    }

                    // Cleanup temporary files
                    for tempFile in temporaryFilesToDelete {
                        await self.videoProcessingService.cleanupTemporaryFile(at: tempFile)
                    }
                    print("Temporary video files cleaned up for batch \\\\(batchId).")

                    // Update batch status to completed if all went well (or with errors if some failed)
                    // This needs to be robust to partial failures.
                    // For now, let's assume if we reached here, we can mark it completed.
                    DispatchQueue.main.async { [weak self] in
                        self?.updateBatchStatus(batchId: batchId, status: "completed")
                    }
                } // End of Task for video processing

            case .failure(let err):
                print("Gemini failed for Batch \(batchId). Day \(currentLogicalDayString) may have been cleared. Error: \(err.localizedDescription)")
                self.markBatchFailed(batchId: batchId, reason: err.localizedDescription)
            }
        }
    }

    // MARK: – DB helpers -----------------------------------------------------

    private func markBatchFailed(batchId: Int64, reason: String) {
        store.updateProcessingBatchStatus(batchId, status: "failed", reason: reason)
    }

    private func updateBatchStatus(batchId: Int64, status: String) {
        store.updateProcessingBatchStatus(batchId, status: status, reason: nil)
    }

    // MARK: – Batching logic -------------------------------------------------

    private struct AnalysisBatch { let chunks: [Recording]; let start: Int; let end: Int }

    private func fetchUnprocessedRecordings() -> [Recording] {
        let oldest = Int(Date().timeIntervalSince1970) - Int(maxLookback)
        return store.fetchUnprocessedRecordings(olderThan: oldest)
    }

    // MARK: – Batching logic -----------------------------------------------------

private func createBatches(from chunks: [Recording]) -> [AnalysisBatch] {
    guard !chunks.isEmpty else { return [] }

    let ordered = chunks.sorted { $0.start_ts < $1.start_ts }
    let maxGap: TimeInterval        = 120             // ≤ 2 min between chunks
    let maxBatchDuration: TimeInterval = targetBatchDuration // 900 s (15 min)

    var batches: [AnalysisBatch] = []

    var bucket: [Recording]   = []
    var bucketDur: TimeInterval    = 0                // sum of 15‑s chunks

    for chunk in ordered {
        if bucket.isEmpty {
            bucket.append(chunk)
            bucketDur = chunk.duration                // first chunk → 15 s
            continue
        }

        let prev       = bucket.last!
        let gap        = TimeInterval(chunk.start_ts - prev.end_ts)
        let wouldBurst = bucketDur + chunk.duration > maxBatchDuration

        if gap > maxGap || wouldBurst {
            // close current batch
            batches.append(
                AnalysisBatch(chunks: bucket,
                              start: bucket.first!.start_ts,
                              end:   bucket.last!.end_ts)
            )
            // start new bucket with this chunk
            bucket      = [chunk]
            bucketDur   = chunk.duration
        } else {
            // still in same batch
            bucket.append(chunk)
            bucketDur += chunk.duration
        }
    }

    // Flush any leftover bucket
    if !bucket.isEmpty {
        batches.append(
            AnalysisBatch(chunks: bucket,
                          start: bucket.first!.start_ts,
                          end:   bucket.last!.end_ts)
        )
    }

    // ─── Special rule: drop the *most‑recent* batch if < 15 min ───
    if let last = batches.last {
        let dur = last.chunks.reduce(0) { $0 + $1.duration }   // sum of 15‑s chunks
        if dur < maxBatchDuration {
            batches.removeLast()
        }
    }

    return batches
}


    private func saveBatch(_ batch: AnalysisBatch) -> Int64? {
        let ids = batch.chunks.map { $0.id }
        return store.createProcessingBatch(startTs: batch.start, endTs: batch.end, recordingIds: ids)
    }

    // MARK: - Timestamp conversion helpers

    // Parses a video timestamp like "05:30" into seconds
    private func parseVideoTimestamp(_ timestamp: String) -> TimeInterval? {
        let components = timestamp.components(separatedBy: ":")
        guard components.count == 2,
              let minutes = Int(components[0]),
              let seconds = Int(components[1]) else {
            return nil
        }
        
        return TimeInterval(minutes * 60 + seconds)
    }

    // Formats a Date as a clock time like "11:37 AM"
    private func formatAsClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a" // e.g., "11:37 AM"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}
