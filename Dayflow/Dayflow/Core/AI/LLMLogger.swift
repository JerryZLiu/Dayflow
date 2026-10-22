//
//  LLMLogger.swift
//  Dayflow
//

import Foundation

struct LLMCallContext: Sendable {
  let batchId: Int64?
  let callGroupId: String?
  let attempt: Int
  let provider: String
  var providerID: String? = nil
  let model: String?
  let operation: String
  let requestMethod: String?
  let requestURL: URL?
  let requestHeaders: [String: String]?
  let requestBody: Data?
  let startedAt: Date
}

struct LLMHTTPInfo: Sendable {
  let httpStatus: Int?
  let responseHeaders: [String: String]?
  let responseBody: Data?
}

enum LLMLogStatus: String { case success, failure }

enum LLMLogger {
  private static let maxStoredBodyBytes = 64 * 1024

  // Best-effort: never throw, never block pipeline beyond DB write time
  static func logSuccess(ctx: LLMCallContext, http: LLMHTTPInfo, finishedAt: Date) {
    let latencyMs = Int(finishedAt.timeIntervalSince(ctx.startedAt) * 1000)
    let record = makeRecord(
      ctx: ctx, http: http, status: .success, latencyMs: latencyMs, error: nil)
    StorageManager.shared.insertLLMCall(record)
    let usage = usageProperties(http)
    Task { @MainActor in
      var props: [String: Any] = [
        "provider": ctx.provider,
        "model": ctx.model ?? "unknown",
        "latency_ms": latencyMs,
        "outcome": "success",
        "operation": ctx.operation,
        "attempt": ctx.attempt,
      ]

      if let batchId = ctx.batchId { props["batch_id"] = batchId }
      if let groupId = ctx.callGroupId { props["group_id"] = groupId }
      if let providerID = ctx.providerID { props["provider_id"] = providerID }
      props.merge(usage) { _, new in new }

      AnalyticsService.shared.capture("llm_api_call", props)
    }
  }

  static func logFailure(
    ctx: LLMCallContext, http: LLMHTTPInfo?, finishedAt: Date, errorDomain: String?,
    errorCode: Int?, errorMessage: String?, failureStdout: String? = nil,
    failureStderr: String? = nil
  ) {
    let latencyMs = Int(finishedAt.timeIntervalSince(ctx.startedAt) * 1000)
    let record = makeRecord(
      ctx: ctx, http: http, status: .failure, latencyMs: latencyMs,
      error: (errorDomain, errorCode, errorMessage))
    StorageManager.shared.insertLLMCall(record)
    let usage = usageProperties(http)
    Task { @MainActor in
      var props: [String: Any] = [
        "provider": ctx.provider,
        "model": ctx.model ?? "unknown",
        "latency_ms": latencyMs,
        "outcome": "error",
        "operation": ctx.operation,
        "attempt": ctx.attempt,
      ]

      if let batchId = ctx.batchId { props["batch_id"] = batchId }
      if let groupId = ctx.callGroupId { props["group_id"] = groupId }
      if let providerID = ctx.providerID { props["provider_id"] = providerID }
      if let errorDomain, !errorDomain.isEmpty { props["error_domain"] = errorDomain }
      if let errorCode { props["error_code"] = errorCode }
      if let errorMessage {
        props["error_message_length"] = errorMessage.count
        if let sanitizedMessage = TelemetryErrorSanitizer.sanitize(errorMessage) {
          props["error_message"] = sanitizedMessage
          props["error_message_sanitized"] = true
        }
      }
      props.merge(
        TelemetryErrorSanitizer.failureOutputProperties(failureStdout, prefix: "stdout")
      ) { _, new in new }
      props.merge(
        TelemetryErrorSanitizer.failureOutputProperties(failureStderr, prefix: "stderr")
      ) { _, new in new }
      if let httpStatus = http?.httpStatus { props["http_status"] = httpStatus }
      props.merge(usage) { _, new in new }
      if let body = http?.responseBody {
        props["has_response_body"] = true
        props["response_body_bytes"] = body.count
      } else {
        props["has_response_body"] = false
      }

      AnalyticsService.shared.capture("llm_api_call", props)
    }
  }

  /// Token counts for the analytics event, stored the way Claude reports them: input without
  /// the cached part, cached input, cache writes, and output (thinking included).
  /// CLI providers pass them as x-usage-* headers; HTTP providers return them in the body.
  private static func usageProperties(_ http: LLMHTTPInfo?) -> [String: Int] {
    let usage = usageFromHeaders(http?.responseHeaders) ?? usageFromBody(http?.responseBody)
    guard let usage else { return [:] }
    return [
      "usage_input_tokens": usage.input,
      "usage_cached_input_tokens": usage.cachedInput,
      "usage_cache_creation_input_tokens": usage.cacheCreationInput,
      "usage_output_tokens": usage.output,
    ]
  }

  private static func usageFromHeaders(_ headers: [String: String]?) -> TokenUsage? {
    guard let headers, let input = headers["x-usage-input"].flatMap({ Int($0) }) else {
      return nil
    }
    return TokenUsage(
      input: input,
      cachedInput: headers["x-usage-cached-input"].flatMap { Int($0) } ?? 0,
      cacheCreationInput: headers["x-usage-cache-creation-input"].flatMap { Int($0) } ?? 0,
      output: headers["x-usage-output"].flatMap { Int($0) } ?? 0)
  }

  private static func usageFromBody(_ body: Data?) -> TokenUsage? {
    guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return nil }
    func count(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    // Gemini: promptTokenCount includes cached tokens; thinking is counted separately.
    if let gemini = json["usageMetadata"] as? [String: Any] {
      let cached = count(gemini["cachedContentTokenCount"])
      return TokenUsage(
        input: max(0, count(gemini["promptTokenCount"]) - cached), cachedInput: cached,
        output: count(gemini["candidatesTokenCount"]) + count(gemini["thoughtsTokenCount"]))
    }

    // OpenAI-compatible servers (LM Studio, custom endpoints): prompt_tokens includes cached.
    if let openAI = json["usage"] as? [String: Any], openAI["prompt_tokens"] != nil {
      let details = openAI["prompt_tokens_details"] as? [String: Any]
      let cached = count(details?["cached_tokens"])
      return TokenUsage(
        input: max(0, count(openAI["prompt_tokens"]) - cached), cachedInput: cached,
        output: count(openAI["completion_tokens"]))
    }

    // Ollama's native API.
    if json["prompt_eval_count"] != nil || json["eval_count"] != nil {
      return TokenUsage(
        input: count(json["prompt_eval_count"]), cachedInput: 0,
        output: count(json["eval_count"]))
    }

    return nil
  }

  private static func makeRecord(
    ctx: LLMCallContext, http: LLMHTTPInfo?, status: LLMLogStatus, latencyMs: Int?,
    error: (String?, Int?, String?)?
  ) -> LLMCallDBRecord {
    let (sanURL, sanHeaders) = sanitize(url: ctx.requestURL, headers: ctx.requestHeaders)
    let reqBodyString = dataToUTF8String(ctx.requestBody)
    let resHeadersString = jsonString(http?.responseHeaders)
    let resBodyString = dataToUTF8String(http?.responseBody)

    return LLMCallDBRecord(
      batchId: ctx.batchId,
      callGroupId: ctx.callGroupId,
      attempt: ctx.attempt,
      provider: ctx.provider,
      model: ctx.model,
      operation: ctx.operation,
      status: status.rawValue,
      latencyMs: latencyMs,
      httpStatus: http?.httpStatus,
      requestMethod: ctx.requestMethod,
      requestURL: sanURL?.absoluteString,
      requestHeadersJSON: jsonString(sanHeaders),
      requestBody: reqBodyString,
      responseHeadersJSON: resHeadersString,
      responseBody: resBodyString,
      errorDomain: error?.0,
      errorCode: error?.1,
      errorMessage: error?.2
    )
  }

  private static func sanitize(url: URL?, headers: [String: String]?) -> (URL?, [String: String]?) {
    guard let url = url else { return (nil, sanitizeHeaders(headers)) }
    var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    if let items = comps?.queryItems {
      let redactedKeys = Set([
        "key", "api_key", "apiKey", "access_token", "token", "authorization", "x-goog-api-key",
        "x-api-key",
      ])
      comps?.queryItems = items.map { item in
        if redactedKeys.contains(item.name.lowercased()) {
          return URLQueryItem(name: item.name, value: "<redacted>")
        }
        return item
      }
    }
    return (comps?.url, sanitizeHeaders(headers))
  }

  private static func sanitizeHeaders(_ headers: [String: String]?) -> [String: String]? {
    guard let headers else { return nil }
    let drop = Set(["authorization", "proxy-authorization", "x-api-key", "x-goog-api-key"])
    var out: [String: String] = [:]
    for (k, v) in headers {
      if drop.contains(k.lowercased()) { continue }
      out[k] = v
    }
    return out
  }

  private static func dataToUTF8String(_ data: Data?) -> String? {
    guard let data else { return nil }
    guard data.count <= maxStoredBodyBytes else {
      let prefix = data.prefix(maxStoredBodyBytes)
      let preview = String(decoding: prefix, as: UTF8.self)
      return """
        <truncated llm body: original_bytes=\(data.count), stored_prefix_bytes=\(maxStoredBodyBytes)>
        \(preview)
        """
    }

    return String(data: data, encoding: .utf8) ?? "<non-utf8 data length=\(data.count)>"
  }

  private static func jsonString(_ dict: [String: String]?) -> String? {
    guard let dict else { return nil }
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
      return String(data: data, encoding: .utf8)
    }
    return nil
  }
}
