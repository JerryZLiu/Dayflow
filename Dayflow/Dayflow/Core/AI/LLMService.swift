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
    let cards: [ActivityCardData]
    let cardIds: [Int64]
}

protocol LLMServicing {
    func processBatch(_ batchId: Int64, completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void)
    func generateText(prompt: String) async throws -> String
}

final class LLMService: LLMServicing {
    static let shared: LLMServicing = LLMService()
    
    private var providerType: LLMProviderType {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("\n🔍 [LLMService] Reading provider type at \(timestamp)")
        
        guard let savedData = UserDefaults.standard.data(forKey: "llmProviderType") else {
            print("⚠️ [LLMService] No saved provider type in UserDefaults - defaulting to Gemini")
            return .geminiDirect
        }
        
        print("✅ [LLMService] Found provider data in UserDefaults: \(savedData.count) bytes")
        
        do {
            let decoded = try JSONDecoder().decode(LLMProviderType.self, from: savedData)
            print("✅ [LLMService] Successfully decoded provider type: \(decoded)")
            
            return decoded
        } catch {
            print("❌ [LLMService] Failed to decode provider type: \(error)")
            print("   Raw data (hex): \(savedData.map { String(format: "%02x", $0) }.joined())")
            return .geminiDirect
        }
    }
    
    private var provider: LLMProvider? {
        let type = providerType
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("\n🏗️ [LLMService] Creating provider at \(timestamp)")
        print("   Provider type: \(type)")

        switch type {
        case .geminiDirect:
            return makeGeminiProvider()
        case .dayflowBackend(let endpoint):
            if let token = KeychainManager.shared.retrieve(for: "dayflow"), !token.isEmpty {
                return DayflowBackendProvider(token: token, endpoint: endpoint)
            } else {
                print("❌ [LLMService] Failed to retrieve Dayflow token from Keychain")
                return nil
            }

        case .ollamaLocal(let endpoint):
            return OllamaProvider(endpoint: endpoint)
        case .chatGPTClaude:
            let preferredTool = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "codex"
            let tool: ChatCLITool = (preferredTool == "claude") ? .claude : .codex
            return ChatCLIProvider(tool: tool)
        }
    }
    
    private func makeGeminiProvider() -> LLMProvider? {
        if let apiKey = KeychainManager.shared.retrieve(for: "gemini"), !apiKey.isEmpty {
            let preference = GeminiModelPreference.load()
            return GeminiDirectProvider(apiKey: apiKey, preference: preference)
        } else {
            print("❌ [LLMService] Failed to retrieve Gemini API key from Keychain")
            return nil
        }
    }

    private func providerName() -> String {
        switch providerType {
        case .geminiDirect: return "gemini"
        case .dayflowBackend: return "dayflow"
        case .ollamaLocal: return "ollama"
        case .chatGPTClaude: return "chat_cli"
        }
    }
    
    // Keep the existing processBatch implementation for backward compatibility
    func processBatch(_ batchId: Int64, completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void) {
        Task {
            // Get batch info first (outside do-catch so it's available in catch block)
            let batches = StorageManager.shared.allBatches()
            guard let batchInfo = batches.first(where: { $0.0 == batchId }) else {
                completion(.failure(NSError(domain: "LLMService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Batch not found"])))
                return
            }
            
            let (_, batchStartTs, batchEndTs, _) = batchInfo
            let processingStartTime = Date()

            do {
                print("\n📦 [LLMService] Processing batch \(batchId)")
                print("   Batch time: \(Date(timeIntervalSince1970: TimeInterval(batchStartTs))) to \(Date(timeIntervalSince1970: TimeInterval(batchEndTs)))")

                // Track analysis batch started
                await AnalyticsService.shared.capture("analysis_batch_started", [
                    "batch_id": batchId,
                    "total_duration_seconds": batchEndTs - batchStartTs,
                    "llm_provider": providerName()
                ])
                
                // Check provider inside the do block so errors go through catch
                guard let provider = provider else {
                    throw NSError(domain: "LLMService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No LLM provider configured. Please configure in settings."])
                }
                
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
                    
        
                    if let track = try await asset.loadTracks(withMediaType: .video).first {
                        try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: compositionTime)
                    }
                    
                    compositionTime = CMTimeAdd(compositionTime, duration)
                }
                
                let totalDuration = CMTimeGetSeconds(compositionTime)
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
                
                let videoData = try Data(contentsOf: tempURL)
                let mimeType = "video/mp4"
                // Get batch start time for timestamp conversion
                let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))
                
                let (observations, transcribeLog) = try await provider.transcribeVideo(
                    videoData: videoData,
                    mimeType: mimeType,
                    prompt: "Transcribe this video", // Provider will use its own prompt
                    batchStartTime: batchStartDate,
                    videoDuration: totalDuration,
                    batchId: batchId
                )
                
                // Clean up temp file after transcription is complete
                try? FileManager.default.removeItem(at: tempURL)
                
                StorageManager.shared.saveObservations(batchId: batchId, observations: observations)
                
                // If no observations, mark batch as complete with no activities
                guard !observations.isEmpty else {
                    print("⚠️ [LLMService] Transcription returned 0 observations for batch \(batchId)")
                    if let logOutput = transcribeLog.output, !logOutput.isEmpty {
                        print("   ↳ transcribeLog.output: \(logOutput)")
                    }
                    if let logInput = transcribeLog.input, !logInput.isEmpty {
                        print("   ↳ transcribeLog.input: \(logInput)")
                    }
                    await AnalyticsService.shared.capture("transcription_returned_empty", [
                        "batch_id": batchId,
                        "provider": providerName(),
                        "transcribe_latency_ms": Int((transcribeLog.latency ?? 0) * 1000)
                    ])
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

                print("[DEBUG] LLMService fetched \(recentObservations.count) observations")
                for (i, obs) in recentObservations.enumerated() {
                    print("  [\(i)] observation type: \(type(of: obs.observation))")
                    print("       observation: \(obs.observation)")
                }
                
                // Fetch existing timeline cards that overlap with the last hour
                let existingTimelineCards = StorageManager.shared.fetchTimelineCardsByTimeRange(
                    from: oneHourAgo,
                    to: currentTime
                )
                
                // Convert TimelineCards to ActivityCardData for context
                let existingActivityCards = existingTimelineCards.map { card in
                    ActivityCardData(
                        startTime: card.startTimestamp,
                        endTime: card.endTimestamp,
                        category: card.category,
                        subcategory: card.subcategory,
                        title: card.title,
                        summary: card.summary,
                        detailedSummary: card.detailedSummary,
                        distractions: card.distractions,
                        appSites: card.appSites
                    )
                }
                
                // Prepare context for activity generation
                let categories = CategoryStore.descriptorsForLLM()
                print("[DEBUG] LLMService loaded \(categories.count) categories")
                for (i, cat) in categories.enumerated() {
                    print("  [\(i)] name type: \(type(of: cat.name)), value: \(cat.name)")
                    print("       description type: \(type(of: cat.description)), value: \(cat.description ?? "nil")")
                }

                let context = ActivityGenerationContext(
                    batchObservations: observations,
                    existingCards: existingActivityCards,
                    currentTime: currentTime,
                    categories: categories
                )
                
                // Generate activity cards using sliding window observations
                let (cards, cardsLog) = try await provider.generateActivityCards(
                    observations: recentObservations,
                    context: context,
                    batchId: batchId
                )
                // Note: card generation log is not persisted per-batch yet
                
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
                            distractions: card.distractions,
                            appSites: card.appSites
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

                // Track analysis batch completed
                await AnalyticsService.shared.capture("analysis_batch_completed", [
                    "batch_id": batchId,
                    "cards_generated": cards.count,
                    "processing_duration_seconds": Int(Date().timeIntervalSince(processingStartTime)),
                    "llm_provider": providerName()
                ])

                completion(.success(ProcessedBatchResult(cards: cards, cardIds: insertedCardIds)))
                
            } catch {
                print("Error processing batch: \(error)")
                if let ns = error as NSError?, ns.domain == "GeminiError" {
                    print("🔎 GEMINI DEBUG: NSError.userInfo=\(ns.userInfo)")
                }

                // Track analysis batch failed
                await AnalyticsService.shared.capture("analysis_batch_failed", [
                    "batch_id": batchId,
                    "error_message": error.localizedDescription,
                    "processing_duration_seconds": Int(Date().timeIntervalSince(processingStartTime)),
                    "llm_provider": providerName()
                ])

                // Mark batch as failed
                StorageManager.shared.updateBatch(batchId, status: "failed", reason: error.localizedDescription)
                
                // Create an error card for the failed time period
                let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))
                let batchEndDate = Date(timeIntervalSince1970: TimeInterval(batchEndTs))
                
                let errorCard = createErrorCard(
                    batchId: batchId,
                    batchStartTime: batchStartDate,
                    batchEndTime: batchEndDate,
                    error: error
                )
                
                // Replace any existing cards in this time range with the error card
                // This matches the happy path behavior and prevents duplicates
                let (insertedCardIds, deletedVideoPaths) = StorageManager.shared.replaceTimelineCardsInRange(
                    from: batchStartDate,
                    to: batchEndDate,
                    with: [errorCard],
                    batchId: batchId
                )
                
                // Clean up any deleted video files (if there were existing cards)
                for path in deletedVideoPaths {
                    let url = URL(fileURLWithPath: path)
                    do {
                        try FileManager.default.removeItem(at: url)
                        print("🗑️ Deleted timelapse for replaced card: \(path)")
                    } catch {
                        print("❌ Failed to delete timelapse: \(path) - \(error)")
                    }
                }
                
                if !insertedCardIds.isEmpty {
                    print("✅ Created error card (ID: \(insertedCardIds.first ?? -1)) for failed batch \(batchId), replacing \(deletedVideoPaths.count) existing cards")
                }
                
                // Still return failure but with the error card created
                completion(.failure(error))
            }
        }
    }
    
    
    private func createErrorCard(batchId: Int64, batchStartTime: Date, batchEndTime: Date, error: Error) -> TimelineCardShell {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let startTimeStr = formatter.string(from: batchStartTime)
        let endTimeStr = formatter.string(from: batchEndTime)
        
        // Calculate duration in minutes
        let duration = Int(batchEndTime.timeIntervalSince(batchStartTime) / 60)
        
        // Get human-readable error message
        let humanError = getHumanReadableError(error)
        
        // Create the error card
        return TimelineCardShell(
            startTimestamp: startTimeStr,
            endTimestamp: endTimeStr,
            category: "System",
            subcategory: "Error",
            title: "Processing failed",
            summary: "Failed to process \(duration) minutes of recording from \(startTimeStr) to \(endTimeStr). \(humanError) Your recording is safe and can be reprocessed.",
            detailedSummary: "Error details: \(error.localizedDescription)\n\nThis recording batch (ID: \(batchId)) failed during AI processing. The original video files are preserved and can be reprocessed by retrying from Settings. Common causes include network issues, API rate limits, or temporary service outages.",
            distractions: nil,
            appSites: nil
        )
    }
    
    private func getHumanReadableError(_ error: Error) -> String {
        // First check if it's an NSError with a domain and code we recognize
        if let nsError = error as NSError? {
            // For HTTP errors, check if we have a specific error message in userInfo
            if nsError.domain == "GeminiError" && nsError.code >= 400 && nsError.code < 600 {
                // Check for specific known API error messages
                let errorMessage = nsError.localizedDescription.lowercased()
                if errorMessage.contains("api key not found") {
                    return "Invalid API key. Please check your Gemini API key in Settings."
                } else if errorMessage.contains("rate limit") || errorMessage.contains("quota") {
                    return "Rate limited. Too many requests to Gemini. Please wait a few minutes."
                } else if errorMessage.contains("unauthorized") {
                    return "Unauthorized. Your Gemini API key may be invalid or expired."
                } else if errorMessage.contains("timeout") {
                    return "Request timed out. The video may be too large or the connection is slow."
                }
                // Fall through to switch statement for generic HTTP error messages
            }

            // Check specific error domains and codes
            switch nsError.domain {
            case "LLMService":
                switch nsError.code {
                case 1: return "No AI provider is configured. Please set one up in Settings."
                case 2: return "The recording batch couldn't be found."
                case 3: return "No video recordings found in this time period."
                case 4: return "Failed to create the video for processing."
                case 5: return "Failed to combine video chunks."
                case 6: return "Failed to prepare video for processing."
                default: break
                }
                
            case "GeminiError", "GeminiProvider":
                switch nsError.code {
                case 1: return "Failed to upload the video to Gemini."
                case 2: return "Gemini took too long to process the video."
                case 3, 5: return "Failed to parse Gemini's response."
                case 4: return "Failed to start video upload to Gemini."
                case 6: return "Invalid video file."
                case 7, 9: return "Gemini returned an unexpected response format."
                case 8, 10: return "Failed to connect to Gemini after multiple attempts."
                case 100: return "The AI generated timestamps beyond the video duration."
                case 101: return "The AI couldn't identify any activities in the video."
                // HTTP status codes
                case 400: return "Invalid API key. Please check your Gemini API key in Settings."
                case 401: return "Unauthorized. Your Gemini API key may be invalid or expired."
                case 403: return "Access forbidden. Check your Gemini API permissions."
                case 429: return "Rate limited. Too many requests to Gemini. Please wait a few minutes."
                case 503: return "Google's Gemini servers returned a 503 error. Google's AI services may be temporarily down. If you see many of these in a row, please wait at least a few hours before retrying. Check the [Google AI Studio status](https://aistudio.google.com/status) page for updates."
                case 500...599: return "Gemini service error. The service may be temporarily down."
                default:
                    // For other HTTP errors, provide context
                    if nsError.code >= 400 && nsError.code < 600 {
                        return "Gemini returned HTTP error \(nsError.code). Check your API settings."
                    }
                    break
                }
                
            case "OllamaProvider":
                switch nsError.code {
                case 1: return "Invalid video duration."
                case 2: return "Failed to process video frame."
                case 4: return "Failed to connect to local AI model."
                case 8, 9, 10: return "The local AI returned an unexpected response."
                case 11: return "The local AI couldn't identify any activities."
                case 12: return "The local AI didn't analyze enough of the video."
                case 13: return "The local AI generated too many segments."
                default: break
                }
                
            case "AnalysisManager":
                switch nsError.code {
                case 1: return "The analysis system was interrupted."
                case 2: return "Failed to reprocess some recordings."
                case 3: return "Couldn't find the recording information."
                default: break
                }
                
            default:
                break
            }
        }
        
        // Fallback to checking the error description for common patterns
        let errorDescription = error.localizedDescription.lowercased()
        
        switch true {
        case errorDescription.contains("rate limit") || errorDescription.contains("429"):
            return "The AI service is temporarily overwhelmed. This usually resolves itself in a few minutes."
            
        case errorDescription.contains("network") || errorDescription.contains("connection"):
            return "Couldn't connect to the AI service. Check your internet connection."
            
        case errorDescription.contains("api key") || errorDescription.contains("unauthorized") || errorDescription.contains("401"):
            return "There's an issue with your API key. Please check your settings."
            
        case errorDescription.contains("503"):
            return "Google's Gemini servers returned a 503 error. Google's AI services may be temporarily down. If you see many of these in a row, please wait at least a few hours before retrying. Check the [Google AI Studio status](https://aistudio.google.com/status) page for updates."
            
        case errorDescription.contains("timeout"):
            return "The AI took too long to respond. This might be due to a long recording or slow connection."
            
        case errorDescription.contains("no observations"):
            return "The AI couldn't understand what was happening in this recording."
            
        case errorDescription.contains("exceed") || errorDescription.contains("duration"):
            return "The AI got confused about the video timing."
            
        case errorDescription.contains("no llm provider") || errorDescription.contains("not configured"):
            return "No AI provider is configured. Please set one up in Settings."
            
        case errorDescription.contains("failed to upload"):
            return "Failed to upload the video for processing."
            
        case errorDescription.contains("invalid response") || errorDescription.contains("json"):
            return "The AI returned an unexpected response format."
            
        case errorDescription.contains("failed after") && errorDescription.contains("attempts"):
            return "Couldn't connect to the AI service after multiple attempts."
            
        default:
            // For unknown errors, keep it simple
            return "An unexpected error occurred."
        }
    }

    // MARK: - Text Generation

    func generateText(prompt: String) async throws -> String {
        guard let provider = provider else {
            throw NSError(domain: "LLMService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No LLM provider configured. Please configure in settings."])
        }

        let (text, _) = try await provider.generateText(prompt: prompt)
        return text
    }
}
