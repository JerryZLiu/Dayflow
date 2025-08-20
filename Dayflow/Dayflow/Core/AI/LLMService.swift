//
//  LLMService.swift
//  Dayflow
//

import Foundation
import Combine
import AppKit
import AVFoundation
import SwiftUI
import GRDB

struct ProcessedBatchResult {
    let cards: [ActivityCard]
    let cardIds: [Int64]
}

protocol LLMServicing {
    func processBatch(_ batchId: Int64, completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void)
}

final class LLMService: LLMServicing {
    static let shared: LLMServicing = LLMService()
    
    private var providerType: LLMProviderType {
        // Read provider configuration from UserDefaults
        guard let savedData = UserDefaults.standard.data(forKey: "llmProviderType") else {
            // No saved provider type - default to Gemini
            return .geminiDirect
        }
        
        do {
            return try JSONDecoder().decode(LLMProviderType.self, from: savedData)
        } catch {
            // Failed to decode provider type - default to Gemini
            return .geminiDirect
        }
    }
    
    private var provider: LLMProvider? {
        switch providerType {
        case .geminiDirect:
            // Retrieve API key from Keychain
            guard let apiKey = KeychainManager.shared.retrieve(for: "gemini"),
                  !apiKey.isEmpty else { return nil }
            return GeminiDirectProvider(apiKey: apiKey)
            
        case .dayflowBackend(let endpoint):
            // Retrieve token from Keychain
            guard let token = KeychainManager.shared.retrieve(for: "dayflow"),
                  !token.isEmpty else { return nil }
            return DayflowBackendProvider(token: token, endpoint: endpoint)
            
        case .ollamaLocal(let endpoint):
            return OllamaProvider(endpoint: endpoint)
        }
    }
    
    // Keep the existing processBatch implementation for backward compatibility
    func processBatch(_ batchId: Int64, completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void) {
        guard let provider = provider else {
            completion(.failure(NSError(domain: "LLMService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No LLM provider configured. Please configure in settings."])))
            return
        }
        
        Task {
            do {
                // Get batch info from StorageManager
                let batches = StorageManager.shared.allBatches()
                guard let batchInfo = batches.first(where: { $0.0 == batchId }) else {
                    throw NSError(domain: "LLMService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Batch not found"])
                }
                
                let (_, batchStartTs, batchEndTs, _) = batchInfo
                
                // Mark batch as processing
                StorageManager.shared.updateBatch(batchId, status: "processing")
                
                // Get chunk file paths for this batch
                let chunkFiles = StorageManager.shared.getChunkFilesForBatch(batchId: batchId)
                
                guard !chunkFiles.isEmpty else {
                    throw NSError(domain: "LLMService", code: 3, userInfo: [NSLocalizedDescriptionKey: "No recordings in batch"])
                }
                
                // Combine all video files
                
                // Create a combined video for transcription
                let composition = AVMutableComposition()
                var compositionTime = CMTime.zero
                
                // Combining video chunks
                
                // Create a single video track for all chunks
                guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw NSError(domain: "LLMService", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
                }
                
                for (index, filePath) in chunkFiles.enumerated() {
                    let url = URL(fileURLWithPath: filePath)
                    
                    let asset = AVAsset(url: url)
                    let duration = try await asset.load(.duration)
                    let durationSeconds = CMTimeGetSeconds(duration)
                    
                    // Processing chunk
                    
                    if let track = try await asset.loadTracks(withMediaType: .video).first {
                        try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: compositionTime)
                    }
                    
                    compositionTime = CMTimeAdd(compositionTime, duration)
                }
                
                let totalDuration = CMTimeGetSeconds(compositionTime)
                // Total composition duration calculated
                
                // Export combined video to temporary file
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
                
                guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                    throw NSError(domain: "LLMService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create video exporter"])
                }
                
                exporter.outputURL = tempURL
                exporter.outputFileType = .mp4
                
                await exporter.export()
                
                guard exporter.status == .completed else {
                    throw NSError(domain: "LLMService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to export combined video"])
                }
                
                // Load video data
                let videoData = try Data(contentsOf: tempURL)
                let mimeType = "video/mp4"
                // Video exported successfully
                
                // Get batch start time for timestamp conversion
                let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))
                
                // Transcribe video
                let (observations, transcribeLog) = try await provider.transcribeVideo(
                    videoData: videoData,
                    mimeType: mimeType,
                    prompt: "Transcribe this video", // Provider will use its own prompt
                    batchStartTime: batchStartDate,
                    videoDuration: totalDuration
                )
                
                // Clean up temp file after transcription is complete
                try? FileManager.default.removeItem(at: tempURL)
                
                // Save observations to database
                StorageManager.shared.saveObservations(batchId: batchId, observations: observations)
                
                // Save transcription log as batch metadata
                if let logData = try? JSONEncoder().encode(transcribeLog),
                   let logString = String(data: logData, encoding: .utf8) {
                    StorageManager.shared.updateBatchMetadata(batchId, metadata: logString)
                }
                
                // If no observations, mark batch as complete with no activities
                guard !observations.isEmpty else {
                    StorageManager.shared.updateBatch(batchId, status: "analyzed")
                    completion(.success(ProcessedBatchResult(cards: [], cardIds: [])))
                    return
                }
                
                // SLIDING WINDOW CARD GENERATION - Replace old card generation with sliding window approach
                
                // Calculate time window (1 hour before current batch end time)
                let currentTime = Date(timeIntervalSince1970: TimeInterval(batchEndTs))
                let oneHourAgo = currentTime.addingTimeInterval(-3600) // 1 hour = 3600 seconds
                
                // Fetch all observations from the last hour (instead of just current batch)
                let recentObservations = StorageManager.shared.fetchObservationsByTimeRange(
                    from: oneHourAgo,
                    to: currentTime
                )
                
                // Fetch existing timeline cards that overlap with the last hour
                let existingTimelineCards = StorageManager.shared.fetchTimelineCardsByTimeRange(
                    from: oneHourAgo,
                    to: currentTime
                )
                
                // Convert TimelineCards to ActivityCards for context
                let existingActivityCards = existingTimelineCards.map { card in
                    ActivityCard(
                        startTime: card.startTimestamp,
                        endTime: card.endTimestamp,
                        category: card.category,
                        subcategory: card.subcategory,
                        title: card.title,
                        summary: card.summary,
                        detailedSummary: card.detailedSummary,
                        distractions: card.distractions
                    )
                }
                
                // Prepare context for activity generation
                let userTaxonomy = UserDefaults.standard.string(forKey: "userTaxonomy") ?? ""
                let extractedTaxonomy = UserDefaults.standard.string(forKey: "extractedTaxonomy") ?? ""
                
                let context = ActivityGenerationContext(
                    userTaxonomy: userTaxonomy,
                    extractedTaxonomy: extractedTaxonomy,
                    batchObservations: observations,
                    existingCards: existingActivityCards,
                    currentTime: currentTime
                )
                
                // Generate activity cards using sliding window observations
                let (cards, cardsLog) = try await provider.generateActivityCards(
                    observations: recentObservations,
                    context: context
                )
                
                // Replace old cards with new ones in the time range
                let (insertedCardIds, deletedVideoPaths) = StorageManager.shared.replaceTimelineCardsInRange(
                    from: oneHourAgo,
                    to: currentTime,
                    with: cards.map { card in
                        TimelineCardShell(
                            startTimestamp: card.startTime,
                            endTimestamp: card.endTime,
                            category: card.category,
                            subcategory: card.subcategory,
                            title: card.title,
                            summary: card.summary,
                            detailedSummary: card.detailedSummary,
                            distractions: card.distractions
                        )
                    },
                    batchId: batchId
                )
                
                // Clean up deleted video files
                for path in deletedVideoPaths {
                    let url = URL(fileURLWithPath: path)
                    do {
                        try FileManager.default.removeItem(at: url)
                        print("🗑️ Deleted timelapse: \(path)")
                    } catch {
                        print("❌ Failed to delete timelapse: \(path) - \(error)")
                    }
                }
                
                // Mark batch as complete
                StorageManager.shared.updateBatch(batchId, status: "analyzed")
                
                // Extract and save taxonomy
                let allHighlights = cards.flatMap { card in
                    // Extract key terms from summary and detailed summary
                    let words = (card.summary + " " + card.detailedSummary)
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { $0.count > 3 }
                    return words
                }
                
                let extractedTerms = Array(Set(allHighlights))
                    .prefix(50)
                    .joined(separator: ", ")
                
                if !extractedTerms.isEmpty {
                    UserDefaults.standard.set(extractedTerms, forKey: "extractedTaxonomy")
                }
                
                completion(.success(ProcessedBatchResult(cards: cards, cardIds: insertedCardIds)))
                
            } catch {
                print("Error processing batch: \(error)")
                
                // Mark batch as failed
                StorageManager.shared.updateBatch(batchId, status: "failed", reason: error.localizedDescription)
                
                completion(.failure(error))
            }
        }
    }
}

