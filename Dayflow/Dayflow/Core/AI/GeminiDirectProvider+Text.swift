import Foundation

extension GeminiDirectProvider {
  // MARK: - Text Generation

  func generateText(prompt: String, maxOutputTokens: Int = 8192) async throws
    -> (text: String, log: LLMCall)
  {
    let callStart = Date()

    let generationConfig: [String: Any] = [
      "temperature": 0.7,
      "maxOutputTokens": maxOutputTokens,
    ]

    let requestBody: [String: Any] = [
      "contents": [["parts": [["text": prompt]]]],
      "generationConfig": generationConfig,
    ]

    let maxRetries = 4
    var attempt = 0
    var lastError: Error?
    var modelState = ModelRunState(models: modelPreference.orderedModels)

    while attempt < maxRetries {
      do {
        print("🔄 generateText attempt \(attempt + 1)/\(maxRetries)")
        let activeModel = modelState.current
        let urlWithKey = endpointForModel(activeModel) + "?key=\(apiKey)"

        var request = URLRequest(url: URL(string: urlWithKey)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let requestStart = Date()
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
          throw NSError(
            domain: "GeminiError", code: 9,
            userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
        }
        let requestDuration = Date().timeIntervalSince(requestStart)
        logCallDuration(
          operation: "generateText", duration: requestDuration, status: httpResponse.statusCode)

        if httpResponse.statusCode >= 400 {
          var errorMessage = "HTTP \(httpResponse.statusCode) error"
          if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
          {
            errorMessage = message
          }
          throw NSError(
            domain: "GeminiError", code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let candidates = json["candidates"] as? [[String: Any]],
          let firstCandidate = candidates.first,
          let content = firstCandidate["content"] as? [String: Any],
          let parts = content["parts"] as? [[String: Any]],
          let text = parts.first?["text"] as? String
        else {
          throw NSError(
            domain: "GeminiError", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Failed to parse response"])
        }

        // Success!
        print("✅ generateText succeeded on attempt \(attempt + 1)")
        let log = LLMCall(
          timestamp: callStart,
          latency: Date().timeIntervalSince(callStart),
          input: prompt,
          output: text
        )
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), log)

      } catch {
        lastError = error
        print("❌ generateText attempt \(attempt + 1) failed: \(error.localizedDescription)")

        var appliedFallback = false
        if let nsError = error as NSError?,
          nsError.domain == "GeminiError",
          Self.capacityErrorCodes.contains(nsError.code),
          let transition = modelState.advance()
        {

          appliedFallback = true
          let reason = fallbackReason(for: nsError.code)
          print("↔️ Switching to \(transition.to.rawValue) after \(nsError.code)")

          Task { @MainActor in
            AnalyticsService.shared.capture(
              "llm_model_fallback",
              [
                "provider": "gemini",
                "operation": "generate_text",
                "from_model": transition.from.rawValue,
                "to_model": transition.to.rawValue,
                "reason": reason,
              ])
          }
        }

        if !appliedFallback {
          let strategy = classifyError(error)

          // Check if we should retry
          if strategy == .noRetry || attempt >= maxRetries - 1 {
            print(
              "🚫 Not retrying generateText: strategy=\(strategy), attempt=\(attempt + 1)/\(maxRetries)"
            )
            throw error
          }

          // Apply appropriate delay based on error type
          let delay = delayForStrategy(strategy, attempt: attempt)
          if delay > 0 {
            print(
              "⏳ Waiting \(String(format: "%.1f", delay))s before retry (strategy: \(strategy))")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          }
        }
      }

      attempt += 1
    }

    // Should never reach here, but just in case
    throw lastError
      ?? NSError(
        domain: "GeminiError", code: 999,
        userInfo: [NSLocalizedDescriptionKey: "generateText failed after \(maxRetries) attempts"])
  }

  struct GeminiFileMetadata: Codable {
    let file: GeminiFileInfo
  }

  struct GeminiFileInfo: Codable {
    let displayName: String

    enum CodingKeys: String, CodingKey {
      case displayName = "display_name"
    }
  }

}
