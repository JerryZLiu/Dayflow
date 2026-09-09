//
//  DayflowBackendProvider.swift
//  Dayflow
//

import AppKit
import Foundation

struct DayflowDailyGenerationRequest: Codable, Sendable {
  let day: String
  let cardsText: String
  let observationsText: String
  let priorDailyText: String
  let preferencesText: String
  let preferredOutputLanguage: String?

  init(
    day: String,
    cardsText: String,
    observationsText: String = "",
    priorDailyText: String = "",
    preferencesText: String = "",
    preferredOutputLanguage: String? = nil
  ) {
    self.day = day
    self.cardsText = cardsText
    self.observationsText = observationsText
    self.priorDailyText = priorDailyText
    self.preferencesText = preferencesText
    self.preferredOutputLanguage = preferredOutputLanguage
  }

  private enum CodingKeys: String, CodingKey {
    case day
    case cardsText = "cards_text"
    case observationsText = "observations_text"
    case priorDailyText = "prior_daily_text"
    case preferencesText = "preferences_text"
    case preferredOutputLanguage = "preferred_output_language"
  }
}

struct DayflowDailyGenerationResponse: Codable, Sendable {
  let day: String
  let highlights: [String]
  let unfinished: [String]
  let blockers: [String]
}

private struct DayflowObservationPayload: Codable, Sendable {
  let startTs: Int
  let endTs: Int
  let observation: String
  let metadata: String?
  let llmModel: String?
  let batchId: Int64?

  init(_ observation: Observation) {
    self.startTs = observation.startTs
    self.endTs = observation.endTs
    self.observation = observation.observation
    self.metadata = observation.metadata
    self.llmModel = observation.llmModel
    self.batchId = observation.batchId
  }

  private enum CodingKeys: String, CodingKey {
    case startTs = "start_ts"
    case endTs = "end_ts"
    case observation
    case metadata
    case llmModel = "llm_model"
    case batchId = "batch_id"
  }
}

private struct DayflowCategoryDescriptorPayload: Codable, Sendable {
  let name: String
  let description: String?
  let isIdle: Bool

  init(_ descriptor: LLMCategoryDescriptor) {
    self.name = descriptor.name
    self.description = descriptor.description
    self.isIdle = descriptor.isIdle
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case description
    case isIdle = "is_idle"
  }
}

private struct DayflowGenerateCardsRequest: Codable, Sendable {
  let observations: [DayflowObservationPayload]
  let existingCards: [ActivityCardData]
  let categories: [DayflowCategoryDescriptorPayload]
  let batchId: Int64?
  let preferredOutputLanguage: String?
  let timezone: String

  private enum CodingKeys: String, CodingKey {
    case observations
    case existingCards = "existing_cards"
    case categories
    case batchId = "batch_id"
    case preferredOutputLanguage = "preferred_output_language"
    case timezone
  }
}

private struct DayflowScreenshotPayload: Codable, Sendable {
  let capturedAt: Int
  let imageBase64: String

  private enum CodingKeys: String, CodingKey {
    case capturedAt = "captured_at"
    case imageBase64 = "image_base64"
  }
}

private struct DayflowTranscribeRequest: Codable, Sendable {
  let screenshots: [DayflowScreenshotPayload]
  let batchStartTime: String
  let batchId: Int64?

  private enum CodingKeys: String, CodingKey {
    case screenshots
    case batchStartTime = "batch_start_time"
    case batchId = "batch_id"
  }
}

private struct DayflowLLMCallResponse: Codable, Sendable {
  let timestamp: String
  let latencySeconds: Double
  let input: String?
  let output: String?

  private enum CodingKeys: String, CodingKey {
    case timestamp
    case latencySeconds = "latency_seconds"
    case input
    case output
  }
}

private struct DayflowGenerateCardsResponse: Codable, Sendable {
  let cards: [ActivityCardData]
  let provider: String
  let model: String
  let log: DayflowLLMCallResponse
}

private struct DayflowTranscribeResponse: Codable, Sendable {
  let observations: [DayflowObservationPayload]
  let provider: String
  let model: String
  let log: DayflowLLMCallResponse
}

final class DayflowBackendProvider {
  private let token: String
  private let endpoint: String

  init(token: String, endpoint: String) {
    self.token = token
    self.endpoint = endpoint
    #if DEBUG
      print(
        "[DayflowBackendProvider] init endpoint=\(endpoint) auth_id_length=\(token.count)"
      )
    #endif
  }

  private func resolvedEndpointString() -> String {
    endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private static func date(from isoString: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: isoString) {
      return date
    }

    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: isoString)
  }

  private static func isoString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  func generateDaily(_ request: DayflowDailyGenerationRequest) async throws
    -> DayflowDailyGenerationResponse
  {
    let requestId = UUID().uuidString
    let startedAt = Date()
    let normalizedEndpoint = resolvedEndpointString()

    let endpointHost: String = {
      guard let parsed = URL(string: normalizedEndpoint), let host = parsed.host, !host.isEmpty
      else {
        return "invalid_host"
      }
      return host
    }()

    let baseProps: [String: Any] = [
      "daily_request_id": requestId,
      "day": request.day,
      "endpoint_host": endpointHost,
      "cards_text_chars": request.cardsText.count,
      "observations_text_chars": request.observationsText.count,
      "prior_daily_text_chars": request.priorDailyText.count,
      "preferences_text_chars": request.preferencesText.count,
    ]

    AnalyticsService.shared.capture("daily_generation_request_started", baseProps)

    var httpStatusCode: Int? = nil
    var responseByteCount = 0

    do {
      guard let url = URL(string: "\(normalizedEndpoint)/v1/daily") else {
        throw NSError(
          domain: "DayflowBackend",
          code: -10,
          userInfo: [NSLocalizedDescriptionKey: "Invalid Dayflow backend endpoint: \(endpoint)"]
        )
      }

      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
      urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      urlRequest.httpBody = try JSONEncoder().encode(request)
      print(
        "[DayflowBackendProvider] daily request_id=\(requestId) day=\(request.day) "
          + "url=\(url.absoluteString) endpoint_host=\(endpointHost) auth_id_length=\(token.count)"
      )

      let requestByteCount = urlRequest.httpBody?.count ?? 0
      let (data, response) = try await URLSession.shared.data(for: urlRequest)
      responseByteCount = data.count

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(
          domain: "DayflowBackend",
          code: -11,
          userInfo: [
            NSLocalizedDescriptionKey: "Daily generation request returned a non-HTTP response."
          ]
        )
      }

      httpStatusCode = httpResponse.statusCode
      print(
        "[DayflowBackendProvider] daily response request_id=\(requestId) "
          + "status=\(httpResponse.statusCode) bytes=\(data.count)"
      )

      guard (200...299).contains(httpResponse.statusCode) else {
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        print(
          "[DayflowBackendProvider] daily http error request_id=\(requestId) "
            + "status=\(httpResponse.statusCode) body=\(responseBody)"
        )
        throw NSError(
          domain: "DayflowBackend",
          code: httpResponse.statusCode,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Daily generation failed (\(httpResponse.statusCode)): \(responseBody)"
          ]
        )
      }

      let decoded: DayflowDailyGenerationResponse
      do {
        decoded = try JSONDecoder().decode(DayflowDailyGenerationResponse.self, from: data)
      } catch {
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        print(
          "[DayflowBackendProvider] daily decode error request_id=\(requestId) body=\(responseBody)"
        )
        throw NSError(
          domain: "DayflowBackend",
          code: -12,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to decode daily generation response: \(responseBody)"
          ]
        )
      }

      var successProps = baseProps
      successProps["latency_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
      successProps["http_status"] = httpResponse.statusCode
      successProps["request_bytes"] = requestByteCount
      successProps["response_bytes"] = responseByteCount
      successProps["highlights_count"] = decoded.highlights.count
      successProps["unfinished_count"] = decoded.unfinished.count
      successProps["blockers_count"] = decoded.blockers.count
      AnalyticsService.shared.capture("daily_generation_request_succeeded", successProps)

      return decoded
    } catch {
      let nsError = error as NSError
      var failureProps = baseProps
      failureProps["latency_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
      failureProps["response_bytes"] = responseByteCount
      failureProps["error_domain"] = nsError.domain
      failureProps["error_code"] = nsError.code
      if let httpStatusCode {
        failureProps["http_status"] = httpStatusCode
      } else if nsError.code >= 100, nsError.code <= 599 {
        failureProps["http_status"] = nsError.code
      }
      print(
        "[DayflowBackendProvider] daily failure request_id=\(requestId) "
          + "error_domain=\(nsError.domain) error_code=\(nsError.code) "
          + "error_message=\(nsError.localizedDescription)"
      )
      AnalyticsService.shared.capture("daily_generation_request_failed", failureProps)
      throw error
    }
  }

  /// Matches the server's MAX_SCREENSHOTS_PER_REQUEST so we never upload frames it would discard.
  private static let maxFramesPerBatch = 15

  /// Picks `maxCount` evenly spaced frames, the same way the backend samples them.
  private static func evenlySampled(_ screenshots: [Screenshot], maxCount: Int) -> [Screenshot] {
    guard screenshots.count > maxCount, maxCount > 0 else { return screenshots }
    let step = Double(screenshots.count) / Double(maxCount)
    return (0..<maxCount).map { i in
      screenshots[min(Int(Double(i) * step), screenshots.count - 1)]
    }
  }

  func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?)
    async throws -> (observations: [Observation], log: LLMCall)
  {
    let requestId = UUID().uuidString
    let startedAt = Date()
    let normalizedEndpoint = resolvedEndpointString()
    guard let url = URL(string: "\(normalizedEndpoint)/v1/dayflow/transcribe") else {
      throw NSError(
        domain: "DayflowBackend",
        code: -30,
        userInfo: [NSLocalizedDescriptionKey: "Invalid Dayflow backend endpoint: \(endpoint)"]
      )
    }

    let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    let sampledScreenshots = Self.evenlySampled(sortedScreenshots, maxCount: Self.maxFramesPerBatch)
    let screenshotPayloads = sampledScreenshots.compactMap {
      screenshot -> DayflowScreenshotPayload? in
      guard let data = screenshot.jpegData(maxHeight: 720, quality: 0.85) else { return nil }
      return DayflowScreenshotPayload(
        capturedAt: screenshot.capturedAt,
        imageBase64: data.base64EncodedString()
      )
    }

    guard !screenshotPayloads.isEmpty else {
      throw NSError(
        domain: "DayflowBackend",
        code: -31,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots could be loaded for transcription."]
      )
    }

    let payload = DayflowTranscribeRequest(
      screenshots: screenshotPayloads,
      batchStartTime: Self.isoString(from: batchStartTime),
      batchId: batchId
    )

    let endpointHost: String = {
      guard let parsed = URL(string: normalizedEndpoint), let host = parsed.host, !host.isEmpty
      else {
        return "invalid_host"
      }
      return host
    }()

    let baseProps: [String: Any] = [
      "transcribe_request_id": requestId,
      "endpoint_host": endpointHost,
      "screenshots_count": screenshots.count,
      "loaded_screenshots_count": screenshotPayloads.count,
      "batch_id": batchId as Any,
    ]
    AnalyticsService.shared.capture("backend_transcription_request_started", baseProps)
    print(
      "🌐 [DayflowBackendProvider] transcribe start request_id=\(requestId) "
        + "endpoint=\(url.absoluteString) screenshots=\(screenshots.count) "
        + "loaded=\(screenshotPayloads.count) batch_id=\(batchId.map(String.init) ?? "nil") "
        + "token_length=\(token.count)"
    )

    var httpStatusCode: Int? = nil
    var responseByteCount = 0

    do {
      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
      urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      urlRequest.httpBody = try JSONEncoder().encode(payload)

      let requestByteCount = urlRequest.httpBody?.count ?? 0
      let (data, response) = try await URLSession.shared.data(for: urlRequest)
      responseByteCount = data.count

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(
          domain: "DayflowBackend",
          code: -32,
          userInfo: [
            NSLocalizedDescriptionKey: "Transcription request returned a non-HTTP response."
          ]
        )
      }

      httpStatusCode = httpResponse.statusCode
      print(
        "🌐 [DayflowBackendProvider] transcribe response request_id=\(requestId) "
          + "status=\(httpResponse.statusCode) bytes=\(responseByteCount)"
      )
      guard (200...299).contains(httpResponse.statusCode) else {
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        print(
          "❌ [DayflowBackendProvider] transcribe failed request_id=\(requestId) "
            + "status=\(httpResponse.statusCode) body=\(String(responseBody.prefix(500)))"
        )
        throw NSError(
          domain: "DayflowBackend",
          code: httpResponse.statusCode,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Transcription failed (\(httpResponse.statusCode)): \(responseBody)"
          ]
        )
      }

      let decoded: DayflowTranscribeResponse
      do {
        decoded = try JSONDecoder().decode(DayflowTranscribeResponse.self, from: data)
      } catch {
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        throw NSError(
          domain: "DayflowBackend",
          code: -33,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to decode transcription response: \(responseBody)"
          ]
        )
      }

      let observations = decoded.observations.map { payload in
        Observation(
          id: nil,
          batchId: payload.batchId ?? batchId ?? 0,
          startTs: payload.startTs,
          endTs: payload.endTs,
          observation: payload.observation,
          metadata: payload.metadata,
          llmModel: payload.llmModel ?? decoded.model,
          createdAt: Date()
        )
      }

      var successProps = baseProps
      successProps["latency_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
      successProps["http_status"] = httpResponse.statusCode
      successProps["request_bytes"] = requestByteCount
      successProps["response_bytes"] = responseByteCount
      successProps["observations_count"] = observations.count
      successProps["provider"] = decoded.provider
      successProps["model"] = decoded.model
      AnalyticsService.shared.capture("backend_transcription_request_succeeded", successProps)
      print(
        "✅ [DayflowBackendProvider] transcribe succeeded request_id=\(requestId) "
          + "observations=\(observations.count) provider=\(decoded.provider) model=\(decoded.model)"
      )

      let log = LLMCall(
        timestamp: Self.date(from: decoded.log.timestamp) ?? Date(),
        latency: decoded.log.latencySeconds,
        input: decoded.log.input,
        output: decoded.log.output
      )
      return (observations, log)
    } catch {
      let nsError = error as NSError
      var failureProps = baseProps
      failureProps["latency_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
      failureProps["response_bytes"] = responseByteCount
      failureProps["error_domain"] = nsError.domain
      failureProps["error_code"] = nsError.code
      if let httpStatusCode {
        failureProps["http_status"] = httpStatusCode
      } else if nsError.code >= 100, nsError.code <= 599 {
        failureProps["http_status"] = nsError.code
      }
      AnalyticsService.shared.capture("backend_transcription_request_failed", failureProps)
      print(
        "❌ [DayflowBackendProvider] transcribe error request_id=\(requestId) "
          + "domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)"
      )
      throw error
    }
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    let requestId = UUID().uuidString
    let startedAt = Date()
    let normalizedEndpoint = resolvedEndpointString()
    guard let url = URL(string: "\(normalizedEndpoint)/v1/dayflow/generate-cards") else {
      throw NSError(
        domain: "DayflowBackend",
        code: -20,
        userInfo: [NSLocalizedDescriptionKey: "Invalid Dayflow backend endpoint: \(endpoint)"]
      )
    }

    let payload = DayflowGenerateCardsRequest(
      observations: observations.map(DayflowObservationPayload.init),
      existingCards: context.existingCards,
      categories: context.categories.map(DayflowCategoryDescriptorPayload.init),
      batchId: batchId,
      preferredOutputLanguage: LLMOutputLanguagePreferences.normalizedOverride,
      timezone: TimeZone.current.identifier
    )

    let endpointHost: String = {
      guard let parsed = URL(string: normalizedEndpoint), let host = parsed.host, !host.isEmpty
      else {
        return "invalid_host"
      }
      return host
    }()

    let baseProps: [String: Any] = [
      "cardgen_request_id": requestId,
      "endpoint_host": endpointHost,
      "observations_count": observations.count,
      "existing_cards_count": context.existingCards.count,
      "categories_count": context.categories.count,
    ]
    AnalyticsService.shared.capture("activity_card_generation_request_started", baseProps)
    print(
      "🌐 [DayflowBackendProvider] cards start request_id=\(requestId) "
        + "endpoint=\(url.absoluteString) observations=\(observations.count) "
        + "existing_cards=\(context.existingCards.count) categories=\(context.categories.count) "
        + "batch_id=\(batchId.map(String.init) ?? "nil") token_length=\(token.count)"
    )

    var httpStatusCode: Int? = nil
    var responseByteCount = 0

    do {
      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
      urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      urlRequest.httpBody = try JSONEncoder().encode(payload)

      let requestByteCount = urlRequest.httpBody?.count ?? 0
      let (data, response) = try await URLSession.shared.data(for: urlRequest)
      responseByteCount = data.count

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(
          domain: "DayflowBackend",
          code: -21,
          userInfo: [
            NSLocalizedDescriptionKey: "Card generation request returned a non-HTTP response."
          ]
        )
      }

      httpStatusCode = httpResponse.statusCode
      print(
        "🌐 [DayflowBackendProvider] cards response request_id=\(requestId) "
          + "status=\(httpResponse.statusCode) bytes=\(responseByteCount)"
      )
      guard (200...299).contains(httpResponse.statusCode) else {
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        print(
          "❌ [DayflowBackendProvider] cards failed request_id=\(requestId) "
            + "status=\(httpResponse.statusCode) body=\(String(responseBody.prefix(500)))"
        )
        throw NSError(
          domain: "DayflowBackend",
          code: httpResponse.statusCode,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Card generation failed (\(httpResponse.statusCode)): \(responseBody)"
          ]
        )
      }

      let decoded: DayflowGenerateCardsResponse
      do {
        decoded = try JSONDecoder().decode(DayflowGenerateCardsResponse.self, from: data)
      } catch {
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        throw NSError(
          domain: "DayflowBackend",
          code: -22,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to decode card generation response: \(responseBody)"
          ]
        )
      }

      var successProps = baseProps
      successProps["latency_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
      successProps["http_status"] = httpResponse.statusCode
      successProps["request_bytes"] = requestByteCount
      successProps["response_bytes"] = responseByteCount
      successProps["cards_count"] = decoded.cards.count
      successProps["provider"] = decoded.provider
      successProps["model"] = decoded.model
      AnalyticsService.shared.capture("activity_card_generation_request_succeeded", successProps)
      print(
        "✅ [DayflowBackendProvider] cards succeeded request_id=\(requestId) "
          + "cards=\(decoded.cards.count) provider=\(decoded.provider) model=\(decoded.model)"
      )

      let log = LLMCall(
        timestamp: Self.date(from: decoded.log.timestamp) ?? Date(),
        latency: decoded.log.latencySeconds,
        input: decoded.log.input,
        output: decoded.log.output
      )
      return (decoded.cards, log)
    } catch {
      let nsError = error as NSError
      var failureProps = baseProps
      failureProps["latency_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
      failureProps["response_bytes"] = responseByteCount
      failureProps["error_domain"] = nsError.domain
      failureProps["error_code"] = nsError.code
      if let httpStatusCode {
        failureProps["http_status"] = httpStatusCode
      } else if nsError.code >= 100, nsError.code <= 599 {
        failureProps["http_status"] = nsError.code
      }
      AnalyticsService.shared.capture("activity_card_generation_request_failed", failureProps)
      print(
        "❌ [DayflowBackendProvider] cards error request_id=\(requestId) "
          + "domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)"
      )
      throw error
    }
  }

  func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
    throw NSError(
      domain: "DayflowBackend",
      code: -1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Text generation is not yet supported with Dayflow Backend. Please configure Gemini, ChatGPT, Claude, an OpenAI-compatible endpoint, or Local in Settings."
      ]
    )
  }
}
