import Foundation

/// Uses ChatGPT's timeline prompts over an OpenAI-compatible HTTP connection.
final class OpenAICompatibleProvider: ChatGPTTimelinePromptSupporting {
  typealias ChatRequest = OllamaProvider.ChatRequest
  typealias MessageContent = OllamaProvider.MessageContent
  typealias Completion = (ChatRequest, String, Int64?) async throws -> String

  private let transport: OllamaProvider
  private let configuration: OpenAICompatibleRuntimeConfiguration
  private let completion: Completion?

  init(configuration: OpenAICompatibleRuntimeConfiguration, completion: Completion? = nil) {
    self.configuration = configuration
    self.transport = OllamaProvider(openAICompatible: configuration)
    self.completion = completion
  }

  func makeRequest(content: [MessageContent]) -> ChatRequest {
    var request = ChatRequest(
      model: configuration.modelID,
      messages: [
        .init(
          role: "system",
          content: [
            .init(
              type: "text", text: "Return only the requested JSON. No commentary.", image_url: nil)
          ]),
        .init(role: "user", content: content),
      ],
      max_tokens: 8000
    )
    // Other compatible endpoints may not accept OpenRouter's reasoning object.
    if URL(string: configuration.endpoint)?.host?.lowercased() == "openrouter.ai" {
      request.reasoning = .init(effort: "low")
    }
    return request
  }

  /// Hosted models reading fifteen screenshots often need more than the transport's 60 seconds.
  private static let requestTimeout: TimeInterval = 180
  private static let maxAttempts = 3
  private static let emptyReplyCode = 2

  /// Only the reply text is read, and any level of it may be missing or null.
  private struct ChatReply: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable {
        let content: String?
      }
      let message: Message?
    }
    let choices: [Choice]?
  }

  /// A reply with no text in it. The wording keeps "Failed to parse response" so failure
  /// handling treats it like any other unusable reply.
  private func emptyReply() -> NSError {
    NSError(
      domain: "OpenAICompatibleProvider", code: Self.emptyReplyCode,
      userInfo: [
        NSLocalizedDescriptionKey: "Failed to parse response: empty reply from the model."
      ])
  }

  /// Sends one request and returns the reply text. Throws when the request fails, the server
  /// answers with an error status (the error code is that status), or the reply is empty.
  private func complete(
    _ request: ChatRequest, operation: String, batchId: Int64?, callGroupId: String, attempt: Int
  ) async throws -> String {
    if let completion {
      let output = try await completion(request, operation, batchId)
      guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw emptyReply()
      }
      return output
    }

    let urlRequest = try transport.makeChatURLRequest(
      request, timeoutInterval: Self.requestTimeout)
    let ctx = LLMCallContext(
      batchId: batchId,
      callGroupId: callGroupId,
      attempt: attempt,
      provider: transport.localEngine,
      providerID: transport.providerID.rawValue,
      model: request.model,
      operation: operation,
      requestMethod: urlRequest.httpMethod,
      requestURL: urlRequest.url,
      requestHeaders: urlRequest.allHTTPHeaderFields,
      // Screenshots stay out of the call log.
      requestBody: operation == "transcribe_screenshots" ? nil : urlRequest.httpBody,
      startedAt: Date()
    )

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: urlRequest)
    } catch {
      let nsError = error as NSError
      LLMLogger.logFailure(
        ctx: ctx, http: nil, finishedAt: Date(), errorDomain: nsError.domain,
        errorCode: nsError.code, errorMessage: nsError.localizedDescription)
      throw error
    }

    let httpResponse = response as? HTTPURLResponse
    let status = httpResponse?.statusCode
    let responseHeaders: [String: String]? = httpResponse?.allHeaderFields.reduce(into: [:]) {
      acc, kv in
      if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
        acc[k] = v.description
      }
    }
    let http = LLMHTTPInfo(httpStatus: status, responseHeaders: responseHeaders, responseBody: data)

    if let status, status != 200 {
      let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
      LLMLogger.logFailure(
        ctx: ctx, http: http, finishedAt: Date(), errorDomain: "OpenAICompatibleProvider",
        errorCode: status, errorMessage: errorBody)
      // Same wording as the shared transport, which failure handling matches by text.
      throw NSError(
        domain: "OpenAICompatibleProvider", code: status,
        userInfo: [
          NSLocalizedDescriptionKey: "Ollama API request failed with status \(status): \(errorBody)"
        ])
    }

    let reply = try? JSONDecoder().decode(ChatReply.self, from: data)
    guard let output = reply?.choices?.first?.message?.content,
      !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      let error = emptyReply()
      LLMLogger.logFailure(
        ctx: ctx, http: http, finishedAt: Date(), errorDomain: error.domain,
        errorCode: error.code, errorMessage: error.localizedDescription)
      throw error
    }
    LLMLogger.logSuccess(ctx: ctx, http: http, finishedAt: Date())
    return output
  }

  /// Whether sending the same request again could work. A 4xx answer (bad key, no credit,
  /// unknown model) will not change; 408 and 429 are the two that ask the caller to retry.
  private static func isWorthResending(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      // A bad or unsupported address is a setup problem; it fails the same way every time.
      return ![NSURLErrorCancelled, NSURLErrorBadURL, NSURLErrorUnsupportedURL]
        .contains(nsError.code)
    }
    guard nsError.domain == "OpenAICompatibleProvider" else { return false }
    return nsError.code == emptyReplyCode || nsError.code == 408 || nsError.code == 429
      || (500...599).contains(nsError.code)
  }

  private func generate<Value>(
    prompt: String, images: [MessageContent] = [], operation: String, batchId: Int64?,
    decode: (String) throws -> Value
  ) async throws -> (Value, LLMCall) {
    let startedAt = Date()
    let callGroupId = UUID().uuidString
    var currentPrompt = prompt
    for attempt in 1...Self.maxAttempts {
      try Task.checkCancellation()
      let request = makeRequest(
        content: [
          .init(type: "text", text: currentPrompt, image_url: nil)
        ] + images)

      let output: String
      do {
        output = try await complete(
          request, operation: operation, batchId: batchId, callGroupId: callGroupId,
          attempt: attempt)
      } catch {
        try Task.checkCancellation()
        if error is CancellationError || attempt == Self.maxAttempts
          || !Self.isWorthResending(error)
        {
          throw error
        }
        // A timeout, network error or empty reply means the model never answered, so there
        // is nothing to correct: send the same request again after a short wait.
        try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
        continue
      }

      do {
        let value = try decode(output)
        return (
          value,
          LLMCall(
            timestamp: startedAt, latency: Date().timeIntervalSince(startedAt),
            input: currentPrompt, output: output)
        )
      } catch {
        if attempt == Self.maxAttempts { throw error }
        // The model answered, but with something unusable. Every HTTP call is independent,
        // so keep the full input on correction attempts.
        currentPrompt =
          prompt + "\n\nPREVIOUS ATTEMPT FAILED. Fix: "
          + error.localizedDescription + "\nReturn the full corrected JSON only."
        try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
      }
    }
    throw invalidOutput("No valid response returned.")
  }

  private func cleanJSON(_ output: String) -> String {
    output.replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func invalidOutput(_ message: String) -> NSError {
    NSError(
      domain: "OpenAICompatibleProvider", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }

  func transcribeScreenshots(
    _ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?
  ) async throws -> (observations: [Observation], log: LLMCall) {
    let sorted = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    guard let first = sorted.first, let last = sorted.last else {
      throw invalidOutput("No screenshots to transcribe.")
    }
    // Include both endpoints and cap the request at 15 images.
    let count = min(15, sorted.count)
    let selected = (0..<count).map { index in
      sorted[count == 1 ? 0 : index * (sorted.count - 1) / (count - 1)]
    }
    let duration = max(1, TimeInterval(last.capturedAt - first.capturedAt))
    var images: [MessageContent] = []
    var validFrameCount = 0
    for screenshot in selected {
      guard let jpeg = screenshot.jpegData(maxHeight: 720, quality: 0.85) else { continue }
      let timestamp = formatSeconds(TimeInterval(screenshot.capturedAt - first.capturedAt))
      images.append(.init(type: "text", text: "Screenshot at \(timestamp):", image_url: nil))
      images.append(
        .init(
          type: "image_url", text: nil,
          image_url: .init(url: "data:image/jpeg;base64,\(jpeg.base64EncodedString())")))
      validFrameCount += 1
    }
    guard validFrameCount > 0 else { throw invalidOutput("No readable screenshots to transcribe.") }
    let prompt = buildScreenshotTranscriptionPrompt(
      numFrames: validFrameCount, duration: formatSeconds(duration),
      startTime: "00:00:00", endTime: formatSeconds(duration),
      frameTiming: "They are in chronological order, each labeled with its actual timestamp.")
    return try await generate(
      prompt: prompt, images: images, operation: "transcribe_screenshots", batchId: batchId
    ) { output in
      let response = try self.transport.parseJSONResponse(
        SegmentMergeResponse.self, from: Data(self.cleanJSON(output).utf8))
      if let error = self.validateSegments(response.segments, duration: duration) {
        throw self.invalidOutput(error)
      }
      return try response.segments.sorted {
        self.parseVideoTimestamp($0.start) < self.parseVideoTimestamp($1.start)
      }.map { segment in
        let description = segment.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
          throw self.invalidOutput("Segment description is empty.")
        }
        let start = max(0, self.parseVideoTimestamp(segment.start))
        let end = min(Int(duration), self.parseVideoTimestamp(segment.end))
        guard end > start else { throw self.invalidOutput("Segment has no duration.") }
        return Observation(
          id: nil, batchId: batchId ?? -1,
          startTs: Int(batchStartTime.timeIntervalSince1970) + start,
          endTs: Int(batchStartTime.timeIntervalSince1970) + end,
          observation: description, metadata: nil, llmModel: self.configuration.modelID,
          createdAt: Date())
      }
    }
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let prompt = buildCardsPrompt(observations: observations, context: context)
    return try await generate(prompt: prompt, operation: "generate_cards", batchId: batchId) {
      output in
      let decoded = try self.transport.parseJSONResponse(
        [ActivityCardData].self, from: Data(self.cleanJSON(output).utf8))
      guard !decoded.isEmpty else { throw self.invalidOutput("No cards returned.") }
      let cards = self.normalizeCards(decoded, descriptors: context.categories)
      let coverage = self.validateTimeCoverage(
        existingCards: context.existingCards, newCards: cards)
      let timeline = self.validateTimeline(cards)
      guard coverage.isValid, timeline.isValid else {
        throw self.invalidOutput(
          [coverage.error, timeline.error].compactMap { $0 }.joined(separator: "\n"))
      }
      return cards
    }
  }

  func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
    try await transport.generateText(prompt: prompt)
  }
}
