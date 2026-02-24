import Foundation

struct DebugLogFormatter {
  static func makeLog(
    timeline: [TimelineCardDebugEntry], llmCalls: [LLMCallDebugEntry],
    batches: [AnalysisBatchDebugEntry]
  ) -> String {
    var sections: [String] = []

    let timestampFormatter = DateFormatter()
    timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    timestampFormatter.timeZone = .current

    if timeline.isEmpty {
      sections.append("--- Timeline cards: none ---")
    } else {
      var lines: [String] = []
      lines.append("--- Timeline cards (latest \(timeline.count)) ---")

      for (index, card) in timeline.enumerated() {
        let created = card.createdAt.map { timestampFormatter.string(from: $0) } ?? "unknown"
        var header = "\(index + 1). [\(card.day)] \(card.startTime)-\(card.endTime)"
        if !card.title.isEmpty {
          header += " | \(card.title)"
        }
        header += " | \(card.category)"
        if let sub = card.subcategory, !sub.isEmpty {
          header += " / \(sub)"
        }
        header += " | created \(created)"
        lines.append(header)

        if let summary = cleaned(card.summary), !summary.isEmpty {
          lines.append("   Summary: \(summary)")
        }
        if let details = cleaned(card.detailedSummary), !details.isEmpty,
          details != cleaned(card.summary)
        {
          lines.append("   Details: \(details)")
        }
      }
      sections.append(lines.joined(separator: "\n"))
    }

    if llmCalls.isEmpty {
      sections.append("--- LLM calls: none ---")
    } else {
      var lines: [String] = []
      lines.append("--- LLM calls (latest \(llmCalls.count)) ---")

      for (index, call) in llmCalls.enumerated() {
        let created = call.createdAt.map { timestampFormatter.string(from: $0) } ?? "unknown"
        var parts: [String] = [created, call.provider]
        if let model = call.model, !model.isEmpty {
          parts.append(model)
        }
        parts.append(call.operation)
        parts.append(call.status)
        if let latency = call.latencyMs {
          parts.append("\(latency)ms")
        }
        if let http = call.httpStatus {
          parts.append("HTTP \(http)")
        }

        let line = "\(index + 1). " + parts.joined(separator: " | ")
        lines.append(line)

        var context: [String] = []
        if let batch = call.batchId {
          context.append("batch \(batch)")
        }
        if let group = call.callGroupId, !group.isEmpty {
          context.append("group \(group)")
        }
        if call.attempt > 1 {
          context.append("attempt \(call.attempt)")
        }
        if !context.isEmpty {
          lines.append("   " + context.joined(separator: ", "))
        }

        if let method = call.requestMethod, !method.isEmpty {
          let urlText = call.requestURL ?? ""
          lines.append("   \(method) \(urlText)")
        } else if let urlText = call.requestURL, !urlText.isEmpty {
          lines.append("   URL: \(urlText)")
        }

        if let error = cleaned(call.errorMessage), !error.isEmpty {
          lines.append("   Error: \(error)")
        }

        if let request = formatPayload(call.requestBody) {
          lines.append(contentsOf: block(label: "Request", body: request))
        }
        if let response = formatPayload(call.responseBody) {
          lines.append(contentsOf: block(label: "Response", body: response))
        }
      }
      sections.append(lines.joined(separator: "\n"))
    }

    if batches.isEmpty {
      sections.append("--- Analysis batches: none ---")
    } else {
      var lines: [String] = []
      lines.append("--- Analysis batches (latest \(batches.count)) ---")

      for (index, batch) in batches.enumerated() {
        let created = batch.createdAt.map { timestampFormatter.string(from: $0) } ?? "unknown"
        let start = Date(timeIntervalSince1970: TimeInterval(batch.startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(batch.endTs))
        let startString = timestampFormatter.string(from: start)
        let endString = timestampFormatter.string(from: end)
        lines.append("\(index + 1). id=\(batch.id) | status=\(batch.status) | created \(created)")
        lines.append("   window: \(startString) → \(endString)")
        if let reason = cleaned(batch.reason) {
          lines.append("   reason: \(reason)")
        }
      }

      sections.append(lines.joined(separator: "\n"))
    }

    return sections.joined(separator: "\n\n")
  }

  private static func block(label: String, body: String) -> [String] {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let lines = trimmed.components(separatedBy: CharacterSet.newlines)
    var output: [String] = ["   \(label):"]
    for line in lines {
      output.append("      \(line)")
    }
    return output
  }

  private static func formatPayload(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let data = trimmed.data(using: .utf8) else { return trimmed }

    if let jsonObject = try? JSONSerialization.jsonObject(with: data),
      JSONSerialization.isValidJSONObject(jsonObject),
      let prettyData = try? JSONSerialization.data(
        withJSONObject: jsonObject, options: [.prettyPrinted]),
      let prettyString = String(data: prettyData, encoding: .utf8)
    {
      return prettyString
    }

    return trimmed
  }

  private static func cleaned(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    let components = value.components(separatedBy: .whitespacesAndNewlines)
    let trimmed = components.filter { !$0.isEmpty }.joined(separator: " ")
    return trimmed.isEmpty ? nil : trimmed
  }
}
