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

/// Batches being worked on right now, and which of them already had a failed one-step call.
private final class BatchRunRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]
  /// Runs that ended before their task could be added, so `add` doesn't keep them forever.
  private var endedBeforeAdded = Set<UUID>()
  private var batchesWithFailedOneStep = Set<Int64>()

  func add(_ task: Task<Void, Never>, for run: UUID) {
    lock.lock()
    if endedBeforeAdded.remove(run) == nil {
      tasks[run] = task
    }
    lock.unlock()
  }

  func remove(_ run: UUID) {
    lock.lock()
    if tasks.removeValue(forKey: run) == nil {
      endedBeforeAdded.insert(run)
    }
    lock.unlock()
  }

  func cancelAll() {
    lock.lock()
    let running = Array(tasks.values)
    lock.unlock()
    running.forEach { $0.cancel() }
  }

  /// True the first time a batch's one-step call fails, false on later failures.
  func markOneStepFailed(_ batchId: Int64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return batchesWithFailedOneStep.insert(batchId).inserted
  }

  func clearOneStepFailure(_ batchId: Int64) {
    lock.lock()
    batchesWithFailedOneStep.remove(batchId)
    lock.unlock()
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
  private static let batchRuns = BatchRunRegistry()

  /// Stops the batches being worked on, so they wait for the Mac to wake instead of failing
  /// when their requests time out during sleep.
  static func cancelBatchesForSleep() {
    batchRuns.cancelAll()
  }

  /// Card generators report `rewriteSpan`, the stretch of timeline (Unix seconds) their cards
  /// replace. nil means the whole lookback window is replaced, as for providers that are shown
  /// every card in it.
  private typealias ActivityCardsGenerator =
    ([Observation], ActivityGenerationContext, Int64?) async throws -> (
      cards: [ActivityCardData], rewriteSpan: Range<Int>?, log: LLMCall
    )

  private typealias OneStepTimelineResult = (
    cards: [ActivityCardData], observations: [Observation], rewriteSpan: Range<Int>?,
    log: LLMCall
  )

  private struct BatchProviderActions {
    let transcribeScreenshots:
      ([Screenshot], Date, Int64?) async throws -> (observations: [Observation], log: LLMCall)
    let generateActivityCards: ActivityCardsGenerator
    /// Screenshots straight to cards in one call. Only providers that support it set this.
    var generateTimeline:
      (([Screenshot], ActivityGenerationContext, Int64?) async throws -> OneStepTimelineResult)? =
        nil
  }

  /// Claude and ChatGPT run their two-step path through a command-line tool, one frame group
  /// at a time, which takes many minutes per batch.
  private static func hasSlowTwoStepPath(_ provider: LLMProviderID) -> Bool {
    provider == .claude || provider == .chatGPT
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

      var actions = BatchProviderActions(
        transcribeScreenshots: { [weak self] screenshots, batchStartTime, batchId in
          if fallbackState.preferGemma, let gemmaProvider {
            do {
              return try await gemmaProvider.transcribeScreenshots(
                screenshots, batchStartTime: batchStartTime, batchId: batchId)
            } catch {
              // Gemma only runs because Gemini failed, so Gemini's error is the one to report.
              throw fallbackState.geminiFailure ?? error
            }
          }

          do {
            return try await provider.transcribeScreenshots(
              screenshots, batchStartTime: batchStartTime, batchId: batchId)
          } catch {
            guard let gemmaProvider, Self.gemmaCanTakeOver(after: error) else { throw error }
            fallbackState.preferGemma = true
            fallbackState.geminiFailure = error
            self?.logGemmaFallback(operation: "transcribe", error: error, batchId: batchId)
            do {
              return try await gemmaProvider.transcribeScreenshots(
                screenshots, batchStartTime: batchStartTime, batchId: batchId)
            } catch {
              throw fallbackState.geminiFailure ?? error
            }
          }
        },
        generateActivityCards: Self.rewritingWholeWindow {
          [weak self] observations, context, batchId in
          if fallbackState.preferGemma, let gemmaProvider {
            fallbackState.usedGemmaForCardGeneration = true
            do {
              return try await gemmaProvider.generateActivityCards(
                observations: observations, context: context, batchId: batchId)
            } catch {
              throw fallbackState.geminiFailure ?? error
            }
          }

          do {
            return try await provider.generateActivityCards(
              observations: observations, context: context, batchId: batchId)
          } catch {
            guard let gemmaProvider, Self.gemmaCanTakeOver(after: error) else { throw error }
            fallbackState.preferGemma = true
            fallbackState.usedGemmaForCardGeneration = true
            fallbackState.geminiFailure = error
            self?.logGemmaFallback(operation: "generate_cards", error: error, batchId: batchId)
            do {
              return try await gemmaProvider.generateActivityCards(
                observations: observations, context: context, batchId: batchId)
            } catch {
              throw fallbackState.geminiFailure ?? error
            }
          }
        }
      )
      // Only models that handle the one-step prompt (4 Hydrogen) skip the transcript. If the
      // call fails, the batch falls through to the two-step closures above.
      if provider.supportsOneStepTimeline {
        actions.generateTimeline = { screenshots, context, batchId in
          do {
            return try await provider.generateTimeline(
              screenshots: screenshots, context: context, batchId: batchId)
          } catch {
            // An account error such as a usage limit would make LLMService skip Gemini's
            // two-step path, but that path can still finish the batch on Gemma with the same
            // key. Pass it on as a plain failure so the two-step path runs. A bad key or a
            // billing problem stops Gemma too, so those are thrown as they are.
            let kind = TimelineFailureClassifier.classify(error).kind
            guard gemmaProvider != nil, kind.failsEveryRequestToProvider,
              Self.gemmaCanTakeOver(after: error)
            else { throw error }
            fallbackState.geminiFailure = error
            // Gemini's account is the problem, so the two-step path goes straight to Gemma.
            fallbackState.preferGemma = true
            let nsError = error as NSError
            throw NSError(
              domain: "GeminiOneStep", code: nsError.code,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Gemini one-step timeline failed (\(nsError.domain) \(nsError.code))",
                NSUnderlyingErrorKey: error,
              ])
          }
        }
      }
      return (actions: actions, fallbackState: fallbackState)
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
    /// The Gemini error that sent the batch to Gemma. Reported if Gemma fails as well.
    var geminiFailure: Error?
  }

  /// Gemma runs on the same API key as Gemini, so it can't help when the key or its billing is
  /// the problem.
  private static func gemmaCanTakeOver(after error: Error) -> Bool {
    guard !wasInterrupted(error) else { return false }
    switch TimelineFailureClassifier.classify(error).kind {
    case .apiKeyProblem, .accountBlocked, .geoBlocked, .outOfCredits:
      return false
    default:
      return true
    }
  }

  /// True when the call stopped because the Mac is going to sleep or lost its connection, not
  /// because of the provider. Another provider would be cut off the same way, so nothing else
  /// is tried and the batch waits. Being offline doesn't stop a `nextProvider` that runs on
  /// this Mac, so the batch can still go to it.
  private static func wasInterrupted(_ error: Error, nextProvider: LLMProviderID? = nil) -> Bool {
    if Task.isCancelled || error is CancellationError { return true }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
    if let nextProvider, !needsInternet(nextProvider) { return false }
    return !ConnectivityMonitor.shared.isOnline
  }

  /// False for providers that run on this Mac: a local model, or a custom provider whose
  /// address is this Mac (LM Studio or a self-hosted server set up as a custom provider).
  private static func needsInternet(_ provider: LLMProviderID) -> Bool {
    switch provider {
    case .local:
      return false
    case .openAICompatible:
      let host = OpenAICompatiblePreferences.load()?.chatCompletionsURL?.host?.lowercased() ?? ""
      return !["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
    default:
      return true
    }
  }

  /// Gemini's one-step call hides an account error inside a plain one so the two-step path
  /// still runs on Gemma. This gets the real error back for reporting and for the hold.
  private static func realProviderError(_ error: Error) -> Error {
    let nsError = error as NSError
    guard nsError.domain == "GeminiOneStep",
      let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error
    else { return error }
    return underlying
  }

  /// Changes when the user changes how a provider is set up, which lifts a hold on it.
  private func setupSignature(for provider: LLMProviderID) -> String {
    switch provider {
    case .gemini:
      return String((KeychainManager.shared.retrieve(for: "gemini") ?? "").hashValue)
    case .dayflow:
      return String((DayflowAuthManager.storedSessionToken() ?? "").hashValue)
    case .local:
      let model = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? ""
      return "\(localProviderEndpoint())|\(model)"
    case .openAICompatible:
      let key =
        KeychainManager.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider) ?? ""
      return "\(String(describing: OpenAICompatiblePreferences.load()))|\(key.hashValue)"
    case .claude, .chatGPT:
      return ""
    }
  }

  /// Why a batch should not be sent to `provider` right now, or nil when it can be.
  private func waitReason(for provider: LLMProviderID, label: String) async -> BatchHeldError? {
    if Self.needsInternet(provider), !ConnectivityMonitor.shared.isOnline {
      return BatchHeldError(reason: .offline, providerFailureKind: nil, providerLabel: label)
    }
    guard let hold = ProviderHoldStore.shared.hold(for: provider) else { return nil }
    let isReady = await ProviderHoldStore.shared.isReadyForAttempt(
      provider, setupSignature: setupSignature(for: provider))
    guard !isReady else { return nil }
    return BatchHeldError(
      reason: .providerDown, providerFailureKind: hold.kind, providerLabel: label,
      providerName: hold.providerName)
  }

  /// Starts or extends a hold when `error` means every request to `provider` will fail.
  private func holdProviderIfDown(_ provider: LLMProviderID, after error: Error) async {
    let classification = TimelineFailureClassifier.classify(error)
    let kind = classification.kind
    guard kind.failsEveryRequestToProvider else { return }
    let health = await ProviderHealthCheck.check(provider, failureKind: kind)
    let isNewHold = ProviderHoldStore.shared.recordFailure(
      provider: provider,
      kind: kind,
      health: health,
      setupSignature: setupSignature(for: provider),
      providerName: classification.providerName
    )
    guard isNewHold else { return }
    AnalyticsService.shared.capture(
      "provider_hold_started",
      [
        "provider": provider.analyticsName,
        "provider_id": provider.rawValue,
        "failure_kind": kind.rawValue,
        "health_check": health.rawValue,
      ])
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
    onPrimaryFailure: (Error) -> Void,
    work: (TimelineProviderContext) async throws -> T
  ) async throws -> (value: T, activeContext: TimelineProviderContext, usedProviderBackup: Bool) {
    do {
      let value = try await work(activeContext)
      let usingBackup = activeContext.id != primaryContext.id
      return (value, activeContext, usingBackup)
    } catch {
      guard activeContext.id == primaryContext.id, let backupContext,
        !Self.wasInterrupted(error, nextProvider: backupContext.id)
      else {
        throw error
      }
      onPrimaryFailure(error)

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
  ) async {
    // Only interrupt the user for problems they have to fix themselves.
    // Everything else is retried automatically after the next success.
    guard let content = classification.toastContent(fallbackProviderLabel: primaryProviderLabel)
    else { return }

    let backupOffer = await backupProviderToOffer(
      classification: classification, backupConfigured: backupConfigured)

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
      batchId: batchId,
      signInProvider: classification.signInProvider(
        fallbackProviderLabel: primaryProviderLabel)?.rawValue,
      backupOfferProvider: backupOffer?.rawValue
    )
    // How often the card, the notification and the menu bar warning show is decided where
    // they are shown, so a card nobody saw doesn't use up the day's one showing.
    TimelineFailureToastCenter.post(payload)
  }

  /// The other command-line tool (Claude or ChatGPT), when the main one is down, no backup is
  /// set, and the other is installed and signed in on this Mac. The user is asked before it is
  /// used, and is not asked again after saying no.
  private func backupProviderToOffer(
    classification: TimelineFailureClassification, backupConfigured: Bool
  ) async -> LLMProviderID? {
    guard !backupConfigured, classification.kind.failsEveryRequestToProvider,
      !ProviderProblemCenter.backupOfferWasDeclined,
      let primary = try? LLMProviderRoutingStore.load().primary
    else { return nil }

    let other: LLMProviderID
    switch primary {
    case .claude: other = .chatGPT
    case .chatGPT: other = .claude
    default: return nil
    }
    return await ProviderHealthCheck.isReadyToUse(other) ? other : nil
  }

  /// Recorded time from the last 24 hours that failed and is waiting to be retried.
  private func failedRecordingSecondsInLastDay(now: Date = Date()) -> Int {
    let cutoff = Int(now.timeIntervalSince1970) - 24 * 60 * 60
    return StorageManager.shared.allBatches()
      .filter { $0.status == "failed" && $0.start >= cutoff }
      .reduce(0) { total, batch in total + max(0, batch.end - batch.start) }
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
    let run = UUID()
    let task: Task<Void, Never> = Task {
      var holdsTimelineCardGenerationGate = false
      defer {
        if holdsTimelineCardGenerationGate {
          Self.timelineCardGenerationGate.release()
        }
        Self.batchRuns.remove(run)
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
      // The primary provider's error once the batch has moved to the backup provider. If the
      // backup fails too, this is the error the user is told about.
      var primaryFailure: Error?
      // A switch to the backup whose outcome hasn't been reported to analytics yet.
      var pendingFallbackProps: [String: Any]?
      print(
        "🧭 [LLMService] processBatch selected primary=\(primaryProviderID.analyticsName) "
          + "label=\(primaryProviderLabel) backup=\(configuredBackup?.analyticsName ?? "none")"
      )

      do {
        print("\n📦 [LLMService] Processing batch \(batchId)")
        print(
          "   Batch time: \(Date(timeIntervalSince1970: TimeInterval(batchStartTs))) to \(Date(timeIntervalSince1970: TimeInterval(batchEndTs)))"
        )

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

        // A backup that is itself down or unreachable can't take the batch.
        var usableBackupContext = configuredBackupContext
        if let backup = configuredBackupContext,
          await waitReason(for: backup.id, label: backup.providerLabel) != nil
        {
          usableBackupContext = nil
        }

        // Keep the batch away from a primary provider that is known to be down, and from the
        // network while this Mac is offline. The batch starts on the backup when it can run;
        // otherwise it waits, which is not a failure.
        let primaryResult: Result<TimelineProviderContext, Error>
        if let waitError = await waitReason(for: primaryProviderID, label: primaryProviderLabel) {
          guard usableBackupContext != nil else { throw waitError }
          primaryResult = .failure(waitError)
        } else {
          primaryResult = Result { try makeTimelineProviderContext(for: primaryProviderID) }
        }

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

        let startup = try selectTimelineProviderStartup(
          primary: primaryResult,
          backup: usableBackupContext
        )
        if startup.usedProviderBackup,
          let configuredBackup,
          let usableBackupContext,
          let primaryError = startup.primaryInitializationError
        {
          primaryFailure = primaryError
          let props = fallbackProps(
            operation: primaryError is BatchHeldError ? "primary_on_hold" : "initialize_provider",
            batchId: batchId,
            primaryProviderID: primaryProviderID,
            primaryProviderLabel: primaryProviderLabel,
            backupProviderID: configuredBackup,
            backupProviderLabel: usableBackupContext.providerLabel,
            error: primaryError
          )
          AnalyticsService.shared.capture("llm_timeline_fallback_attempted", props)
          pendingFallbackProps = props
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

        // One-step generation: the provider reads the screenshots and writes the cards in a
        // single call. When the primary's call fails the batch goes to the backup provider,
        // which gets its own one-step call. The slower transcribe-then-generate path below is
        // only used when it is worth the wait.
        var oneStepCards: [ActivityCardData]?
        var rewriteSpan: Range<Int>?
        if let generateTimeline = activeContext.actions.generateTimeline {
          lastProcessingStep = .generatingCards
          await MainActor.run {
            progressHandler?(.generatingCards)
          }

          // The call reads and rewrites the recent timeline, so it must not overlap another
          // batch's rewrite.
          await Self.timelineCardGenerationGate.acquire()
          holdsTimelineCardGenerationGate = true

          let oneStepStartedAt = Date()
          var oneStepResult: OneStepTimelineResult?
          do {
            oneStepResult = try await generateTimeline(
              screenshots, makeGenerationContext(batchObservations: []), batchId)
          } catch {
            if Self.wasInterrupted(
              error, nextProvider: usedProviderBackup ? nil : backupContext?.id)
            {
              throw error
            }
            let nsError = error as NSError
            let failureKind = TimelineFailureClassifier.classify(error).kind
            let failedContext = activeContext
            let handsToBackup = !usedProviderBackup && backupContext != nil
            // A usage limit, sign-out or similar account problem fails the two-step calls to
            // the same provider too. Dayflow's sign-in and subscription rejections do as well.
            let isAccountProblem =
              failureKind.failsEveryRequestToProvider
              || (nsError.domain == "DayflowBackend" && [401, 402, 403].contains(nsError.code))
            // Claude's and ChatGPT's two-step path takes many minutes and holds up every batch
            // behind it, so the first failure sets the batch aside to be retried later. The
            // two-step path is only used if the one-step call fails again on that retry.
            let setsBatchAside =
              !handsToBackup && !isAccountProblem
              && Self.hasSlowTwoStepPath(failedContext.id)
              && Self.batchRuns.markOneStepFailed(batchId)
            let nextStep =
              handsToBackup
              ? "backup" : isAccountProblem ? "fail" : setsBatchAside ? "set_aside" : "two_step"
            AnalyticsService.shared.capture(
              "timeline_one_step_fallback",
              [
                "batch_id": batchId,
                "provider": failedContext.id.analyticsName,
                "provider_id": failedContext.id.rawValue,
                "error_domain": nsError.domain,
                "error_code": nsError.code,
                "failure_kind": failureKind.rawValue,
                "skipped_primary_two_step": nextStep != "two_step",
                "next_step": nextStep,
                "latency_ms": Int(Date().timeIntervalSince(oneStepStartedAt) * 1000),
              ])

            if handsToBackup, let backupContext {
              primaryFailure = Self.realProviderError(error)
              let props = fallbackProps(
                operation: "generate_timeline",
                batchId: batchId,
                primaryProviderID: primaryContext.id,
                primaryProviderLabel: primaryContext.providerLabel,
                backupProviderID: backupContext.id,
                backupProviderLabel: backupContext.providerLabel,
                error: error
              )
              AnalyticsService.shared.capture("llm_timeline_fallback_attempted", props)
              pendingFallbackProps = props
              activeContext = backupContext
              usedProviderBackup = true
              print(
                "⚠️ [LLMService] One-step timeline failed for batch \(batchId) on "
                  + "\(primaryContext.providerLabel); using \(backupContext.providerLabel): "
                  + nsError.localizedDescription)

              if let backupTimeline = backupContext.actions.generateTimeline {
                do {
                  oneStepResult = try await backupTimeline(
                    screenshots, makeGenerationContext(batchObservations: []), batchId)
                } catch {
                  // The backup's two-step path is only worth trying when its account works and
                  // the path is quick.
                  let backupKind = TimelineFailureClassifier.classify(error).kind
                  if backupKind.failsEveryRequestToProvider
                    || Self.hasSlowTwoStepPath(backupContext.id)
                  {
                    throw error
                  }
                  print(
                    "⚠️ [LLMService] One-step timeline also failed on "
                      + "\(backupContext.providerLabel) for batch \(batchId), falling back to "
                      + "transcribe + generate: \(error.localizedDescription)")
                }
              }
            } else if isAccountProblem || setsBatchAside {
              throw error
            } else {
              print(
                "⚠️ [LLMService] One-step timeline failed for batch \(batchId), "
                  + "falling back to transcribe + generate: \(nsError.localizedDescription)")
            }
          }

          if let oneStepResult {
            observations = oneStepResult.observations
            StorageManager.shared.saveObservations(batchId: batchId, observations: observations)
            oneStepCards = oneStepResult.cards
            rewriteSpan = oneStepResult.rewriteSpan
            print(
              "🧩 [LLMService] One-step timeline → \(oneStepResult.cards.count) cards, "
                + "\(observations.count) observations")
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
            backupContext: backupContext,
            onPrimaryFailure: { primaryFailure = $0 }
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
            backupContext: backupContext,
            onPrimaryFailure: { primaryFailure = $0 }
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

        Self.batchRuns.clearOneStepFailure(batchId)
        if let pendingFallbackProps {
          AnalyticsService.shared.capture("llm_timeline_fallback_succeeded", pendingFallbackProps)
        }

        // Remember which providers work and which don't, so the next batches go straight to
        // the one that does.
        if usedProviderBackup {
          ProviderHoldStore.shared.clear(activeContext.id)
          if let primaryFailure, !(primaryFailure is BatchHeldError) {
            await holdProviderIfDown(primaryProviderID, after: primaryFailure)
          }
        } else if ProviderHoldStore.shared.clear(primaryProviderID) {
          AnalyticsService.shared.capture(
            "provider_hold_cleared",
            [
              "provider": primaryProviderID.analyticsName,
              "provider_id": primaryProviderID.rawValue,
              "reason": "batch_succeeded",
            ])
        }

        // Whatever the failure card asked the user to fix is working again, unless the backup
        // provider did the work and the primary still needs fixing.
        if !usedProviderBackup {
          TimelineFailureToastCenter.hide()
        }

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

        let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))
        let batchEndDate = Date(timeIntervalSince1970: TimeInterval(batchEndTs))
        let backupProps: [String: Any] = [
          "backup_provider": configuredBackupProviderName as Any,
          "backup_provider_label": configuredBackupProviderLabel as Any,
          "backup_provider_id": configuredBackup?.rawValue as Any,
          "backup_configured": backupConfigured,
        ]

        // A batch that was never sent, or was cut short by sleep or a lost connection, is
        // waiting rather than failed: nothing is wrong that Dayflow can't retry on its own.
        var heldError = error as? BatchHeldError
        let wasNeverSent = heldError != nil
        if heldError == nil {
          // Only a provider that needs the internet is stopped by being offline. A batch that
          // started on such a primary also waits, even if a backup on this Mac failed too, so it
          // keeps its retries for when the internet is back and the primary can take it.
          let lastProvider =
            primaryFailure != nil ? configuredBackup ?? primaryProviderID : primaryProviderID
          let isOffline =
            !ConnectivityMonitor.shared.isOnline
            && (Self.needsInternet(primaryProviderID) || Self.needsInternet(lastProvider))
          if isOffline {
            heldError = BatchHeldError(
              reason: .offline, providerFailureKind: nil, providerLabel: primaryProviderLabel)
          } else if Task.isCancelled
            || ConnectivityMonitor.shared.wasAsleep(since: processingStartTime)
          {
            heldError = BatchHeldError(
              reason: .interrupted, providerFailureKind: nil, providerLabel: primaryProviderLabel)
          }
        }

        if let heldError {
          var props: [String: Any] = [
            "batch_id": batchId,
            "reason": heldError.reason.rawValue,
            "failure_kind": heldError.providerFailureKind?.rawValue as Any,
            "processing_duration_seconds": Int(Date().timeIntervalSince(processingStartTime)),
            "llm_provider": primaryProviderID.analyticsName,
            "llm_provider_label": primaryProviderLabel,
            "provider_id": primaryProviderID.rawValue,
          ]
          props.merge(backupProps) { current, _ in current }
          AnalyticsService.shared.capture(
            wasNeverSent ? "analysis_batch_held" : "analysis_batch_interrupted", props)

          if heldError.reason == .interrupted {
            // The retry that runs when the Mac wakes can come while this batch is still
            // stopping and skip it, so ask for another one once it has stopped.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
              AnalysisManager.shared.catchUpFailedBatches(reason: "interrupted_batch_ended")
            }
          }

          // The row stays "failed" so the retry and catch-up code keeps finding it. The reason
          // and the timeline card are what mark it as waiting.
          StorageManager.shared.updateBatch(
            batchId, status: "failed", reason: heldError.localizedDescription)

          var cardTitle = heldError.cardTitle(providerDisplayName: primaryProviderLabel)
          var cardSummary = heldError.cardSummary
          if let kind = heldError.providerFailureKind {
            let classification = TimelineFailureClassification(
              kind: kind, providerName: heldError.providerName)
            cardTitle = classification.waitingCardTitle(
              fallbackProviderLabel: primaryProviderLabel)
            cardSummary =
              classification.cardMessage(fallbackProviderLabel: primaryProviderLabel)
              + " Your recording is saved."
            // Keep the fix-it card up to date with how much is waiting.
            await emitTimelineFailureToast(
              classification: classification,
              operation: lastProcessingStep,
              error: heldError,
              primaryProvider: primaryProviderID.analyticsName,
              primaryProviderLabel: primaryProviderLabel,
              backupProvider: configuredBackupProviderName,
              backupProviderLabel: configuredBackupProviderLabel,
              backupConfigured: backupConfigured,
              batchId: batchId
            )
          }

          replaceBatchCards(
            with: createStatusCard(
              batchStartTime: batchStartDate,
              batchEndTime: batchEndDate,
              subcategory: cardTitle,
              summary: cardSummary
            ),
            batchId: batchId,
            from: batchStartDate,
            to: batchEndDate
          )
          completion(.failure(heldError))
          return
        }

        // When the backup failed too, the primary provider's error is the one that matters:
        // fixing it is what gets the timeline going again. The backup's error is only used
        // when the primary's needs nothing from the user and the backup's does.
        let backupError: Error? = primaryFailure == nil ? nil : error
        var reportedError = primaryFailure ?? error
        var reportedProviderLabel = primaryProviderLabel
        var failureClassification: TimelineFailureClassification
        if let heldPrimary = primaryFailure as? BatchHeldError {
          if let kind = heldPrimary.providerFailureKind {
            failureClassification = TimelineFailureClassification(
              kind: kind, providerName: heldPrimary.providerName)
          } else {
            failureClassification = TimelineFailureClassifier.classify(error)
            reportedError = error
            reportedProviderLabel = configuredBackupProviderLabel ?? primaryProviderLabel
          }
        } else {
          failureClassification = TimelineFailureClassifier.classify(reportedError)
        }
        if let backupError,
          failureClassification.toastContent(fallbackProviderLabel: reportedProviderLabel) == nil
        {
          let backupClassification = TimelineFailureClassifier.classify(backupError)
          let backupLabel = configuredBackupProviderLabel ?? primaryProviderLabel
          if backupClassification.toastContent(fallbackProviderLabel: backupLabel) != nil {
            failureClassification = backupClassification
            reportedError = backupError
            reportedProviderLabel = backupLabel
          }
        }

        // Track analysis batch failed
        var failedProps: [String: Any] = [
          "batch_id": batchId,
          "failure_kind": failureClassification.kind.rawValue,
          "processing_duration_seconds": Int(Date().timeIntervalSince(processingStartTime)),
          "llm_provider": primaryProviderID.analyticsName,
          "llm_provider_label": primaryProviderLabel,
          "provider_id": primaryProviderID.rawValue,
          "used_provider_backup": backupError != nil,
        ]
        failedProps.merge(backupProps) { current, _ in current }
        if let backupError {
          let backupNSError = backupError as NSError
          failedProps["backup_failure_kind"] =
            TimelineFailureClassifier.classify(backupError).kind.rawValue
          failedProps["backup_error_domain"] = backupNSError.domain
          failedProps["backup_error_code"] = backupNSError.code
        }
        AnalyticsService.shared.capture("analysis_batch_failed", failedProps)

        if var props = pendingFallbackProps {
          let backupNSError = error as NSError
          props["backup_error_domain"] = backupNSError.domain
          props["backup_error_code"] = backupNSError.code
          AnalyticsService.shared.capture("llm_timeline_fallback_failed", props)
        }

        // Stop sending batches to a provider whose account or setup is the problem.
        if let primaryFailure {
          if !(primaryFailure is BatchHeldError) {
            await holdProviderIfDown(primaryProviderID, after: primaryFailure)
          }
          if let configuredBackup {
            await holdProviderIfDown(configuredBackup, after: error)
          }
        } else {
          await holdProviderIfDown(primaryProviderID, after: error)
        }

        // Mark batch as failed. The raw error stays in the batch row for debugging;
        // the user only ever sees the classifier's plain-language copy.
        var failureReason = reportedError.localizedDescription
        if let backupError, (backupError as NSError) != (reportedError as NSError) {
          failureReason += " | backup: \(backupError.localizedDescription)"
        }
        StorageManager.shared.updateBatch(batchId, status: "failed", reason: failureReason)

        await emitTimelineFailureToast(
          classification: failureClassification,
          operation: lastProcessingStep,
          error: reportedError,
          primaryProvider: primaryProviderID.analyticsName,
          primaryProviderLabel: reportedProviderLabel,
          backupProvider: configuredBackupProviderName,
          backupProviderLabel: configuredBackupProviderLabel,
          backupConfigured: backupConfigured,
          batchId: batchId
        )

        // Put a card over the failed time period. A provider that is down gets a waiting card,
        // since the recording is fine and cards appear once the provider is fixed.
        let cardMessage = failureClassification.cardMessage(
          fallbackProviderLabel: reportedProviderLabel)
        let statusCard: TimelineCardShell
        if failureClassification.kind.failsEveryRequestToProvider {
          statusCard = createStatusCard(
            batchStartTime: batchStartDate,
            batchEndTime: batchEndDate,
            subcategory: failureClassification.waitingCardTitle(
              fallbackProviderLabel: reportedProviderLabel),
            summary: "\(cardMessage) Your recording is saved."
          )
        } else {
          statusCard = createErrorCard(
            batchStartTime: batchStartDate,
            batchEndTime: batchEndDate,
            message: cardMessage
          )
        }
        replaceBatchCards(
          with: statusCard, batchId: batchId, from: batchStartDate, to: batchEndDate)

        // Still return failure but with the error card created
        completion(.failure(reportedError))
      }
    }
    Self.batchRuns.add(task, for: run)
  }

  /// Replaces the cards in a batch's time range with one status card. This matches the happy
  /// path and prevents duplicates. A retry can fail after newer batches succeeded, so their
  /// cards stay.
  private func replaceBatchCards(
    with card: TimelineCardShell, batchId: Int64, from start: Date, to end: Date
  ) {
    let (insertedCardIds, deletedVideoPaths) = StorageManager.shared
      .replaceTimelineCardsInRange(
        from: start,
        to: end,
        with: [card],
        batchId: batchId,
        keepingNewerBatchesCardsStartingAfter: start
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
        "✅ Created status card (ID: \(insertedCardIds.first ?? -1)) for batch \(batchId), replacing \(deletedVideoPaths.count) existing cards"
      )
    }
  }

  /// A card for a batch that is waiting rather than failed. The title stays the sentinel the
  /// timeline uses to find cards it can retry; `subcategory` carries what the card shows as
  /// its title, such as "Waiting for Claude".
  private func createStatusCard(
    batchStartTime: Date, batchEndTime: Date, subcategory: String, summary: String
  ) -> TimelineCardShell {
    let failedCard = createErrorCard(
      batchStartTime: batchStartTime, batchEndTime: batchEndTime, message: "")
    return TimelineCardShell(
      startTimestamp: failedCard.startTimestamp,
      endTimestamp: failedCard.endTimestamp,
      category: failedCard.category,
      subcategory: subcategory,
      title: failedCard.title,
      summary: summary,
      detailedSummary: "",
      distractions: nil,
      appSites: nil
    )
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
