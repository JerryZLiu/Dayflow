//
//  ApfelProvider.swift
//  Dayflow
//
//  Fully on-device LLM provider:
//  – Screenshot transcription via Apple Vision OCR (AppleOCRTranscriber)
//  – Activity-card generation via Apple Intelligence (ApfelLanguageModel)
//
//  Requires macOS 26+ with Apple Intelligence enabled. The factory
//  `makeIfAvailable()` returns nil on unsupported platforms so callers
//  can surface a friendly error.
//

import Foundation

final class ApfelProvider {
  private let ocr: AppleOCRTranscriber
  private let languageModel: ApfelLanguageModel

  init(ocr: AppleOCRTranscriber = AppleOCRTranscriber(), languageModel: ApfelLanguageModel = ApfelLanguageModel()) {
    self.ocr = ocr
    self.languageModel = languageModel
  }

  /// Returns nil if Apple Intelligence is not runtime-available on this device.
  static func makeIfAvailable() -> ApfelProvider? {
    guard ApfelLanguageModel.availability.isAvailable else { return nil }
    return ApfelProvider()
  }

  // MARK: - BatchProviderActions surface

  func transcribeScreenshots(
    _ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?
  ) async throws -> (observations: [Observation], log: LLMCall) {
    try await ocr.transcribe(
      screenshots: screenshots, batchStartTime: batchStartTime, batchId: batchId)
  }

  func generateActivityCards(
    observations: [Observation],
    context: ActivityGenerationContext,
    batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let callStart = Date()
    let sorted = context.batchObservations.sorted { $0.startTs < $1.startTs }
    guard let firstObs = sorted.first, let lastObs = sorted.last else {
      throw NSError(
        domain: "ApfelProvider", code: 20,
        userInfo: [NSLocalizedDescriptionKey: "No observations provided for card generation"])
    }

    let prompt = buildCardPrompt(observations: sorted, context: context)
    let systemInstructions = cardSystemInstructions()

    let rawResponse = try await languageModel.generate(
      prompt: prompt, systemInstructions: systemInstructions)
    let cleaned = stripCodeFences(rawResponse)
    let parsedCards = try decodeCards(
      cleaned,
      fallbackStart: firstObs.startTs,
      fallbackEnd: lastObs.endTs,
      categories: context.categories
    )

    let latency = Date().timeIntervalSince(callStart)
    let log = LLMCall(
      timestamp: callStart,
      latency: latency,
      input: prompt,
      output: rawResponse
    )
    return (parsedCards, log)
  }

  func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
    let callStart = Date()
    let response = try await languageModel.generate(prompt: prompt)
    let latency = Date().timeIntervalSince(callStart)
    let log = LLMCall(
      timestamp: callStart, latency: latency, input: prompt, output: response)
    return (response, log)
  }

  // MARK: - Prompt building

  private func cardSystemInstructions() -> String {
    """
    You are Dayflow, a local activity timeline assistant running entirely \
    on-device. You receive OCR-derived observations of a user's screen over \
    a time window and summarize them into activity cards. Output is \
    consumed by a program, so it must be strict JSON that matches the \
    requested schema exactly. Never invent activities outside the given \
    observations. Pick categories only from the provided list.
    """
  }

  private func buildCardPrompt(
    observations: [Observation], context: ActivityGenerationContext
  ) -> String {
    var out = ""
    out += "# Task\n"
    out += "Summarize the observations below into one or more activity cards.\n\n"

    out += "# Allowed categories\n"
    if context.categories.isEmpty {
      out += "- Work\n- Personal\n- Other\n"
    } else {
      for category in context.categories {
        if let description = category.description, !description.isEmpty {
          out += "- \(category.name): \(description)\n"
        } else {
          out += "- \(category.name)\n"
        }
      }
    }
    out += "\n"

    if !context.existingCards.isEmpty {
      out += "# Existing cards in window (for continuity; do not duplicate)\n"
      for card in context.existingCards.suffix(6) {
        out += "- [\(card.startTime) - \(card.endTime)] \(card.category) • \(card.title)\n"
      }
      out += "\n"
    }

    out += "# Observations (start → end: OCR text)\n"
    for obs in observations {
      let start = formatTimestamp(obs.startTs)
      let end = formatTimestamp(obs.endTs)
      let text = obs.observation
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "  ", with: " ")
      out += "\(start) → \(end): \(text)\n"
    }
    out += "\n"

    out += """
      # Output format
      Return ONLY a JSON array. No prose. No code fences. Each element is:
      {
        "startTime": "h:mm AM/PM",
        "endTime": "h:mm AM/PM",
        "category": "<one of the allowed categories>",
        "subcategory": "<short string, can be empty>",
        "title": "<≤ 6 words>",
        "summary": "<one sentence>",
        "detailedSummary": "<2-3 sentences, may be empty>"
      }
      Merge adjacent observations that describe the same activity. Do not \
      emit cards that end after the last observation ends.
      """
    return out
  }

  // MARK: - Response parsing

  private struct RawCard: Decodable {
    let startTime: String?
    let endTime: String?
    let category: String?
    let subcategory: String?
    let title: String?
    let summary: String?
    let detailedSummary: String?
  }

  private func decodeCards(
    _ text: String,
    fallbackStart: Int,
    fallbackEnd: Int,
    categories: [LLMCategoryDescriptor]
  ) throws -> [ActivityCardData] {
    let jsonSlice = extractJSONArray(from: text) ?? text
    guard let data = jsonSlice.data(using: .utf8) else {
      throw NSError(
        domain: "ApfelProvider", code: 21,
        userInfo: [NSLocalizedDescriptionKey: "Model response was not valid UTF-8"])
    }

    let raw: [RawCard]
    do {
      raw = try JSONDecoder().decode([RawCard].self, from: data)
    } catch {
      throw NSError(
        domain: "ApfelProvider", code: 22,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Model did not return a JSON array of cards: \(error.localizedDescription)"
        ])
    }

    let fallbackStartStr = formatTimestamp(fallbackStart)
    let fallbackEndStr = formatTimestamp(fallbackEnd)
    let categoryNames = Set(categories.map { $0.name })

    let result: [ActivityCardData] = raw.map { card in
      let rawCategory = card.category ?? categories.first?.name ?? "Other"
      let category =
        categoryNames.contains(rawCategory) ? rawCategory : (categories.first?.name ?? "Other")
      return ActivityCardData(
        startTime: card.startTime ?? fallbackStartStr,
        endTime: card.endTime ?? fallbackEndStr,
        category: category,
        subcategory: card.subcategory ?? "",
        title: card.title ?? "Activity",
        summary: card.summary ?? "",
        detailedSummary: card.detailedSummary ?? "",
        distractions: nil,
        appSites: nil
      )
    }
    return result
  }

  /// Find the first balanced `[ ... ]` span in the string. Apple Intelligence
  /// tends to return pure JSON when asked, but this is cheap insurance against
  /// stray prose or markdown.
  private func extractJSONArray(from text: String) -> String? {
    guard let start = text.firstIndex(of: "[") else { return nil }
    var depth = 0
    var idx = start
    while idx < text.endIndex {
      let ch = text[idx]
      if ch == "[" { depth += 1 }
      if ch == "]" {
        depth -= 1
        if depth == 0 {
          return String(text[start...idx])
        }
      }
      idx = text.index(after: idx)
    }
    return nil
  }

  private func stripCodeFences(_ text: String) -> String {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("```") {
      if let newlineIdx = s.firstIndex(of: "\n") {
        s = String(s[s.index(after: newlineIdx)...])
      }
    }
    if s.hasSuffix("```") {
      s = String(s.dropLast(3))
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func formatTimestamp(_ ts: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }
}
