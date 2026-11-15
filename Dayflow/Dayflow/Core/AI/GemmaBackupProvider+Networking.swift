import AppKit
import Foundation

extension GemmaBackupProvider {
  // MARK: - Networking

  /// Waits before the second and third try of a request that failed on Google's side.
  private static var retryDelays: [TimeInterval] { [2, 5] }
  private static var emptyReplyCode: Int { 15 }

  /// Sends one request, trying again after a short wait when the failure is temporary: a
  /// server error or overload, a network timeout, or an empty reply. Key, billing, quota and
  /// other 4xx answers are thrown straight away, because asking again gets the same answer.
  func callGenerateContent(
    parts: [[String: Any]],
    operation: String,
    batchId: Int64?,
    temperature: Double,
    maxOutputTokens: Int,
    logRequestBody: Bool
  ) async throws -> String {
    let callGroupId = UUID().uuidString
    var attempt = 1
    while true {
      do {
        return try await sendGenerateContent(
          parts: parts, operation: operation, batchId: batchId, temperature: temperature,
          maxOutputTokens: maxOutputTokens, logRequestBody: logRequestBody,
          callGroupId: callGroupId, attempt: attempt)
      } catch {
        guard Self.isTemporaryFailure(error), attempt <= Self.retryDelays.count else {
          throw error
        }
        let delay = Self.retryDelays[attempt - 1]
        print("[Gemma] \(operation) attempt \(attempt) failed, retrying in \(Int(delay))s")
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        attempt += 1
      }
    }
  }

  /// A failure that a plain retry can fix.
  static func isTemporaryFailure(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      return [
        NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
      ].contains(nsError.code)
    }
    guard nsError.domain == "GemmaBackupProvider" else { return false }
    return (500...599).contains(nsError.code) || nsError.code == emptyReplyCode
  }

  /// A failure of the request itself, as opposed to a reply that came back but could not be
  /// used. `callGenerateContent` has already retried the temporary ones, so callers that retry
  /// with a stricter prompt should give up on these: a stricter prompt does not fix them.
  static func isRequestFailure(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain { return true }
    guard nsError.domain == "GemmaBackupProvider" else { return false }
    return nsError.code >= 400 || nsError.code == emptyReplyCode
  }

  private func sendGenerateContent(
    parts: [[String: Any]],
    operation: String,
    batchId: Int64?,
    temperature: Double,
    maxOutputTokens: Int,
    logRequestBody: Bool,
    callGroupId: String,
    attempt: Int
  ) async throws -> String {
    let url = URL(string: "\(baseURL)/\(model):generateContent?key=\(apiKey)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120

    let requestBody: [String: Any] = [
      "contents": [["parts": parts]],
      "generationConfig": [
        "temperature": temperature,
        "maxOutputTokens": maxOutputTokens,
      ],
    ]

    let requestData = try JSONSerialization.data(withJSONObject: requestBody)
    request.httpBody = requestData

    let requestStart = Date()
    let logBody = logRequestBody ? requestData : nil

    let ctx = LLMCallContext(
      batchId: batchId,
      callGroupId: callGroupId,
      attempt: attempt,
      provider: "gemma",
      model: model,
      operation: operation,
      requestMethod: request.httpMethod,
      requestURL: request.url,
      requestHeaders: request.allHTTPHeaderFields,
      requestBody: logBody,
      startedAt: requestStart
    )

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      LLMLogger.logFailure(
        ctx: ctx,
        http: nil,
        finishedAt: Date(),
        errorDomain: (error as NSError).domain,
        errorCode: (error as NSError).code,
        errorMessage: (error as NSError).localizedDescription
      )
      throw error
    }

    let httpResponse = response as? HTTPURLResponse
    let status = httpResponse?.statusCode
    let responseHeaders: [String: String]? = httpResponse?.allHeaderFields.reduce(into: [:]) {
      acc, kv in
      if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
        acc[k] = v.description
      }
    }

    if let status, status >= 400 {
      let errorMessage = extractErrorMessage(from: data, fallback: "HTTP \(status) error")
      LLMLogger.logFailure(
        ctx: ctx,
        http: LLMHTTPInfo(httpStatus: status, responseHeaders: responseHeaders, responseBody: data),
        finishedAt: Date(),
        errorDomain: "GemmaBackupProvider",
        errorCode: status,
        errorMessage: errorMessage
      )
      throw NSError(
        domain: "GemmaBackupProvider", code: status,
        userInfo: [NSLocalizedDescriptionKey: errorMessage])
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      LLMLogger.logFailure(
        ctx: ctx,
        http: LLMHTTPInfo(httpStatus: status, responseHeaders: responseHeaders, responseBody: data),
        finishedAt: Date(),
        errorDomain: "GemmaBackupProvider",
        errorCode: 0,
        errorMessage: "Failed to parse response"
      )
      throw NSError(
        domain: "GemmaBackupProvider", code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Failed to parse response"])
    }

    // A 200 with no candidates, no parts or blank text is an empty reply. It keeps the
    // "Failed to parse response" wording that failure handling already recognises.
    let candidates = json["candidates"] as? [[String: Any]]
    let content = candidates?.first?["content"] as? [String: Any]
    let replyParts = content?["parts"] as? [[String: Any]]
    guard let text = replyParts?.first?["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      let message = "Failed to parse response: empty reply from Gemma"
      LLMLogger.logFailure(
        ctx: ctx,
        http: LLMHTTPInfo(httpStatus: status, responseHeaders: responseHeaders, responseBody: data),
        finishedAt: Date(),
        errorDomain: "GemmaBackupProvider",
        errorCode: Self.emptyReplyCode,
        errorMessage: message
      )
      throw NSError(
        domain: "GemmaBackupProvider", code: Self.emptyReplyCode,
        userInfo: [NSLocalizedDescriptionKey: message])
    }

    LLMLogger.logSuccess(
      ctx: ctx,
      http: LLMHTTPInfo(httpStatus: status, responseHeaders: responseHeaders, responseBody: data),
      finishedAt: Date()
    )

    return text
  }

  func extractErrorMessage(from data: Data, fallback: String) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = json["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      return message
    }
    return fallback
  }

  // MARK: - Utilities

  func parseJSONResponse<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
    guard let data = text.data(using: .utf8) else {
      throw NSError(
        domain: "GemmaBackupProvider", code: 14,
        userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
    }

    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      // Attempt to extract JSON object
      guard let responseString = String(data: data, encoding: .utf8) else {
        throw error
      }
      // A garbled reply can put its last "}" before its first "{"; slicing that
      // range traps at runtime, so only slice when the bounds are ordered.
      if let startIndex = responseString.firstIndex(of: "{"),
        let endIndex = responseString.lastIndex(of: "}"),
        startIndex <= endIndex
      {
        let jsonSubstring = responseString[startIndex...endIndex]
        if let jsonData = jsonSubstring.data(using: .utf8) {
          return try JSONDecoder().decode(type, from: jsonData)
        }
      }
      throw error
    }
  }

  func frameDescriptionPrompt(frameCount: Int) -> String {
    """
    You are a precise activity logger analyzing screenshots from a screen recording. For each screenshot, describe EXACTLY what the user is doing with hyper-specific detail.

    REQUIRED DETAILS FOR EACH FRAME:
    1. EXACT APP/SITE: Name the specific application (e.g., "VS Code", "Xcode", "Safari on twitter.com", "Terminal running npm")
    2. SPECIFIC ACTION: What is the user actively doing? (e.g., "typing code", "reading article", "scrolling feed", "debugging error", "running command")
    3. VISIBLE CONTENT: What specific content is shown? (e.g., "Swift function called fetchUserData", "PostHog dashboard showing DAU chart", "Google search for 'tokyo restaurants'")
    4. UI STATE: Any relevant UI details (e.g., "error dialog visible", "loading spinner", "dropdown menu open", "cursor in search bar")

    BAD (too vague): "User is using a code editor"
    GOOD (specific): "VS Code with Swift file AuthManager.swift open, cursor on line 45 inside fetchToken() function, yellow warning on line 42"

    BAD: "User is browsing the web"
    GOOD: "Safari on tabelog.com restaurant page for 'Haidilao Shibuya', scrolling through reviews section, 4.2 star rating visible"

    Output ONLY valid JSON:
    {
      "frames": [
        {"index": 1, "description": "Hyper-specific description"},
        {"index": 2, "description": "Hyper-specific description"}
      ]
    }

    Analyze these \(frameCount) screenshots with maximum specificity:
    """
  }

  func segmentPrompt(
    frameDescriptions: [(timestamp: TimeInterval, description: String)], durationString: String,
    targetSegments: Int
  ) -> String {
    var lines: [String] = []
    for frame in frameDescriptions {
      let minutes = Int(frame.timestamp) / 60
      let seconds = Int(frame.timestamp) % 60
      let timeStr = String(format: "%02d:%02d", minutes, seconds)
      lines.append("- \(timeStr): \(frame.description)")
    }
    let framesText = lines.joined(separator: "\n")

    return """
      Create an activity log from \(durationString) of screen recording.

      Frame descriptions:
      \(framesText)

      TARGET: Create EXACTLY \(targetSegments) segment(s). Not more, not less.

      MERGING RULES (CRITICAL):
      - Same app + same activity = ONE segment (even if 10+ minutes)
      - Same game session = ONE segment (don't split by in-game events)
      - Same video = ONE segment (don't split by video timestamps)
      - Same conversation = ONE segment (don't split by messages)
      - Quick app switches serving same goal = ONE segment

      FORBIDDEN SEGMENTS:
      - "Transition" or "Shifted focus" segments (just end previous, start next)
      - Segments under 2 minutes (merge with adjacent)
      - Segments describing nothing specific

      DESCRIPTION FORMAT:
      "[App]: [Specific task] - [key details: files, URLs, names, outcomes]"

      GOOD: "YouTube: Watching 'Ninja CREAMi: Pacojet Killer?' review by Chris Young, evaluating ice cream makers"
      GOOD: "Kingdom Two Crowns: Playing snowy biome campaign, building settlement, survived multiple nights (+100 coins rewards)"
      BAD: "Transition: Shifted from YouTube to restaurant search" (FORBIDDEN)
      BAD: "YouTube: Watching video" then "YouTube: Continued watching" (should be ONE segment)

      Output JSON only:
      {"segments": [{"start": "00:00", "end": "MM:SS", "description": "..."}]}
      """
  }

  func normalizeCategory(_ raw: String, categories: [LLMCategoryDescriptor]) -> String {
    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return categories.first?.name ?? "" }
    let normalized = cleaned.lowercased()
    if let match = categories.first(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }) {
      return match.name
    }
    if let idle = categories.first(where: { $0.isIdle }) {
      let idleLabels = [
        "idle", "idle time", idle.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      ]
      if idleLabels.contains(normalized) {
        return idle.name
      }
    }
    return categories.first?.name ?? cleaned
  }

  func buildAppSites(from response: SummaryResponse.AppSitesResponse?) -> AppSites? {
    guard let response else { return nil }
    let primary = response.primary?.trimmingCharacters(in: .whitespacesAndNewlines)
    let secondary = response.secondary?.trimmingCharacters(in: .whitespacesAndNewlines)

    let cleanedPrimary = primary?.isEmpty == false ? primary : nil
    let cleanedSecondary = secondary?.isEmpty == false ? secondary : nil

    if cleanedPrimary == nil && cleanedSecondary == nil {
      return nil
    }

    return AppSites(primary: cleanedPrimary, secondary: cleanedSecondary)
  }

  func formatTimestampForPrompt(_ timestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  func parseVideoTimestamp(_ timestamp: String) -> Int {
    let components = timestamp.components(separatedBy: ":")
    if components.count == 2 {
      let minutes = Int(components[0]) ?? 0
      let seconds = Int(components[1]) ?? 0
      return minutes * 60 + seconds
    } else if components.count == 3 {
      let hours = Int(components[0]) ?? 0
      let minutes = Int(components[1]) ?? 0
      let seconds = Int(components[2]) ?? 0
      return hours * 3600 + minutes * 60 + seconds
    }
    return 0
  }

  func calculateDurationInMinutes(from startTime: String, to endTime: String) -> Int {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    guard let start = formatter.date(from: startTime),
      let end = formatter.date(from: endTime)
    else {
      return 0
    }

    var duration = end.timeIntervalSince(start)
    if duration < 0 {
      duration += 24 * 60 * 60
    }

    return Int(duration / 60)
  }
}
