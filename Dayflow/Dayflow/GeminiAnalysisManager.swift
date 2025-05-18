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

protocol AnalysisManaging {
    func startAnalysisJob()
    func stopAnalysisJob()
    func triggerAnalysisNow()
}

final class GeminiAnalysisManager: AnalysisManaging, @unchecked Sendable {
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

        // 1. Gather unprocessed chunks
        let chunks = fetchUnprocessedChunks()
        // 2. Build logical batches (~15‑min)
        let batches = createBatches(from: chunks)
        // 3. Persist batch rows & join table
        let batchIDs = batches.compactMap(saveBatch)
        // 4. Fire Gemini for each batch
        for id in batchIDs { queueGeminiRequest(batchId: id) }
    }

    // MARK: – Gemini kick‑off ----------------------------------------------

    private func queueGeminiRequest(batchId: Int64) {
        let chunksInBatch = StorageManager.shared.chunksForBatch(batchId)

        if chunksInBatch.isEmpty {
            print("Warning: Batch \\(batchId) has no chunks. Marking as 'failed_empty'.")
            self.updateBatchStatus(batchId: batchId, status: "failed_empty")
            return
        }

        let totalVideoDurationSeconds = chunksInBatch.reduce(0.0) { acc, chunk -> TimeInterval in
            let duration = TimeInterval(chunk.endTs - chunk.startTs)
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
            // Assuming chunk.fileUrl is a String path, convert to URL
            // Ensure this path is accessible. If it's a relative path, resolve it.
            // For now, assuming it's an absolute file path string.
            URL(fileURLWithPath: chunk.fileUrl)
        }

        geminiService.processBatch(batchId) { [weak self] result in
            guard let self else { return }

            let now = Date()
            let currentDayInfo = now.getDayInfoFor4AMBoundary()
            let currentLogicalDayString = currentDayInfo.dayString
            print("Processing batch \\\\(batchId) for logical day: \\\\(currentLogicalDayString)")

            switch result {
            case .success(let activityCards):
                print("Gemini succeeded for Batch \\\\(batchId). Processing \\\\(activityCards.count) activity cards for day \\\\(currentLogicalDayString).")
                
                guard let firstChunk = chunksInBatch.first else {
                    print("Error: No chunks found for batch \\\\(batchId) during timestamp conversion")
                    self.markBatchFailed(batchId: batchId, reason: "No chunks found for timestamp conversion")
                    return
                }
                let firstChunkStartDate = Date(timeIntervalSince1970: TimeInterval(firstChunk.startTs))
                print("First chunk starts at real time: \\\\(firstChunkStartDate)")

                // --- Asynchronous Video Processing Task ---
                Task { [weak self] in
                    guard let self else { return }
                    var temporaryFilesToDelete: [URL] = []
                    var mainEventVideoURL: URL? = nil
                    var mainEventSummaryURLPath: String? = nil
                    
                    // Create a structure to hold processed data including video summary paths
                    struct ProcessedCardInfo {
                        let activityCard: ActivityCard // Assuming ActivityCard is defined elsewhere (from GeminiService)
                        var mainEventSummaryPath: String?
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
                            print("Starting video preparation for batch \\\\(batchId)...")
                            let preparedVideoURL = try await self.videoProcessingService.prepareVideoForProcessing(urls: chunkFileURLs)
                            temporaryFilesToDelete.append(preparedVideoURL)
                            mainEventVideoURL = preparedVideoURL
                            print("Main event video prepared for batch \\\\(batchId) at: \\\\(preparedVideoURL.path)")

                            let persistentMainSummaryURL = await self.videoProcessingService.generatePersistentSummaryURL(for: now, originalFileName: "batch_\\\\(batchId)_main_event")
                            print("Attempting to generate main event summary for batch \\\\(batchId) to: \\\\(persistentMainSummaryURL.path)")
                            try await self.videoProcessingService.generateVideoSummary(
                                sourceVideoURL: preparedVideoURL,
                                outputSummaryFileURL: persistentMainSummaryURL,
                                inputFramePickIntervalFactorN: self.MAIN_EVENT_SUMMARY_PICK_INTERVAL_N
                            )
                            mainEventSummaryURLPath = persistentMainSummaryURL.path
                        } else {
                            print("Warning: No chunk file URLs to process for video summaries for batch \\\\(batchId).")
                        }

                        // Process distractions for each activity card
                        for activityCard in activityCards {
                            var processedDistractionInfos: [ProcessedDistractionInfo] = []
                            if let mainVideoURL = mainEventVideoURL, let originalDistractions = activityCard.distractions {
                                for dist in originalDistractions {
                                    guard let distStartInterval = self.parseVideoTimestamp(dist.startTime),
                                          let distEndInterval = self.parseVideoTimestamp(dist.endTime) else {
                                        print("Error: Could not parse distraction video timestamps for summary: start=\(dist.startTime), end=\(dist.endTime)")
                                        // Add with nil summary path. Provide 0 or a sensible default for interval if parsing fails.
                                         let clockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(self.parseVideoTimestamp(dist.startTime) ?? 0.0))
                                         let clockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(self.parseVideoTimestamp(dist.endTime) ?? 0.0))
                                        processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: clockStart, clockEndTime: clockEnd, videoSummaryPath: nil))
                                        continue
                                    }
                                    let distractionDuration = distEndInterval - distStartInterval
                                    if distractionDuration <= 0 {
                                        print("Warning: Distraction has non-positive duration. Skipping summary generation. Start: \(dist.startTime), End: \(dist.endTime)")
                                        let distClockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distStartInterval))
                                        let distClockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distEndInterval))
                                        processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: distClockStart, clockEndTime: distClockEnd, videoSummaryPath: nil))
                                        continue
                                    }

                                    print("Processing distraction '\(dist.title)' for summary. Video Time: \(dist.startTime) - \(dist.endTime)")
                                    let distractionSegmentURL = try await self.videoProcessingService.extractSegment(
                                        from: mainVideoURL,
                                        startTime: distStartInterval,
                                        duration: distractionDuration
                                    )
                                    temporaryFilesToDelete.append(distractionSegmentURL)
                                    print("Distraction segment extracted to: \(distractionSegmentURL.path)")

                                    let persistentDistractionSummaryURL = await self.videoProcessingService.generatePersistentSummaryURL(for: now, originalFileName: "batch_\(batchId)_dist_\(dist.title.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression))")
                                    try await self.videoProcessingService.generateVideoSummary(
                                        sourceVideoURL: distractionSegmentURL,
                                        outputSummaryFileURL: persistentDistractionSummaryURL,
                                        inputFramePickIntervalFactorN: self.DISTRACTION_SUMMARY_PICK_INTERVAL_N
                                    )
                                    let distractionSummaryPath = persistentDistractionSummaryURL.path
                                    print("Distraction summary generated: \(distractionSummaryPath)")
                                    
                                    let distClockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distStartInterval))
                                    let distClockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distEndInterval))
                                    processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: distClockStart, clockEndTime: distClockEnd, videoSummaryPath: distractionSummaryPath))
                                }
                            } else if let originalDistractions = activityCard.distractions { // Case: No main video, but distractions exist
                                for dist in originalDistractions {
                                    guard let distStartInterval = self.parseVideoTimestamp(dist.startTime),
                                          let distEndInterval = self.parseVideoTimestamp(dist.endTime) else {
                                        print("Error: Could not parse distraction video timestamps (no main video): start=\(dist.startTime), end=\(dist.endTime)")
                                        continue
                                    }
                                    let distClockStart = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distStartInterval))
                                    let distClockEnd = self.formatAsClockTime(firstChunkStartDate.addingTimeInterval(distEndInterval))
                                    processedDistractionInfos.append(ProcessedDistractionInfo(originalDistraction: dist, clockStartTime: distClockStart, clockEndTime: distClockEnd, videoSummaryPath: nil))
                                }
                            }
                            allProcessedCardInfo.append(ProcessedCardInfo(activityCard: activityCard, mainEventSummaryPath: mainEventSummaryURLPath, processedDistractions: processedDistractionInfos))
                        }

                    } catch {
                        print("Error during video processing for batch \\\\(batchId): \\\\(error.localizedDescription). Some summaries may be missing.")
                        // Fallback: populate allProcessedCardInfo with nil summary paths if not already done due to error
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
                                allProcessedCardInfo.append(ProcessedCardInfo(activityCard: activityCard, mainEventSummaryPath: nil, processedDistractions: processedDistractionInfos))
                            }
                        }
                    }

                    // Cleanup temporary files
                    for tempFile in temporaryFilesToDelete {
                        await self.videoProcessingService.cleanupTemporaryFile(at: tempFile)
                    }
                    print("Temporary video files cleaned up for batch \\\\(batchId).")

                    // --- Now build TimelineCards with the summary URLs ---
                    var timelineCardsToSave: [TimelineCard] = []
                    for processedInfo in allProcessedCardInfo {
                        let activityCard = processedInfo.activityCard
                        
                        guard let videoStartInterval = self.parseVideoTimestamp(activityCard.startTime),
                              let videoEndInterval = self.parseVideoTimestamp(activityCard.endTime) else {
                            print("Error: Could not parse video timestamps (final pass): start=\(activityCard.startTime), end=\(activityCard.endTime)")
                            continue
                        }
                        let actualStartDate = firstChunkStartDate.addingTimeInterval(videoStartInterval)
                        let actualEndDate = firstChunkStartDate.addingTimeInterval(videoEndInterval)
                        let startTimestamp = self.formatAsClockTime(actualStartDate)
                        let endTimestamp = self.formatAsClockTime(actualEndDate)

                        let finalDistractions: [Distraction]? = processedInfo.processedDistractions.map { pDist in
                            Distraction(
                                startTime: pDist.clockStartTime,
                                endTime: pDist.clockEndTime,
                                title: pDist.originalDistraction.title,
                                summary: pDist.originalDistraction.summary,
                                videoSummaryURL: pDist.videoSummaryPath // This is the new field
                            )
                        }

                        let timelineCard = TimelineCard(
                            startTimestamp: startTimestamp,
                            endTimestamp: endTimestamp,
                            category: activityCard.category,
                            subcategory: activityCard.subcategory,
                            title: activityCard.title,
                            summary: activityCard.summary,
                            detailedSummary: activityCard.detailedSummary,
                            day: currentLogicalDayString,
                            distractions: finalDistractions,
                            videoSummaryURL: processedInfo.mainEventSummaryPath // This is the new field
                        )
                        timelineCardsToSave.append(timelineCard)
                    }
                    
                    // --- Save the new timeline cards (moved inside Task to use processed data) ---
                    DispatchQueue.main.async { [weak self] in // Ensure DB operations are on the correct queue if needed
                        guard let self else { return }
                        if !timelineCardsToSave.isEmpty {
                            print("Saving \(timelineCardsToSave.count) new timeline cards for batch \(batchId) (Day: \(currentLogicalDayString)) with video summaries.")
                            self.store.saveTimelineCards(batchId: batchId, cards: timelineCardsToSave)
                            self.updateBatchStatus(batchId: batchId, status: "completed")
                        } else if activityCards.isEmpty { // No activity cards from Gemini
                             print("No activity cards received from Gemini for batch \(batchId). Marking as completed.")
                             self.updateBatchStatus(batchId: batchId, status: "completed")
                        }
                        else { // Activity cards existed, but none converted to timeline cards (e.g. all parsing errors)
                            print("No new timeline cards to save for batch \(batchId) after video processing for day \(currentLogicalDayString). Marking as completed.")
                            self.updateBatchStatus(batchId: batchId, status: "completed") // Still mark batch as completed
                        }
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
        store.markBatchFailed(batchId: batchId, reason: reason)
    }

    private func updateBatchStatus(batchId: Int64, status: String) {
        store.updateBatchStatus(batchId: batchId, status: status)
    }

    // MARK: – Batching logic -------------------------------------------------

    private struct AnalysisBatch { let chunks: [RecordingChunk]; let start: Int; let end: Int }

    private func fetchUnprocessedChunks() -> [RecordingChunk] {
        let oldest = Int(Date().timeIntervalSince1970) - Int(maxLookback)
        return store.fetchUnprocessedChunks(olderThan: oldest)
    }

    // MARK: – Batching logic -----------------------------------------------------

private func createBatches(from chunks: [RecordingChunk]) -> [AnalysisBatch] {
    guard !chunks.isEmpty else { return [] }

    let ordered = chunks.sorted { $0.startTs < $1.startTs }
    let maxGap: TimeInterval        = 120             // ≤ 2 min between chunks
    let maxBatchDuration: TimeInterval = targetBatchDuration // 900 s (15 min)

    var batches: [AnalysisBatch] = []

    var bucket: [RecordingChunk]   = []
    var bucketDur: TimeInterval    = 0                // sum of 15‑s chunks

    for chunk in ordered {
        if bucket.isEmpty {
            bucket.append(chunk)
            bucketDur = chunk.duration                // first chunk → 15 s
            continue
        }

        let prev       = bucket.last!
        let gap        = TimeInterval(chunk.startTs - prev.endTs)
        let wouldBurst = bucketDur + chunk.duration > maxBatchDuration

        if gap > maxGap || wouldBurst {
            // close current batch
            batches.append(
                AnalysisBatch(chunks: bucket,
                              start: bucket.first!.startTs,
                              end:   bucket.last!.endTs)
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
                          start: bucket.first!.startTs,
                          end:   bucket.last!.endTs)
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
        return store.saveBatch(startTs: batch.start, endTs: batch.end, chunkIds: ids)
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
