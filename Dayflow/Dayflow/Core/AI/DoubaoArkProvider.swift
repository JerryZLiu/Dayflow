//
//  DoubaoArkProvider.swift
//  Dayflow
//

import Foundation

// MARK: - Volcengine Ark / Doubao (OpenAI-compatible)

enum ArkEndpointUtilities {
  /// Builds a chat-completions endpoint URL from a user-provided Ark base URL.
  /// Ark commonly uses `https://ark.cn-beijing.volces.com/api/v3`.
  static func chatCompletionsURL(baseURL: String) -> URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard var components = URLComponents(string: trimmed) else { return nil }

    var normalizedPath = sanitize(components.path)
    let targetCandidates = [
      "/api/v3/chat/completions",
      "/v3/chat/completions",
      "/v1/chat/completions",
    ]
    if targetCandidates.contains(where: { normalizedPath.hasSuffix($0) }) {
      components.path = normalizedPath
      return components.url
    }

    if normalizedPath.isEmpty || normalizedPath == "/" {
      normalizedPath = "/api/v3/chat/completions"
    } else if normalizedPath.hasSuffix("/api/v3") || normalizedPath.hasSuffix("/v3")
      || normalizedPath.hasSuffix("/v1")
    {
      normalizedPath.append(contentsOf: "/chat/completions")
    } else {
      // If the user gave an Ark URL that already includes the version path in the middle, we can't safely normalize.
      // Best effort: append /chat/completions.
      if normalizedPath.hasSuffix("/chat") {
        normalizedPath.append(contentsOf: "/completions")
      } else {
        normalizedPath.append(contentsOf: "/chat/completions")
      }
    }

    if !normalizedPath.hasPrefix("/") {
      normalizedPath = "/" + normalizedPath
    }
    components.path = sanitize(normalizedPath)
    return components.url
  }

  private static func sanitize(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    var normalized = path
    while normalized.contains("//") {
      normalized = normalized.replacingOccurrences(of: "//", with: "/")
    }
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }
}

final class DoubaoArkProvider {
  private let apiKey: String
  private let endpoint: String
  private let modelId: String

  init(
    apiKey: String, endpoint: String = "https://ark.cn-beijing.volces.com/api/v3",
    modelId: String = "doubao-seed-1-6-flash-250828"
  ) {
    self.apiKey = apiKey
    self.endpoint = endpoint
    self.modelId = modelId
  }

  // MARK: - API types

  private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxTokens: Int?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
      case model
      case messages
      case temperature
      case maxTokens = "max_tokens"
      case responseFormat = "response_format"
    }
  }

  private struct ResponseFormat: Encodable {
    let type: String
    let jsonSchema: JSONSchema

    enum CodingKeys: String, CodingKey {
      case type
      case jsonSchema = "json_schema"
    }
  }

  private struct AnyCodable: Codable {
    let value: Any

    init<T>(_ value: T?) {
      self.value = value ?? ()
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self.value = ()
      } else if let bool = try? container.decode(Bool.self) {
        self.value = bool
      } else if let int = try? container.decode(Int.self) {
        self.value = int
      } else if let double = try? container.decode(Double.self) {
        self.value = double
      } else if let string = try? container.decode(String.self) {
        self.value = string
      } else if let array = try? container.decode([AnyCodable].self) {
        self.value = array.map { $0.value }
      } else if let dictionary = try? container.decode([String: AnyCodable].self) {
        self.value = dictionary.mapValues { $0.value }
      } else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "AnyCodable value cannot be decoded")
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch value {
      case is Void:
        try container.encodeNil()
      case let bool as Bool:
        try container.encode(bool)
      case let int as Int:
        try container.encode(int)
      case let double as Double:
        try container.encode(double)
      case let string as String:
        try container.encode(string)
      case let array as [Any]:
        try container.encode(array.map { AnyCodable($0) })
      case let dictionary as [String: Any]:
        try container.encode(dictionary.mapValues { AnyCodable($0) })
      default:
        throw EncodingError.invalidValue(
          value,
          EncodingError.Context(
            codingPath: container.codingPath, debugDescription: "AnyCodable value cannot be encoded"
          ))
      }
    }
  }

  private struct JSONSchema: Encodable {
    let name: String
    let schema: [String: Any]
    let strict: Bool

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(name, forKey: .name)
      try container.encode(strict, forKey: .strict)

      // Ark expects an object for `schema` (not a JSON string).
      // AnyCodable handles serializing the hardcoded schema dictionary.
      try container.encode(AnyCodable(schema), forKey: .schema)
    }

    init(name: String, schema: [String: Any], strict: Bool) {
      self.name = name
      self.schema = schema
      self.strict = strict
    }

    enum CodingKeys: String, CodingKey {
      case name, schema, strict
    }
  }

  private struct ChatMessage: Codable {
    let role: String
    let content: ChatMessageContent
  }

  private enum ChatMessageContent: Codable {
    case text(String)
    case parts([ChatContentPart])

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .text(let value):
        try container.encode(value)
      case .parts(let parts):
        try container.encode(parts)
      }
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let str = try? container.decode(String.self) {
        self = .text(str)
        return
      }
      if let parts = try? container.decode([ChatContentPart].self) {
        self = .parts(parts)
        return
      }
      throw DecodingError.typeMismatch(
        ChatMessageContent.self,
        DecodingError.Context(
          codingPath: decoder.codingPath, debugDescription: "Unsupported content shape")
      )
    }
  }

  private struct ChatContentPart: Codable {
    let type: String
    let text: String?
    let imageURL: ImageURL?
    let videoURL: VideoURL?

    enum CodingKeys: String, CodingKey {
      case type
      case text
      case imageURL = "image_url"
      case videoURL = "video_url"
    }

    struct ImageURL: Codable {
      let url: String
    }

    struct VideoURL: Codable {
      let url: String
      let fps: Double?
    }

    static func text(_ value: String) -> ChatContentPart {
      ChatContentPart(type: "text", text: value, imageURL: nil, videoURL: nil)
    }

    static func imageDataURL(_ url: String) -> ChatContentPart {
      ChatContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: url), videoURL: nil)
    }

    static func videoDataURL(_ url: String, fps: Double?) -> ChatContentPart {
      ChatContentPart(
        type: "video_url", text: nil, imageURL: nil, videoURL: VideoURL(url: url, fps: fps))
    }
  }

  private struct ChatCompletionResponse: Codable {
    struct Choice: Codable {
      struct Message: Codable {
        let content: String?
      }
      let message: Message
    }

    struct APIError: Codable {
      let message: String?
      let type: String?
      let code: String?
    }

    let choices: [Choice]?
    let error: APIError?
  }

  // MARK: - Public

  func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
    let callStart = Date()
    let output = try await callChatCompletions(
      messages: [ChatMessage(role: "user", content: .text(prompt))],
      operation: "generate_text",
      batchId: nil,
      includeRequestBodyInLog: true
    )
    let log = LLMCall(
      timestamp: callStart, latency: Date().timeIntervalSince(callStart), input: prompt,
      output: output)
    return (output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), log)
  }

  func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?)
    async throws -> (observations: [Observation], log: LLMCall)
  {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "DoubaoProvider", code: 12,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
    }

    let callStart = Date()
    let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

    // Match GeminiDirectProvider's timelapse model:
    // - Use a compressed timeline where each screenshot becomes 1 second of video.
    // - Expand model timestamps back into real time using ScreenshotConfig.interval.
    let compressionFactor = ScreenshotConfig.interval
    let compressedVideoDuration = TimeInterval(sortedScreenshots.count)

    // Save a temporary MP4 (same pipeline as Gemini uses, but we send it directly to Ark).
    let fileManager = FileManager.default
    let tempURL = fileManager.temporaryDirectory
      .appendingPathComponent("doubao_batch_\(batchId ?? 0)_\(UUID().uuidString).mp4")
    defer { try? fileManager.removeItem(at: tempURL) }

    do {
      let videoService = VideoProcessingService()
      try await videoService.generateVideoFromScreenshots(
        screenshots: sortedScreenshots,
        outputURL: tempURL,
        fps: 1,
        useCompressedTimeline: true
      )
    } catch {
      throw NSError(
        domain: "DoubaoProvider", code: 11,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Failed to composite screenshots into video: \(error.localizedDescription)"
        ])
    }

    let videoData = try Data(contentsOf: tempURL)
    let videoDataURL = "data:video/mp4;base64,\(videoData.base64EncodedString())"

    // Format compressed video duration EXACTLY like GeminiDirectProvider.
    let durationMinutes = Int(compressedVideoDuration / 60)
    let durationSeconds = Int(compressedVideoDuration.truncatingRemainder(dividingBy: 60))
    let durationString = String(format: "%02d:%02d", durationMinutes, durationSeconds)

    let finalTranscriptionPrompt = LLMPromptTemplates.screenRecordingTranscriptionPrompt(
      durationString: durationString, schema: LLMSchema.screenRecordingTranscriptionSchema)

    let maxRetries = 3
    var attempt = 0
    var lastError: Error?
    let callGroupId = UUID().uuidString

    while attempt < maxRetries {
      do {
        let parts: [ChatContentPart] = [
          .text(finalTranscriptionPrompt),
          .videoDataURL(videoDataURL, fps: 1),
        ]

        let output = try await callChatCompletions(
          messages: [ChatMessage(role: "user", content: .parts(parts))],
          operation: "transcribe_screenshots",
          batchId: batchId,
          attempt: attempt + 1,
          callGroupId: callGroupId,
          includeRequestBodyInLog: false,
          schema: (
            name: "screen_recording_transcription",
            definition: LLMSchema.screenRecordingTranscriptionSchema
          )
        )

        let transcripts = try LLMTranscriptUtilities.decodeTranscriptChunks(
          from: output, allowBracketFallback: true)

        // Convert transcripts to observations, expanding compressed video timestamps back into real time.
        let conversion = LLMTranscriptUtilities.observations(
          from: transcripts,
          batchStartTime: batchStartTime,
          observationBatchId: batchId ?? 0,  // Use real batchId when provided; 0 is a safe placeholder.
          llmModel: modelId,
          compressedVideoDuration: compressedVideoDuration,
          compressionFactor: compressionFactor,
          tolerance: 10.0
        )
        let observations = conversion.observations

        if conversion.invalidTimestampCount > 0 {
          throw NSError(
            domain: "DoubaoProvider", code: 100,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Model generated observations with timestamps exceeding video duration. Video is \(durationString) long but observations extended beyond this."
            ])
        }

        if observations.isEmpty {
          throw NSError(
            domain: "DoubaoProvider", code: 101,
            userInfo: [
              NSLocalizedDescriptionKey:
                "No valid observations generated after filtering out invalid timestamps"
            ])
        }

        let log = LLMCall(
          timestamp: callStart, latency: Date().timeIntervalSince(callStart),
          input: finalTranscriptionPrompt, output: output)
        return (observations, log)
      } catch {
        lastError = error
        if attempt >= maxRetries - 1 { break }
        let backoff = pow(2.0, Double(attempt)) * 2.0
        try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
      }
      attempt += 1
    }

    throw lastError
      ?? NSError(
        domain: "DoubaoProvider", code: 102,
        userInfo: [
          NSLocalizedDescriptionKey: "Video transcription failed after \(maxRetries) attempts"
        ])
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let callStart = Date()

    let transcriptText = observations.map { obs in
      let startTime = formatTimestampForPrompt(obs.startTs)
      let endTime = formatTimestampForPrompt(obs.endTs)
      return "[" + startTime + " - " + endTime + "]: " + obs.observation
    }.joined(separator: "\n")

    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let existingCardsJSON = (try? encoder.encode(context.existingCards)) ?? Data("[]".utf8)
    let existingCardsString = String(data: existingCardsJSON, encoding: .utf8) ?? "[]"
    let promptSections = VideoPromptSections(overrides: VideoPromptPreferences.load())

    let languageBlock =
      LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
      .map { "\n\n\($0)" } ?? ""

    let basePrompt = LLMPromptTemplates.activityCardsPrompt(
      existingCardsString: existingCardsString,
      transcriptText: transcriptText,
      categoriesSection: categoriesSection(from: context.categories),
      promptSections: promptSections,
      languageBlock: languageBlock, schema: LLMSchema.activityCardsSchema
    )

    let maxRetries = 4
    var attempt = 0
    var lastError: Error?
    var actualPromptUsed = basePrompt
    var finalResponse = ""
    var finalCards: [ActivityCardData] = []
    let callGroupId = UUID().uuidString

    while attempt < maxRetries {
      do {
        let output = try await callChatCompletions(
          messages: [ChatMessage(role: "user", content: .text(actualPromptUsed))],
          operation: "generate_activity_cards",
          batchId: batchId,
          attempt: attempt + 1,
          callGroupId: callGroupId,
          includeRequestBodyInLog: true,
          schema: (name: "activity_cards", definition: LLMSchema.activityCardsSchema)
        )

        let cards = try parseCards(from: output)
        let normalized = normalizeCards(cards, descriptors: context.categories)
        let (coverageValid, coverageError) = validateTimeCoverage(
          existingCards: context.existingCards, newCards: normalized)
        let (durationValid, durationError) = validateTimeline(normalized)

        if coverageValid && durationValid {
          finalResponse = output
          finalCards = normalized
          break
        }

        var errorMessages: [String] = []
        if !coverageValid, let coverageError {
          errorMessages.append(
            """
            TIME COVERAGE ERROR:
            \(coverageError)

            You MUST ensure your output cards collectively cover ALL time periods from the input cards. Do not drop any time segments.
            """)
        }

        if !durationValid, let durationError {
          errorMessages.append(
            """
            DURATION ERROR:
            \(durationError)

            REMINDER: All cards except the last one must be at least 10 minutes long. Please merge short activities into longer, more meaningful cards that tell a coherent story.
            """)
        }

        actualPromptUsed =
          basePrompt + """


            PREVIOUS ATTEMPT FAILED - CRITICAL REQUIREMENTS NOT MET:

            \(errorMessages.joined(separator: "\n\n"))

            Please fix these issues and ensure your output meets all requirements.
            """

        if attempt < maxRetries - 1 {
          try await Task.sleep(nanoseconds: UInt64(1.0 * 1_000_000_000))
        }
      } catch {
        lastError = error
        if attempt >= maxRetries - 1 { break }
        try await Task.sleep(nanoseconds: UInt64(1.0 * 1_000_000_000))
      }

      attempt += 1
    }

    guard !finalCards.isEmpty else {
      throw lastError
        ?? NSError(
          domain: "DoubaoProvider", code: 121,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Activity card generation failed after \(maxRetries) attempts"
          ])
    }

    let log = LLMCall(
      timestamp: callStart, latency: Date().timeIntervalSince(callStart), input: actualPromptUsed,
      output: finalResponse)
    return (finalCards, log)
  }

  // MARK: - Network

  private func callChatCompletions(
    messages: [ChatMessage],
    operation: String,
    batchId: Int64?,
    attempt: Int = 1,
    callGroupId: String? = nil,
    includeRequestBodyInLog: Bool,
    schema: (name: String, definition: String)? = nil
  ) async throws -> String {
    guard let url = ArkEndpointUtilities.chatCompletionsURL(baseURL: endpoint) else {
      throw NSError(
        domain: "DoubaoProvider", code: 15,
        userInfo: [NSLocalizedDescriptionKey: "Invalid Ark endpoint URL"])
    }

    let startedAt = Date()
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 120

    let responseFormat: ResponseFormat? = schema.flatMap { schema in
      let schemaData = Data(schema.definition.utf8)
      guard
        let schemaJSON = try? JSONSerialization.jsonObject(with: schemaData, options: [])
          as? [String: Any]
      else {
        assertionFailure("Hardcoded LLMSchema is not valid JSON: \(schema.name)")
        return nil
      }
      return ResponseFormat(
        type: "json_schema",
        jsonSchema: JSONSchema(name: schema.name, schema: schemaJSON, strict: true))
    }

    let body = ChatCompletionRequest(
      model: modelId,
      messages: messages,
      temperature: 0.3,
      maxTokens: 8192,
      responseFormat: responseFormat
    )
    let encoder = JSONEncoder()
    let bodyData = try encoder.encode(body)
    request.httpBody = bodyData

    let ctx = LLMCallContext(
      batchId: batchId,
      callGroupId: callGroupId,
      attempt: attempt,
      provider: "doubao",
      model: modelId,
      operation: operation,
      requestMethod: request.httpMethod,
      requestURL: request.url,
      requestHeaders: request.allHTTPHeaderFields,
      requestBody: includeRequestBodyInLog ? bodyData : nil,
      startedAt: startedAt
    )

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let finishedAt = Date()
      guard let http = response as? HTTPURLResponse else {
        LLMLogger.logFailure(
          ctx: ctx, http: nil, finishedAt: finishedAt, errorDomain: "DoubaoProvider", errorCode: -1,
          errorMessage: "Non-HTTP response")
        throw NSError(
          domain: "DoubaoProvider", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
      }

      let responseHeaders: [String: String] = http.allHeaderFields.reduce(into: [:]) { acc, kv in
        if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
          acc[k] = v.description
        }
      }
      let httpInfo = LLMHTTPInfo(
        httpStatus: http.statusCode, responseHeaders: responseHeaders, responseBody: data)

      guard http.statusCode == 200 else {
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        LLMLogger.logFailure(
          ctx: ctx, http: httpInfo, finishedAt: finishedAt, errorDomain: "DoubaoProvider",
          errorCode: http.statusCode, errorMessage: bodyText)
        throw NSError(
          domain: "DoubaoProvider", code: http.statusCode,
          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyText)"])
      }

      let decoded = (try? JSONDecoder().decode(ChatCompletionResponse.self, from: data))
      if let apiError = decoded?.error, let message = apiError.message {
        LLMLogger.logFailure(
          ctx: ctx, http: httpInfo, finishedAt: finishedAt, errorDomain: "DoubaoProvider",
          errorCode: http.statusCode, errorMessage: message)
        throw NSError(
          domain: "DoubaoProvider", code: http.statusCode,
          userInfo: [NSLocalizedDescriptionKey: message])
      }

      let text =
        decoded?.choices?.first?.message.content
        ?? String(data: data, encoding: .utf8)
        ?? ""
      LLMLogger.logSuccess(ctx: ctx, http: httpInfo, finishedAt: finishedAt)
      return text
    } catch {
      let finishedAt = Date()
      if (error as NSError).domain != "DoubaoProvider" {
        LLMLogger.logFailure(
          ctx: ctx,
          http: nil,
          finishedAt: finishedAt,
          errorDomain: (error as NSError).domain,
          errorCode: (error as NSError).code,
          errorMessage: (error as NSError).localizedDescription
        )
      }
      throw error
    }
  }

  // MARK: - Parsing helpers

  private func parseCards(from output: String) throws -> [ActivityCardData] {
    let cleaned =
      output
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if let data = cleaned.data(using: .utf8),
      let cards = try? JSONDecoder().decode([ActivityCardData].self, from: data)
    {
      return cards
    }

    // Bracket-balance extraction: take the last ']' and find matching '['.
    func findBalancedArrayStart(_ str: String, endBracket: String.Index) -> String.Index? {
      var balance = 0
      var idx = endBracket
      while true {
        let ch = str[idx]
        if ch == "]" {
          balance += 1
        } else if ch == "[" {
          balance -= 1
          if balance == 0 { return idx }
        }
        if idx == str.startIndex { break }
        idx = str.index(before: idx)
      }
      return nil
    }

    if let lastBracket = cleaned.lastIndex(of: "]"),
      let firstBracket = findBalancedArrayStart(cleaned, endBracket: lastBracket)
    {
      let slice = String(cleaned[firstBracket...lastBracket])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let data = slice.data(using: .utf8),
        let cards = try? JSONDecoder().decode([ActivityCardData].self, from: data)
      {
        return cards
      }
    }

    throw NSError(
      domain: "DoubaoProvider", code: 32,
      userInfo: [NSLocalizedDescriptionKey: "Failed to decode activity cards: \(output)"])
  }

  // MARK: - Prompt helpers

  // NOTE: DoubaoArkProvider intentionally uses the exact prompt string from GeminiDirectProvider
  // for video transcription, so we do not maintain a separate prompt builder here.

  // MARK: - Time helpers

  private func formatSeconds(_ seconds: TimeInterval) -> String {
    LLMVideoTimestampUtilities.formatSecondsHHMMSS(seconds)
  }

  private func parseVideoTimestamp(_ timestamp: String) -> Int {
    LLMVideoTimestampUtilities.parseVideoTimestamp(timestamp)
  }

  private func formatTimestampForPrompt(_ unixTime: Int) -> String {
    LLMTimelineCardValidation.formatTimestampForPrompt(unixTime)
  }

  // MARK: - Categories

  private func categoriesSection(from descriptors: [LLMCategoryDescriptor]) -> String {
    guard !descriptors.isEmpty else {
      return
        "USER CATEGORIES: No categories configured. Use consistent labels based on the activity story."
    }

    let allowed = descriptors.map { "\"\($0.name)\"" }.joined(separator: ", ")
    var lines: [String] = ["USER CATEGORIES (choose exactly one label):"]
    for (index, descriptor) in descriptors.enumerated() {
      var desc = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if descriptor.isIdle && desc.isEmpty {
        desc = "Use when the user is idle for most of this period."
      }
      let suffix = desc.isEmpty ? "" : " — \(desc)"
      lines.append("\(index + 1). \"\(descriptor.name)\"\(suffix)")
    }

    if let idle = descriptors.first(where: { $0.isIdle }) {
      lines.append(
        "Only use \"\(idle.name)\" when the user is idle for more than half of the timeframe. Otherwise pick the closest non-idle label."
      )
    }
    lines.append("Return the category exactly as written. Allowed values: [\(allowed)].")
    return lines.joined(separator: "\n")
  }

  private func normalizeCategory(_ raw: String, descriptors: [LLMCategoryDescriptor]) -> String {
    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return descriptors.first?.name ?? "" }
    let normalized = cleaned.lowercased()
    if let match = descriptors.first(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }) {
      return match.name
    }
    if let idle = descriptors.first(where: { $0.isIdle }) {
      let idleLabels = ["idle", "idle time", idle.name.lowercased()]
      if idleLabels.contains(normalized) {
        return idle.name
      }
    }
    return descriptors.first?.name ?? cleaned
  }

  private func normalizeCards(_ cards: [ActivityCardData], descriptors: [LLMCategoryDescriptor])
    -> [ActivityCardData]
  {
    cards.map { card in
      ActivityCardData(
        startTime: card.startTime,
        endTime: card.endTime,
        category: normalizeCategory(card.category, descriptors: descriptors),
        subcategory: card.subcategory,
        title: card.title,
        summary: card.summary,
        detailedSummary: card.detailedSummary,
        distractions: card.distractions,
        appSites: card.appSites
      )
    }
  }

  // MARK: - Card validation (shared logic mirrored from other providers)

  private func timeToMinutes(_ timeStr: String) -> Double {
    LLMTimelineCardValidation.timeToMinutes(timeStr)
  }

  private func validateTimeCoverage(existingCards: [ActivityCardData], newCards: [ActivityCardData])
    -> (isValid: Bool, error: String?)
  {
    LLMTimelineCardValidation.validateTimeCoverage(existingCards: existingCards, newCards: newCards)
  }

  private func validateTimeline(_ cards: [ActivityCardData]) -> (isValid: Bool, error: String?) {
    LLMTimelineCardValidation.validateTimeline(cards)
  }
}
