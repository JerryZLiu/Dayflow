import Foundation

extension AgentCLISupporting {
  // MARK: - Shared transcription output contract

  func parseSegments(from output: String, stderr: String) throws -> [SegmentMergeResponse
    .Segment]
  {
    // First try parsing without any modifications
    let basicCleaned =
      output
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    var lastDecodeError: String?

    // Strategy 1: Direct decode
    if let data = basicCleaned.data(using: .utf8),
      let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
      !parsed.segments.isEmpty
    {
      return parsed.segments
    }

    // Strategy 2: Array decode
    if let data = basicCleaned.data(using: .utf8),
      let parsed = try? JSONDecoder().decode([SegmentMergeResponse.Segment].self, from: data),
      !parsed.isEmpty
    {
      return parsed
    }

    // Strategy 3: Brace extraction
    if let firstBrace = basicCleaned.firstIndex(of: "{"),
      let lastBrace = basicCleaned.lastIndex(of: "}"),
      firstBrace < lastBrace
    {
      let slice = String(basicCleaned[firstBrace...lastBrace])
      if let data = slice.data(using: .utf8),
        let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
        !parsed.segments.isEmpty
      {
        return parsed.segments
      }
    }

    // Strategy 4 (fallback): Strip OSC escapes and retry brace extraction
    let oscCleaned = stripOSCEscapes(basicCleaned)
    if let firstBrace = oscCleaned.firstIndex(of: "{"),
      let lastBrace = oscCleaned.lastIndex(of: "}"),
      firstBrace < lastBrace
    {
      let slice = String(oscCleaned[firstBrace...lastBrace])
      if let data = slice.data(using: .utf8) {
        do {
          let parsed = try JSONDecoder().decode(SegmentMergeResponse.self, from: data)
          if !parsed.segments.isEmpty { return parsed.segments }
        } catch {
          lastDecodeError = "Strategy 4 (OSC strip + brace): \(error.localizedDescription)"
        }
      }
    } else {
      lastDecodeError = "No JSON object found in output"
    }

    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let failureReason: String
    if trimmedOutput.isEmpty {
      failureReason = "empty_output"
    } else if lastDecodeError == "No JSON object found in output" {
      failureReason = "missing_json_object"
    } else {
      failureReason = "invalid_json"
    }

    var decodeProperties: [String: Any] = [
      "provider": "chat_cli",
      "provider_id": providerID.rawValue,
      "operation": "parse_segments",
      "tool": cliTool.rawValue,
      "failure_reason": failureReason,
    ]
    decodeProperties.merge(
      TelemetryErrorSanitizer.failureOutputProperties(output, prefix: "output")
    ) { _, new in new }
    decodeProperties.merge(
      TelemetryErrorSanitizer.failureOutputProperties(stderr, prefix: "stderr")
    ) { _, new in new }
    AnalyticsService.shared.capture("llm_decode_failed", decodeProperties)

    // Surface CLI error messages to the user if available
    if let cliError = extractCLIError(stdout: output, stderr: stderr) {
      throw NSError(domain: "ChatCLI", code: -33, userInfo: [NSLocalizedDescriptionKey: cliError])
    }

    throw NSError(
      domain: "ChatCLI", code: -31,
      userInfo: [NSLocalizedDescriptionKey: "Failed to decode segments JSON"])
  }

}
