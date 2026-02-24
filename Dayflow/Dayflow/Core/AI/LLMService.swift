//
//  LLMService.swift
//  Dayflow
//

import Foundation
import Combine
import AppKit
import SwiftUI
import GRDB

struct ProcessedBatchResult {
    let cards: [ActivityCardData]
    let cardIds: [Int64]
}

enum LLMProcessingStep: Sendable, Equatable {
    case transcribing
    case generatingCards
}

protocol LLMServicing {
    func processBatch(_ batchId: Int64, progressHandler: ((LLMProcessingStep) -> Void)?, completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void)
    func generateText(prompt: String) async throws -> String
    func generateTextStreaming(prompt: String) -> AsyncThrowingStream<String, Error>
    /// Rich chat streaming with thinking, tool calls, and text events (ChatCLI only)
    /// - Parameter sessionId: Optional session ID to resume a previous conversation
    func generateChatStreaming(prompt: String, sessionId: String?) -> AsyncThrowingStream<ChatStreamEvent, Error>
    var batchingConfig: BatchingConfig { get }
}

final class LLMService: LLMServicing {
    static let shared: LLMServicing = LLMService()
    
    private struct BatchProviderActions {
        let transcribeScreenshots: ([Screenshot], Date, Int64?) async throws -> (observations: [Observation], log: LLMCall)
        let generateActivityCards: ([Observation], ActivityGenerationContext, Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall)
    }

    private struct TextProviderActions {
        let generateText: (String) async throws -> (text: String, log: LLMCall)
        let generateTextStreaming: ((String) -> AsyncThrowingStream<String, Error>)?
    }

    private struct TimelineProviderContext {
        let id: LLMProviderID
        let providerLabel: String
        let actions: BatchProviderActions
        let fallbackState: GemmaFallbackState?
    }

    private struct ConfiguredBackupProvider {
        let id: LLMProviderID
        let chatToolOverride: ChatCLITool?
    }

    private var providerType: LLMProviderType {
        LLMProviderType.load()
    }
    
    private func makeGeminiProvider() -> GeminiDirectProvider? {
        if let apiKey = KeychainManager.shared.retrieve(for: "gemini"), !apiKey.isEmpty {
            let preference = GeminiModelPreference.load()
            return GeminiDirectProvider(apiKey: apiKey, preference: preference)
        } else {
            print("❌ [LLMService] Failed to retrieve Gemini API key from Keychain")
            return nil
        }
    }

    private func makeGemmaBackupProvider() -> GemmaBackupProvider? {
        if let apiKey = KeychainManager.shared.retrieve(for: "gemini"), !apiKey.isEmpty {
            return GemmaBackupProvider(apiKey: apiKey)
        }
        print("❌ [LLMService] Failed to retrieve Gemini API key for Gemma fallback")
        return nil
    }

    private func makeDayflowProvider(endpoint: String) -> DayflowBackendProvider? {
        if let token = KeychainManager.shared.retrieve(for: "dayflow"), !token.isEmpty {
            return DayflowBackendProvider(token: token, endpoint: endpoint)
        }
        print("❌ [LLMService] Failed to retrieve Dayflow token from Keychain")
        return nil
    }

    private func makeOllamaProvider(endpoint: String) -> OllamaProvider {
        OllamaProvider(endpoint: endpoint)
    }

    private func makeDoubaoProvider(endpoint: String, modelId: String) -> DoubaoArkProvider? {
        if let apiKey = KeychainManager.shared.retrieve(for: "doubao"), !apiKey.isEmpty {
            return DoubaoArkProvider(apiKey: apiKey, endpoint: endpoint, modelId: modelId)
        }
        print("❌ [LLMService] Failed to retrieve Doubao API key from Keychain")
        return nil
    }

    private func makeChatCLIProvider(preferredToolOverride: ChatCLITool? = nil) -> ChatCLIProvider {
        let tool: ChatCLITool
        if let preferredToolOverride {
            tool = preferredToolOverride
        } else {
            let preferredTool = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "codex"
            tool = (preferredTool == "claude") ? .claude : .codex
        }
        return ChatCLIProvider(tool: tool)
    }

    private func resolvedChatCLITool(for providerID: LLMProviderID, override: ChatCLITool? = nil) -> ChatCLITool? {
        guard providerID == .chatGPTClaude else { return nil }
        if let override {
            return override
        }
        let preferredTool = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "codex"
        return preferredTool == "claude" ? .claude : .codex
    }

    private func providerLabel(for providerID: LLMProviderID, chatToolOverride: ChatCLITool? = nil) -> String {
        providerID.providerLabel(chatTool: resolvedChatCLITool(for: providerID, override: chatToolOverride))
    }

    private func noProviderError() -> NSError {
        NSError(
            domain: "LLMService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No LLM provider configured. Please configure in settings."]
        )
    }

    private func makeBatchProvider(
        for providerID: LLMProviderID,
        chatToolOverride: ChatCLITool? = nil
    ) throws -> (actions: BatchProviderActions, fallbackState: GemmaFallbackState?) {
        switch providerID {
        case .gemini:
            guard let provider = makeGeminiProvider() else { throw noProviderError() }
            let gemmaProvider = makeGemmaBackupProvider()
            let fallbackState = GemmaFallbackState()

            return (actions: BatchProviderActions(
                transcribeScreenshots: { [weak self] screenshots, batchStartTime, batchId in
                    if fallbackState.preferGemma, let gemmaProvider {
                        return try await gemmaProvider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
                    }

                    do {
                        return try await provider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
                    } catch {
                        guard let gemmaProvider else { throw error }
                        fallbackState.preferGemma = true
                        self?.logGemmaFallback(operation: "transcribe", error: error, batchId: batchId)
                        return try await gemmaProvider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
                    }
                },
                generateActivityCards: { [weak self] observations, context, batchId in
                    if fallbackState.preferGemma, let gemmaProvider {
                        fallbackState.usedGemmaForCardGeneration = true
                        return try await gemmaProvider.generateActivityCards(observations: observations, context: context, batchId: batchId)
                    }

                    do {
                        return try await provider.generateActivityCards(observations: observations, context: context, batchId: batchId)
                    } catch {
                        guard let gemmaProvider else { throw error }
                        fallbackState.preferGemma = true
                        fallbackState.usedGemmaForCardGeneration = true
                        self?.logGemmaFallback(operation: "generate_cards", error: error, batchId: batchId)
                        return try await gemmaProvider.generateActivityCards(observations: observations, context: context, batchId: batchId)
                    }
                }
            ), fallbackState: fallbackState)
        case .dayflow:
            let endpoint: String
            if case .dayflowBackend(let savedEndpoint) = providerType {
                endpoint = savedEndpoint
            } else {
                endpoint = "https://api.dayflow.app"
            }
            guard let provider = makeDayflowProvider(endpoint: endpoint) else { throw noProviderError() }
            return (actions: BatchProviderActions(
                transcribeScreenshots: provider.transcribeScreenshots,
                generateActivityCards: provider.generateActivityCards
            ), fallbackState: nil)
        case .ollama:
            let endpoint = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "http://localhost:11434"
            let provider = makeOllamaProvider(endpoint: endpoint)
            return (actions: BatchProviderActions(
                transcribeScreenshots: provider.transcribeScreenshots,
                generateActivityCards: provider.generateActivityCards
            ), fallbackState: nil)
        case .chatGPTClaude:
            let provider = makeChatCLIProvider(preferredToolOverride: chatToolOverride)
            return (actions: BatchProviderActions(
                transcribeScreenshots: provider.transcribeScreenshots,
                generateActivityCards: provider.generateActivityCards
            ), fallbackState: nil)

        case .doubao:
            let endpoint: String
            if case .doubaoArk(let savedEndpoint) = providerType {
                endpoint = savedEndpoint
            } else {
                endpoint = DoubaoPreferences.defaultBaseURL
            }

            let modelId = (UserDefaults.standard.string(forKey: DoubaoPreferences.modelIdDefaultsKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModelId = modelId.isEmpty ? DoubaoPreferences.defaultModelId : modelId

            guard let provider = makeDoubaoProvider(endpoint: endpoint, modelId: resolvedModelId) else {
                throw noProviderError()
            }
            return (actions: BatchProviderActions(
                transcribeScreenshots: provider.transcribeScreenshots,
                generateActivityCards: provider.generateActivityCards
            ), fallbackState: nil)
        }
    }

    private func makeTimelineProviderContext(
        for providerID: LLMProviderID,
        chatToolOverride: ChatCLITool? = nil
    ) throws -> TimelineProviderContext {
        let providerBundle = try makeBatchProvider(for: providerID, chatToolOverride: chatToolOverride)
        return TimelineProviderContext(
            id: providerID,
            providerLabel: providerLabel(for: providerID, chatToolOverride: chatToolOverride),
            actions: providerBundle.actions,
            fallbackState: providerBundle.fallbackState
        )
    }

    private func configuredBackupProvider(primaryProviderID: LLMProviderID) -> ConfiguredBackupProvider? {
        guard let backupProvider = LLMProviderRoutingPreferences.loadBackupProvider(),
              backupProvider != primaryProviderID else {
            return nil
        }

        // Dayflow backend isn't currently supported in provider settings.
        if backupProvider == .dayflow {
            return nil
        }

        let chatToolOverride: ChatCLITool?
        if backupProvider == .chatGPTClaude {
            chatToolOverride = LLMProviderRoutingPreferences.loadBackupChatCLITool()
        } else {
            chatToolOverride = nil
        }

        return ConfiguredBackupProvider(id: backupProvider, chatToolOverride: chatToolOverride)
    }

    private final class GemmaFallbackState {
        var preferGemma = false
        var usedGemmaForCardGeneration = false
    }

    private func logGemmaFallback(operation: String, error: Error, batchId: Int64?) {
        let nsError = error as NSError
        AnalyticsService.shared.capture("llm_fallback_used", [
            "provider": "gemini",
            "provider_label": "gemini",
            "fallback_provider": "gemma",
            "fallback_provider_label": "gemma",
            "operation": operation,
            "error_domain": nsError.domain,
            "error_code": nsError.code,
            "error_message": nsError.localizedDescription,
            "batch_id": batchId as Any
        ])
    }

    private func fallbackProps(
        operation: String,
        batchId: Int64?,
        primaryProvider: String,
        primaryProviderLabel: String,
        backupProvider: String,
        backupProviderLabel: String,
        error: Error
    ) -> [String: Any] {
        let nsError = error as NSError
        return [
            "operation": operation,
            "batch_id": batchId as Any,
            "primary_provider": primaryProvider,
            "primary_provider_label": primaryProviderLabel,
            "backup_provider": backupProvider,
            "backup_provider_label": backupProviderLabel,
            "error_domain": nsError.domain,
            "error_code": nsError.code,
            "error_message": nsError.localizedDescription
        ]
    }

    private func executeWithProviderBackup<T>(
        operation: String,
        batchId: Int64?,
        primaryContext: TimelineProviderContext,
        activeContext: TimelineProviderContext,
        backupContext: TimelineProviderContext?,
        work: (TimelineProviderContext) async throws -> T
    ) async throws -> (value: T, activeContext: TimelineProviderContext, usedProviderBackup: Bool) {
        do {
            let value = try await work(activeContext)
            let usingBackup = activeContext.id != primaryContext.id
            return (value, activeContext, usingBackup)
        } catch {
            guard activeContext.id == primaryContext.id, let backupContext else {
                throw error
            }

            let attemptProps = fallbackProps(
                operation: operation,
                batchId: batchId,
                primaryProvider: primaryContext.id.analyticsName,
                primaryProviderLabel: primaryContext.providerLabel,
                backupProvider: backupContext.id.analyticsName,
                backupProviderLabel: backupContext.providerLabel,
                error: error
            )
            AnalyticsService.shared.capture("llm_timeline_fallback_attempted", attemptProps)

            do {
                let value = try await work(backupContext)
                AnalyticsService.shared.capture("llm_timeline_fallback_succeeded", attemptProps)
                return (value, backupContext, true)
            } catch {
                var failureProps = attemptProps
                let backupError = error as NSError
                failureProps["backup_error_domain"] = backupError.domain
                failureProps["backup_error_code"] = backupError.code
                failureProps["backup_error_message"] = backupError.localizedDescription
                AnalyticsService.shared.capture("llm_timeline_fallback_failed", failureProps)
                throw error
            }
        }
    }

    private func operationName(for step: LLMProcessingStep?) -> String {
        switch step {
        case .transcribing:
            return "transcribe"
        case .generatingCards:
            return "generate_cards"
        case .none:
            return "unknown"
        }
    }

    private func isRateLimitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "GeminiError" || nsError.domain == "GeminiProvider" {
            if nsError.code == 429 || nsError.code == 403 {
                return true
            }
            let message = nsError.localizedDescription.lowercased()
            if message.contains("quota") || message.contains("rate limit") || message.contains("too many requests") {
                return true
            }
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("rate limit") ||
            message.contains("too many requests") ||
            message.contains("quota exceeded") ||
            message.contains("quota") ||
            message.contains("you've hit your limit") {
            return true
        }

        return false
    }

    private func buildFailureToastMessage(
        operation: LLMProcessingStep?,
        error: Error,
        backupConfigured: Bool
    ) -> String {
        let rateLimited = isRateLimitError(error)

        if rateLimited && !backupConfigured {
            return "Dayflow hit a rate limit and no backup provider is configured. Add a backup in Settings > Providers to avoid interruptions."
        }

        switch operation {
        case .transcribing:
            return "Dayflow couldn't transcribe this batch. Check Settings > Providers and configure a backup provider."
        case .generatingCards:
            return "Dayflow couldn't generate timeline cards for this batch. Check Settings > Providers and configure a backup provider."
        case .none:
            return "Dayflow couldn't finish this batch. Check Settings > Providers and configure a backup provider."
        }
    }

    private func emitTimelineFailureToast(
        operation: LLMProcessingStep?,
        error: Error,
        primaryProvider: String,
        primaryProviderLabel: String,
        backupProvider: String?,
        backupProviderLabel: String?,
        backupConfigured: Bool,
        batchId: Int64?
    ) {
        let nsError = error as NSError
        let rateLimited = isRateLimitError(error)
        let payload = TimelineFailureToastPayload(
            message: buildFailureToastMessage(operation: operation, error: error, backupConfigured: backupConfigured),
            operation: operationName(for: operation),
            primaryProvider: primaryProvider,
            primaryProviderLabel: primaryProviderLabel,
            backupProvider: backupProvider,
            backupProviderLabel: backupProviderLabel,
            backupConfigured: backupConfigured,
            rateLimitDetected: rateLimited,
            errorDomain: nsError.domain,
            errorCode: nsError.code,
            batchId: batchId
        )
        AnalyticsService.shared.capture("llm_timeline_failure_toast_shown", payload.analyticsProps)
        TimelineFailureToastCenter.post(payload)
    }

    private func makeTextProvider() throws -> TextProviderActions {
        switch providerType {
        case .geminiDirect:
            guard let provider = makeGeminiProvider() else { throw noProviderError() }
            return TextProviderActions(
                generateText: provider.generateText,
                generateTextStreaming: nil
            )
        case .dayflowBackend(let endpoint):
            guard let provider = makeDayflowProvider(endpoint: endpoint) else { throw noProviderError() }
            return TextProviderActions(
                generateText: provider.generateText,
                generateTextStreaming: nil
            )
        case .ollamaLocal(let endpoint):
            let provider = makeOllamaProvider(endpoint: endpoint)
            return TextProviderActions(
                generateText: provider.generateText,
                generateTextStreaming: nil
            )
        case .chatGPTClaude:
            let provider = makeChatCLIProvider()
            return TextProviderActions(
                generateText: provider.generateText,
                generateTextStreaming: provider.generateTextStreaming
            )

        case .doubaoArk(let endpoint):
            let modelId = (UserDefaults.standard.string(forKey: DoubaoPreferences.modelIdDefaultsKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModelId = modelId.isEmpty ? DoubaoPreferences.defaultModelId : modelId
            guard let provider = makeDoubaoProvider(endpoint: endpoint, modelId: resolvedModelId) else { throw noProviderError() }
            return TextProviderActions(
                generateText: provider.generateText,
                generateTextStreaming: nil
            )
        }
    }

    private func makeFallbackTextStream(_ work: @escaping () async throws -> String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let text = try await work()
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func makeErrorStream(_ error: Error) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    var batchingConfig: BatchingConfig {
        .standard
    }
    
    // Keep the existing processBatch implementation for backward compatibility
    func processBatch(_ batchId: Int64, progressHandler: ((LLMProcessingStep) -> Void)? = nil, completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void) {
        Task {
            // Get batch info first (outside do-catch so it's available in catch block)
            let batches = StorageManager.shared.allBatches()
            guard let batchInfo = batches.first(where: { $0.0 == batchId }) else {
                completion(.failure(NSError(domain: "LLMService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Batch not found"])))
                return
            }
            
            let (_, batchStartTs, batchEndTs, _) = batchInfo
            let processingStartTime = Date()
            let primaryProviderID = LLMProviderID.from(providerType)
            let primaryProviderLabel = providerLabel(for: primaryProviderID)
            let configuredBackup = configuredBackupProvider(primaryProviderID: primaryProviderID)
            let configuredBackupProviderName = configuredBackup?.id.analyticsName
            let configuredBackupProviderLabel = configuredBackup.map {
                providerLabel(for: $0.id, chatToolOverride: $0.chatToolOverride)
            }
            var backupConfigured = false
            var lastProcessingStep: LLMProcessingStep?

            do {
                print("\n📦 [LLMService] Processing batch \(batchId)")
                print("   Batch time: \(Date(timeIntervalSince1970: TimeInterval(batchStartTs))) to \(Date(timeIntervalSince1970: TimeInterval(batchEndTs)))")

                // Track analysis batch started
                AnalyticsService.shared.capture("analysis_batch_started", [
                    "batch_id": batchId,
                    "total_duration_seconds": batchEndTs - batchStartTs,
                    "llm_provider": primaryProviderID.analyticsName,
                    "llm_provider_label": primaryProviderLabel
                ])

                let primaryContext = try makeTimelineProviderContext(for: primaryProviderID)
                let backupContext: TimelineProviderContext? = {
                    guard let configuredBackup else { return nil }
                    return try? makeTimelineProviderContext(
                        for: configuredBackup.id,
                        chatToolOverride: configuredBackup.chatToolOverride
                    )
                }()
                backupConfigured = backupContext != nil
                if let configuredBackup, backupContext == nil {
                    AnalyticsService.shared.capture("llm_timeline_backup_unavailable", [
                        "primary_provider": primaryProviderID.analyticsName,
                        "primary_provider_label": primaryProviderLabel,
                        "backup_provider": configuredBackup.id.analyticsName,
                        "backup_provider_label": configuredBackupProviderLabel as Any,
                        "batch_id": batchId
                    ])
                }
                var activeContext = primaryContext
                var usedProviderBackup = false
                
                // Mark batch as processing
                StorageManager.shared.updateBatch(batchId, status: "processing")

                // Get batch start time for timestamp conversion
                let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))

                // Try screenshot-based transcription first (new system)
                let screenshots = StorageManager.shared.screenshotsForBatch(batchId)
                var observations: [Observation]
                var transcribeLog: LLMCall

                guard !screenshots.isEmpty else {
                    throw NSError(domain: "LLMService", code: 3, userInfo: [NSLocalizedDescriptionKey: "No screenshots in batch"])
                }

                lastProcessingStep = .transcribing
                await MainActor.run {
                    progressHandler?(.transcribing)
                }

                print("📸 [LLMService] Transcribing \(screenshots.count) screenshots")

                // Transcribe screenshots using provider
                let transcribeResult = try await executeWithProviderBackup(
                    operation: "transcribe",
                    batchId: batchId,
                    primaryContext: primaryContext,
                    activeContext: activeContext,
                    backupContext: backupContext
                ) { context in
                    try await context.actions.transcribeScreenshots(screenshots, batchStartDate, batchId)
                }
                observations = transcribeResult.value.observations
                transcribeLog = transcribeResult.value.log
                activeContext = transcribeResult.activeContext
                usedProviderBackup = usedProviderBackup || transcribeResult.usedProviderBackup
                print("📸 [LLMService] Transcribed → \(observations.count) observations")
                
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
                    AnalyticsService.shared.capture("transcription_returned_empty", [
                        "batch_id": batchId,
                        "provider": activeContext.id.analyticsName,
                        "provider_label": activeContext.providerLabel,
                        "transcribe_latency_ms": Int((transcribeLog.latency ?? 0) * 1000)
                    ])
                    StorageManager.shared.updateBatch(batchId, status: "analyzed")
                    completion(.success(ProcessedBatchResult(cards: [], cardIds: [])))
                    return
                }
                
                // SLIDING WINDOW CARD GENERATION - Replace old card generation with sliding window approach
                
                // Calculate card-generation lookback window.
                let currentTime = Date(timeIntervalSince1970: TimeInterval(batchEndTs))
                let windowStartTime = currentTime.addingTimeInterval(-batchingConfig.cardLookbackDuration)
                
                // Fetch observations from the recent batching window (instead of just current batch).
                let recentObservations = StorageManager.shared.fetchObservationsByTimeRange(
                    from: windowStartTime,
                    to: currentTime
                )

                print("[DEBUG] LLMService fetched \(recentObservations.count) observations")
                for (i, obs) in recentObservations.enumerated() {
                    print("  [\(i)] observation type: \(type(of: obs.observation))")
                    print("       observation: \(obs.observation)")
                }
                
                // Fetch existing timeline cards that overlap with the recent batching window.
                let existingTimelineCards = StorageManager.shared.fetchTimelineCardsByTimeRange(
                    from: windowStartTime,
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
                
                lastProcessingStep = .generatingCards
                await MainActor.run {
                    progressHandler?(.generatingCards)
                }

                // Generate activity cards using sliding window observations
                let cardsResult = try await executeWithProviderBackup(
                    operation: "generate_cards",
                    batchId: batchId,
                    primaryContext: primaryContext,
                    activeContext: activeContext,
                    backupContext: backupContext
                ) { providerContext in
                    try await providerContext.actions.generateActivityCards(recentObservations, context, batchId)
                }
                let cards = cardsResult.value.cards
                activeContext = cardsResult.activeContext
                usedProviderBackup = usedProviderBackup || cardsResult.usedProviderBackup
                let usedGemmaForCardGeneration = activeContext.fallbackState?.usedGemmaForCardGeneration == true
                let isBackupGenerated = usedProviderBackup || usedGemmaForCardGeneration
                // Note: card generation log is not persisted per-batch yet
                
                // Replace old cards with new ones in the time range
                let (insertedCardIds, deletedVideoPaths) = StorageManager.shared.replaceTimelineCardsInRange(
                    from: windowStartTime,
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
                            appSites: card.appSites,
                            isBackupGenerated: isBackupGenerated ? true : nil
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

                // Checkpoint WAL after batch processing to ensure data is persisted
                StorageManager.shared.checkpoint(mode: .passive)

                // Track analysis batch completed
                AnalyticsService.shared.capture("analysis_batch_completed", [
                    "batch_id": batchId,
                    "cards_generated": cards.count,
                    "processing_duration_seconds": Int(Date().timeIntervalSince(processingStartTime)),
                    "llm_provider": primaryProviderID.analyticsName,
                    "llm_provider_label": primaryProviderLabel,
                    "effective_llm_provider": activeContext.id.analyticsName,
                    "used_provider_backup": usedProviderBackup
                ])

                completion(.success(ProcessedBatchResult(cards: cards, cardIds: insertedCardIds)))
                
            } catch {
                print("Error processing batch: \(error)")
                if let ns = error as NSError?, ns.domain == "GeminiError" {
                    print("🔎 GEMINI DEBUG: NSError.userInfo=\(ns.userInfo)")
                }

                // Track analysis batch failed
                AnalyticsService.shared.capture("analysis_batch_failed", [
                    "batch_id": batchId,
                    "error_message": error.localizedDescription,
                    "processing_duration_seconds": Int(Date().timeIntervalSince(processingStartTime)),
                    "llm_provider": primaryProviderID.analyticsName,
                    "llm_provider_label": primaryProviderLabel,
                    "backup_provider": configuredBackupProviderName as Any,
                    "backup_provider_label": configuredBackupProviderLabel as Any,
                    "backup_configured": backupConfigured
                ])

                emitTimelineFailureToast(
                    operation: lastProcessingStep,
                    error: error,
                    primaryProvider: primaryProviderID.analyticsName,
                    primaryProviderLabel: primaryProviderLabel,
                    backupProvider: configuredBackupProviderName,
                    backupProviderLabel: configuredBackupProviderLabel,
                    backupConfigured: backupConfigured,
                    batchId: batchId
                )

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
        let textProvider = try makeTextProvider()
        let (text, _) = try await textProvider.generateText(prompt)
        return text
    }

    // MARK: - Streaming Text Generation

    func generateTextStreaming(prompt: String) -> AsyncThrowingStream<String, Error> {
        do {
            let textProvider = try makeTextProvider()
            if let streaming = textProvider.generateTextStreaming {
                return streaming(prompt)
            }
            return makeFallbackTextStream { try await textProvider.generateText(prompt).text }
        } catch {
            return makeErrorStream(error)
        }
    }

    // MARK: - Rich Chat Streaming (ChatCLI only)

    func generateChatStreaming(prompt: String, sessionId: String? = nil) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let chatCLI = makeChatCLIProvider()
        return chatCLI.generateChatStreaming(prompt: prompt, sessionId: sessionId)
    }
}
