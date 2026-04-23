import Foundation

extension GeminiDirectProvider {
  /// Internal method to transcribe video data after compositing from screenshots.
  ///
  /// - Parameters:
  ///   - videoData: The video file data
  ///   - mimeType: MIME type of the video
  ///   - batchStartTime: When this batch started (for absolute timestamp calculation)
  ///   - videoDuration: Duration of the compressed video (in seconds)
  ///   - realDuration: Actual real-world duration this video represents (in seconds)
  ///   - compressionFactor: How much the timeline is compressed (e.g., 10 = 10x faster)
  ///   - batchId: Optional batch ID for logging
  func transcribeVideoData(
    _ videoData: Data,
    mimeType: String,
    batchStartTime: Date,
    videoDuration: TimeInterval,
    realDuration: TimeInterval,
    compressionFactor: TimeInterval,
    batchId: Int64?
  ) async throws -> (observations: [Observation], log: LLMCall) {
    let callStart = Date()

    // First, save video data to a temporary file
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString).mp4")
    try videoData.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let fileURI = try await uploadAndAwait(tempURL, mimeType: mimeType, key: apiKey).1

    // Format compressed video duration for the prompt
    let durationMinutes = Int(videoDuration / 60)
    let durationSeconds = Int(videoDuration.truncatingRemainder(dividingBy: 60))
    let durationString = String(format: "%02d:%02d", durationMinutes, durationSeconds)

    // realDuration is available via compressionFactor if needed for debugging

    let finalTranscriptionPrompt = """
      Screen Recording Transcription (Reconstruct Mode)
      Watch this screen recording and create an activity log detailed enough that someone could reconstruct the session.
      CRITICAL: This video is exactly \(durationString) long. ALL timestamps must be within 00:00 to \(durationString). No gaps.
      Identifying the active app: On macOS, the app name is always shown in the top-left corner of the screen, right next to the Apple () menu. Check this FIRST to identify which app is being used. Do NOT guess — read the actual name from the menu bar. If you can't read it clearly, describe it generically (e.g., "code editor," "browser," "messaging app") rather than guessing a specific product name. Common code editors like Cursor, VS Code, Xcode, and Zed all look similar but have different names in the menu bar.
      For each segment, ask yourself:
      "What EXACTLY did they do? What SPECIFIC things can I see?"
      Capture:
      - Exact app/site names visible (check menu bar for app name)
      - Exact file names, URLs, page titles
      - Exact usernames, search queries, messages
      - Exact numbers, stats, prices shown
      Bad: "Checked email"
      Good: "Gmail: Read email from boss@company.com 'RE: Budget approval' - replied 'Looks good'"
      Bad: "Browsing Twitter"
      Good: "Twitter/X: Scrolled feed - viewed posts by @pmarca about AI, @sama thread on GPT-5 (12 tweets)"
      Bad: "Working on code"
      Good: "Editing StorageManager.swift in [exact app name from menu bar] - fixed type error on line 47, changed String to String?"
      Segments:
      - 3-8 segments total
      - You may use 1 segment only if the user appears idle for most of the recording
      - Group by GOAL not app (IDE + Terminal + Browser for the same task = 1 segment)
      - Do not create gaps; cover the full timeline
      Return ONLY JSON in this format:
      [
      {
      "startTimestamp": "MM:SS",
      "endTimestamp": "MM:SS",
      "description": "1-3 sentences with specific details"
      }
      ]
      """

    // UNIFIED RETRY LOOP - Handles ALL errors comprehensively
    let maxRetries = 3
    var attempt = 0
    var lastError: Error?
    var finalResponse = ""
    var finalObservations: [Observation] = []

    var modelState = ModelRunState(models: modelPreference.orderedModels)
    let callGroupId = UUID().uuidString

    while attempt < maxRetries {
      do {
        print("🔄 Video transcribe attempt \(attempt + 1)/\(maxRetries)")
        let activeModel = modelState.current
        let (response, usedModel) = try await geminiTranscribeRequest(
          fileURI: fileURI,
          mimeType: mimeType,
          prompt: finalTranscriptionPrompt,
          batchId: batchId,
          groupId: callGroupId,
          model: activeModel,
          attempt: attempt + 1
        )

        let videoTranscripts = try parseTranscripts(response)

        // Convert video transcripts to observations with proper Unix timestamps
        // Timestamps from Gemini are in compressed video time, so we expand them
        // by the compression factor to get real-world timestamps.
        var hasValidationErrors = false
        let observations = videoTranscripts.compactMap { chunk -> Observation? in
          let compressedStartSeconds = parseVideoTimestamp(chunk.startTimestamp)
          let compressedEndSeconds = parseVideoTimestamp(chunk.endTimestamp)

          // Validate timestamps are within compressed video duration (with small tolerance)
          let tolerance: TimeInterval = 10.0  // 10 seconds tolerance in compressed time
          if Double(compressedStartSeconds) < -tolerance
            || Double(compressedEndSeconds) > videoDuration + tolerance
          {
            print(
              "❌ VALIDATION ERROR: Observation timestamps (\(chunk.startTimestamp) - \(chunk.endTimestamp)) exceed video duration \(durationString)!"
            )
            hasValidationErrors = true
            return nil
          }

          // Expand timestamps by compression factor to get real-world time
          let realStartSeconds = TimeInterval(compressedStartSeconds) * compressionFactor
          let realEndSeconds = TimeInterval(compressedEndSeconds) * compressionFactor

          let startDate = batchStartTime.addingTimeInterval(realStartSeconds)
          let endDate = batchStartTime.addingTimeInterval(realEndSeconds)

          print(
            "📐 Timestamp expansion: \(chunk.startTimestamp)-\(chunk.endTimestamp) → \(Int(realStartSeconds))s-\(Int(realEndSeconds))s real"
          )

          return Observation(
            id: nil,
            batchId: 0,  // Will be set when saved
            startTs: Int(startDate.timeIntervalSince1970),
            endTs: Int(endDate.timeIntervalSince1970),
            observation: chunk.description,
            metadata: nil,
            llmModel: usedModel,
            createdAt: Date()
          )
        }

        // If we had validation errors, throw to trigger retry
        if hasValidationErrors {
          AnalyticsService.shared.captureValidationFailure(
            provider: "gemini",
            operation: "transcribe",
            validationType: "timestamp_exceeds_duration",
            attempt: attempt + 1,
            model: activeModel.rawValue,
            batchId: batchId,
            errorDetail: "Observations exceeded video duration \(durationString)"
          )
          throw NSError(
            domain: "GeminiProvider", code: 100,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Gemini generated observations with timestamps exceeding video duration. Video is \(durationString) long but observations extended beyond this."
            ])
        }

        // Ensure we have at least one observation
        if observations.isEmpty {
          AnalyticsService.shared.captureValidationFailure(
            provider: "gemini",
            operation: "transcribe",
            validationType: "empty_observations",
            attempt: attempt + 1,
            model: activeModel.rawValue,
            batchId: batchId,
            errorDetail: "No valid observations after filtering"
          )
          throw NSError(
            domain: "GeminiProvider", code: 101,
            userInfo: [
              NSLocalizedDescriptionKey:
                "No valid observations generated after filtering out invalid timestamps"
            ])
        }

        // SUCCESS! All validations passed
        print("✅ Video transcription succeeded on attempt \(attempt + 1)")
        finalResponse = response
        finalObservations = observations
        break

      } catch {
        lastError = error
        print("❌ Attempt \(attempt + 1) failed: \(error.localizedDescription)")

        var appliedFallback = false
        if let nsError = error as NSError?,
          nsError.domain == "GeminiError",
          Self.capacityErrorCodes.contains(nsError.code),
          let transition = modelState.advance()
        {

          appliedFallback = true
          let reason = fallbackReason(for: nsError.code)
          print("↔️ Switching to \(transition.to.rawValue) after \(nsError.code)")

          Task { @MainActor in
            AnalyticsService.shared.capture(
              "llm_model_fallback",
              [
                "provider": "gemini",
                "operation": "transcribe",
                "from_model": transition.from.rawValue,
                "to_model": transition.to.rawValue,
                "reason": reason,
                "batch_id": batchId as Any,
              ])
          }
        }

        if !appliedFallback {
          // Normal error handling with backoff
          let strategy = classifyError(error)

          // Check if we should retry
          if strategy == .noRetry || attempt >= maxRetries - 1 {
            print("🚫 Not retrying: strategy=\(strategy), attempt=\(attempt + 1)/\(maxRetries)")
            throw error
          }

          // Apply appropriate delay based on error type
          let delay = delayForStrategy(strategy, attempt: attempt)
          if delay > 0 {
            print(
              "⏳ Waiting \(String(format: "%.1f", delay))s before retry (strategy: \(strategy))")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          }
        }
      }

      attempt += 1
    }

    // Check if we succeeded
    guard !finalObservations.isEmpty else {
      throw lastError
        ?? NSError(
          domain: "GeminiProvider", code: 102,
          userInfo: [
            NSLocalizedDescriptionKey: "Video transcription failed after \(maxRetries) attempts"
          ])
    }

    let log = LLMCall(
      timestamp: callStart,
      latency: Date().timeIntervalSince(callStart),
      input: finalTranscriptionPrompt,
      output: finalResponse
    )

    return (finalObservations, log)
  }

  func geminiTranscribeRequest(
    fileURI: String, mimeType: String, prompt: String, batchId: Int64?, groupId: String,
    model: GeminiModel, attempt: Int
  ) async throws -> (String, String) {
    let transcriptionSchema: [String: Any] = [
      "type": "ARRAY",
      "items": [
        "type": "OBJECT",
        "properties": [
          "startTimestamp": ["type": "STRING"],
          "endTimestamp": ["type": "STRING"],
          "description": ["type": "STRING"],
        ],
        "required": ["startTimestamp", "endTimestamp", "description"],
        "propertyOrdering": ["startTimestamp", "endTimestamp", "description"],
      ],
    ]

    let generationConfig: [String: Any] = [
      "temperature": 0.3,
      "maxOutputTokens": 65536,
      "mediaResolution": "MEDIA_RESOLUTION_HIGH",
      "responseMimeType": "application/json",
      "responseSchema": transcriptionSchema,
    ]

    let requestBody: [String: Any] = [
      "contents": [
        [
          "parts": [
            ["file_data": ["mime_type": mimeType, "file_uri": fileURI]],
            ["text": prompt],
          ]
        ]
      ],
      "generationConfig": generationConfig,
    ]

    // Single API call (no retry logic in this function)
    let urlWithKey = endpointForModel(model) + "?key=\(apiKey)"
    var request = URLRequest(url: URL(string: urlWithKey)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120  // 2 minutes timeout
    let requestStart = Date()

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

      let (data, response) = try await URLSession.shared.data(for: request)
      let requestDuration = Date().timeIntervalSince(requestStart)

      guard let httpResponse = response as? HTTPURLResponse else {
        print("🔴 Non-HTTP response received")
        throw NSError(
          domain: "GeminiError", code: 9, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"]
        )
      }

      logCallDuration(
        operation: "transcribe.generateContent", duration: requestDuration,
        status: httpResponse.statusCode)

      // Prepare logging context
      let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
        acc, kv in
        if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
          acc[k] = v.description
        }
      }
      let modelName = model.rawValue
      let ctx = LLMCallContext(
        batchId: batchId,
        callGroupId: groupId,
        attempt: attempt,
        provider: "gemini",
        model: modelName,
        operation: "transcribe",
        requestMethod: request.httpMethod,
        requestURL: request.url,
        requestHeaders: request.allHTTPHeaderFields,
        requestBody: request.httpBody,
        startedAt: requestStart
      )
      let httpInfo = LLMHTTPInfo(
        httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data)

      // Check HTTP status first - any 400+ is a failure, except for a special 503 case where
      // Gemini sometimes streams a valid payload before closing with an error.
      if httpResponse.statusCode >= 400 {
        if httpResponse.statusCode == 503, let recovered = recover503CandidateText(data) {
          print(
            "⚠️ HTTP 503 received, but valid candidate payload was recovered; treating as success.")
          logGeminiFailure(
            context: "transcribe.http503.salvaged", attempt: attempt, response: response,
            data: data, error: nil)
          LLMLogger.logSuccess(
            ctx: ctx,
            http: httpInfo,
            finishedAt: Date()
          )
          return (recovered, model.rawValue)
        } else if httpResponse.statusCode == 503 {
          let preview =
            String(data: data, encoding: .utf8).map { truncate($0, max: 200) } ?? "<non-UTF8 body>"
          print("⚠️ HTTP 503 contained no recoverable payload. preview=\(preview)")
          logGeminiFailure(
            context: "transcribe.http503.unrecoverable", attempt: attempt, response: response,
            data: data, error: nil)
        }

        print("🔴 HTTP error status: \(httpResponse.statusCode)")
        if let bodyText = String(data: data, encoding: .utf8) {
          print("   Response Body: \(truncate(bodyText, max: 2000))")
        } else {
          print("   Response Body: <non-UTF8 data, \(data.count) bytes>")
        }

        // Try to parse error details for better error message
        var errorMessage = "HTTP \(httpResponse.statusCode) error"
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = json["error"] as? [String: Any]
        {
          if let code = error["code"] { print("   Error Code: \(code)") }
          if let message = error["message"] as? String {
            print("   Error Message: \(message)")
            errorMessage = message
          }
          if let status = error["status"] { print("   Error Status: \(status)") }
          if let details = error["details"] { print("   Error Details: \(details)") }
        }

        // Log as failure and throw
        LLMLogger.logFailure(
          ctx: ctx,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "HTTPError",
          errorCode: httpResponse.statusCode,
          errorMessage: errorMessage
        )
        logGeminiFailure(
          context: "transcribe.httpError", attempt: attempt, response: response, data: data,
          error: nil)
        throw NSError(
          domain: "GeminiError", code: httpResponse.statusCode,
          userInfo: [NSLocalizedDescriptionKey: errorMessage])
      }

      // HTTP status is good (200-299), now validate content
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        LLMLogger.logFailure(
          ctx: ctx,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "ParseError",
          errorCode: 7,
          errorMessage: "Invalid JSON response"
        )
        logGeminiFailure(
          context: "transcribe.generateContent.invalidJSON", attempt: attempt, response: response,
          data: data, error: nil)
        throw NSError(
          domain: "GeminiError", code: 7,
          userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
      }

      guard let candidates = json["candidates"] as? [[String: Any]],
        let firstCandidate = candidates.first
      else {
        LLMLogger.logFailure(
          ctx: ctx,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "ParseError",
          errorCode: 7,
          errorMessage: "No candidates in response"
        )
        logGeminiFailure(
          context: "transcribe.generateContent.noCandidates", attempt: attempt, response: response,
          data: data, error: nil)
        throw NSError(
          domain: "GeminiError", code: 7,
          userInfo: [NSLocalizedDescriptionKey: "No candidates in response"])
      }

      guard let content = firstCandidate["content"] as? [String: Any] else {
        LLMLogger.logFailure(
          ctx: ctx,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "ParseError",
          errorCode: 7,
          errorMessage: "No content in candidate"
        )
        logGeminiFailure(
          context: "transcribe.generateContent.noContent", attempt: attempt, response: response,
          data: data, error: nil)
        throw NSError(
          domain: "GeminiError", code: 7,
          userInfo: [NSLocalizedDescriptionKey: "No content in candidate"])
      }

      guard let parts = content["parts"] as? [[String: Any]],
        let firstPart = parts.first,
        let text = firstPart["text"] as? String
      else {
        LLMLogger.logFailure(
          ctx: ctx,
          http: httpInfo,
          finishedAt: Date(),
          errorDomain: "ParseError",
          errorCode: 7,
          errorMessage: "Empty content - no parts array"
        )
        logGeminiFailure(
          context: "transcribe.generateContent.emptyContent", attempt: attempt, response: response,
          data: data, error: nil)
        throw NSError(
          domain: "GeminiError", code: 7,
          userInfo: [NSLocalizedDescriptionKey: "Empty content - no parts array"])
      }

      // Everything succeeded - log success and return
      LLMLogger.logSuccess(
        ctx: ctx,
        http: httpInfo,
        finishedAt: Date()
      )

      return (text, model.rawValue)

    } catch {
      // Only log if this is a network/transport error (not our custom GeminiError which was already logged)
      if (error as NSError).domain != "GeminiError" {
        let modelName = model.rawValue
        let ctx = LLMCallContext(
          batchId: batchId,
          callGroupId: groupId,
          attempt: attempt,
          provider: "gemini",
          model: modelName,
          operation: "transcribe",
          requestMethod: request.httpMethod,
          requestURL: request.url,
          requestHeaders: request.allHTTPHeaderFields,
          requestBody: request.httpBody,
          startedAt: requestStart
        )
        LLMLogger.logFailure(
          ctx: ctx,
          http: nil,
          finishedAt: Date(),
          errorDomain: (error as NSError).domain,
          errorCode: (error as NSError).code,
          errorMessage: (error as NSError).localizedDescription
        )
      }

      // Log detailed error information
      print("🔴 GEMINI TRANSCRIBE FAILED:")
      print("   Error Type: \(type(of: error))")
      print("   Error Description: \(error.localizedDescription)")

      // Log URLError details if applicable
      if let urlError = error as? URLError {
        print("   URLError Code: \(urlError.code.rawValue) (\(urlError.code))")
        if let failingURL = urlError.failingURL {
          print("   Failing URL: \(failingURL.absoluteString)")
        }

        // Check for specific network errors
        switch urlError.code {
        case .timedOut:
          print("   ⏱️ REQUEST TIMED OUT")
        case .notConnectedToInternet:
          print("   📵 NO INTERNET CONNECTION")
        case .networkConnectionLost:
          print("   📡 NETWORK CONNECTION LOST")
        case .cannotFindHost:
          print("   🔍 CANNOT FIND HOST")
        case .cannotConnectToHost:
          print("   🚫 CANNOT CONNECT TO HOST")
        case .badServerResponse:
          print("   💔 BAD SERVER RESPONSE")
        default:
          break
        }
      }

      // Log NSError details if applicable
      if let nsError = error as NSError? {
        print("   NSError Domain: \(nsError.domain)")
        print("   NSError Code: \(nsError.code)")
        if !nsError.userInfo.isEmpty {
          print("   NSError UserInfo: \(nsError.userInfo)")
        }
      }

      // Log transport/parse error
      logGeminiFailure(
        context: "transcribe.generateContent.catch", attempt: attempt, response: nil, data: nil,
        error: error)

      // Rethrow error (outer loop in calling function handles retries)
      throw error
    }
  }

  // Temporary struct for parsing Gemini response
  struct VideoTranscriptChunk: Codable {
    let startTimestamp: String  // MM:SS
    let endTimestamp: String  // MM:SS
    let description: String
  }

  func parseTranscripts(_ response: String) throws -> [VideoTranscriptChunk] {
    guard let data = response.data(using: .utf8) else {
      print(
        "🔎 GEMINI DEBUG: parseTranscripts received non-UTF8 or empty response: \(truncate(response, max: 400))"
      )
      throw NSError(
        domain: "GeminiError", code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
    }
    do {
      let transcripts = try JSONDecoder().decode([VideoTranscriptChunk].self, from: data)
      return transcripts
    } catch {
      let snippet = truncate(String(data: data, encoding: .utf8) ?? "<non-utf8>", max: 1200)
      print(
        "🔎 GEMINI DEBUG: parseTranscripts JSON decode failed: \(error.localizedDescription) bodySnippet=\(snippet)"
      )
      throw error
    }
  }

  func parseVideoTimestamp(_ timestamp: String) -> Int {
    let components = timestamp.components(separatedBy: ":")

    if components.count == 2 {
      // MM:SS format
      let minutes = Int(components[0]) ?? 0
      let seconds = Int(components[1]) ?? 0
      return minutes * 60 + seconds
    } else if components.count == 3 {
      // HH:MM:SS format
      let hours = Int(components[0]) ?? 0
      let minutes = Int(components[1]) ?? 0
      let seconds = Int(components[2]) ?? 0
      return hours * 3600 + minutes * 60 + seconds
    } else {
      // Invalid format, return 0
      print("Warning: Invalid video timestamp format: \(timestamp)")
      return 0
    }
  }

  // Helper function to format timestamps
  func formatTimestampForPrompt(_ unixTime: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  // MARK: - Screenshot Transcription

  /// Transcribe observations from screenshots by first compositing them into a video.
  /// Gemini's API expects video files, so we composite screenshots → video → upload → transcribe.
  ///
  /// We use a compressed timeline: each screenshot = 1 second of video.
  /// This reduces a 15-minute batch (90 screenshots) to a 90-second video.
  /// Timestamps returned by Gemini are then expanded by the screenshot interval.
  func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?)
    async throws -> (observations: [Observation], log: LLMCall)
  {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "GeminiDirectProvider", code: 11,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
    }

    let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

    // Calculate real duration from timestamp range (for timestamp expansion later)
    let firstTs = sortedScreenshots.first!.capturedAt
    let lastTs = sortedScreenshots.last!.capturedAt
    let realDuration = TimeInterval(lastTs - firstTs)

    // Compressed video duration: 1 second per screenshot
    let compressedVideoDuration = TimeInterval(sortedScreenshots.count)

    // Compression factor = screenshot interval (e.g., 10s screenshots → 10x compression)
    let compressionFactor = ScreenshotConfig.interval

    print(
      "[Gemini] 📊 Timeline compression: \(Int(realDuration))s real → \(Int(compressedVideoDuration))s video (\(Int(compressionFactor))x)"
    )

    // Create temp video file
    let tempVideoURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("gemini_batch_\(batchId ?? 0)_\(UUID().uuidString).mp4")

    defer {
      try? FileManager.default.removeItem(at: tempVideoURL)
    }

    // Composite screenshots into compressed video (1fps)
    let videoService = VideoProcessingService()
    do {
      try await videoService.generateVideoFromScreenshots(
        screenshots: sortedScreenshots,
        outputURL: tempVideoURL,
        fps: 1,
        useCompressedTimeline: true,  // Each frame = 1 second
        options: .init(
          maxOutputHeight: 720,
          frameStride: 1,
          averageBitRate: 1_200_000,
          codec: .h264,
          keyframeIntervalSeconds: 10
        )
      )
    } catch {
      print("[Gemini] ❌ Failed to composite screenshots into video: \(error.localizedDescription)")
      throw NSError(
        domain: "GeminiDirectProvider",
        code: 10,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Failed to composite screenshots into video: \(error.localizedDescription)"
        ]
      )
    }

    // Load video data
    let videoData = try Data(contentsOf: tempVideoURL)
    print(
      "[Gemini] 📹 Composited \(screenshots.count) screenshots into compressed video (\(videoData.count / 1024)KB)"
    )

    // Transcribe the composited video with compression info
    return try await transcribeVideoData(
      videoData,
      mimeType: "video/mp4",
      batchStartTime: batchStartTime,
      videoDuration: compressedVideoDuration,
      realDuration: realDuration,
      compressionFactor: compressionFactor,
      batchId: batchId
    )
  }

}
