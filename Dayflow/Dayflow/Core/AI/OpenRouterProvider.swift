//
//  OpenRouterProvider.swift
//  Dayflow
//
//  OpenRouter-powered LLM provider. Uses the OpenAI-compatible chat completions
//  endpoint (https://openrouter.ai/api/v1/chat/completions) with Bearer auth.
//  Supports vision for screenshot transcription and text for card generation + chat.
//

import AppKit
import Foundation

// MARK: - API Types

struct ORChatRequest: Codable {
    let model: String
    let messages: [ORMessage]
    var temperature: Double = 0.7
    var max_tokens: Int = 4000
    var stream: Bool = false
    var response_format: ORResponseFormat?

    struct ORResponseFormat: Codable {
        let type: String // "text" or "json_object"
    }
}

struct ORMessage: Codable {
    let role: String
    let content: [ORContentPart]
}

struct ORContentPart: Codable {
    let type: String
    let text: String?
    let image_url: ORImageURL?

    struct ORImageURL: Codable {
        let url: String
    }
}

struct ORChatResponse: Codable {
    let choices: [ORChoice]
    let usage: ORUsage?

    struct ORChoice: Codable {
        let message: ORResponseMessage
    }

    struct ORResponseMessage: Codable {
        let content: String?
    }

    struct ORUsage: Codable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
}

struct ORModelListResponse: Codable {
    let data: [ORModelEntry]
}

struct ORModelEntry: Codable, Identifiable {
    let id: String
    let name: String?
    let created: Int?
    let description: String?
    let pricing: ORModelPricing?
    let context_length: Int?

    var modelID: String { id }

    struct ORModelPricing: Codable {
        let prompt: String?
        let completion: String?
    }
}

// MARK: - Error

enum ORProviderError: LocalizedError {
    case noAPIKey
    case invalidURL
    case httpError(Int, String)
    case parseError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "OpenRouter API key not configured. Add it in Settings > Providers."
        case .invalidURL: return "Invalid OpenRouter API URL."
        case .httpError(let code, let body): return "OpenRouter returned HTTP \(code): \(body)"
        case .parseError(let msg): return "Failed to parse OpenRouter response: \(msg)"
        case .networkError(let msg): return "OpenRouter network error: \(msg)"
        }
    }
}

// MARK: - Provider

final class OpenRouterProvider {
    static let defaultBaseURL = "https://openrouter.ai/api/v1"
    static let defaultModel = "deepseek/deepseek-v4-flash"

    let baseURL: String
    let screenshotInterval: TimeInterval = 10

    private var apiKey: String? {
        KeychainManager.shared.retrieve(for: "openrouter")
    }

    var savedModelId: String {
        UserDefaults.standard.string(forKey: "openrouterModelId") ?? Self.defaultModel
    }

    init(baseURL: String = defaultBaseURL) {
        self.baseURL = baseURL
    }

    // MARK: - URL Building

    private func url(_ path: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }
        var normalizedPath = components.path
        if normalizedPath.hasSuffix("/") { normalizedPath = String(normalizedPath.dropLast()) }
        let fullPath = normalizedPath + path
        components.path = fullPath
        return components.url
    }

    private var chatCompletionsURL: URL? { url("/chat/completions") }
    private var modelsURL: URL? { url("/models") }

    // MARK: - Common HTTP Call

    private func makeRequest(path: String, body: Data?) -> URLRequest? {
        guard let url = url(path) else { return nil }
        guard let key = apiKey, !key.isEmpty else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = body != nil ? "POST" : "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("Dayflow/1.0", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Dayflow", forHTTPHeaderField: "X-Title")
        req.httpBody = body
        req.timeoutInterval = 120
        return req
    }

    /// Sends a chat request and returns the parsed response + usage info.
    func callChatAPI(
        model: String? = nil,
        messages: [ORMessage],
        operation: String,
        batchId: Int64? = nil,
        maxRetries: Int = 3,
        responseFormat: ORChatRequest.ORResponseFormat? = nil
    ) async throws -> (response: ORChatResponse, model: String) {
        guard let key = apiKey, !key.isEmpty else { throw ORProviderError.noAPIKey }

        let actualModel = model ?? savedModelId
        var request = ORChatRequest(
            model: actualModel,
            messages: messages,
            temperature: 0.7,
            max_tokens: 8000,
            stream: false
        )
        request.response_format = responseFormat
        let body = try JSONEncoder().encode(request)

        guard let urlRequest = makeRequest(path: "/chat/completions", body: body) else {
            throw ORProviderError.invalidURL
        }

        let callGroupId = UUID().uuidString
        var lastError: Error?

        for attempt in 0..<max(maxRetries, 1) {
            let start = Date()
            let ctx = LLMCallContext(
                batchId: batchId,
                callGroupId: callGroupId,
                attempt: attempt + 1,
                provider: "openrouter",
                model: actualModel,
                operation: operation,
                requestMethod: "POST",
                requestURL: urlRequest.url,
                requestHeaders: urlRequest.allHTTPHeaderFields,
                requestBody: body,
                startedAt: start
            )

            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ORProviderError.networkError("Invalid response type")
                }

                guard httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
                    let headers: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
                        if let k = $1.key as? String, let v = $1.value as? CustomStringConvertible {
                            $0[k] = v.description
                        }
                    }
                    LLMLogger.logFailure(
                        ctx: ctx,
                        http: LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: headers, responseBody: data),
                        finishedAt: Date(),
                        errorDomain: "OpenRouterProvider",
                        errorCode: httpResponse.statusCode,
                        errorMessage: errorBody
                    )
                    throw ORProviderError.httpError(httpResponse.statusCode, errorBody)
                }

                let decoded = try JSONDecoder().decode(ORChatResponse.self, from: data)
                let headers: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
                    if let k = $1.key as? String, let v = $1.value as? CustomStringConvertible {
                        $0[k] = v.description
                    }
                }
                LLMLogger.logSuccess(ctx: ctx, http: LLMHTTPInfo(httpStatus: 200, responseHeaders: headers, responseBody: data), finishedAt: Date())
                return (decoded, actualModel)

            } catch {
                lastError = error
                print("[OR] Request failed (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    let delay = pow(2.0, Double(attempt)) * 2.0
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else if let orError = error as? ORProviderError {
                    throw orError
                } else {
                    throw ORProviderError.networkError(error.localizedDescription)
                }
            }
        }

        throw lastError ?? ORProviderError.networkError("Request failed after \(maxRetries) attempts")
    }

    // MARK: - Text-Only Helper

    func callTextAPI(
        _ prompt: String,
        operation: String,
        model: String? = nil,
        expectJSON: Bool = false,
        batchId: Int64? = nil,
        maxRetries: Int = 3,
        maxTokens: Int = 4000
    ) async throws -> String {
        let systemPrompt = expectJSON
            ? "You are a helpful assistant. Always respond with valid JSON."
            : "You are a helpful assistant."

        let messages: [ORMessage] = [
            ORMessage(role: "system", content: [ORContentPart(type: "text", text: systemPrompt, image_url: nil)]),
            ORMessage(role: "user", content: [ORContentPart(type: "text", text: prompt, image_url: nil)])
        ]

        let (response, _) = try await callChatAPI(
            model: model,
            messages: messages,
            operation: operation,
            batchId: batchId,
            maxRetries: maxRetries,
            responseFormat: expectJSON ? ORChatRequest.ORResponseFormat(type: "json_object") : nil
        )
        return response.choices.first?.message.content ?? ""
    }

    // MARK: - Model Listing

    func fetchAvailableModels() async throws -> [ORModelEntry] {
        guard let key = apiKey, !key.isEmpty else { throw ORProviderError.noAPIKey }
        guard let req = makeRequest(path: "/models", body: nil) else { throw ORProviderError.invalidURL }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw ORProviderError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        let list = try JSONDecoder().decode(ORModelListResponse.self, from: data)
        return list.data.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    // MARK: - Text Generation (LLMCall compatible)

    func generateText(prompt: String, maxTokens: Int = 4000) async throws -> (text: String, log: LLMCall) {
        let callStart = Date()
        let response = try await callTextAPI(prompt, operation: "generate_text", maxTokens: maxTokens)
        let log = LLMCall(
            timestamp: callStart,
            latency: Date().timeIntervalSince(callStart),
            input: prompt,
            output: response
        )
        return (response.trimmingCharacters(in: .whitespacesAndNewlines), log)
    }
}

// MARK: - Logging Helper

private extension OpenRouterProvider {
    func logCallDuration(operation: String, duration: TimeInterval, status: Int? = nil) {
        let statusText = status.map { " status=\($0)" } ?? ""
        print("⏱️ [openrouter] \(operation) \(String(format: "%.2f", duration))s\(statusText)")
    }
}