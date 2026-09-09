import Foundation

extension GeminiDirectProvider {
  func truncate(_ text: String, max: Int = 2000) -> String {
    // Default to full debug payloads so dashboard-chat issues are easier to inspect.
    // Set `geminiDebugClipLogs` in UserDefaults to restore clipping behavior.
    let shouldClipDebugLogs = UserDefaults.standard.bool(forKey: "geminiDebugClipLogs")
    if !shouldClipDebugLogs { return text }
    if text.count <= max { return text }
    let endIdx = text.index(text.startIndex, offsetBy: max)
    return String(text[..<endIdx]) + "…(truncated)"
  }

  func headerValue(_ response: URLResponse?, _ name: String) -> String? {
    (response as? HTTPURLResponse)?.value(forHTTPHeaderField: name)
  }

  func logGeminiFailure(
    context: String, attempt: Int? = nil, response: URLResponse?, data: Data?, error: Error?
  ) {
    var parts: [String] = []
    parts.append("🔎 GEMINI DEBUG: context=\(context)")
    if let attempt { parts.append("attempt=\(attempt)") }
    if let http = response as? HTTPURLResponse {
      parts.append("status=\(http.statusCode)")
      let reqId =
        headerValue(response, "X-Goog-Request-Id") ?? headerValue(response, "x-request-id")
      if let reqId { parts.append("requestId=\(reqId)") }
      if let ct = headerValue(response, "Content-Type") { parts.append("contentType=\(ct)") }
    }
    if let error = error as NSError? {
      parts.append("error=\(error.domain)#\(error.code): \(error.localizedDescription)")
    }
    print(parts.joined(separator: " "))

    if let data {
      if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let keys = Array(jsonObj.keys).sorted().joined(separator: ", ")
        if let err = jsonObj["error"] as? [String: Any] {
          let message = err["message"] as? String ?? "<none>"
          let status = err["status"] as? String ?? "<none>"
          let code = err["code"] as? Int ?? -1
          print(
            "🔎 GEMINI DEBUG: errorObject code=\(code) status=\(status) message=\(truncate(message, max: 500))"
          )
        } else {
          print("🔎 GEMINI DEBUG: jsonKeys=[\(keys)]")
        }
      }
      if let body = String(data: data, encoding: .utf8) {
        print("🔎 GEMINI DEBUG: bodySnippet=\(truncate(body, max: 1200))")
      } else {
        print("🔎 GEMINI DEBUG: bodySnippet=<non-UTF8 data length=\(data.count) bytes>")
      }
    }
  }

  func logCallDuration(operation: String, duration: TimeInterval, status: Int? = nil) {
    let statusText = status.map { " status=\($0)" } ?? ""
    print("⏱️ [Gemini] \(operation) \(String(format: "%.2f", duration))s\(statusText)")
  }

  // Gemini sometimes streams a well-formed JSON payload before aborting with HTTP 503.
  // When this happens we want to salvage the first JSON object so the caller can proceed.
  func extractFirstJSONObject(from body: String) -> String? {
    guard let start = body.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) else {
      return nil
    }
    guard body[start] == "{" else { return nil }

    var depth = 0
    var inString = false
    var isEscaped = false
    var index = start

    while index < body.endIndex {
      let ch = body[index]

      if inString {
        if isEscaped {
          isEscaped = false
        } else if ch == "\\" {
          isEscaped = true
        } else if ch == "\"" {
          inString = false
        }
      } else {
        switch ch {
        case "\"":
          inString = true
        case "{":
          depth += 1
        case "}":
          depth -= 1
          if depth == 0 {
            return String(body[start...index])
          }
        default:
          break
        }
      }

      index = body.index(after: index)
    }

    return nil
  }

  func recover503CandidateText(_ data: Data) -> String? {
    guard let bodyString = String(data: data, encoding: .utf8) else { return nil }
    guard let objectString = extractFirstJSONObject(from: bodyString) else { return nil }
    guard let objectData = objectString.data(using: .utf8) else { return nil }

    guard
      let json = try? JSONSerialization.jsonObject(with: objectData) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let firstCandidate = candidates.first,
      let content = firstCandidate["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let text = parts.first?["text"] as? String
    else {
      return nil
    }

    return text
  }
}
