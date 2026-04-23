import Foundation

extension GeminiDirectProvider {
  // MARK: - Dashboard Chat (Gemini function calling)

  static let dashboardChatModel = "gemini-3.1-flash-lite-preview"
  static let dashboardChatMaxToolRounds = 20
  static let dashboardChatTimelinePayloadSoftLimitBytes = 800_000
  var dashboardGenerateEndpoint: String {
    "https://generativelanguage.googleapis.com/v1beta/models/\(Self.dashboardChatModel):generateContent"
  }

  var dashboardStreamEndpoint: String {
    "https://generativelanguage.googleapis.com/v1beta/models/\(Self.dashboardChatModel):streamGenerateContent"
  }

  struct DashboardFunctionCall {
    let name: String
    let args: [String: Any]
  }

  struct DashboardTurnResult {
    let text: String
    let functionCalls: [DashboardFunctionCall]
    let modelFunctionCallParts: [[String: Any]]
  }

  enum DashboardToolName: String {
    case fetchTimeline
    case fetchObservations
  }

  enum DashboardToolArgError: Error, LocalizedError {
    case invalidCombination
    case invalidDate(String)
    case invalidRange

    var errorDescription: String? {
      switch self {
      case .invalidCombination:
        return "Provide either {date} OR {startDate, endDate}."
      case .invalidDate(let value):
        return "Invalid date format '\(value)'. Use YYYY-MM-DD."
      case .invalidRange:
        return "startDate must be less than or equal to endDate."
      }
    }
  }

  struct DashboardDateRange {
    let mode: String
    let date: String?
    let startDate: String?
    let endDate: String?
    let from: Date
    let to: Date
  }

  var dashboardDateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter
  }

  var dashboardTimeFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter
  }

  var dashboardSingleDateDisplayFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE, MMM d"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter
  }

  var dashboardRangeDateDisplayFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter
  }

  func generateDashboardChatStreaming(
    systemInstruction: String,
    history: [DashboardChatTurn]
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          try await runDashboardChatLoop(
            systemInstruction: systemInstruction,
            history: history,
            continuation: continuation
          )
          continuation.finish()
        } catch {
          continuation.yield(.error(error.localizedDescription))
          continuation.finish(throwing: error)
        }
      }
    }
  }

  func runDashboardChatLoop(
    systemInstruction: String,
    history: [DashboardChatTurn],
    continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
  ) async throws {
    var contents = dashboardChatContents(from: history)

    var toolRounds = 0

    while toolRounds < Self.dashboardChatMaxToolRounds {
      let turn = try await runDashboardTurnWithFallback(
        systemInstruction: systemInstruction,
        contents: contents,
        continuation: continuation
      )

      if turn.functionCalls.isEmpty {
        continuation.yield(.complete(text: turn.text))
        return
      }

      toolRounds += 1
      contents.append(["role": "model", "parts": turn.modelFunctionCallParts])

      var functionResponseParts: [[String: Any]] = []
      for call in turn.functionCalls {
        let command = describeDashboardFunctionCall(call)
        continuation.yield(.toolStart(command: command))
        let toolResponse = executeDashboardFunction(call)
        let summary = toolResponse["summary"] as? String ?? "Tool finished."
        let didFail = toolResponse["error"] != nil
        continuation.yield(.toolEnd(output: summary, exitCode: didFail ? 1 : 0))
        functionResponseParts.append(
          [
            "functionResponse": [
              "name": call.name,
              "response": toolResponse,
            ]
          ])
      }

      contents.append(["role": "user", "parts": functionResponseParts])
    }

    throw NSError(
      domain: "GeminiDashboardChat",
      code: 901,
      userInfo: [
        NSLocalizedDescriptionKey:
          "The assistant exceeded the maximum tool-call rounds. Please try a narrower query."
      ])
  }

  func runDashboardTurnWithFallback(
    systemInstruction: String,
    contents: [[String: Any]],
    continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
  ) async throws -> DashboardTurnResult {
    var includeThinkingConfig = true

    do {
      return try await streamDashboardTurn(
        systemInstruction: systemInstruction,
        contents: contents,
        includeThinkingConfig: includeThinkingConfig,
        continuation: continuation
      )
    } catch {
      if shouldRetryDashboardWithoutThinkingConfig(error) {
        includeThinkingConfig = false
        print("🔎 GEMINI DEBUG: dashboard_chat retrying without thinkingConfig")
      }
      logGeminiFailure(
        context: "dashboard_chat.stream.attempt1",
        response: nil,
        data: nil,
        error: error
      )
    }

    do {
      return try await streamDashboardTurn(
        systemInstruction: systemInstruction,
        contents: contents,
        includeThinkingConfig: includeThinkingConfig,
        continuation: continuation
      )
    } catch {
      logGeminiFailure(
        context: "dashboard_chat.stream.attempt2",
        response: nil,
        data: nil,
        error: error
      )
    }

    return try await generateDashboardTurnNonStreaming(
      systemInstruction: systemInstruction,
      contents: contents,
      includeThinkingConfig: includeThinkingConfig
    )
  }

  func dashboardToolDeclarations() -> [[String: Any]] {
    [
      [
        "name": DashboardToolName.fetchTimeline.rawValue,
        "description":
          "Fetch timeline cards for a single day or date range. Returns structured JSON cards including day, time range, title, summary, category, and optional detailed summaries.",
        "parameters": [
          "type": "OBJECT",
          "properties": [
            "date": ["type": "STRING", "description": "Single day in YYYY-MM-DD format."],
            "startDate": ["type": "STRING", "description": "Range start date in YYYY-MM-DD."],
            "endDate": ["type": "STRING", "description": "Range end date in YYYY-MM-DD."],
            "includeDetailedSummary": [
              "type": "BOOLEAN",
              "description":
                "When true (default), include detailedSummary. Set false for very large windows.",
            ],
            "limit": [
              "type": "NUMBER",
              "description":
                "Optional row cap. If omitted, returns all matching rows.",
            ],
          ],
        ],
      ],
      [
        "name": DashboardToolName.fetchObservations.rawValue,
        "description":
          "Fetch raw observations for a single day or date range. Returns structured JSON grouped by day, with each day's observations ordered chronologically.",
        "parameters": [
          "type": "OBJECT",
          "properties": [
            "date": ["type": "STRING", "description": "Single day in YYYY-MM-DD format."],
            "startDate": ["type": "STRING", "description": "Range start date in YYYY-MM-DD."],
            "endDate": ["type": "STRING", "description": "Range end date in YYYY-MM-DD."],
            "limit": [
              "type": "NUMBER",
              "description":
                "Optional row cap. If omitted, returns all matching rows.",
            ],
          ],
        ],
      ],
    ]
  }

  func dashboardChatRequestBody(
    systemInstruction: String,
    contents: [[String: Any]],
    includeThinkingConfig: Bool
  ) -> [String: Any] {
    var generationConfig: [String: Any] = [
      "temperature": 0.2,
      "maxOutputTokens": 8192,
    ]
    if includeThinkingConfig {
      generationConfig["thinkingConfig"] = [
        "thinkingLevel": "medium"
      ]
    }

    var body: [String: Any] = [
      "contents": contents,
      "tools": [
        [
          "functionDeclarations": dashboardToolDeclarations()
        ]
      ],
      "toolConfig": [
        "functionCallingConfig": [
          "mode": "AUTO"
        ]
      ],
      "generationConfig": generationConfig,
    ]
    let trimmedInstruction = systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedInstruction.isEmpty {
      body["systemInstruction"] = [
        "parts": [
          ["text": trimmedInstruction]
        ]
      ]
    }
    return body
  }

}
