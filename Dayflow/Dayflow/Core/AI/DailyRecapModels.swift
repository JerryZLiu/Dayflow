import Foundation

enum DailyRecapProvider: String, Codable, CaseIterable, Sendable {
  case dayflow
  case gemini
  case chatgpt
  case claude

  private static let storageKey = "dailyRecapProvider_v1"

  static func load(from defaults: UserDefaults = .standard) -> DailyRecapProvider {
    if let rawValue = defaults.string(forKey: storageKey),
      let provider = DailyRecapProvider(rawValue: rawValue)
    {
      return provider
    }

    let provider = migrateInitialSelection(from: defaults)
    provider.save(to: defaults)
    return provider
  }

  func save(to defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.storageKey)
  }

  private static func migrateInitialSelection(from defaults: UserDefaults) -> DailyRecapProvider {
    if defaults.bool(forKey: "isDailyUnlocked") {
      return .dayflow
    }

    switch LLMProviderType.load(from: defaults) {
    case .geminiDirect:
      return .gemini
    case .dayflowBackend:
      return .dayflow
    case .chatGPTClaude:
      let preferredTool = defaults.string(forKey: "chatCLIPreferredTool") ?? "codex"
      return preferredTool == "claude" ? .claude : .chatgpt
    case .ollamaLocal:
      return .dayflow
    }
  }

  var analyticsName: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .dayflow:
      return "Dayflow backend"
    case .gemini:
      return "Gemini"
    case .chatgpt:
      return "ChatGPT"
    case .claude:
      return "Claude"
    }
  }

  var selectionLabel: String {
    switch self {
    case .dayflow:
      return "Dayflow backend"
    case .gemini:
      return "Gemini 3.1 Flash-Lite"
    case .chatgpt:
      return "GPT-5.4"
    case .claude:
      return "Claude Opus"
    }
  }

  var pickerSubtitle: String {
    switch self {
    case .dayflow:
      return "Use the current Dayflow daily backend"
    case .gemini:
      return "Pinned to Gemini 3.1 Flash-Lite"
    case .chatgpt:
      return "Pinned to GPT-5.4 via Codex CLI"
    case .claude:
      return "Pinned to Claude Opus via Claude Code"
    }
  }

  var runtimeLabel: String {
    switch self {
    case .dayflow:
      return "dayflow_backend"
    case .gemini:
      return "gemini_direct"
    case .chatgpt, .claude:
      return "chat_cli"
    }
  }

  var modelOrTool: String? {
    switch self {
    case .dayflow:
      return nil
    case .gemini:
      return GeminiModel.flashLite31Preview.rawValue
    case .chatgpt:
      return "gpt-5.4"
    case .claude:
      return "opus"
    }
  }
}

enum DailyStandupPlaceholder {
  static let notGeneratedMessage =
    "Daily data has not been generated yet. If this is unexpected, please report a bug."
  static let todayNotGeneratedMessage = "Today's daily recap will be generated tomorrow morning."
  static let insufficientHistoryMessage =
    "Not enough captured activity in the previous 3 days to generate a standup."
}

struct DailyStandupGenerationMetadata: Codable, Equatable, Sendable {
  var provider: DailyRecapProvider
  var runtime: String
  var modelOrTool: String?
  var generatedAt: Date?

  init(
    provider: DailyRecapProvider,
    runtime: String? = nil,
    modelOrTool: String? = nil,
    generatedAt: Date? = Date()
  ) {
    self.provider = provider
    self.runtime = runtime ?? provider.runtimeLabel
    self.modelOrTool = modelOrTool ?? provider.modelOrTool
    self.generatedAt = generatedAt
  }

  static let legacyDayflow = DailyStandupGenerationMetadata(
    provider: .dayflow,
    generatedAt: nil
  )

  var displayLabel: String {
    switch provider {
    case .dayflow:
      return "Dayflow backend"
    case .gemini:
      return "Gemini 3.1 Flash-Lite"
    case .chatgpt:
      return "GPT-5.4"
    case .claude:
      return "Claude Opus"
    }
  }
}

struct DailyBulletItem: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var text: String
}

struct DailyStandupDraft: Codable, Equatable, Sendable {
  var highlightsTitle: String
  var highlights: [DailyBulletItem]
  var tasksTitle: String
  var tasks: [DailyBulletItem]
  var blockersTitle: String
  var blockersBody: String
  var generation: DailyStandupGenerationMetadata?

  static let `default` = DailyStandupDraft(
    highlightsTitle: "Yesterday's highlights",
    highlights: [DailyBulletItem(text: DailyStandupPlaceholder.notGeneratedMessage)],
    tasksTitle: "Today's tasks",
    tasks: [DailyBulletItem(text: DailyStandupPlaceholder.notGeneratedMessage)],
    blockersTitle: "Blockers",
    blockersBody: DailyStandupPlaceholder.notGeneratedMessage,
    generation: nil
  )

  static let todayPlaceholder = DailyStandupDraft(
    highlightsTitle: "Yesterday's highlights",
    highlights: [DailyBulletItem(text: DailyStandupPlaceholder.todayNotGeneratedMessage)],
    tasksTitle: "Today's tasks",
    tasks: [DailyBulletItem(text: DailyStandupPlaceholder.todayNotGeneratedMessage)],
    blockersTitle: "Blockers",
    blockersBody: DailyStandupPlaceholder.todayNotGeneratedMessage,
    generation: nil
  )

  static let insufficientHistory = DailyStandupDraft(
    highlightsTitle: "Recent highlights",
    highlights: [DailyBulletItem(text: DailyStandupPlaceholder.insufficientHistoryMessage)],
    tasksTitle: "Tasks",
    tasks: [DailyBulletItem(text: DailyStandupPlaceholder.insufficientHistoryMessage)],
    blockersTitle: "Blockers",
    blockersBody: DailyStandupPlaceholder.insufficientHistoryMessage,
    generation: nil
  )

  func encodedJSONString() -> String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
