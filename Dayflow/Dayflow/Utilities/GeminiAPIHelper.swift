//
//  GeminiAPIHelper.swift
//  Dayflow
//
//  Helper for testing Gemini API connection
//

import Foundation

final class GeminiAPIHelper {
  typealias RequestData = (URLRequest) async throws -> (Data, URLResponse)

  struct ConnectionResult {
    let responseText: String
    let model: GeminiModel
  }

  static let shared = GeminiAPIHelper()

  private let requestData: RequestData
  private let logsRequests: Bool

  private init() {
    requestData = { request in
      try await URLSession.shared.data(for: request)
    }
    logsRequests = true
  }

  init(requestData: @escaping RequestData, logsRequests: Bool = true) {
    self.requestData = requestData
    self.logsRequests = logsRequests
  }

  enum APIError: Error, LocalizedError {
    case invalidAPIKey
    case rateLimited(String, model: GeminiModel)
    case apiError(String)
    case networkError(String)
    case invalidResponse

    var errorDescription: String? {
      switch self {
      case .invalidAPIKey:
        return "Invalid or missing API key"
      case .rateLimited(let message, _):
        return message
      case .apiError(let message):
        return message
      case .networkError(let message):
        return "Network error: \(message)"
      case .invalidResponse:
        return "Invalid response from server"
      }
    }
  }

  private struct HTTPFailure: Error {
    let statusCode: Int
    let apiError: APIError
  }

  // Test the selected model first, then use the same fallback order as normal Gemini requests.
  func testConnection(apiKey: String, preference: GeminiModelPreference) async throws
    -> ConnectionResult
  {
    let cleanedAPIKey = apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
    guard !cleanedAPIKey.isEmpty else {
      throw APIError.invalidAPIKey
    }

    let models = preference.orderedModels
    for (index, model) in models.enumerated() {
      do {
        return try await testConnection(
          apiKey: cleanedAPIKey,
          model: model,
          attempt: index + 1
        )
      } catch let failure as HTTPFailure {
        let hasFallback = index < models.count - 1
        if hasFallback, GeminiDirectProvider.capacityErrorCodes.contains(failure.statusCode) {
          continue
        }
        throw failure.apiError
      }
    }

    throw APIError.invalidResponse
  }

  private func testConnection(apiKey: String, model: GeminiModel, attempt: Int) async throws
    -> ConnectionResult
  {
    let url = URL(
      string:
        "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent"
    )!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

    let requestBody: [String: Any] = [
      "contents": [
        [
          "parts": [
            ["text": "Please respond with exactly: Hi from Gemini!"]
          ]
        ]
      ],
      "generationConfig": [
        "maxOutputTokens": 4096,
        "thinkingConfig": ["thinkingLevel": "high"],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

    let startedAt = Date()
    let context = LLMCallContext(
      batchId: nil,
      callGroupId: UUID().uuidString,
      attempt: attempt,
      provider: "gemini",
      providerID: LLMProviderID.gemini.rawValue,
      model: model.rawValue,
      operation: "test_connection",
      requestMethod: request.httpMethod,
      requestURL: request.url,
      requestHeaders: request.allHTTPHeaderFields,
      requestBody: request.httpBody,
      startedAt: startedAt
    )

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await requestData(request)
    } catch {
      if logsRequests {
        LLMLogger.logFailure(
          ctx: context,
          http: nil,
          finishedAt: Date(),
          errorDomain: (error as NSError).domain,
          errorCode: (error as NSError).code,
          errorMessage: error.localizedDescription
        )
      }
      throw error
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      if logsRequests {
        LLMLogger.logFailure(
          ctx: context,
          http: nil,
          finishedAt: Date(),
          errorDomain: "GeminiAPIHelper",
          errorCode: nil,
          errorMessage: "Invalid response"
        )
      }
      throw APIError.invalidResponse
    }

    let httpInfo = LLMHTTPInfo(
      httpStatus: httpResponse.statusCode,
      responseHeaders: responseHeaders(from: httpResponse),
      responseBody: data
    )

    guard httpResponse.statusCode == 200 else {
      let error = apiError(
        statusCode: httpResponse.statusCode,
        data: data,
        model: model
      )
      if logsRequests {
        LLMLogger.logFailure(
          ctx: context,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "GeminiAPIHelper",
          errorCode: httpResponse.statusCode,
          errorMessage: error.localizedDescription
        )
      }
      throw HTTPFailure(statusCode: httpResponse.statusCode, apiError: error)
    }

    if logsRequests {
      LLMLogger.logSuccess(
        ctx: context,
        http: httpInfo,
        finishedAt: Date()
      )
    }

    return ConnectionResult(
      responseText: extractResponseText(from: data) ?? "",
      model: model
    )
  }

  private func apiError(statusCode: Int, data: Data, model: GeminiModel) -> APIError {
    let message = extractErrorMessage(from: data) ?? "Status code: \(statusCode)"

    if isRateLimit(statusCode: statusCode, message: message) {
      return .rateLimited(message, model: model)
    }

    if statusCode == 401 || statusCode == 403 {
      return extractErrorMessage(from: data) == nil ? .invalidAPIKey : .apiError(message)
    }

    return .networkError(message)
  }

  private func extractResponseText(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let firstCandidate = candidates.first,
      let content = firstCandidate["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let firstPart = parts.first
    else {
      return nil
    }

    return firstPart["text"] as? String
  }

  private func extractErrorMessage(from data: Data) -> String? {
    guard let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = errorData["error"] as? [String: Any],
      let message = error["message"] as? String,
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return message
  }

  private func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
    response.allHeaderFields.reduce(into: [:]) { headers, field in
      if let key = field.key as? String, let value = field.value as? CustomStringConvertible {
        headers[key] = value.description
      }
    }
  }

  private func isRateLimit(statusCode: Int, message: String) -> Bool {
    let lowercased = message.lowercased()
    return statusCode == 429
      || statusCode == 503
      || lowercased.contains("quota")
      || lowercased.contains("rate limit")
      || lowercased.contains("rate-limit")
      || lowercased.contains("too many requests")
      || lowercased.contains("high demand")
      || lowercased.contains("overloaded")
      || lowercased.contains("temporarily unavailable")
  }
}
