//
//  MiniMaxProvider.swift
//  Dayflow
//
//  LLM provider for MiniMax M3 — a multimodal model from MiniMax.
//  Uses the OpenAI-compatible Chat Completions endpoint at https://api.minimax.io/v1.
//  API key is stored in the macOS Keychain (key: "minimax").
//

import AppKit
import Foundation

final class MiniMaxProvider {
  // MARK: - Constants

  /// The default API base URL. Can be overridden in init for tests.
  static let defaultEndpoint = "https://api.minimax.io/v1"

  /// Keychain key for the API key.
  static let keychainKey = "minimax"

  /// The default model identifier for MiniMax M3.
  static let defaultModelId = "MiniMax-M3"

  // MARK: - Stored properties

  let endpoint: String

  /// The current model ID. Read from UserDefaults (key: "llmMiniMaxModelId") if present,
  /// otherwise falls back to `defaultModelId`.
  var savedModelId: String {
    if let m = UserDefaults.standard.string(forKey: "llmMiniMaxModelId"), !m.isEmpty {
      return m
    }
    return Self.defaultModelId
  }

  /// API key loaded from Keychain. May be nil if the user has not yet configured one.
  var apiKey: String? {
    guard let raw = KeychainManager.shared.retrieve(for: Self.keychainKey) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Screenshot interval in seconds. Mirrors `OllamaProvider.screenshotInterval` so
  /// frame-stitching logic in extensions stays consistent.
  let screenshotInterval: TimeInterval = 10

  /// For analytics tracking.
  var providerName: String { "minimax" }

  // MARK: - Init

  init(endpoint: String = MiniMaxProvider.defaultEndpoint) {
    self.endpoint = endpoint
  }

  // MARK: - Helpers (mirrored from OllamaProvider for consistency)

  /// Strip user references from observations to prevent the LLM from using third-person
  /// language. Mirrors the behaviour of `OllamaProvider.stripUserReferences`.
  func stripUserReferences(_ text: String) -> String {
    return text
      .replacingOccurrences(of: "The user", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "A user", with: "", options: .caseInsensitive)
  }

  func logCallDuration(operation: String, duration: TimeInterval, status: Int? = nil) {
    let statusText = status.map { " status=\($0)" } ?? ""
    print("⏱️ [MiniMax] \(operation) \(String(format: "%.2f", duration))s\(statusText)")
  }

  // MARK: - Activity card generation (public entry point)

  func generateActivityCards(
    observations: [Observation],
    context: ActivityGenerationContext,
    batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let callStart = Date()
    var logs: [String] = []

    let sortedObservations = context.batchObservations.sorted { $0.startTs < $1.startTs }

    guard let firstObservation = sortedObservations.first,
      let lastObservation = sortedObservations.last
    else {
      throw NSError(
        domain: "MiniMaxProvider",
        code: 16,
        userInfo: [
          NSLocalizedDescriptionKey: "Cannot generate activity cards: no observations provided"
        ]
      )
    }

    // 1. Generate initial title+summary for these observations.
    let (titleSummary, firstLog) = try await generateTitleAndSummary(
      observations: sortedObservations,
      categories: context.categories,
      batchId: batchId
    )
    logs.append(firstLog)

    let normalizedCategory = normalizeCategory(
      titleSummary.category, categories: context.categories)

    let initialCard = ActivityCardData(
      startTime: formatTimestampForPrompt(firstObservation.startTs),
      endTime: formatTimestampForPrompt(lastObservation.endTs),
      category: normalizedCategory,
      subcategory: "",
      title: titleSummary.title,
      summary: titleSummary.summary,
      detailedSummary: "",
      distractions: nil,
      appSites: titleSummary.appSites
    )

    var allCards = context.existingCards

    // 2. Decide whether to merge with the last existing card.
    if !allCards.isEmpty, let lastExistingCard = allCards.last {
      let lastCardDuration = calculateDurationInMinutes(
        from: lastExistingCard.startTime, to: lastExistingCard.endTime)

      if lastCardDuration >= 40 {
        allCards.append(initialCard)
      } else {
        let gapMinutes = calculateDurationInMinutes(
          from: lastExistingCard.endTime, to: initialCard.startTime)
        if gapMinutes > 5 {
          allCards.append(initialCard)
        } else {
          let candidateDuration = calculateDurationInMinutes(
            from: lastExistingCard.startTime, to: initialCard.endTime)
          if candidateDuration > 60 {
            allCards.append(initialCard)
          } else {
            let (shouldMerge, mergeLog) = try await checkShouldMerge(
              previousCard: lastExistingCard,
              newCard: initialCard,
              batchId: batchId
            )
            logs.append(mergeLog)

            if shouldMerge {
              let (mergedCard, mergeCreateLog) = try await mergeTwoCards(
                previousCard: lastExistingCard,
                newCard: initialCard,
                batchId: batchId
              )

              let mergedDuration = calculateDurationInMinutes(
                from: mergedCard.startTime, to: mergedCard.endTime)

              if mergedDuration > 60 {
                allCards.append(initialCard)
              } else {
                logs.append(mergeCreateLog)
                allCards[allCards.count - 1] = mergedCard
              }
            } else {
              allCards.append(initialCard)
            }
          }
        }
      }
    } else {
      allCards.append(initialCard)
    }

    let totalLatency = Date().timeIntervalSince(callStart)

    let combinedLog = LLMCall(
      timestamp: callStart,
      latency: totalLatency,
      input: "Two-pass activity card generation",
      output: logs.joined(separator: "\n\n---\n\n")
    )

    return (allCards, combinedLog)
  }

  // MARK: - Utility helpers (also mirrored from OllamaProvider)

  private func normalizeCategory(_ raw: String, categories: [LLMCategoryDescriptor]) -> String {
    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return categories.first?.name ?? "" }
    let normalized = cleaned.lowercased()
    if let match = categories.first(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }) {
      return match.name
    }
    if let idle = categories.first(where: { $0.isIdle }) {
      let idleLabels = [
        "idle", "idle time", idle.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      ]
      if idleLabels.contains(normalized) {
        return idle.name
      }
    }
    return categories.first?.name ?? cleaned
  }

  func parseJSONResponse<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      guard let responseString = String(data: data, encoding: .utf8) else {
        throw error
      }
      if let startIndex = responseString.firstIndex(of: "{"),
        let endIndex = responseString.lastIndex(of: "}")
      {
        let jsonSubstring = responseString[startIndex...endIndex]
        if let jsonData = jsonSubstring.data(using: .utf8) {
          return try JSONDecoder().decode(type, from: jsonData)
        }
      }
      throw error
    }
  }

  func formatTimestampForPrompt(_ timestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  private func calculateDurationInMinutes(from startTime: String, to endTime: String) -> Int {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    guard let start = formatter.date(from: startTime),
      let end = formatter.date(from: endTime)
    else {
      return 0
    }

    var duration = end.timeIntervalSince(start)
    if duration < 0 {
      duration += 24 * 60 * 60
    }
    return Int(duration / 60)
  }
}
