//
//  LLMService.swift
//  Dayflow
//

import AppKit
import Combine
import Foundation
import GRDB
import SwiftUI

private final class TimelineCardGenerationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isHeld {
        waiters.append(continuation)
        lock.unlock()
      } else {
        isHeld = true
        lock.unlock()
        continuation.resume()
      }
    }
  }

  func release() {
    lock.lock()
    let next = waiters.isEmpty ? nil : waiters.removeFirst()
    if next == nil { isHeld = false }
    lock.unlock()
    next?.resume()
  }
}

struct ProcessedBatchResult {
  let cards: [ActivityCardData]
  let cardIds: [Int64]
}

enum LLMProcessingStep: Sendable, Equatable {
  case transcribing
  case generatingCards
}

struct TimelineProviderStartupSelection<Context> {
  let baselineContext: Context
  let fallbackContext: Context?
  let activeContext: Context
  let usedProviderBackup: Bool
  let primaryInitializationError: Error?
}

func selectTimelineProviderStartup<Context>(
  primary: Result<Context, Error>,
  backup: Context?
) throws -> TimelineProviderStartupSelection<Context> {
  switch primary {
  case .success(let primaryContext):
    return TimelineProviderStartupSelection(
      baselineContext: primaryContext,
      fallbackContext: backup,
      activeContext: primaryContext,
      usedProviderBackup: false,
      primaryInitializationError: nil
    )
  case .failure(let error):
    guard let backup else { throw error }
    return TimelineProviderStartupSelection(
      baselineContext: backup,
      fallbackContext: nil,
      activeContext: backup,
      usedProviderBackup: true,
      primaryInitializationError: error
    )
  }
}

protocol LLMServicing {
  func processBatch(
    _ batchId: Int64, progressHandler: ((LLMProcessingStep) -> Void)?,
    completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void)
  func generateText(prompt: String) async throws -> String
  func generateTextStreaming(prompt: String) -> AsyncThrowingStream<String, Error>
  /// Rich chat streaming with thinking, tool calls, and text events.
  /// - Parameter sessionId: Optional session ID to resume a previous conversation
  func generateChatStreaming(request: DashboardChatRequest) -> AsyncThrowingStream<
    ChatStreamEvent, Error
  >
  var batchingConfig: BatchingConfig { get }
}

final class LLMService: LLMServicing {
  static let shared: LLMServicing = LLMService()
  private static let timelineCardGenerationGate = TimelineCardGenerationGate()
  private static let timelineFailureToastLastShownDayByKindDefaultsKey =
    "timelineFailureToastLastShownDayByKind"
  private static let timelineFailureToastThrottleQueue = DispatchQueue(
    label: "com.dayflow.timelineFailureToastThrottle"
  )

  /// Card generators report `rewriteSpan`, the stretch of timeline (Unix seconds) their cards
  /// replace. nil means the whole lookback window is replaced, as for providers that are shown
  /// every card in it.
  private typealias ActivityCardsGenerator =
    ([Observation], ActivityGenerationContext, Int64?) async throws -> (
      cards: [ActivityCardData], rewriteSpan: Range<Int>?, log: LLMCall
    )

  private struct BatchProviderActions {
    let transcribeScreenshots:
      ([Screenshot], Date, Int64?) async throws -> (observations: [Observation], log: LLMCall)
    let generateActivityCards: ActivityCardsGenerator
    /// Screenshots straight to cards in one call. Only providers that support it set this.
    var generateTimeline:
      (
        ([Screenshot], ActivityGenerationContext, Int64?) async throws -> (
          cards: [ActivityCardData], observations: [Observation], rewriteSpan: Range<Int>?,
          log: LLMCall
        )
      )? = nil
  }

  /// Adapts a provider whose cards rewrite the whole lookback window.
  private static func rewritingWholeWindow(
    _ generate:
      @escaping ([Observation], ActivityGenerationContext, Int64?) async throws -> (
        cards: [ActivityCardData], log: LLMCall
      )
  ) -> ActivityCardsGenerator {
    { observations, context, batchId in
      let result = try await generate(observations, context, batchId)
      return (result.cards, nil, result.log)
    }
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
    let token = DayflowAuthManager.storedSessionToken()?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let token, !token.isEmpty else {
      print("❌ [LLMService] Dayflow provider unavailable: missing session token")
      return nil
    }
    print(
      "🔐 [LLMService] Dayflow provider ready endpoint=\(endpoint) token_length=\(token.count)"
    )
    return DayflowBackendProvider(token: token, endpoint: endpoint)
  }

  private func resolvedDayflowEndpoint(savedEndpoint: String?) -> String? {
    DayflowBackendConfiguration.endpoint(legacySavedEndpoint: savedEndpoint)
  }

  private func makeOllamaProvider(endpoint: String) -> OllamaProvider {
    OllamaProvider(endpoint: endpoint)
  }

  private func localProviderEndpoint() -> String {
    let saved =
      UserDefaults.standard.string(forKey: "llmLocalBaseURL")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return saved.isEmpty ? "http://localhost:11434" : saved
  }

  private func makeOpenAICompatibleProvider() -> OpenAICompatibleProvider? {
    guard let configuration = OpenAICompatiblePreferences.load(), configuration.isComplete else {
      print("❌ [LLMService] OpenAI-compatible provider unavailable: incomplete configuration")
      return nil
    }
    let apiKey = KeychainManager.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider)
    let runtimeConfiguration = OpenAICompatibleRuntimeConfiguration(
      configuration: configuration,
      bearerToken: apiKey
    )
    return OpenAICompatibleProvider(configuration: runtimeConfiguration)
  }

  private func providerLabel(for providerID: LLMProviderID) -> String {
    providerID.providerLabel
  }

  private func noProviderError() -> NSError {
    NSError(
      domain: "LLMService",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "No LLM provider configured. Please configure in settings."
      ]
    )
  }

  private func makeBatchProvider(for providerID: LLMProviderID) throws -> (
    actions: BatchProviderActions, fallbackState: GemmaFallbackState?
  ) {
    switch providerID {
    case .gemini:
      guard let provider = makeGeminiProvider() else { throw noProviderError() }
      let gemmaProvider = makeGemmaBackupProvider()
      let fallbackState = GemmaFallbackState()

      return (
        actions: BatchProviderActions(
          transcribeScreenshots: { [weak self] screenshots, batchStartTime, batchId in
            if fallbackState.preferGemma, let gemmaProvider {
              return try await gemmaProvider.transcribeScreenshots(
                screenshots, batchStartTime: batchStartTime, batchId: batchId)
            }

            do {
              return try await provider.transcribeScreenshots(
                screenshots, batchStartTime: batchStartTime, batchId: batchId)
            } catch {
              guard let gemmaProvider else { throw error }
              fallbackState.preferGemma = true
              self?.logGemmaFallback(operation: "transcribe", error: error, batchId: batchId)
              return try await gemmaProvider.transcribeScreenshots(
                screenshots, batchStartTime: batchStartTime, batchId: batchId)
            }
          },
          generateActivityCards: Self.rewritingWholeWindow {
            [weak self] observations, context, batchId in
            if fallbackState.preferGemma, let gemmaProvider {
              fallbackState.usedGemmaForCardGeneration = true
              return try await gemmaProvider.generateActivityCards(
                observations: observations, context: context, batchId: batchId)
            }

            do {
              return try await provider.generateActivityCards(
                observations: observations, context: context, batchId: batchId)
            } catch {
              guard let gemmaProvider else { throw error }
              fallbackState.preferGemma = true
              fallbackState.usedGemmaForCardGeneration = true
              self?.logGemmaFallback(operation: "generate_cards", error: error, batchId: batchId)
              return try await gemmaProvider.generateActivityCards(
                observations: observations, context: context, batchId: batchId)
            }
          }
        ), fallbackState: fallbackState
      )
    case .dayflow:
      let savedEndpoint = DayflowEndpointPreferences.load()
      guard let endpoint = resolvedDayflowEndpoint(savedEndpoint: savedEndpoint) else {
        throw noProviderError()
      }
      guard let provider = makeDayflowProvider(endpoint: endpoint) else { throw noProviderError() }
      return (
        actions: BatchProviderActions(
          transcribeScreenshots: provider.transcribeScreenshots,
          generateActivityCards: Self.rewritingWholeWindow(provider.generateActivityCards),
          // The backend is shown every card in the window, like rewritingWholeWindow providers.
          generateTimeline: { screenshots, context, batchId in
            let result = try await provider.generateTimeline(
              screenshots: screenshots, context: context, batchId: batchId)
            return (result.cards, result.observations, nil, result.log)
          }
        ), fallbackState: nil
      )
    case .local:
      let provider = makeOllamaProvider(endpoint: localProviderEndpoint())
      return (
        actions: BatchProviderActions(
          transcribeScreenshots: provider.transcribeScreenshots,
          generateActivityCards: Self.rewritingWholeWindow(provider.generateActivityCards)
        ), fallbackState: nil
      )
    case .openAICompatible:
      guard let provider = makeOpenAICompatibleProvider() else { throw noProviderError() }
      return (
        actions: BatchProviderActions(
          transcribeScreenshots: provider.transcribeScreenshots,
          generateActivityCards: Self.rewritingWholeWindow(provider.generateActivityCards)
        ), fallbackState: nil
      )
    case .chatGPT:
      let provider = CodexProvider()
      return (
        actions: BatchProviderActions(
          transcribeScreenshots: provider.transcribeScreenshots,
          generateActivityCards: Self.rewritingWholeWindow(provider.generateActivityCards),
          generateTimeline: provider.generateTimeline
        ), fallbackState: nil
      )
    case .claude:
      let provider = ClaudeProvider()
      return (
        actions: BatchProviderActions(
          transcribeScreenshots: provider.transcribeScreenshots,
          generateActivityCards: provider.generateActivityCards,
          generateTimeline: provider.generateTimeline
        ), fallbackState: nil
      )
    }
  }

  private func makeTimelineProviderContext(for providerID: LLMProviderID) throws
    -> TimelineProviderContext
  {
    let providerBundle = try makeBatchProvider(for: providerID)
    return TimelineProviderContext(
      id: providerID,
      providerLabel: providerLabel(for: providerID),
      actions: providerBundle.actions,
      fallbackState: providerBundle.fallbackState
    )
  }

  private func configuredBackupProvider(
    primaryProviderID: LLMProviderID,
    routing: LLMProviderRouting
  ) -> LLMProviderID? {
    guard let secondary = routing.secondary, secondary != primaryProviderID else { return nil }
    return secondary
  }

  private final class GemmaFallbackState {
    var preferGemma = false
    var usedGemmaForCardGeneration = false
  }

  private func logGemmaFallback(operation: String, error: Error, batchId: Int64?) {
    let nsError = error as NSError
    AnalyticsService.shared.capture(
      "llm_fallback_used",
      [
        "provider": "gemini",
        "provider_id": LLMProviderID.gemini.rawValue,
        "provider_label": "gemini",
        "fallback_provider": "gemma",
        "fallback_provider_label": "gemma",
        "operation": operation,
        "error_domain": nsError.domain,
        "error_code": nsError.code,
        "batch_id": batchId as Any,
      ])
  }

  private func fallbackProps(
    operation: String,
    batchId: Int64?,
    primaryProviderID: LLMProviderID,
    primaryProviderLabel: String,
    backupProviderID: LLMProviderID,
    backupProviderLabel: String,
    error: Error
  ) -> [String: Any] {
    let nsError = error as NSError
    return [
      "operation": operation,
      "batch_id": batchId as Any,
      "primary_provider": primaryProviderID.analyticsName,
      "primary_provider_id": primaryProviderID.rawValue,
      "primary_provider_label": primaryProviderLabel,
      "backup_provider": backupProviderID.analyticsName,
      "backup_provider_id": backupProviderID.rawValue,
      "backup_provider_label": backupProviderLabel,
      "error_domain": nsError.domain,
      "error_code": nsError.code,
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
        primaryProviderID: primaryContext.id,
        primaryProviderLabel: primaryContext.providerLabel,
        backupProviderID: backupContext.id,
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
      if message.contains("quota") || message.contains("rate limit")
        || message.contains("too many requests")
      {
        return true
      }
    }

    let message = error.localizedDescription.lowercased()
    if message.contains("rate limit") || message.contains("too many requests")
      || message.contains("quota exceeded") || message.contains("quota")
      || message.contains("you've hit your")
    {
      return true
    }

    return false
  }

  private func emitTimelineFailureToast(
    classification: TimelineFailureClassification,
    operation: LLMProcessingStep?,
    error: Error,
    primaryProvider: String,
    primaryProviderLabel: String,
    backupProvider: String?,
    backupProviderLabel: String?,
    backupConfigured: Bool,
    batchId: Int64?
  ) {
    // Only interrupt the user for problems they have to fix themselves.
    // Everything else is retried automatically after the next success.
    guard let content = classification.toastContent(fallbackProviderLabel: primaryProviderLabel)
    else { return }

    guard shouldEmitTimelineFailureToast(kind: classification.kind) else { return }

    let nsError = error as NSError
    let payload = TimelineFailureToastPayload(
      message: content.body,
      title: content.title,
      providerName: content.providerName,
      steps: content.steps,
      command: content.command,
      waitingSeconds: failedRecordingSecondsInLastDay(),
      destination: content.destination,
      failureKind: classification.kind.rawValue,
      operation: operationName(for: operation),
      primaryProvider: primaryProvider,
      primaryProviderLabel: primaryProviderLabel,
      backupProvider: backupProvider,
      backupProviderLabel: backupProviderLabel,
      backupConfigured: backupConfigured,
      rateLimitDetected: isRateLimitError(error),
      errorDomain: nsError.domain,
      errorCode: nsError.code,
      batchId: batchId
    )
    AnalyticsService.shared.capture("llm_timeline_failure_toast_shown", payload.analyticsProps)
    TimelineFailureToastCenter.post(payload)
  }

  /// Recorded time from the last 24 hours that failed and is waiting to be retried.
  private func failedRecordingSecondsInLastDay(now: Date = Date()) -> Int {
    let cutoff = Int(now.timeIntervalSince1970) - 24 * 60 * 60
    return StorageManager.shared.allBatches()
      .filter { $0.status == "failed" && $0.start >= cutoff }
      .reduce(0) { total, batch in total + max(0, batch.end - batch.start) }
  }

  private func shouldEmitTimelineFailureToast(
    kind: TimelineFailureKind, now: Date = Date()
  ) -> Bool {
    let logicalDay = now.getDayInfoFor4AMBoundary().dayString
    return Self.timelineFailureToastThrottleQueue.sync {
      let defaults = UserDefaults.standard
      var lastShownDayByKind =
        defaults.dictionary(forKey: Self.timelineFailureToastLastShownDayByKindDefaultsKey)
        as? [String: String] ?? [:]
      guard lastShownDayByKind[kind.rawValue] != logicalDay else {
        return false
      }
      lastShownDayByKind[kind.rawValue] = logicalDay
      defaults.set(
        lastShownDayByKind, forKey: Self.timelineFailureToastLastShownDayByKindDefaultsKey)
      return true
    }
  }

  private func makeTextProvider() throws -> TextProviderActions {
    let providerID = try LLMProviderRoutingStore.load().primary
    switch providerID {
    case .gemini:
      guard let provider = makeGeminiProvider() else { throw noProviderError() }
      return TextProviderActions(
        generateText: { prompt in
          try await provider.generateText(prompt: prompt)
        },
        generateTextStreaming: nil
      )
    case .dayflow:
      guard
        let resolvedEndpoint = resolvedDayflowEndpoint(
          savedEndpoint: DayflowEndpointPreferences.load())
      else {
        throw noProviderError()
      }
      guard let provider = makeDayflowProvider(endpoint: resolvedEndpoint) else {
        throw noProviderError()
      }
      return TextProviderActions(
        generateText: { prompt in
          try await provider.generateText(prompt: prompt)
        },
        generateTextStreaming: nil
      )
    case .local:
      let provider = makeOllamaProvider(endpoint: localProviderEndpoint())
      return TextProviderActions(
        generateText: { prompt in
          try await provider.generateText(prompt: prompt)
        },
        generateTextStreaming: nil
      )
    case .openAICompatible:
      guard let provider = makeOpenAICompatibleProvider() else { throw noProviderError() }
      return TextProviderActions(
        generateText: { prompt in
          try await provider.generateText(prompt: prompt)
        },
        generateTextStreaming: nil
      )
    case .chatGPT:
      let provider = CodexProvider()
      return TextProviderActions(
        generateText: { prompt in
          try await provider.generateText(prompt: prompt)
        },
        generateTextStreaming: provider.generateTextStreaming
      )
    case .claude:
      let provider = ClaudeProvider()
      return TextProviderActions(
        generateText: { prompt in
          try await provider.generateText(prompt: prompt)
        },
        generateTextStreaming: provider.generateTextStreaming
      )
    }
  }

  private func makeFallbackTextStream(_ work: @escaping () async throws -> String)
    -> AsyncThrowingStream<String, Error>
  {
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

  /// The stretch of timeline a batch's new cards replace. Providers that were shown only the
  /// cards connected to this batch report the span they rewrote; the rest rewrote the whole
  /// lookback window, so every card in it is replaced.
  static func cardReplacementRange(
    rewriteSpan: Range<Int>?,
    windowStartTime: Date,
    batchEndTime: Date
  ) -> (from: Date, to: Date) {
    guard let rewriteSpan else { return (windowStartTime, batchEndTime) }
    return (
      Date(timeIntervalSince1970: TimeInterval(rewriteSpan.lowerBound)),
      Date(timeIntervalSince1970: TimeInterval(rewriteSpan.upperBound))
    )
  }

  // Keep the existing processBatch implementation for backward compatibility
  func processBatch(
    _ batchId: Int64, progressHandler: ((LLMProcessingStep) -> Void)? = nil,
    completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void
  ) {
    Task {
      var holdsTimelineCardGenerationGate = false
      defer {
        if holdsTimelineCardGenerationGate {
          Self.timelineCardGenerationGate.release()
        }
      }

      // Get batch info first (outside do-catch so it's available in catch block)
      let batches = StorageManager.shared.allBatches()
      guard let batchInfo = batches.first(where: { $0.0 == batchId }) else {
        completion(
          .failure(
            NSError(
              domain: "LLMService", code: 2,
              userInfo: [NSLocalizedDescriptionKey: "Batch not found"])))
        return
      }

      let (_, batchStartTs, batchEndTs, _) = batchInfo
      let routing: LLMProviderRouting
      do {
        routing = try LLMProviderRoutingStore.load()
      } catch {
        completion(.failure(error))
        return
      }
      let processingStartTime = Date()
      let primaryProviderID = routing.primary
      let primaryProviderLabel = providerLabel(for: primaryProviderID)
      let configuredBackup = configuredBackupProvider(
        primaryProviderID: primaryProviderID,
        routing: routing
      )
      let configuredBackupProviderName = configuredBackup?.analyticsName
      let configuredBackupProviderLabel = configuredBackup.map { providerLabel(for: $0) }
      var backupConfigured = false
      var lastProcessingStep: LLMProcessingStep?
      print(
        "🧭 [LLMService] processBatch selected primary=\(primaryProviderID.analyticsName) "
          + "label=\(primaryProviderLabel) backup=\(configuredBackup?.analyticsName ?? "none")"
      )

      do {
        print("\n📦 [LLMService] Processing batch \(batchId)")
        print(
          "   Batch time: \(Date(timeIntervalSince1970: TimeInterval(batchStartTs))) to \(Date(timeIntervalSince1970: TimeInterval(batchEndTs)))"
        )

        // Track analysis batch started
        AnalyticsService.shared.capture(
          "analysis_batch_started",
          [
            "batch_id": batchId,
            "total_duration_seconds": batchEndTs - batchStartTs,
            "llm_provider": primaryProviderID.analyticsName,
            "llm_provider_label": primaryProviderLabel,
            "provider_id": primaryProviderID.rawValue,
          ])

        let primaryResult: Result<TimelineProviderContext, Error> = Result {
          try makeTimelineProviderContext(for: primaryProviderID)
        }
        let configuredBackupContext: TimelineProviderContext? = {
          guard let configuredBackup else { return nil }
          return try? makeTimelineProviderContext(for: configuredBackup)
        }()
        backupConfigured = configuredBackupContext != nil
        if let configuredBackup, configuredBackupContext == nil {
          AnalyticsService.shared.capture(
            "llm_timeline_backup_unavailable",
            [
              "primary_provider": primaryProviderID.analyticsName,
              "primary_provider_label": primaryProviderLabel,
              "primary_provider_id": primaryProviderID.rawValue,
              "backup_provider": configuredBackup.analyticsName,
              "backup_provider_label": configuredBackupProviderLabel as Any,
              "backup_provider_id": configuredBackup.rawValue,
              "batch_id": batchId,
            ])
        }
        let startup = try selectTimelineProviderStartup(
          primary: primaryResult,
          backup: configuredBackupContext
        )
        if startup.usedProviderBackup,
          let configuredBackup,
          let configuredBackupContext,
          let primaryError = startup.primaryInitializationError
        {
          let props = fallbackProps(
            operation: "initialize_provider",
            batchId: batchId,
            primaryProviderID: primaryProviderID,
            primaryProviderLabel: primaryProviderLabel,
            backupProviderID: configuredBackup,
            backupProviderLabel: configuredBackupContext.providerLabel,
            error: primaryError
          )
          AnalyticsService.shared.capture("llm_timeline_fallback_attempted", props)
          AnalyticsService.shared.capture("llm_timeline_fallback_succeeded", props)
        }

        // If the routed primary could not initialize, the backup becomes the batch baseline.
        // Its fallback is nil so later stages stay pinned to it instead of retrying the primary.
        let primaryContext = startup.baselineContext
        let backupContext = startup.fallbackContext
        var activeContext = startup.activeContext
        var usedProviderBackup = startup.usedProviderBackup

        // Mark batch as processing
        StorageManager.shared.updateBatch(batchId, status: "processing")

        // Get batch start time for timestamp conversion
        let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))

        // Try screenshot-based transcription first (new system)
        let screenshots = StorageManager.shared.screenshotsForBatch(batchId)
        var observations: [Observation] = []

        guard !screenshots.isEmpty else {
          throw NSError(
            domain: "LLMService", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "No screenshots in batch"])
        }

        // Card-generation lookback window.
        let currentTime = Date(timeIntervalSince1970: TimeInterval(batchEndTs))
        let windowStartTime = currentTime.addingTimeInterval(-batchingConfig.cardLookbackDuration)
        let batchStartTime = batchStartDate

        func makeGenerationContext(batchObservations: [Observation]) -> ActivityGenerationContext {
          // Fetch existing timeline cards that overlap with the recent batching window.
          let existingTimelineCards = StorageManager.shared.fetchTimelineCardsByTimeRange(
            from: windowStartTime,
            to: currentTime
          )
          let hasPreviousCardWithinFiveMinutes = StorageManager.shared.hasTimelineCardConnected(
            toBatchStartingAt: batchStartTime,
            maxGap: 5 * 60
          )

          // Convert TimelineCards to ActivityCardData for context
          let existingActivityCards = existingTimelineCards.filter { card in
            card.category != "System"
          }.map { card in
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

          return ActivityGenerationContext(
            batchObservations: batchObservations,
            existingCards: existingActivityCards,
            currentTime: currentTime,
            categories: CategoryStore.descriptorsForLLM(),
            hasPreviousCardWithinFiveMinutes: hasPreviousCardWithinFiveMinutes
          )
        }

        // One-step generation: the primary provider reads the screenshots and writes the cards
        // in a single call. If it fails, the batch falls through to transcribe-then-generate
        // below, which keeps its own backup-provider handling.
        var oneStepCards: [ActivityCardData]?
        var rewriteSpan: Range<Int>?
        if !usedProviderBackup, let generateTimeline = activeContext.actions.generateTimeline {
          lastProcessingStep = .generatingCards
          await MainActor.run {
            progressHandler?(.generatingCards)
          }

          // The call reads and rewrites the recent timeline, so it must not overlap another
          // batch's rewrite.
          await Self.timelineCardGenerationGate.acquire()
          holdsTimelineCardGenerationGate = true

          let oneStepStartedAt = Date()
          do {
            let result = try await generateTimeline(
              screenshots, makeGenerationContext(batchObservations: []), batchId)
            observations = result.observations
            StorageManager.shared.saveObservations(batchId: batchId, observations: observations)
            oneStepCards = result.cards
            rewriteSpan = result.rewriteSpan
            print(
              "🧩 [LLMService] One-step timeline → \(result.cards.count) cards, "
                + "\(observations.count) observations")
          } catch {
            let nsError = error as NSError
            // Sign-in and subscription rejections would fail the same way on the two-step
            // endpoints, so surface them instead of sending a second doomed request.
            if nsError.domain == "DayflowBackend", [401, 402, 403].contains(nsError.code) {
              throw error
            }
            // A usage limit, sign-out or similar account problem fails the two-step calls to the
            // same provider too, so skip them: go to the backup provider, or fail the batch now.
            let failureKind = TimelineFailureClassifier.classify(error).kind
            let skipsPrimaryTwoStep = failureKind.failsEveryRequestToProvider
            AnalyticsService.shared.capture(
              "timeline_one_step_fallback",
              [
                "batch_id": batchId,
                "provider": activeContext.id.analyticsName,
                "provider_id": activeContext.id.rawValue,
                "error_domain": nsError.domain,
                "error_code": nsError.code,
                "failure_kind": failureKind.rawValue,
                "skipped_primary_two_step": skipsPrimaryTwoStep,
                "latency_ms": Int(Date().timeIntervalSince(oneStepStartedAt) * 1000),
              ])
            if skipsPrimaryTwoStep {
              guard let backupContext else { throw error }
              AnalyticsService.shared.capture(
                "llm_timeline_fallback_attempted",
                fallbackProps(
                  operation: "generate_timeline",
                  batchId: batchId,
                  primaryProviderID: primaryContext.id,
                  primaryProviderLabel: primaryContext.providerLabel,
                  backupProviderID: backupContext.id,
                  backupProviderLabel: backupContext.providerLabel,
                  error: error
                ))
              activeContext = backupContext
              usedProviderBackup = true
              print(
                "⚠️ [LLMService] One-step timeline failed for batch \(batchId) with an account "
                  + "problem; skipping \(primaryContext.providerLabel)'s two-step path and using "
                  + "\(backupContext.providerLabel): \(nsError.localizedDescription)")
            } else {
              print(
                "⚠️ [LLMService] One-step timeline failed for batch \(batchId), "
                  + "falling back to transcribe + generate: \(nsError.localizedDescription)")
            }
          }
        }

        let cards: [ActivityCardData]
        if let oneStepCards {
          cards = oneStepCards
        } else {
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
          let transcribeLog = transcribeResult.value.log
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
            AnalyticsService.shared.capture(
              "transcription_returned_empty",
              [
                "batch_id": batchId,
                "provider": activeContext.id.analyticsName,
                "provider_id": activeContext.id.rawValue,
                "provider_label": activeContext.providerLabel,
                "transcribe_latency_ms": Int((transcribeLog.latency ?? 0) * 1000),
              ])
            StorageManager.shared.updateBatch(batchId, status: "analyzed")
            completion(.success(ProcessedBatchResult(cards: [], cardIds: [])))
            return
          }

          // SLIDING WINDOW CARD GENERATION

          // Transcription can run in parallel, but timeline reads, generation, and replacement
          // form one serialized rewrite and must not overlap another batch's rewrite.
          if !holdsTimelineCardGenerationGate {
            await Self.timelineCardGenerationGate.acquire()
            holdsTimelineCardGenerationGate = true
          }

          // Fetch observations from the recent batching window (instead of just current batch).
          let recentObservations = StorageManager.shared.fetchObservationsByTimeRange(
            from: windowStartTime,
            to: currentTime
          )
          print("[DEBUG] LLMService fetched \(recentObservations.count) observations")

          let context = makeGenerationContext(batchObservations: observations)
          print("[DEBUG] LLMService loaded \(context.categories.count) categories")

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
            try await providerContext.actions.generateActivityCards(
              recentObservations, context, batchId)
          }
          cards = cardsResult.value.cards
          rewriteSpan = cardsResult.value.rewriteSpan
          activeContext = cardsResult.activeContext
          usedProviderBackup = usedProviderBackup || cardsResult.usedProviderBackup
        }
        let usedGemmaForCardGeneration =
          activeContext.fallbackState?.usedGemmaForCardGeneration == true
        let isBackupGenerated = usedProviderBackup || usedGemmaForCardGeneration
        // Note: card generation log is not persisted per-batch yet

        // Replace old cards with new ones in the time range
        let replacementRange = Self.cardReplacementRange(
          rewriteSpan: rewriteSpan,
          windowStartTime: windowStartTime,
          batchEndTime: currentTime
        )
        // A model shown only connected cards never saw cards that newer batches started after
        // this one began, so a retry finishing late must not delete them. Providers shown the
        // whole window saw those cards and rewrote them, so theirs are replaced as before.
        let keepNewerCardsAfter = rewriteSpan == nil ? nil : batchStartTime
        let (insertedCardIds, deletedVideoPaths) = StorageManager.shared
          .replaceTimelineCardsInRange(
            from: replacementRange.from,
            to: replacementRange.to,
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
            batchId: batchId,
            keepingNewerBatchesCardsStartingAfter: keepNewerCardsAfter
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
        AnalyticsService.shared.capture(
          "analysis_batch_completed",
          [
            "batch_id": batchId,
            "cards_generated": cards.count,
            "processing_duration_seconds": Int(Date().timeIntervalSince(processingStartTime)),
            "llm_provider": primaryProviderID.analyticsName,
            "llm_provider_label": primaryProviderLabel,
            "provider_id": primaryProviderID.rawValue,
            "effective_llm_provider": activeContext.id.analyticsName,
            "effective_provider_id": activeContext.id.rawValue,
            "used_provider_backup": usedProviderBackup,
            "one_step": oneStepCards != nil,
          ])

        // Whatever the failure card asked the user to fix is working again.
        TimelineFailureToastCenter.hide()

        let analyzedCardCount = cards.count
        Task { @MainActor in
          GettingStarted.handleBatchAnalyzed(cardCount: analyzedCardCount)
        }

        completion(.success(ProcessedBatchResult(cards: cards, cardIds: insertedCardIds)))

      } catch {
        if !holdsTimelineCardGenerationGate {
          await Self.timelineCardGenerationGate.acquire()
          holdsTimelineCardGenerationGate = true
        }

        print("Error processing batch: \(error)")
        if let ns = error as NSError?, ns.domain == "GeminiError" {
          print("🔎 GEMINI DEBUG: NSError.userInfo=\(ns.userInfo)")
        }

        let failureClassification = TimelineFailureClassifier.classify(error)

        // Track analysis batch failed
        AnalyticsService.shared.capture(
          "analysis_batch_failed",
          [
            "batch_id": batchId,
            "failure_kind": failureClassification.kind.rawValue,
            "processing_duration_seconds": Int(Date().timeIntervalSince(processingStartTime)),
            "llm_provider": primaryProviderID.analyticsName,
            "llm_provider_label": primaryProviderLabel,
            "provider_id": primaryProviderID.rawValue,
            "backup_provider": configuredBackupProviderName as Any,
            "backup_provider_label": configuredBackupProviderLabel as Any,
            "backup_provider_id": configuredBackup?.rawValue as Any,
            "backup_configured": backupConfigured,
          ])

        // Mark batch as failed. The raw error stays in the batch row for debugging;
        // the user only ever sees the classifier's plain-language copy.
        StorageManager.shared.updateBatch(
          batchId, status: "failed", reason: error.localizedDescription)

        emitTimelineFailureToast(
          classification: failureClassification,
          operation: lastProcessingStep,
          error: error,
          primaryProvider: primaryProviderID.analyticsName,
          primaryProviderLabel: primaryProviderLabel,
          backupProvider: configuredBackupProviderName,
          backupProviderLabel: configuredBackupProviderLabel,
          backupConfigured: backupConfigured,
          batchId: batchId
        )

        // Create an error card for the failed time period
        let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))
        let batchEndDate = Date(timeIntervalSince1970: TimeInterval(batchEndTs))

        let errorCard = createErrorCard(
          batchStartTime: batchStartDate,
          batchEndTime: batchEndDate,
          message: failureClassification.cardMessage(fallbackProviderLabel: primaryProviderLabel)
        )

        // Replace any existing cards in this time range with the error card
        // This matches the happy path behavior and prevents duplicates. A retry can fail after
        // newer batches succeeded, so their cards stay.
        let (insertedCardIds, deletedVideoPaths) = StorageManager.shared
          .replaceTimelineCardsInRange(
            from: batchStartDate,
            to: batchEndDate,
            with: [errorCard],
            batchId: batchId,
            keepingNewerBatchesCardsStartingAfter: batchStartDate
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
          print(
            "✅ Created error card (ID: \(insertedCardIds.first ?? -1)) for failed batch \(batchId), replacing \(deletedVideoPaths.count) existing cards"
          )
        }

        // Still return failure but with the error card created
        completion(.failure(error))
      }
    }
  }

  private func createErrorCard(
    batchStartTime: Date, batchEndTime: Date, message: String
  ) -> TimelineCardShell {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    let startTimeStr = formatter.string(from: batchStartTime)
    let endTimeStr = formatter.string(from: batchEndTime)

    // The title stays the English sentinel the timeline uses to spot failed cards.
    // No detailed summary: raw error text never reaches the card.
    return TimelineCardShell(
      startTimestamp: startTimeStr,
      endTimestamp: endTimeStr,
      category: "System",
      subcategory: "Error",
      title: "Processing failed",
      summary: "\(message) Your recording is saved.",
      detailedSummary: "",
      distractions: nil,
      appSites: nil
    )
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

  // MARK: - Rich Chat Streaming

  func generateChatStreaming(request: DashboardChatRequest) -> AsyncThrowingStream<
    ChatStreamEvent, Error
  > {
    switch request.provider {
    case .gemini:
      guard let gemini = makeGeminiProvider() else {
        return AsyncThrowingStream { continuation in
          continuation.yield(
            .error("Gemini is not configured. Add your Gemini API key in Settings > Providers."))
          continuation.finish(
            throwing: NSError(
              domain: "LLMService",
              code: 1101,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Gemini is not configured. Add your Gemini API key in Settings > Providers."
              ]))
        }
      }
      return gemini.generateDashboardChatStreaming(
        systemInstruction: request.systemInstruction ?? "",
        history: request.history
      )
    case .codex:
      return CodexProvider().generateChatStreaming(
        prompt: request.prompt,
        sessionId: request.sessionId
      )
    case .claude:
      return ClaudeProvider().generateChatStreaming(
        prompt: request.prompt,
        sessionId: request.sessionId
      )
    }
  }
}
