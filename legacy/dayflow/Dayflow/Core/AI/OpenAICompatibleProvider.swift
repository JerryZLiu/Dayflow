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

  private func complete(_ request: ChatRequest, operation: String, batchId: Int64?) async throws
    -> String
  {
    if let completion { return try await completion(request, operation, batchId) }
    let response = try await transport.callChatAPI(
      request, operation: operation, batchId: batchId, maxRetries: 1)
    return response.choices.first?.message.content ?? ""
  }

  private func generate<Value>(
    prompt: String, images: [MessageContent] = [], operation: String, batchId: Int64?,
    decode: (String) throws -> Value
  ) async throws -> (Value, LLMCall) {
    let startedAt = Date()
    var currentPrompt = prompt
    for attempt in 1...3 {
      try Task.checkCancellation()
      do {
        let request = makeRequest(
          content: [
            .init(type: "text", text: currentPrompt, image_url: nil)
          ] + images)
        let output = try await complete(request, operation: operation, batchId: batchId)
        let value = try decode(output)
        return (
          value,
          LLMCall(
            timestamp: startedAt, latency: Date().timeIntervalSince(startedAt),
            input: currentPrompt, output: output)
        )
      } catch {
        try Task.checkCancellation()
        if error is CancellationError || attempt == 3 { throw error }
        // Every HTTP call is independent, so keep the full input on correction attempts.
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
