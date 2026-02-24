//
//  GeminiAPIHelper.swift
//  Dayflow
//
//  Helper for testing Gemini API connection
//

import Foundation

class GeminiAPIHelper {
  static let shared = GeminiAPIHelper()
  private init() {}

  private let baseURL =
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent"

  enum APIError: Error, LocalizedError {
    case invalidAPIKey
    case apiError(String)
    case networkError(String)
    case invalidResponse

    var errorDescription: String? {
      switch self {
      case .invalidAPIKey:
        return "Invalid or missing API key"
      case .apiError(let message):
        return message
      case .networkError(let message):
        return "Network error: \(message)"
      case .invalidResponse:
        return "Invalid response from server"
      }
    }
  }

  // Test the API connection with a simple request
  func testConnection(apiKey: String) async throws -> String {
    guard !apiKey.isEmpty else {
      throw APIError.invalidAPIKey
    }

    let url = URL(string: "\(baseURL)?key=\(apiKey)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Simple test request
    let requestBody: [String: Any] = [
      "contents": [
        [
          "parts": [
            ["text": "Please respond with exactly: Hi from Gemini!"]
          ]
        ]
      ],
      "generationConfig": [
        "temperature": 0.1,
        "maxOutputTokens": 100,
      ],
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

    // Build timing
    let startedAt = Date()

    let (data, response) = try await URLSession.shared.data(for: request)
    let ctx = LLMCallContext(
      batchId: nil,
      callGroupId: UUID().uuidString,
      attempt: 1,
      provider: "gemini",
      model: nil,
      operation: "test_connection",
      requestMethod: request.httpMethod,
      requestURL: request.url,
      requestHeaders: request.allHTTPHeaderFields,
      requestBody: request.httpBody,
      startedAt: startedAt
    )
    if let http = response as? HTTPURLResponse {
      let headers: [String: String] = http.allHeaderFields.reduce(into: [:]) { acc, kv in
        if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
          acc[k] = v.description
        }
      }
      LLMLogger.logSuccess(
        ctx: ctx,
        http: LLMHTTPInfo(
          httpStatus: http.statusCode, responseHeaders: headers, responseBody: data),
        finishedAt: Date()
      )
    } else {
      LLMLogger.logSuccess(
        ctx: ctx,
        http: LLMHTTPInfo(httpStatus: nil, responseHeaders: nil, responseBody: data),
        finishedAt: Date()
      )
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      LLMLogger.logFailure(
        ctx: ctx,
        http: (response as? HTTPURLResponse).map { http in
          let headers: [String: String] = http.allHeaderFields.reduce(into: [:]) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }
          return LLMHTTPInfo(
            httpStatus: http.statusCode, responseHeaders: headers, responseBody: data)
        },
        finishedAt: Date(),
        errorDomain: "GeminiAPIHelper",
        errorCode: nil,
        errorMessage: "Invalid response"
      )
      throw APIError.invalidResponse
    }

    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
      if let message = extractErrorMessage(from: data) {
        LLMLogger.logFailure(
          ctx: ctx,
          http: LLMHTTPInfo(
            httpStatus: httpResponse.statusCode,
            responseHeaders: httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
              if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
                acc[k] = v.description
              }
            }, responseBody: data),
          finishedAt: Date(),
          errorDomain: "GeminiAPIHelper",
          errorCode: httpResponse.statusCode,
          errorMessage: message
        )
        throw APIError.apiError(message)
      }
      if let body = String(data: data, encoding: .utf8) {
        print(
          "🔎 GEMINI DEBUG: testConnection unauthorized (\(httpResponse.statusCode)) body=\(body)")
      }
      LLMLogger.logFailure(
        ctx: ctx,
        http: LLMHTTPInfo(
          httpStatus: httpResponse.statusCode,
          responseHeaders: httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }, responseBody: data),
        finishedAt: Date(),
        errorDomain: "GeminiAPIHelper",
        errorCode: httpResponse.statusCode,
        errorMessage: "Invalid or missing API key"
      )
      throw APIError.invalidAPIKey
    }

    if httpResponse.statusCode != 200 {
      if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let error = errorData["error"] as? [String: Any],
        let message = error["message"] as? String
      {
        print(
          "🔎 GEMINI DEBUG: testConnection non-200 status=\(httpResponse.statusCode) message=\(message)"
        )
        LLMLogger.logFailure(
          ctx: ctx,
          http: LLMHTTPInfo(
            httpStatus: httpResponse.statusCode,
            responseHeaders: httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
              if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
                acc[k] = v.description
              }
            }, responseBody: data),
          finishedAt: Date(),
          errorDomain: "GeminiAPIHelper",
          errorCode: httpResponse.statusCode,
          errorMessage: message
        )
        throw APIError.networkError(message)
      }
      if let body = String(data: data, encoding: .utf8) {
        print(
          "🔎 GEMINI DEBUG: testConnection non-200 status=\(httpResponse.statusCode) body=\(body)")
      }
      LLMLogger.logFailure(
        ctx: ctx,
        http: LLMHTTPInfo(
          httpStatus: httpResponse.statusCode,
          responseHeaders: httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }, responseBody: data),
        finishedAt: Date(),
        errorDomain: "GeminiAPIHelper",
        errorCode: httpResponse.statusCode,
        errorMessage: "Status code: \(httpResponse.statusCode)"
      )
      throw APIError.networkError("Status code: \(httpResponse.statusCode)")
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let firstCandidate = candidates.first,
      let content = firstCandidate["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let firstPart = parts.first,
      let text = firstPart["text"] as? String
    else {
      if let body = String(data: data, encoding: .utf8) {
        print("🔎 GEMINI DEBUG: testConnection unexpected format; body=\(body)")
      }
      throw APIError.invalidResponse
    }

    return text
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

}
