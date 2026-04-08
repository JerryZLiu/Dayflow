import Foundation

struct DailyRecapGenerationContext: Sendable {
  let targetDayString: String
  let sourceDayString: String
  let cards: [TimelineCard]
  let observations: [Observation]
  let priorEntries: [DailyStandupEntry]
  let highlightsTitle: String
  let tasksTitle: String
  let blockersTitle: String
}

struct DailyRecapProviderAvailability: Equatable, Sendable {
  let isAvailable: Bool
  let detail: String
}

enum DailyRecapGeneratorError: LocalizedError {
  case emptyCards(day: String)
  case noProviderSelected
  case missingDayflowAuthToken
  case missingLocalConfiguration
  case missingGeminiAPIKey
  case missingCodexCLI
  case missingClaudeCLI
  case invalidJSONResponse(rawResponse: String)
  case invalidResponseShape(rawResponse: String)

  var errorDescription: String? {
    switch self {
    case .emptyCards(let day):
      return "No timeline cards were found for \(day)."
    case .noProviderSelected:
      return
        "No Daily provider is selected. Choose one from the gear button above to turn Daily generation back on."
    case .missingDayflowAuthToken:
      return "Dayflow backend auth token is unavailable."
    case .missingLocalConfiguration:
      return
        "Local Daily generation is not configured. Set up Ollama or LM Studio, or pick a different provider."
    case .missingGeminiAPIKey:
      return "Gemini API key is missing."
    case .missingCodexCLI:
      return "Codex CLI is not installed."
    case .missingClaudeCLI:
      return "Claude Code is not installed."
    case .invalidJSONResponse(let rawResponse):
      return "The model did not return valid JSON.\n\nRAW OUTPUT:\n\(rawResponse)"
    case .invalidResponseShape(let rawResponse):
      return
        "The model returned JSON, but it did not match the Daily recap schema.\n\nRAW OUTPUT:\n\(rawResponse)"
    }
  }
}

final class DailyRecapGenerator {
  static let shared = DailyRecapGenerator()

  private static let dayflowBackendDefaultEndpoint = "https://web-production-f3361.up.railway.app"
  private static let dayflowBackendInfoPlistKey = "DayflowBackendURL"
  private static let dayflowBackendOverrideDefaultsKey = "dayflowBackendURLOverride"
  private static let localRecapMaxOutputTokens = 8192

  private static let localPrompt = """
    # Daily Recap Prompt

    You are the person whose activity log this is, writing a quick end-of-day recap for yourself.
    Your future self doesn't need a diary. You need the 3-5 things that actually moved the needle today so you can look back and know what happened.

    Read the log, find the real accomplishments, and write them up the way you'd tell a friend: "here's what I actually got done today."

    ## Selection rules

    - Put 0 to 5 items in "done" based on evidence quality.
    - Do NOT pad to reach 5. If only two things were genuinely meaningful, return two.
    - If nothing high-confidence exists, return an empty "done" array.

    ## What counts as an accomplishment

    An accomplishment is something that has a clear before and after. You finished it, decided it, figured it out, or made something real. Anything where the state of the world changed because of what you did.

    Examples across roles:
    - A founder closed a conversation, sent a launch, locked in a positioning decision.
    - A student finished a problem set, nailed down a thesis argument, submitted an application.
    - A designer shipped a comp, got approval on a flow, resolved a UX question with evidence.
    - An engineer fixed a bug, landed a feature, unblocked a dependency.

    Not accomplishments: browsing, reading without a takeaway, meetings that ended without a decision, half-started tasks with no checkpoint.

    ## Writing rules

    - Each item: one sentence, 8-20 words max. If it's over 20, split or trim.
    - Lead with what changed or what you decided, not the process of getting there.
    - Write like a real person. Plain, direct, no filler.
    - Banned words: leverage, surface, actionable, facilitate, optimize (unless literally about an optimizer), deep-dive, synergy, align (unless about visual alignment).
    - If something sounds like a consultant or a report generator wrote it, rewrite it in your own words.
    - Use only evidence from the log. Do not invent or assume details.
    - Name concrete things: the pricing page, the midterm essay, the onboarding flow, the partner deal. Not vague categories.
    - Include a number when it adds real signal (a metric, count, %, dollar amount, word count). If the log has a useful number, use it. Don't force one in.
    - If a useful number from the log matters, include it in the bullet.

    ## What to skip

    - Browsing, entertainment, social media scrolling, side distractions.
    - Low-signal process noise: "build succeeded," "synced files," "opened app."
    - Tool and workflow internals your future self won't care about: file names, class names, git/PR activity, IDE details, batch IDs.
    - Don't mention AI tools by name (Claude, ChatGPT, Cursor, Copilot) unless the work was explicitly about that tool. The accomplishment is the output, not the tool.
    - No em dashes. No hype. No self-praise.

    ## Tomorrow / next section

    - Include "next" (exactly 1 item) only when the log shows a specific task that was clearly started but unfinished, or a concrete next step explicitly discussed or planned during the day.
    - Do not speculate. If nothing in the log points to a specific carryover task, set "next" to null.
    - The bar: could you point to a specific moment in the log where this next step was set up? If not, leave it out.

    ## Examples

    Good bullets:
    - "Fixed the webhook retry bug that was dropping ~12% of partner callbacks."
    - "Finished the pricing page FAQ and got sign-off from Lisa."
    - "Narrowed the signup drop-off to the email verification step, 41% abandon rate."
    - "Submitted the constitutional law essay, 2,800 words."
    - "Locked in the 'automatic work journal' positioning after testing five alternatives."
    - "Got verbal yes from the Acme partnership, sending the agreement tomorrow."
    - "Finalized the onboarding flow redesign, down from 7 screens to 4."

    Bad bullets and why:
    - "Updated AuthService.swift and pushed three commits." -> Implementation details nobody needs.
    - "Surfaced conversion leakage insights and drafted actionable recommendations." -> Consultant-speak. What did you actually find?
    - "Spent a focused session analyzing churn patterns to derive strategic retention insights." -> Describes the process, not the result. What did the analysis show?
    - "Did some research on competitors." -> Too vague. What did you learn? What did you decide?
    - "Had a productive brainstorm with the team." -> What came out of it?

    """

  private init() {}

  func selectedProvider(from defaults: UserDefaults = .standard) -> DailyRecapProvider {
    DailyRecapProvider.load(from: defaults)
  }

  func persistSelectedProvider(
    _ provider: DailyRecapProvider, to defaults: UserDefaults = .standard
  ) {
    provider.save(to: defaults)
  }

  func availabilitySnapshot() -> [DailyRecapProvider: DailyRecapProviderAvailability] {
    let geminiKey =
      KeychainManager.shared.retrieve(for: "gemini")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let codexInstalled = LoginShellRunner.isInstalled("codex")
    let claudeInstalled = LoginShellRunner.isInstalled("claude")
    let isLocalConfigured = localProviderIsConfigured()
    let localModel = DailyRecapProvider.local.modelOrTool

    return [
      .dayflow: DailyRecapProviderAvailability(
        isAvailable: true,
        detail: DailyRecapProvider.dayflow.pickerSubtitle
      ),
      .local: DailyRecapProviderAvailability(
        isAvailable: isLocalConfigured,
        detail: isLocalConfigured
          ? (localModel ?? DailyRecapProvider.local.pickerSubtitle)
          : "Configure Ollama or LM Studio before using this provider"
      ),
      .gemini: DailyRecapProviderAvailability(
        isAvailable: !geminiKey.isEmpty,
        detail: geminiKey.isEmpty
          ? "Add a Gemini API key before using this provider"
          : DailyRecapProvider.gemini.pickerSubtitle
      ),
      .chatgpt: DailyRecapProviderAvailability(
        isAvailable: codexInstalled,
        detail: codexInstalled
          ? DailyRecapProvider.chatgpt.pickerSubtitle
          : "Install Codex CLI before using this provider"
      ),
      .claude: DailyRecapProviderAvailability(
        isAvailable: claudeInstalled,
        detail: claudeInstalled
          ? DailyRecapProvider.claude.pickerSubtitle
          : "Install Claude Code before using this provider"
      ),
      .none: DailyRecapProviderAvailability(
        isAvailable: true,
        detail: DailyRecapProvider.none.pickerSubtitle
      ),
    ]
  }

  func generate(context: DailyRecapGenerationContext) async throws -> DailyStandupDraft {
    guard !context.cards.isEmpty else {
      throw DailyRecapGeneratorError.emptyCards(day: context.sourceDayString)
    }

    let provider = selectedProvider()
    let metadata = DailyStandupGenerationMetadata(provider: provider)

    switch provider {
    case .dayflow:
      return try await generateWithDayflow(context: context, metadata: metadata)
    case .local:
      return try await generateWithLocal(context: context, metadata: metadata)
    case .gemini:
      return try await generateWithGemini(context: context, metadata: metadata)
    case .chatgpt:
      return try await generateWithChatGPT(context: context, metadata: metadata)
    case .claude:
      return try await generateWithClaude(context: context, metadata: metadata)
    case .none:
      throw DailyRecapGeneratorError.noProviderSelected
    }
  }

  static func makeCardsText(day: String, cards: [TimelineCard]) -> String {
    let ordered = cards.sorted { lhs, rhs in
      if lhs.startTimestamp == rhs.startTimestamp {
        return lhs.endTimestamp < rhs.endTimestamp
      }
      return lhs.startTimestamp < rhs.startTimestamp
    }

    guard !ordered.isEmpty else {
      return "No timeline activities were recorded for \(day)."
    }

    var lines: [String] = ["Timeline activities for \(day):", ""]
    for (index, card) in ordered.enumerated() {
      let title = standupLine(from: card) ?? "Untitled activity"
      let start = humanReadableClockTime(card.startTimestamp)
      let end = humanReadableClockTime(card.endTimestamp)
      lines.append("\(index + 1). \(start) - \(end): \(title)")

      let summary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
      if !summary.isEmpty, summary != title {
        lines.append("   \(summary)")
      }
    }

    return lines.joined(separator: "\n")
  }

  static func makeObservationsText(day: String, observations: [Observation]) -> String {
    guard !observations.isEmpty else {
      return "No observations were recorded for \(day)."
    }

    let ordered = observations.sorted { $0.startTs < $1.startTs }
    var lines: [String] = ["Observations for \(day):", ""]

    for observation in ordered {
      let text = observation.observation.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let start = humanReadableClockTime(unixTimestamp: observation.startTs)
      let end = humanReadableClockTime(unixTimestamp: observation.endTs)
      lines.append("\(start) - \(end): \(text)")
    }

    if lines.count <= 2 {
      return "No observations were recorded for \(day)."
    }
    return lines.joined(separator: "\n")
  }

  static func makePriorDailyText(entries: [DailyStandupEntry]) -> String {
    guard !entries.isEmpty else { return "" }

    return entries.map { entry in
      let payload = entry.payloadJSON.trimmingCharacters(in: .whitespacesAndNewlines)
      return """
        Day \(entry.standupDay):
        \(payload)
        """
    }
    .joined(separator: "\n\n")
  }

  static func makePreferencesText(
    highlightsTitle: String,
    tasksTitle: String,
    blockersTitle: String
  ) -> String {
    let preferences: [String: String] = [
      "highlights_title": highlightsTitle,
      "tasks_title": tasksTitle,
      "blockers_title": blockersTitle,
    ]

    guard
      let jsonData = try? JSONSerialization.data(
        withJSONObject: preferences,
        options: [.sortedKeys]
      ),
      let jsonString = String(data: jsonData, encoding: .utf8)
    else {
      return ""
    }

    return jsonString
  }

  private func generateWithDayflow(
    context: DailyRecapGenerationContext,
    metadata: DailyStandupGenerationMetadata
  ) async throws -> DailyStandupDraft {
    guard let provider = makeDayflowProvider() else {
      throw DailyRecapGeneratorError.missingDayflowAuthToken
    }

    let request = DayflowDailyGenerationRequest(
      day: context.sourceDayString,
      cardsText: Self.makeCardsText(day: context.sourceDayString, cards: context.cards),
      observationsText: Self.makeObservationsText(
        day: context.sourceDayString,
        observations: context.observations
      ),
      priorDailyText: Self.makePriorDailyText(entries: context.priorEntries),
      preferencesText: Self.makePreferencesText(
        highlightsTitle: context.highlightsTitle,
        tasksTitle: context.tasksTitle,
        blockersTitle: context.blockersTitle
      ),
      preferredOutputLanguage: Self.preferredOutputLanguage()
    )

    let response = try await provider.generateDaily(request)
    return DailyStandupDraft(
      highlightsTitle: context.highlightsTitle,
      highlights: Self.normalizedBulletItems(from: response.highlights),
      tasksTitle: context.tasksTitle,
      tasks: Self.normalizedBulletItems(from: response.unfinished),
      blockersTitle: context.blockersTitle,
      blockersBody: Self.normalizedBlockersText(from: response.blockers),
      generation: metadata
    )
  }

  private func generateWithGemini(
    context: DailyRecapGenerationContext,
    metadata: DailyStandupGenerationMetadata
  ) async throws -> DailyStandupDraft {
    guard
      let apiKey = KeychainManager.shared.retrieve(for: "gemini")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !apiKey.isEmpty
    else {
      throw DailyRecapGeneratorError.missingGeminiAPIKey
    }

    let provider = GeminiDirectProvider(
      apiKey: apiKey,
      preference: GeminiModelPreference(primary: .flashLite31Preview)
    )
    let prompt = Self.makeLocalPrompt(day: context.sourceDayString, cards: context.cards)
    let (rawText, _) = try await provider.generateText(
      prompt: prompt,
      maxOutputTokens: Self.localRecapMaxOutputTokens
    )
    let parsed = try Self.parseLocalResponse(rawText)
    return makeDraft(from: parsed, context: context, metadata: metadata)
  }

  private func generateWithLocal(
    context: DailyRecapGenerationContext,
    metadata: DailyStandupGenerationMetadata
  ) async throws -> DailyStandupDraft {
    guard localProviderIsConfigured(), let provider = makeLocalProvider() else {
      throw DailyRecapGeneratorError.missingLocalConfiguration
    }

    let prompt = Self.makeLocalPrompt(day: context.sourceDayString, cards: context.cards)
    let (rawText, _) = try await provider.generateText(
      prompt: prompt,
      maxTokens: Self.localRecapMaxOutputTokens
    )
    let parsed = try Self.parseLocalResponse(rawText)
    return makeDraft(from: parsed, context: context, metadata: metadata)
  }

  private func generateWithChatGPT(
    context: DailyRecapGenerationContext,
    metadata: DailyStandupGenerationMetadata
  ) async throws -> DailyStandupDraft {
    guard LoginShellRunner.isInstalled("codex") else {
      throw DailyRecapGeneratorError.missingCodexCLI
    }

    let provider = ChatCLIProvider(tool: .codex)
    let prompt = Self.makeLocalPrompt(day: context.sourceDayString, cards: context.cards)
    let (rawText, _) = try await provider.generateText(
      prompt: prompt,
      model: "gpt-5.4",
      reasoningEffort: nil,
      disableTools: true
    )
    let parsed = try Self.parseLocalResponse(rawText)
    return makeDraft(from: parsed, context: context, metadata: metadata)
  }

  private func generateWithClaude(
    context: DailyRecapGenerationContext,
    metadata: DailyStandupGenerationMetadata
  ) async throws -> DailyStandupDraft {
    guard LoginShellRunner.isInstalled("claude") else {
      throw DailyRecapGeneratorError.missingClaudeCLI
    }

    let provider = ChatCLIProvider(tool: .claude)
    let prompt = Self.makeLocalPrompt(day: context.sourceDayString, cards: context.cards)
    let (rawText, _) = try await provider.generateText(
      prompt: prompt,
      model: "opus",
      reasoningEffort: nil,
      disableTools: true
    )
    let parsed = try Self.parseLocalResponse(rawText)
    return makeDraft(from: parsed, context: context, metadata: metadata)
  }

  private func makeDayflowProvider() -> DayflowBackendProvider? {
    let token = AnalyticsService.shared.backendAuthToken()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return nil }

    let endpoint = resolvedDayflowEndpoint()
    return DayflowBackendProvider(token: token, endpoint: endpoint)
  }

  private func makeLocalProvider() -> OllamaProvider? {
    let defaults = UserDefaults.standard
    let rawEngine = defaults.string(forKey: "llmLocalEngine") ?? LocalEngine.ollama.rawValue
    let engine = LocalEngine(rawValue: rawEngine) ?? .ollama
    let endpoint = defaults.string(forKey: "llmLocalBaseURL")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedEndpoint: String
    if let endpoint, !endpoint.isEmpty {
      resolvedEndpoint = endpoint
    } else {
      resolvedEndpoint = engine.defaultBaseURL
    }

    return OllamaProvider(endpoint: resolvedEndpoint)
  }

  private func localProviderIsConfigured() -> Bool {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: "ollamaSetupComplete") {
      return true
    }

    let baseURL =
      defaults.string(forKey: "llmLocalBaseURL")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let modelId =
      defaults.string(forKey: "llmLocalModelId")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !baseURL.isEmpty && !modelId.isEmpty
  }

  private func resolvedDayflowEndpoint() -> String {
    let defaults = UserDefaults.standard

    if let override = defaults.string(forKey: Self.dayflowBackendOverrideDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return override
    }

    if let infoEndpoint = Bundle.main.infoDictionary?[Self.dayflowBackendInfoPlistKey] as? String {
      let trimmed = infoEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    if case .dayflowBackend(let savedEndpoint) = LLMProviderType.load(from: defaults) {
      let trimmed = savedEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    return Self.dayflowBackendDefaultEndpoint
  }

  private func makeDraft(
    from parsed: ParsedDailyRecapResponse,
    context: DailyRecapGenerationContext,
    metadata: DailyStandupGenerationMetadata
  ) -> DailyStandupDraft {
    let tasks = parsed.next.map { [DailyBulletItem(text: $0)] } ?? []

    return DailyStandupDraft(
      highlightsTitle: context.highlightsTitle,
      highlights: Self.normalizedBulletItems(from: parsed.done),
      tasksTitle: context.tasksTitle,
      tasks: tasks,
      blockersTitle: context.blockersTitle,
      blockersBody: "",
      generation: metadata
    )
  }

  static func makeLocalPrompt(day: String, cards: [TimelineCard]) -> String {
    let cardsText = makeCardsText(day: day, cards: cards)
    let languageSection = makeLocalPromptLanguageSection()

    return """
      \(localPrompt)

      You only have timeline cards for this day. The log is incomplete by nature, so prefer omission over guessing.

      Activity log:

      \(cardsText)

      \(languageSection)

      ## Output format

      Return ONLY valid JSON, no markdown fences, no preamble. Use this exact schema:

      {
        "done": ["first bullet", "second bullet", "..."],
        "next": "one sentence or null"
      }

      Return exactly one JSON object and nothing before or after it.
      """
  }

  private static func preferredOutputLanguage() -> String? {
    LLMOutputLanguagePreferences.normalizedOverride
  }

  private static func makeLocalPromptLanguageSection() -> String {
    guard let instruction = LLMOutputLanguagePreferences.languageInstruction(forJSON: true) else {
      return ""
    }

    return """
      ## Language

      \(instruction)
      """
  }

  private static func parseLocalResponse(_ rawResponse: String) throws -> ParsedDailyRecapResponse {
    let cleaned = cleanRawModelResponse(rawResponse)
    let candidate = extractFirstJSONObject(from: cleaned) ?? cleaned

    guard let data = candidate.data(using: .utf8) else {
      throw DailyRecapGeneratorError.invalidJSONResponse(rawResponse: rawResponse)
    }

    guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
      let json = jsonObject as? [String: Any]
    else {
      throw DailyRecapGeneratorError.invalidJSONResponse(rawResponse: rawResponse)
    }

    let done = Array(normalizedStrings(from: json["done"]).prefix(5))
    let next = normalizedOptionalString(from: json["next"])

    let hasExpectedShape = json.keys.contains("done") || json.keys.contains("next")
    guard hasExpectedShape else {
      throw DailyRecapGeneratorError.invalidResponseShape(rawResponse: rawResponse)
    }

    return ParsedDailyRecapResponse(
      done: done,
      next: next
    )
  }

  private static func cleanRawModelResponse(_ rawResponse: String) -> String {
    var cleaned = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)

    if let thinkingEndRange = cleaned.range(of: "---END_THINKING---") {
      cleaned = String(cleaned[thinkingEndRange.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if cleaned.hasPrefix("```"), let firstNewline = cleaned.firstIndex(of: "\n") {
      cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
      if let closingFenceRange = cleaned.range(of: "\n```", options: .backwards) {
        cleaned = String(cleaned[..<closingFenceRange.lowerBound])
      }
    }

    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func extractFirstJSONObject(from text: String) -> String? {
    var startIndex: String.Index?
    var depth = 0
    var isInsideString = false
    var isEscaped = false

    for index in text.indices {
      let character = text[index]

      if isEscaped {
        isEscaped = false
        continue
      }

      if character == "\\" && isInsideString {
        isEscaped = true
        continue
      }

      if character == "\"" {
        isInsideString.toggle()
        continue
      }

      if isInsideString {
        continue
      }

      if character == "{" {
        if depth == 0 {
          startIndex = index
        }
        depth += 1
        continue
      }

      if character == "}" {
        guard depth > 0 else { continue }
        depth -= 1
        if depth == 0, let startIndex {
          return String(text[startIndex...index])
        }
      }
    }

    return nil
  }

  private static func normalizedStrings(from value: Any?) -> [String] {
    let rawValues: [Any]
    if let array = value as? [Any] {
      rawValues = array
    } else if let scalar = value {
      rawValues = [scalar]
    } else {
      rawValues = []
    }

    var seen: Set<String> = []
    return rawValues.compactMap { item in
      guard let normalized = normalizeScalarString(item) else { return nil }
      guard seen.insert(normalized).inserted else { return nil }
      return normalized
    }
  }

  private static func normalizedOptionalString(from value: Any?) -> String? {
    if value is NSNull {
      return nil
    }

    if let array = value as? [Any] {
      for item in array {
        if let normalized = normalizeScalarString(item) {
          return normalized
        }
      }
      return nil
    }

    return normalizeScalarString(value)
  }

  private static func normalizeScalarString(_ value: Any?) -> String? {
    guard let value else { return nil }

    let raw: String
    switch value {
    case let string as String:
      raw = string
    case let number as NSNumber:
      raw = number.stringValue
    default:
      return nil
    }

    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.lowercased() != "null" else { return nil }
    return trimmed
  }

  private static func normalizedBulletItems(from values: [String]) -> [DailyBulletItem] {
    normalizedStrings(from: values).map { DailyBulletItem(text: $0) }
  }

  private static func normalizedBlockersText(from values: [String]) -> String {
    normalizedStrings(from: values).joined(separator: "\n")
  }

  private static func humanReadableClockTime(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let minuteOfDay = parseTimeHMMA(timeString: trimmed) else {
      return trimmed.lowercased()
    }

    let hour24 = (minuteOfDay / 60) % 24
    let minute = minuteOfDay % 60
    let meridiem = hour24 >= 12 ? "pm" : "am"
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    return String(format: "%d:%02d%@", hour12, minute, meridiem)
  }

  private static func humanReadableClockTime(unixTimestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unixTimestamp))
    let calendar = Calendar.current
    let hour24 = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    let meridiem = hour24 >= 12 ? "pm" : "am"
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    return String(format: "%d:%02d%@", hour12, minute, meridiem)
  }

  private static func standupLine(from card: TimelineCard) -> String? {
    let trimmedTitle = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
      return trimmedTitle
    }

    let trimmedSummary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedSummary.isEmpty ? nil : trimmedSummary
  }
}

private struct ParsedDailyRecapResponse {
  let done: [String]
  let next: String?
}
