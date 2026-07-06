//
//  OllamaProvider+Networking.swift
//  Dayflow
//

import Foundation

extension OllamaProvider {
  struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    var temperature: Double = 0.7
    var max_tokens: Int = 4000
    var stream: Bool = false
  }

  struct ChatMessage: Codable {
    let role: String
    let content: [MessageContent]
  }

  struct MessageContent: Codable {
    let type: String
    let text: String?
    let image_url: ImageURL?

    struct ImageURL: Codable {
      let url: String
    }
  }

  struct ChatResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
      let message: ResponseMessage
    }

    struct ResponseMessage: Codable {
      let content: String
    }
  }

  func makeChatURLRequest(
    _ request: ChatRequest,
    url: URL? = nil,
    timeoutInterval: TimeInterval = 60.0
  ) throws -> URLRequest {
    guard let resolvedURL = url ?? LocalEndpointUtilities.chatCompletionsURL(baseURL: endpoint)
    else {
      throw NSError(
        domain: "OllamaProvider", code: 15,
        userInfo: [NSLocalizedDescriptionKey: "Invalid local endpoint URL"])
    }

    var urlRequest = URLRequest(url: resolvedURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuthorizationHeader(to: &urlRequest)
    urlRequest.httpBody = try JSONEncoder().encode(request)
    urlRequest.timeoutInterval = timeoutInterval
    return urlRequest
  }

  func callChatAPI(
    _ request: ChatRequest, operation: String, batchId: Int64? = nil, maxRetries: Int = 3
  ) async throws -> ChatResponse {
    guard let url = LocalEndpointUtilities.chatCompletionsURL(baseURL: endpoint) else {
      throw NSError(
        domain: "OllamaProvider", code: 15,
        userInfo: [NSLocalizedDescriptionKey: "Invalid local endpoint URL"])
    }

    // Retry logic with exponential backoff
    let attempts = max(1, maxRetries)
    var lastError: Error?

    let callGroupId = UUID().uuidString
    for attempt in 0..<attempts {
      var ctxForAttempt: LLMCallContext?
      var didLogFailureThisAttempt = false
      var didLogTiming = false
      var apiStart: Date?
      do {
        let urlRequest = try makeChatURLRequest(request, url: url)

        let start = Date()
        apiStart = start
        let requestBodyForLogging: Data?
        if operation == "describe_frame" {
          // Don't persist raw base64 image payloads to the LLM call log (SQLite)
          requestBodyForLogging = nil
        } else {
          requestBodyForLogging = urlRequest.httpBody
        }
        let ctx = LLMCallContext(
          batchId: batchId,
          callGroupId: callGroupId,
          attempt: attempt + 1,
          provider: localEngine,  // Track actual engine: ollama, lmstudio, or custom
          providerID: providerID.rawValue,
          model: request.model,
          operation: operation,
          requestMethod: urlRequest.httpMethod,
          requestURL: urlRequest.url,
          requestHeaders: urlRequest.allHTTPHeaderFields,
          requestBody: requestBodyForLogging,
          startedAt: start
        )
        ctxForAttempt = ctx
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let requestDuration = Date().timeIntervalSince(start)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        logCallDuration(operation: operation, duration: requestDuration, status: statusCode)
        didLogTiming = true

        guard let httpResponse = response as? HTTPURLResponse else {
          throw NSError(
            domain: "OllamaProvider", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard httpResponse.statusCode == 200 else {
          let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
          // Log failure with response body via centralized logger
          let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
            acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }
          LLMLogger.logFailure(
            ctx: ctx,
            http: LLMHTTPInfo(
              httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders,
              responseBody: data),
            finishedAt: Date(),
            errorDomain: "OllamaProvider",
            errorCode: httpResponse.statusCode,
            errorMessage: errorBody
          )
          didLogFailureThisAttempt = true
          throw NSError(
            domain: "OllamaProvider", code: 4,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Ollama API request failed with status \(httpResponse.statusCode): \(errorBody)"
            ])
        }

        do {
          let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
          // Centralized success log
          let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
            acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }
          LLMLogger.logSuccess(
            ctx: ctx,
            http: LLMHTTPInfo(
              httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders,
              responseBody: data),
            finishedAt: Date()
          )
          return chatResponse
        } catch {
          // Centralized parse failure
          let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
            acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }
          LLMLogger.logFailure(
            ctx: ctx,
            http: LLMHTTPInfo(
              httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders,
              responseBody: data),
            finishedAt: Date(),
            errorDomain: (error as NSError).domain,
            errorCode: (error as NSError).code,
            errorMessage: (error as NSError).localizedDescription
          )
          didLogFailureThisAttempt = true
          throw error
        }

      } catch {
        lastError = error
        if !didLogTiming, let startedAt = apiStart {
          let requestDuration = Date().timeIntervalSince(startedAt)
          logCallDuration(operation: operation, duration: requestDuration, status: nil)
          didLogTiming = true
        }
        print("[OLLAMA] Request failed (attempt \(attempt + 1)/\(attempts)): \(error)")

        // If it's not the last attempt, wait before retrying
        if attempt < attempts - 1 {
          let backoffDelay = pow(2.0, Double(attempt)) * 2.0  // 2s, 4s, 8s
          try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
        }
        // Network error log without http info
        if !didLogFailureThisAttempt {
          let fallbackBodyForLogging: Data?
          if operation == "describe_frame" {
            fallbackBodyForLogging = nil
          } else {
            fallbackBodyForLogging = try? JSONEncoder().encode(request)
          }
          let ctx =
            ctxForAttempt
            ?? LLMCallContext(
              batchId: batchId,
              callGroupId: callGroupId,
              attempt: attempt + 1,
              provider: localEngine,  // Track actual engine: ollama, lmstudio, or custom
              providerID: providerID.rawValue,
              model: request.model,
              operation: operation,
              requestMethod: "POST",
              requestURL: url,
              requestHeaders: ["Content-Type": "application/json"],
              requestBody: fallbackBodyForLogging,
              startedAt: Date()
            )
          LLMLogger.logFailure(
            ctx: ctx,
            http: nil,
            finishedAt: Date(),
            errorDomain: (error as NSError).domain,
            errorCode: (error as NSError).code,
            errorMessage: (error as NSError).localizedDescription
          )
          didLogFailureThisAttempt = true
        }
      }
    }

    throw lastError
      ?? NSError(
        domain: "OllamaProvider", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Request failed after \(attempts) attempts"])
  }

  // (no local logging helpers needed; centralized via LLMLogger)

  // Helper method for text-only requests
  func callTextAPI(
    _ prompt: String, operation: String, expectJSON: Bool = false, batchId: Int64? = nil,
    maxRetries: Int = 3, maxTokens: Int = 4000
  ) async throws -> String {
    let systemPrompt =
      expectJSON
      ? "You are a helpful assistant. Always respond with valid JSON."
      : "You are a helpful assistant."

    let request = ChatRequest(
      model: savedModelId,
      messages: [
        ChatMessage(
          role: "system",
          content: [MessageContent(type: "text", text: systemPrompt, image_url: nil)]),
        ChatMessage(
          role: "user", content: [MessageContent(type: "text", text: prompt, image_url: nil)]),
      ],
      temperature: 0.7,
      max_tokens: maxTokens,
      stream: false
    )

    let response = try await callChatAPI(
      request, operation: operation, batchId: batchId, maxRetries: maxRetries)
    return response.choices.first?.message.content ?? ""
  }

  private func applyAuthorizationHeader(to request: inout URLRequest) {
    if let token = authorizationBearerToken {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
  }
}

// MARK: - Text Generation

extension OllamaProvider {
  func generateText(prompt: String, maxTokens: Int = 4000) async throws
    -> (text: String, log: LLMCall)
  {
    let callStart = Date()

    let response = try await callTextAPI(
      prompt,
      operation: "generate_text",
      expectJSON: false,
      batchId: nil,
      maxRetries: 3,
      maxTokens: maxTokens
    )

    let log = LLMCall(
      timestamp: callStart,
      latency: Date().timeIntervalSince(callStart),
      input: prompt,
      output: response
    )

    return (response.trimmingCharacters(in: .whitespacesAndNewlines), log)
  }
}
