//
//  CardInsight.swift
//  Dayflow
//
//  Surfaces *how* a timeline card was produced — the on-screen observations the
//  model wrote, the reasoning it gave for grouping/labeling, which model ran, and
//  (for the curious) the raw LLM calls. All of this is already persisted per batch
//  (`observations` + `llm_calls`); this just reads it back and shapes it for the UI
//  so users can see the model's thinking and trust the result. Reasoning is parsed
//  best-effort from the logged responses, so it works retroactively on old cards
//  without a schema migration; observations and raw calls are always available.
//

import Foundation

struct CardInsight: Sendable {
  struct Observation: Identifiable, Sendable {
    let id = UUID()
    let time: String
    let text: String
    let screenshotPath: String?
  }

  struct ReasoningStep: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let text: String
  }

  struct RawCall: Identifiable, Sendable {
    let id = UUID()
    let operation: String
    let model: String?
    let provider: String
    let status: String
    let latencyMs: Int?
    let httpStatus: Int?
    let responseBody: String?
  }

  let observations: [Observation]
  let reasoningSteps: [ReasoningStep]
  let model: String?
  let provider: String?
  let rawCalls: [RawCall]

  var isEmpty: Bool {
    observations.isEmpty && reasoningSteps.isEmpty && rawCalls.isEmpty
  }
}

extension CardInsight {
  /// Loads everything captured for the card's source batch. Synchronous DB reads —
  /// call from a background task (see ActivityCard.loadInsight).
  static func load(forBatchId batchId: Int64) -> CardInsight {
    let store = StorageManager.shared
    let rawObs = store.fetchObservations(batchId: batchId)
    let calls = store.fetchLLMCallsForBatches(batchIds: [batchId], limit: 200)

    // Observations: the model's plain-language notes on what was on screen, each
    // paired with a representative screenshot from its time window for a visual.
    let timeFmt = DateFormatter()
    timeFmt.dateFormat = "h:mm a"
    let sortedObs = rawObs.sorted { $0.startTs < $1.startTs }
    let shots: [(ts: Int, path: String)] = {
      guard let lo = sortedObs.first?.startTs, let hi = sortedObs.last?.endTs else { return [] }
      return store.fetchScreenshotsInTimeRange(startTs: lo, endTs: hi)
        .filter { !$0.isDeleted }
        .map { ($0.capturedAt, $0.filePath) }
    }()
    func nearestShot(start: Int, end: Int) -> String? {
      let within = shots.filter { $0.ts >= start && $0.ts <= end }
      let pool = within.isEmpty ? shots : within
      return pool.min { abs($0.ts - start) < abs($1.ts - start) }?.path
    }
    let observations: [Observation] =
      sortedObs.compactMap { obs in
        let text = obs.observation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let when = timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(obs.startTs)))
        return Observation(
          time: when, text: text, screenshotPath: nearestShot(start: obs.startTs, end: obs.endTs))
      }

    // Reasoning: prefer the reasoning persisted on the card at creation time (robust,
    // survives log pruning); fall back to parsing the logged llm_calls for older cards.
    var steps: [(order: Int, step: ReasoningStep)] = []
    let persistedReasoning = store.fetchCardReasoning(batchId: batchId)
    if let persistedReasoning, !persistedReasoning.isEmpty {
      steps.append((0, ReasoningStep(label: label(for: "generate_cards"), text: persistedReasoning)))
    }
    for call in calls where call.status == "success" {
      guard let priority = reasoningPriority(for: call.operation) else { continue }
      // Card-generation reasoning is already covered by the persisted value above.
      if persistedReasoning != nil && priority == 0 { continue }
      guard let assistant = assistantText(from: call.responseBody),
        let reasoning = reasoningField(from: assistant)
      else { continue }
      steps.append((priority, ReasoningStep(label: label(for: call.operation), text: reasoning)))
    }
    // Stable, logical order (group → summary → title → merge); dedupe repeats.
    var seenLabels = Set<String>()
    let reasoningSteps =
      steps
      .sorted { $0.order < $1.order }
      .map { $0.step }
      .filter { seenLabels.insert($0.label).inserted }

    // Which model/provider actually ran (prefer a card-generating step).
    let primary =
      calls.first { $0.operation == "generate_summary" && $0.model != nil }
      ?? calls.first { $0.model != nil }
    let model = primary?.model
    let provider = primary.map { friendlyProvider($0.provider) }

    let rawCalls = calls.map {
      RawCall(
        operation: $0.operation, model: $0.model, provider: friendlyProvider($0.provider),
        status: $0.status, latencyMs: $0.latencyMs, httpStatus: $0.httpStatus,
        responseBody: $0.responseBody)
    }

    return CardInsight(
      observations: observations, reasoningSteps: reasoningSteps,
      model: model, provider: provider, rawCalls: rawCalls)
  }

  // MARK: - Parsing helpers

  /// Best-effort extraction of the model's `reasoning` field from a raw card-generation
  /// response. Handles a bare JSON object, a fenced one, or an OpenAI/Gemini envelope.
  /// Used at card-save time to persist the reasoning alongside the card.
  static func extractReasoning(fromModelResponse raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    if let direct = reasoningField(from: raw) { return direct }
    if let assistant = assistantText(from: raw), let nested = reasoningField(from: assistant) {
      return nested
    }
    return nil
  }

  /// Pulls the assistant's text out of a logged response body (OpenAI-compatible
  /// or Gemini shapes). Returns nil if it doesn't match either.
  private static func assistantText(from responseBody: String?) -> String? {
    guard let body = responseBody, let data = body.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    if let choices = json["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String
    {
      return content
    }
    if let candidates = json["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]]
    {
      let joined = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
      return joined.isEmpty ? nil : joined
    }
    return nil
  }

  /// The assistant text is usually a JSON object containing a `reasoning` string.
  private static func reasoningField(from assistant: String) -> String? {
    let cleaned = stripCodeFence(assistant)
    guard let data = cleaned.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let reasoning = json["reasoning"] as? String
    else { return nil }
    let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func stripCodeFence(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("```") {
      if let firstNewline = t.firstIndex(of: "\n") { t = String(t[t.index(after: firstNewline)...]) }
      if let fenceEnd = t.range(of: "```", options: .backwards) { t = String(t[..<fenceEnd.lowerBound]) }
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func reasoningPriority(for operation: String) -> Int? {
    switch operation {
    case "segment_video_activity", "generate_activity_cards", "generate_cards": return 0
    case "generate_summary": return 1
    case "generate_title": return 2
    case "evaluate_card_merge", "merge_cards": return 3
    default: return nil
    }
  }

  private static func label(for operation: String) -> String {
    switch operation {
    case "segment_video_activity", "generate_activity_cards", "generate_cards":
      return "Grouped the session into activities"
    case "generate_summary": return "Chose the category & wrote the summary"
    case "generate_title": return "Picked the title"
    case "evaluate_card_merge", "merge_cards": return "Decided whether to merge cards"
    default: return operation.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  private static func friendlyProvider(_ raw: String) -> String {
    switch raw.lowercased() {
    case "ollama": return "Local (Ollama)"
    case "lmstudio": return "Local (LM Studio)"
    case "custom": return "Custom endpoint"
    case "geminidirect", "gemini": return "Gemini"
    case "dayflowbackend", "dayflow": return "Dayflow cloud"
    default: return raw
    }
  }
}
