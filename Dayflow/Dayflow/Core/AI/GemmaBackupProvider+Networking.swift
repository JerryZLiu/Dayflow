import AppKit
import Foundation

extension GemmaBackupProvider {
  // MARK: - Networking

  func callGenerateContent(
    parts: [[String: Any]],
    operation: String,
    batchId: Int64?,
    temperature: Double,
    maxOutputTokens: Int,
    logRequestBody: Bool
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
      callGroupId: UUID().uuidString,
      attempt: 1,
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

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let firstCandidate = candidates.first,
      let content = firstCandidate["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let text = parts.first?["text"] as? String
    else {
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
      if let startIndex = responseString.firstIndex(of: "{"),
        let endIndex = responseString.lastIndex(of: "}")
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

  func loadScreenshotData(
    _ screenshot: Screenshot, maxDimension: CGFloat = 1280, compression: CGFloat = 0.7
  ) -> Data? {
    let url = URL(fileURLWithPath: screenshot.filePath)
    guard let image = NSImage(contentsOf: url) else { return nil }

    let originalSize = image.size
    let maxSide = max(originalSize.width, originalSize.height)
    let scale = maxSide > maxDimension ? (maxDimension / maxSide) : 1.0
    let targetSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

    let resized = NSImage(size: targetSize)
    resized.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: originalSize),
      operation: .copy, fraction: 1.0)
    resized.unlockFocus()

    guard let tiff = resized.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff)
    else { return nil }

    let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    return jpegData
  }
}
