import Foundation

extension GeminiDirectProvider {
  func streamDashboardTurn(
    systemInstruction: String,
    contents: [[String: Any]],
    includeThinkingConfig: Bool,
    continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
  ) async throws -> DashboardTurnResult {
    let requestBody = dashboardChatRequestBody(
      systemInstruction: systemInstruction,
      contents: contents,
      includeThinkingConfig: includeThinkingConfig
    )
    var request = URLRequest(url: URL(string: dashboardStreamEndpoint + "?alt=sse&key=\(apiKey)")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 180
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "GeminiDashboardChat",
        code: 902,
        userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response from Gemini stream endpoint."]
      )
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let errorBody = try await readAllData(from: bytes)
      let message =
        extractGeminiErrorMessage(from: errorBody)
        ?? "Gemini stream request failed with HTTP \(httpResponse.statusCode)."
      throw NSError(
        domain: "GeminiDashboardChat",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    var accumulatedText = ""
    var lastSeenCandidateText = ""
    var functionCalls: [DashboardFunctionCall] = []
    var modelFunctionCallParts: [[String: Any]] = []
    var seenFunctionCalls: Set<String> = []
    var dataBuffer: [String] = []

    for try await line in bytes.lines {
      if line.hasPrefix("data:") {
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if !payload.isEmpty {
          dataBuffer.append(payload)
        }
        continue
      }

      if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        guard !dataBuffer.isEmpty else { continue }
        try processDashboardSSEPayload(
          dataBuffer.joined(separator: "\n"),
          continuation: continuation,
          accumulatedText: &accumulatedText,
          lastSeenCandidateText: &lastSeenCandidateText,
          functionCalls: &functionCalls,
          modelFunctionCallParts: &modelFunctionCallParts,
          seenFunctionCalls: &seenFunctionCalls
        )
        dataBuffer.removeAll(keepingCapacity: true)
      }
    }

    if !dataBuffer.isEmpty {
      try processDashboardSSEPayload(
        dataBuffer.joined(separator: "\n"),
        continuation: continuation,
        accumulatedText: &accumulatedText,
        lastSeenCandidateText: &lastSeenCandidateText,
        functionCalls: &functionCalls,
        modelFunctionCallParts: &modelFunctionCallParts,
        seenFunctionCalls: &seenFunctionCalls
      )
    }

    return DashboardTurnResult(
      text: accumulatedText,
      functionCalls: functionCalls,
      modelFunctionCallParts: modelFunctionCallParts
    )
  }

  func generateDashboardTurnNonStreaming(
    systemInstruction: String,
    contents: [[String: Any]],
    includeThinkingConfig: Bool
  ) async throws
    -> DashboardTurnResult
  {
    let requestBody = dashboardChatRequestBody(
      systemInstruction: systemInstruction,
      contents: contents,
      includeThinkingConfig: includeThinkingConfig
    )
    var request = URLRequest(url: URL(string: dashboardGenerateEndpoint + "?key=\(apiKey)")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 180
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "GeminiDashboardChat",
        code: 903,
        userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response from Gemini endpoint."]
      )
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let message =
        extractGeminiErrorMessage(from: data)
        ?? "Gemini request failed with HTTP \(httpResponse.statusCode)."
      throw NSError(
        domain: "GeminiDashboardChat",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    let parsed = try parseDashboardResponseData(data)
    return DashboardTurnResult(
      text: parsed.text,
      functionCalls: parsed.functionCalls,
      modelFunctionCallParts: parsed.modelFunctionCallParts
    )
  }

  func parseDashboardResponseData(_ data: Data) throws -> (
    text: String, functionCalls: [DashboardFunctionCall], modelFunctionCallParts: [[String: Any]]
  ) {
    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let firstCandidate = candidates.first,
      let content = firstCandidate["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]]
    else {
      throw NSError(
        domain: "GeminiDashboardChat",
        code: 904,
        userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini response format."]
      )
    }

    var text = ""
    var calls: [DashboardFunctionCall] = []
    var modelFunctionCallParts: [[String: Any]] = []
    var seenFunctionCalls: Set<String> = []

    for part in parts {
      if let partText = part["text"] as? String {
        text += partText
      }
      if let functionCall = try parseDashboardFunctionCall(from: part) {
        let fingerprint = dashboardFunctionCallFingerprint(functionCall)
        guard !seenFunctionCalls.contains(fingerprint) else { continue }
        seenFunctionCalls.insert(fingerprint)
        calls.append(functionCall)
        modelFunctionCallParts.append(part)
      }
    }

    return (
      text.trimmingCharacters(in: .whitespacesAndNewlines),
      calls,
      modelFunctionCallParts
    )
  }

  func processDashboardSSEPayload(
    _ payload: String,
    continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation,
    accumulatedText: inout String,
    lastSeenCandidateText: inout String,
    functionCalls: inout [DashboardFunctionCall],
    modelFunctionCallParts: inout [[String: Any]],
    seenFunctionCalls: inout Set<String>
  ) throws {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if trimmed == "[DONE]" { return }

    let chunkObjects: [[String: Any]]
    do {
      chunkObjects = try decodeDashboardSSEChunkObjects(from: trimmed)
    } catch {
      logGeminiFailure(
        context: "dashboard_chat.stream.parse_chunk",
        response: nil,
        data: trimmed.data(using: .utf8),
        error: error
      )
      throw error
    }

    if chunkObjects.count > 1 {
      print(
        "🔎 GEMINI DEBUG: dashboard_chat.stream.parse_chunk decodedObjects=\(chunkObjects.count)")
    }

    for json in chunkObjects {
      try processDashboardSSEChunkObject(
        json,
        continuation: continuation,
        accumulatedText: &accumulatedText,
        lastSeenCandidateText: &lastSeenCandidateText,
        functionCalls: &functionCalls,
        modelFunctionCallParts: &modelFunctionCallParts,
        seenFunctionCalls: &seenFunctionCalls
      )
    }
  }

  func processDashboardSSEChunkObject(
    _ json: [String: Any],
    continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation,
    accumulatedText: inout String,
    lastSeenCandidateText: inout String,
    functionCalls: inout [DashboardFunctionCall],
    modelFunctionCallParts: inout [[String: Any]],
    seenFunctionCalls: inout Set<String>
  ) throws {
    guard
      let candidates = json["candidates"] as? [[String: Any]],
      let candidate = candidates.first,
      let content = candidate["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]]
    else {
      // Ignore non-content stream messages.
      return
    }

    var aggregatedCandidateText = ""
    for part in parts {
      if let partText = part["text"] as? String {
        aggregatedCandidateText += partText
      }

      if let functionCall = try parseDashboardFunctionCall(from: part) {
        let fingerprint = dashboardFunctionCallFingerprint(functionCall)
        guard !seenFunctionCalls.contains(fingerprint) else { continue }
        seenFunctionCalls.insert(fingerprint)
        functionCalls.append(functionCall)
        // Preserve the model-emitted part verbatim so required fields like thought_signature
        // survive when we replay functionCall parts in the next turn.
        modelFunctionCallParts.append(part)
      }
    }

    if functionCalls.isEmpty && !aggregatedCandidateText.isEmpty {
      let delta: String
      if aggregatedCandidateText.hasPrefix(lastSeenCandidateText) {
        delta = String(aggregatedCandidateText.dropFirst(lastSeenCandidateText.count))
      } else {
        delta = aggregatedCandidateText
      }

      if !delta.isEmpty {
        accumulatedText += delta
        continuation.yield(.textDelta(delta))
      }
      lastSeenCandidateText = aggregatedCandidateText
    }
  }

  func decodeDashboardSSEChunkObjects(from payload: String) throws -> [[String: Any]] {
    if let data = payload.data(using: .utf8) {
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return [object]
      }
      if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        return array
      }
    }

    var lineDecodedObjects: [[String: Any]] = []
    for rawLine in payload.split(separator: "\n", omittingEmptySubsequences: true) {
      var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      if line == "[DONE]" { continue }
      if line.hasPrefix("data:") {
        line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !line.isEmpty else { continue }
      guard
        let lineData = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
      else {
        lineDecodedObjects = []
        break
      }
      lineDecodedObjects.append(object)
    }
    if !lineDecodedObjects.isEmpty {
      return lineDecodedObjects
    }

    let objectStrings = extractJSONObjectStrings(from: payload)
    var extractedObjects: [[String: Any]] = []
    for objectString in objectStrings {
      guard let data = objectString.data(using: .utf8) else { continue }
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        continue
      }
      extractedObjects.append(object)
    }

    if !extractedObjects.isEmpty {
      return extractedObjects
    }

    throw NSError(
      domain: "GeminiDashboardChat",
      code: 905,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Failed to parse streamed Gemini chunk (len=\(payload.count))."
      ]
    )
  }

  func extractJSONObjectStrings(from body: String) -> [String] {
    var objects: [String] = []
    var depth = 0
    var inString = false
    var isEscaped = false
    var objectStart: String.Index?
    var index = body.startIndex

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
          if depth == 0 {
            objectStart = index
          }
          depth += 1
        case "}":
          if depth > 0 {
            depth -= 1
            if depth == 0, let start = objectStart {
              objects.append(String(body[start...index]))
              objectStart = nil
            }
          }
        default:
          break
        }
      }

      index = body.index(after: index)
    }

    return objects
  }

  func dashboardChatContents(from history: [DashboardChatTurn]) -> [[String: Any]] {
    history.map { turn in
      [
        "role": turn.role.geminiRole,
        "parts": [
          ["text": turn.content]
        ],
      ]
    }
  }

  func parseDashboardFunctionCall(from part: [String: Any]) throws -> DashboardFunctionCall? {
    guard let functionCall = part["functionCall"] as? [String: Any] else { return nil }
    guard let name = functionCall["name"] as? String, !name.isEmpty else {
      throw NSError(
        domain: "GeminiDashboardChat",
        code: 906,
        userInfo: [NSLocalizedDescriptionKey: "Function call is missing a name."]
      )
    }

    if let args = functionCall["args"] as? [String: Any] {
      return DashboardFunctionCall(name: name, args: args)
    }

    if let argsJSON = functionCall["args"] as? String,
      let data = argsJSON.data(using: .utf8),
      let args = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      return DashboardFunctionCall(name: name, args: args)
    }

    return DashboardFunctionCall(name: name, args: [:])
  }

  func extractGeminiErrorMessage(from data: Data) -> String? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let errorObj = json["error"] as? [String: Any]
    else {
      return nil
    }

    if let message = errorObj["message"] as? String, !message.isEmpty {
      return message
    }
    return nil
  }

  func shouldRetryDashboardWithoutThinkingConfig(_ error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    guard
      message.contains("thinkingconfig")
        || message.contains("thinking level")
        || message.contains("thinkinglevel")
        || message.contains("unknown name \"thinkingconfig\"")
        || message.contains("generationconfig")
        || message.contains("invalid enum value")
    else {
      return false
    }

    let nsError = error as NSError
    return nsError.domain == "GeminiDashboardChat" || nsError.code == 400
  }

  func readAllData(from bytes: URLSession.AsyncBytes) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
    }
    return data
  }
}
