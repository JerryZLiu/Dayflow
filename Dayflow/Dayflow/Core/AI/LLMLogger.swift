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
    // Best-effort: never throw, never block pipeline beyond DB write time
    static func logSuccess(ctx: LLMCallContext, http: LLMHTTPInfo, finishedAt: Date) {
        let latencyMs = Int(finishedAt.timeIntervalSince(ctx.startedAt) * 1000)
        let record = makeRecord(ctx: ctx, http: http, status: .success, latencyMs: latencyMs, error: nil)
        StorageManager.shared.insertLLMCall(record)
        Task { @MainActor in
            var props: [String: Any] = [
                "provider": ctx.provider,
                "model": ctx.model ?? "unknown",
                "latency_ms": latencyMs,
                "outcome": "success",
                "operation": ctx.operation
            ]

            if let batchId = ctx.batchId { props["batch_id"] = batchId }
            if let groupId = ctx.callGroupId { props["group_id"] = groupId }

            // Bubble token usage if present in response headers (non-HTTP calls may stuff them here).
            if let headers = http.responseHeaders {
                if let v = headers["x-usage-input"], let n = Int(v) { props["usage_input_tokens"] = n }
                if let v = headers["x-usage-cached-input"], let n = Int(v) { props["usage_cached_input_tokens"] = n }
                if let v = headers["x-usage-output"], let n = Int(v) { props["usage_output_tokens"] = n }
            }

            AnalyticsService.shared.capture("llm_api_call", props)
        }
    }

    static func logFailure(ctx: LLMCallContext, http: LLMHTTPInfo?, finishedAt: Date, errorDomain: String?, errorCode: Int?, errorMessage: String?) {
        let latencyMs = Int(finishedAt.timeIntervalSince(ctx.startedAt) * 1000)
        let record = makeRecord(ctx: ctx, http: http, status: .failure, latencyMs: latencyMs, error: (errorDomain, errorCode, errorMessage))
        StorageManager.shared.insertLLMCall(record)
        Task { @MainActor in
            var props: [String: Any] = [
                "provider": ctx.provider,
                "model": ctx.model ?? "unknown",
                "latency_ms": latencyMs,
                "outcome": "error",
                "operation": ctx.operation
            ]

            if let batchId = ctx.batchId { props["batch_id"] = batchId }
            if let groupId = ctx.callGroupId { props["group_id"] = groupId }
            if let errorCode { props["error_code"] = errorCode }
            if let errorMessage, !errorMessage.isEmpty { props["error_message"] = errorMessage }

            AnalyticsService.shared.capture("llm_api_call", props)
        }
    }

    private static func makeRecord(ctx: LLMCallContext, http: LLMHTTPInfo?, status: LLMLogStatus, latencyMs: Int?, error: (String?, Int?, String?)?) -> LLMCallDBRecord {
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

    private static func sanitize(url: URL?, headers: [String: String]?) -> (URL?, [String:String]?) {
        guard let url = url else { return (nil, sanitizeHeaders(headers)) }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let items = comps?.queryItems {
            let redactedKeys = Set(["key","api_key","apiKey","access_token","token","authorization","x-goog-api-key","x-api-key"]) 
            comps?.queryItems = items.map { item in
                if redactedKeys.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: "<redacted>")
                }
                return item
            }
        }
        return (comps?.url, sanitizeHeaders(headers))
    }

    private static func sanitizeHeaders(_ headers: [String:String]?) -> [String:String]? {
        guard let headers else { return nil }
        let drop = Set(["authorization","proxy-authorization","x-api-key","x-goog-api-key"]) 
        var out: [String:String] = [:]
        for (k,v) in headers {
            if drop.contains(k.lowercased()) { continue }
            out[k] = v
        }
        return out
    }

    private static func dataToUTF8String(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8) ?? "<non-utf8 data length=\(data.count)>"
    }

    private static func jsonString(_ dict: [String:String]?) -> String? {
        guard let dict else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
