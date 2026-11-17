//
//  GeminiAPIHelper.swift
//  Dayflow
//
//  Checks that a Gemini API key works
//

import Foundation

final class GeminiAPIHelper {
  typealias RequestData = (URLRequest) async throws -> (Data, URLResponse)

  struct ConnectionResult {
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
        return String(localized: "Invalid or missing API key")
      case .rateLimited(let message, _):
        return message
      case .apiError(let message):
        return message
      case .networkError(let message):
        return String(localized: "Network error: \(message)")
      case .invalidResponse:
        return String(localized: "Invalid response from server")
      }
    }
  }

  /// Checks that the key is valid by listing the models it can use. This only asks Google
  /// whether it accepts the key, so it answers in well under a second and doesn't fail when a
  /// model is overloaded. Asking a model to reply used to hang for a minute and fail when
  /// Gemini was busy, even though the key was fine.
  func testConnection(apiKey: String, preference: GeminiModelPreference) async throws
    -> ConnectionResult
  {
    let cleanedAPIKey = apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
    guard !cleanedAPIKey.isEmpty,
      let url = URL(
        string:
          "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1&key=\(cleanedAPIKey)"
      )
    else {
      throw APIError.invalidAPIKey
    }
    let model = preference.primary
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = Self.timeout

    let context = LLMCallContext(
      batchId: nil,
      callGroupId: UUID().uuidString,
      attempt: 1,
      provider: "gemini",
      providerID: LLMProviderID.gemini.rawValue,
      model: model.rawValue,
      operation: "test_connection",
      requestMethod: request.httpMethod,
      requestURL: request.url,
      requestHeaders: request.allHTTPHeaderFields,
      requestBody: nil,
      startedAt: Date()
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
      let error = apiError(statusCode: httpResponse.statusCode, data: data, model: model)
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
      throw error
    }

    if logsRequests {
      LLMLogger.logSuccess(ctx: context, http: httpInfo, finishedAt: Date())
    }
    return ConnectionResult(model: model)
  }

  private static let timeout: TimeInterval = 15

  private func apiError(statusCode: Int, data: Data, model: GeminiModel) -> APIError {
    let message = extractErrorMessage(from: data) ?? "Status code: \(statusCode)"

    if isRateLimit(statusCode: statusCode, message: message) {
      return .rateLimited(message, model: model)
    }

    // Google answers a key it doesn't accept with 400 (API_KEY_INVALID) or 401, and a key it
    // has blocked or restricted with 403.
    if statusCode == 400 || statusCode == 401 || statusCode == 403 {
      return extractErrorMessage(from: data) == nil ? .invalidAPIKey : .apiError(message)
    }

    return .networkError(message)
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
