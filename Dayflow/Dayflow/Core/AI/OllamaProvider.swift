//
//  OllamaProvider.swift
//  Dayflow
//

import AppKit
import Foundation

final class OllamaProvider {
  let endpoint: String
  let screenshotInterval: TimeInterval = 10  // seconds between screenshots
  // Read persisted local settings
  var savedModelId: String {
    if let m = UserDefaults.standard.string(forKey: "llmLocalModelId"), !m.isEmpty {
      return m
    }
    // Fallback to a sensible default
    let engine: LocalEngine = isLMStudio ? .lmstudio : .ollama
    return LocalModelPreferences.defaultModelId(for: engine)
  }
  var isLMStudio: Bool {
    (UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama") == "lmstudio"
  }
  var isCustomEngine: Bool {
    (UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama") == "custom"
  }
  var customAPIKey: String? {
    let trimmed =
      UserDefaults.standard.string(forKey: "llmLocalAPIKey")?.trimmingCharacters(
        in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  // Get the actual local engine type for analytics tracking
  var localEngine: String {
    UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
  }

  init(endpoint: String = "http://localhost:1234") {
    self.endpoint = endpoint
  }

  // Strip user references from observations to prevent LLM from using third-person language
  // For some reason, even after adding negative prompts during observation generation,
  // it still generates text with "a user" and "the user", which poisons the context
  // for the summary prompt and makes it more likely to write in 3rd person.
  // TODO: Remove this when observation generation is fixed upstream
  func stripUserReferences(_ text: String) -> String {
    return
      text
      .replacingOccurrences(of: "The user", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "A user", with: "", options: .caseInsensitive)
  }

  func logCallDuration(operation: String, duration: TimeInterval, status: Int? = nil) {
    let statusText = status.map { " status=\($0)" } ?? ""
    print("⏱️ [\(localEngine)] \(operation) \(String(format: "%.2f", duration))s\(statusText)")
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let callStart = Date()
    var logs: [String] = []

    let sortedObservations = context.batchObservations.sorted { $0.startTs < $1.startTs }

    guard let firstObservation = sortedObservations.first,
      let lastObservation = sortedObservations.last
    else {
      throw NSError(
        domain: "OllamaProvider",
        code: 16,
        userInfo: [
          NSLocalizedDescriptionKey: "Cannot generate activity cards: no observations provided"
        ]
      )
    }

    // Generate initial activity card for these observations
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

    // Check if we should merge with the last existing card
    if !allCards.isEmpty, let lastExistingCard = allCards.last {
      // Hard cap: Don't even try to merge if the last card is already 25+ minutes
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
                // Replace the last card with the merged version
                allCards[allCards.count - 1] = mergedCard
              }
            } else {
              // Add as new card
              allCards.append(initialCard)
            }
          }
        }
      }
    } else {
      // No existing cards, just add the initial card
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
    // First try direct parsing
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      // Try to extract JSON from the response
      guard let responseString = String(data: data, encoding: .utf8) else {
        throw error
      }

      // Look for JSON object
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

    // Handle day boundary - if end is before start, assume it's the next day
    if duration < 0 {
      duration += 24 * 60 * 60  // Add 24 hours in seconds
    }

    return Int(duration / 60)
  }
}
