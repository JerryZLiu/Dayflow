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
import AVFoundation
import GRDB

// MARK: – Public protocol ---------------------------------------------------

protocol AnalysisManaging {
    func startAnalysisJob()
    func stopAnalysisJob()
    func triggerAnalysisNow()
    func reprocessDay(_ day: String, progressHandler: @escaping (String) -> Void, completion: @escaping (Result<Void, Error>) -> Void)
    func reprocessSpecificBatches(_ batchIds: [Int64], progressHandler: @escaping (String) -> Void, completion: @escaping (Result<Void, Error>) -> Void)
}

// MARK: – Manager -----------------------------------------------------------

final class AnalysisManager: AnalysisManaging {
    static let shared = AnalysisManager()
    private let videoProcessingService: VideoProcessingService
    
    private init() {
        store = StorageManager.shared
        llmService = LLMService.shared
        videoProcessingService = VideoProcessingService()
    }

    // MARK: – Private state
    private let store: any StorageManaging
    private let llmService: any LLMServicing
    
    // Video Processing Constants - removed old summary generation

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
    
    func reprocessDay(_ day: String, progressHandler: @escaping (String) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { 
                completion(.failure(NSError(domain: "AnalysisManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])))
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
            DispatchQueue.main.async { progressHandler("Deleted observations for \(batchIds.count) batches") }
            
            // 5. Reset batch statuses to pending
            let resetBatchIds = self.store.resetBatchStatuses(forDay: day)
            DispatchQueue.main.async { progressHandler("Reset \(resetBatchIds.count) batches to pending status") }
            
            // 6. Process each batch sequentially
            var processedCount = 0
            var hasError = false
            
            for (index, batchId) in batchIds.enumerated() {
                if hasError { break }
                
                let batchStartTime = Date()
                let elapsedTotal = Date().timeIntervalSince(overallStartTime)
                
                DispatchQueue.main.async { 
                    progressHandler("Processing batch \(index + 1) of \(batchIds.count)... (Total elapsed: \(self.formatDuration(elapsedTotal)))")
                }
                
                // Use a semaphore to wait for each batch to complete
                let semaphore = DispatchSemaphore(value: 0)
                
                self.queueGeminiRequest(batchId: batchId)
                
                // Wait for batch to complete (check status periodically)
                var isCompleted = false
                while !isCompleted && !hasError {
                    Thread.sleep(forTimeInterval: 2.0) // Check every 2 seconds
                    
                    let currentBatches = self.store.fetchBatches(forDay: day)
                    if let batch = currentBatches.first(where: { $0.id == batchId }) {
                        switch batch.status {
                        case "completed", "analyzed":
                            isCompleted = true
                            processedCount += 1
                            let batchDuration = Date().timeIntervalSince(batchStartTime)
                            batchTimings.append((batchId: batchId, duration: batchDuration))
                            DispatchQueue.main.async {
                                progressHandler("✓ Batch \(index + 1) completed in \(self.formatDuration(batchDuration))")
                            }
                        case "failed", "failed_empty", "skipped_short":
                            // These are acceptable end states
                            isCompleted = true
                            processedCount += 1
                            let batchDuration = Date().timeIntervalSince(batchStartTime)
                            batchTimings.append((batchId: batchId, duration: batchDuration))
                            DispatchQueue.main.async {
                                progressHandler("⚠️ Batch \(index + 1) ended with status '\(batch.status)' after \(self.formatDuration(batchDuration))")
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
                
                if hasError {
                    completion(.failure(NSError(domain: "AnalysisManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to reprocess some batches"])))
                } else {
                    completion(.success(()))
                }
            }
        }
    }
    
    func reprocessSpecificBatches(_ batchIds: [Int64], progressHandler: @escaping (String) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { 
                completion(.failure(NSError(domain: "AnalysisManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])))
                return 
            }
            
            let overallStartTime = Date()
            var batchTimings: [(batchId: Int64, duration: TimeInterval)] = []
            
            DispatchQueue.main.async { progressHandler("Preparing to reprocess \(batchIds.count) selected batches...") }
            
            // Delete all timeline cards for the day (since they can be merged across batches)
            DispatchQueue.main.async { progressHandler("Deleting existing timeline cards for the day...") }
            
            // Get the day string from the first batch
            let allBatches = self.store.allBatches()
            guard let firstBatch = allBatches.first(where: { batchIds.contains($0.id) }) else {
                completion(.failure(NSError(domain: "AnalysisManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not find batch information"])))
                return
            }
            
            // Convert timestamp to day string
            let date = Date(timeIntervalSince1970: TimeInterval(firstBatch.start))
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: date)
            let logicalDate = hour < 4 ? calendar.date(byAdding: .day, value: -1, to: date) ?? date : date
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dayString = formatter.string(from: logicalDate)
            
            let videoPaths = self.store.deleteTimelineCards(forDay: dayString)
            
            // Delete observations
            self.store.deleteObservations(forBatchIds: batchIds)
            
            // Delete video files
            for path in videoPaths {
                if let url = URL(string: path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            
            // Reset batch statuses
            
            DispatchQueue.main.async { progressHandler("Processing \(batchIds.count) batches...") }
            
            // Process batches
            var processedCount = 0
            var hasError = false
            
            for (index, batchId) in batchIds.enumerated() {
                if hasError { break }
                
                let batchStartTime = Date()
                let elapsedTotal = Date().timeIntervalSince(overallStartTime)
                
                DispatchQueue.main.async { 
                    progressHandler("Processing batch \(index + 1) of \(batchIds.count)... (Total elapsed: \(self.formatDuration(elapsedTotal)))")
                }
                
                self.queueGeminiRequest(batchId: batchId)
                
                // Wait for batch to complete (check status periodically)
                var isCompleted = false
                while !isCompleted && !hasError {
                    Thread.sleep(forTimeInterval: 2.0) // Check every 2 seconds
                    
                    let allBatches = self.store.allBatches()
                    if let batch = allBatches.first(where: { $0.id == batchId }) {
                        switch batch.status {
                        case "completed", "analyzed":
                            isCompleted = true
                            processedCount += 1
                            let batchDuration = Date().timeIntervalSince(batchStartTime)
                            batchTimings.append((batchId: batchId, duration: batchDuration))
                            DispatchQueue.main.async {
                                progressHandler("✓ Batch \(index + 1) completed in \(self.formatDuration(batchDuration))")
                            }
                        case "failed", "failed_empty", "skipped_short":
                            // These are acceptable end states
                            isCompleted = true
                            processedCount += 1
                            let batchDuration = Date().timeIntervalSince(batchStartTime)
                            batchTimings.append((batchId: batchId, duration: batchDuration))
                            DispatchQueue.main.async {
                                progressHandler("⚠️ Batch \(index + 1) ended with status '\(batch.status)' after \(self.formatDuration(batchDuration))")
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
            let avgDuration = batchTimings.isEmpty ? 0 : batchTimings.reduce(0) { $0 + $1.duration } / Double(batchTimings.count)
            
            DispatchQueue.main.async {
                progressHandler("""
                ✅ Reprocessing complete!
                • Processed: \(processedCount) of \(batchIds.count) batches
                • Total time: \(self.formatDuration(totalDuration))
                • Average time per batch: \(self.formatDuration(avgDuration))
                """)
            }
            
            completion(.success(()))
        }
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
        // 4. Fire LLM for each batch
        for id in batchIDs { queueGeminiRequest(batchId: id) }
    }

    // MARK: – LLM kick‑off ----------------------------------------------

    private func queueGeminiRequest(batchId: Int64) {
        let chunksInBatch = StorageManager.shared.chunksForBatch(batchId)

        if chunksInBatch.isEmpty {
            print("Warning: Batch \(batchId) has no chunks. Marking as 'failed_empty'.")
            self.updateBatchStatus(batchId: batchId, status: "failed_empty")
            return
        }

        let totalVideoDurationSeconds = chunksInBatch.reduce(0.0) { acc, chunk -> TimeInterval in
            let duration = TimeInterval(chunk.endTs - chunk.startTs)
            return acc + duration
        }

        let minimumDurationSeconds: TimeInterval = 300.0 // 5 minutes

        if totalVideoDurationSeconds < minimumDurationSeconds {
            print("Batch \(batchId) duration (\(totalVideoDurationSeconds)s) is less than \(minimumDurationSeconds)s. Marking as 'skipped_short'.")
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

        llmService.processBatch(batchId) { [weak self] (result: Result<ProcessedBatchResult, Error>) in
            guard let self else { return }

            let now = Date()
            let currentDayInfo = now.getDayInfoFor4AMBoundary()
            let currentLogicalDayString = currentDayInfo.dayString
            print("Processing batch \(batchId) for logical day: \(currentLogicalDayString)")

            switch result {
            case .success(let processedResult):
                let activityCards = processedResult.cards
                let cardIds = processedResult.cardIds
                print("LLM succeeded for Batch \(batchId). Processing \(activityCards.count) activity cards for day \(currentLogicalDayString).")
                
                // Debug: Check for duplicate cards from LLM
                print("\n🔍 DEBUG: Checking for duplicate cards from LLM:")
                for (i, card1) in activityCards.enumerated() {
                    for (j, card2) in activityCards.enumerated() where j > i {
                        if card1.startTime == card2.startTime && card1.endTime == card2.endTime && card1.title == card2.title {
                            print("⚠️ DEBUG: Found duplicate cards at indices \(i) and \(j): '\(card1.title)' [\(card1.startTime) - \(card1.endTime)]")
                        }
                    }
                }
                print("✅ DEBUG: Duplicate check complete\n")
                
                guard let firstChunk = chunksInBatch.first else {
                    print("Error: No chunks found for batch \(batchId) during timestamp conversion")
                    self.markBatchFailed(batchId: batchId, reason: "No chunks found for timestamp conversion")
                    return
                }
                let firstChunkStartDate = Date(timeIntervalSince1970: TimeInterval(firstChunk.startTs))
                print("First chunk starts at real time: \(firstChunkStartDate)")

                // Mark batch as completed immediately
                self.updateBatchStatus(batchId: batchId, status: "completed")
                
                // Generate timelapses asynchronously for each timeline card
                Task { @MainActor in
                    for (index, cardId) in cardIds.enumerated() {
                        guard index < activityCards.count else { continue }
                        
                        // Fetch the saved timeline card to get Unix timestamps
                        guard let timelineCard = self.store.fetchTimelineCard(byId: cardId) else {
                            print("Warning: Could not fetch timeline card \(cardId)")
                            continue
                        }
                        
                        // Fetch chunks that overlap with this card's time range using Unix timestamps
                        let chunks = self.store.fetchChunksInTimeRange(
                            startTs: timelineCard.startTs,
                            endTs: timelineCard.endTs
                        )
                        
                        if chunks.isEmpty {
                            print("No chunks found for timeline card \(cardId) [\(timelineCard.startTimestamp) - \(timelineCard.endTimestamp)]")
                            continue
                        }
                        
                        do {
                            print("Generating timelapse for card \(cardId): '\(timelineCard.title)' [\(timelineCard.startTimestamp) - \(timelineCard.endTimestamp)]")
                            print("  Found \(chunks.count) chunks in time range")
                            
                            // Convert chunks to URLs
                            let chunkURLs = chunks.compactMap { URL(fileURLWithPath: $0.fileUrl) }
                            
                            // Stitch chunks together
                            let stitchedVideo = try await self.videoProcessingService.prepareVideoForProcessing(urls: chunkURLs)
                            print("  Stitched video prepared at: \(stitchedVideo.path)")
                            
                            // Generate timelapse
                            let timelapseURL = await self.videoProcessingService.generatePersistentTimelapseURL(
                                for: Date(timeIntervalSince1970: TimeInterval(timelineCard.startTs)),
                                originalFileName: String(cardId)
                            )
                            
                            try await self.videoProcessingService.generateTimelapse(
                                sourceVideoURL: stitchedVideo,
                                outputTimelapseFileURL: timelapseURL,
                                speedupFactor: 20,  // 20x as requested
                                outputFPS: 24
                            )
                            
                            // Update timeline card with timelapse URL
                            self.store.updateTimelineCardVideoURL(cardId: cardId, videoSummaryURL: timelapseURL.path)
                            print("✅ Generated timelapse for card \(cardId): \(timelapseURL.path)")
                            
                            // Cleanup temp file
                            await self.videoProcessingService.cleanupTemporaryFile(at: stitchedVideo)
                        } catch {
                            print("❌ Error generating timelapse for card \(cardId): \(error)")
                        }
                    }
                    print("✅ Timelapse generation complete for batch \(batchId)")
                }

            case .failure(let err):
                print("LLM failed for Batch \(batchId). Day \(currentLogicalDayString) may have been cleared. Error: \(err.localizedDescription)")
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
    
    // Parses a clock time like "11:37 AM" to a Date
    private func parseClockTime(_ timeString: String, baseDate: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        guard let time = formatter.date(from: timeString) else { return nil }
        
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
        
        return calendar.date(bySettingHour: timeComponents.hour ?? 0,
                           minute: timeComponents.minute ?? 0,
                           second: 0,
                           of: baseDate)
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
