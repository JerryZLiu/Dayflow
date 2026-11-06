//
//  DailyBriefModels.swift
//  Dayflow
//
//  Data for the Daily brief: the morning page that pops up over the Timeline.
//  One background Claude run fills a DailyBriefContent; the app stores it as a
//  DailyBrief together with what the user did with it (DailyBriefUserState).
//

import Foundation

// MARK: - Sections

/// The sections the model may fill. Every section is optional, and the model
/// picks the order (DailyBriefContent.order).
enum DailyBriefSectionKind: String, Codable, CaseIterable, Sendable {
  case docket
  case keepTracking = "keep_tracking"
  case completedYesterday = "completed_yesterday"
  case teamDecisions = "team_decisions"
  case relatedReading = "related_reading"
  case industryNews = "industry_news"
  case siteSeeing = "site_seeing"

  var title: String {
    switch self {
    case .docket: return "Your docket today"
    case .keepTracking: return "Keep tracking"
    case .completedYesterday: return "What you completed yesterday"
    case .teamDecisions: return "Key team decisions"
    case .relatedReading: return "Related to your interests"
    case .industryNews: return "Latest in your industry"
    case .siteSeeing: return "Recent site-seeing"
    }
  }
}

struct DailyBriefPerson: Codable, Hashable, Sendable {
  var name: String
  var note: String?
}

struct DailyBriefLink: Codable, Hashable, Sendable {
  var title: String
  var url: String?
  /// Lowercase app name such as "figma", "slack", "linear", "notion", "google_docs".
  var app: String?
}

/// One note someone left about a docket task, quoted or summarized from where they said it.
struct DailyBriefFeedbackNote: Codable, Hashable, Sendable {
  /// Full name, e.g. "Jerry Liu".
  var name: String
  /// Where it was said, e.g. "#maggie, Oct 21" or "Huddle notes, Oct 22".
  var source: String?
  var text: String
  var url: String?
}

struct DailyBriefDocketItem: Codable, Hashable, Sendable {
  var title: String
  /// The short description shown under Details.
  var detail: String?
  /// yyyy-MM-dd, only when a source stated it.
  var due: String?
  var people: [DailyBriefPerson]?
  var links: [DailyBriefLink]?
  /// A ready-to-send prompt for an AI agent that would do the task.
  var prompt: String?
  /// True when an agent could do the task without the user.
  var agent: Bool?
  var feedback: [DailyBriefFeedbackNote]?
  /// When every feedback note is from one person: a one-paragraph summary shown in their place.
  var feedbackSummary: String?
  /// The message or thread the summary came from.
  var feedbackUrl: String?
  /// Titles of the `links` worth handing to the agent along with the prompt.
  var attach: [String]?
  /// An earlier Codex thread or Claude Code session (by id) the task continues. The hand-off
  /// opens it, in its own app; without one it opens a new thread.
  var thread: String?
  /// For a new thread, the app the brief judged best for it: "claude" or "codex". Nil leaves
  /// it to the agent picked in the gear menu.
  var newThreadApp: String?
}

struct DailyBriefTrackingItem: Codable, Hashable, Sendable {
  var label: String
  var status: String
  var app: String?
  /// yyyy-MM-dd
  var asOf: String?
  var url: String?
}

struct DailyBriefCompletedItem: Codable, Hashable, Sendable {
  var project: String?
  var title: String
  var apps: [String]?
  var cardId: Int64?
  /// Set by the app, not the model: the card's screenshot copied into the brief folder.
  /// A path relative to DailyBriefStore.briefDirectory(for:).
  var imageFile: String?
}

struct DailyBriefDecisionItem: Codable, Hashable, Sendable {
  var decision: String
  /// yyyy-MM-dd
  var date: String?
  var people: [String]?
  /// Where it was decided, e.g. "#dayflow".
  var place: String?
  var app: String?
  var url: String?
}

struct DailyBriefReadingItem: Codable, Hashable, Sendable {
  var title: String
  var source: String?
  var url: String
  var reason: String?
  var imageUrl: String?
}

struct DailyBriefNewsItem: Codable, Hashable, Sendable {
  var headline: String
  var source: String?
  var url: String
  /// yyyy-MM-dd
  var published: String?
}

struct DailyBriefSiteSeeingItem: Codable, Hashable, Sendable {
  /// The candidate screenshot the model picked, e.g. "1234_1342.jpg".
  /// After the run the app copies it into the brief folder under images/ with the same name.
  var file: String
  var caption: String?
}

/// What the model returns (checked against DailyBriefSchema). Every section is
/// optional; `order` lists the filled sections best first.
struct DailyBriefContent: Codable, Equatable, Sendable {
  var order: [String]
  var docket: [DailyBriefDocketItem]?
  var keepTracking: [DailyBriefTrackingItem]?
  var completedYesterday: [DailyBriefCompletedItem]?
  var teamDecisions: [DailyBriefDecisionItem]?
  var relatedReadingIntro: String?
  var relatedReading: [DailyBriefReadingItem]?
  var industryNews: [DailyBriefNewsItem]?
  var siteSeeing: [DailyBriefSiteSeeingItem]?

  enum CodingKeys: String, CodingKey {
    case order
    case docket
    case keepTracking = "keep_tracking"
    case completedYesterday = "completed_yesterday"
    case teamDecisions = "team_decisions"
    case relatedReadingIntro = "related_reading_intro"
    case relatedReading = "related_reading"
    case industryNews = "industry_news"
    case siteSeeing = "site_seeing"
  }

  static let empty = DailyBriefContent(order: [])

  /// Sections to render, in the model's order, skipping unknown names and empty sections.
  /// Sections the model filled but forgot to list are appended at the end.
  var orderedKinds: [DailyBriefSectionKind] {
    var result: [DailyBriefSectionKind] = []
    for name in order {
      if let kind = DailyBriefSectionKind(rawValue: name), hasItems(kind), !result.contains(kind) {
        result.append(kind)
      }
    }
    for kind in DailyBriefSectionKind.allCases where hasItems(kind) && !result.contains(kind) {
      result.append(kind)
    }
    return result
  }

  func itemCount(_ kind: DailyBriefSectionKind) -> Int {
    switch kind {
    case .docket: return docket?.count ?? 0
    case .keepTracking: return keepTracking?.count ?? 0
    case .completedYesterday: return completedYesterday?.count ?? 0
    case .teamDecisions: return teamDecisions?.count ?? 0
    case .relatedReading: return relatedReading?.count ?? 0
    case .industryNews: return industryNews?.count ?? 0
    case .siteSeeing: return siteSeeing?.count ?? 0
    }
  }

  func hasItems(_ kind: DailyBriefSectionKind) -> Bool {
    itemCount(kind) > 0
  }
}

// MARK: - Stored brief

/// A task the user typed into the docket with "Add a new task".
struct DailyBriefAddedTask: Codable, Hashable, Identifiable, Sendable {
  var id = UUID()
  var title: String
}

/// Where a docket task went: handed to an agent, or dismissed.
struct DailyBriefHandoff: Codable, Hashable, Sendable {
  enum Method: String, Codable, Sendable {
    /// Copy the prompt and paste it into the agent's app.
    case paste
    /// Run the prompt in the background in the task's folder.
    case run
  }

  var title: String
  var dismissed: Bool
  /// "Claude" or "ChatGPT"; nil for a dismissal.
  var agent: String?
  var method: Method?
  var at = Date()
  /// Why it was dismissed, from the pop-up.
  var reason: String?
  /// The user opened the result.
  var reviewed = false
  /// A background run: its output file (relative to the brief folder), and when it ended.
  var outputFile: String?
  var finishedAt: Date?
  var failed = false
}

/// What the user did with one day's brief. Item keys come from DailyBriefStore.itemKey.
struct DailyBriefUserState: Codable, Equatable, Sendable {
  var checkedItemKeys: Set<String> = []
  var dismissedItemKeys: Set<String> = []
  var addedTasks: [DailyBriefAddedTask] = []
  /// True once the brief has been shown to the user (auto pop-up or opened from the notice).
  var hasBeenShown = false
  /// Docket task title → the user's edited prompt.
  var promptEdits: [String: String] = [:]
  /// Docket task title → the folder its agent works in ("" for no folder).
  var folders: [String: String] = [:]
  /// Every hand-off and dismissal, oldest first. The last entry for a title wins.
  var handoffs: [DailyBriefHandoff] = []

  init() {}

  // Missing keys fall back to defaults, so adding a field later doesn't make
  // older brief.json files fail to load.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    checkedItemKeys =
      try container.decodeIfPresent(Set<String>.self, forKey: .checkedItemKeys) ?? []
    dismissedItemKeys =
      try container.decodeIfPresent(Set<String>.self, forKey: .dismissedItemKeys) ?? []
    addedTasks =
      try container.decodeIfPresent([DailyBriefAddedTask].self, forKey: .addedTasks) ?? []
    hasBeenShown = try container.decodeIfPresent(Bool.self, forKey: .hasBeenShown) ?? false
    promptEdits =
      try container.decodeIfPresent([String: String].self, forKey: .promptEdits) ?? [:]
    folders = try container.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
    handoffs =
      try container.decodeIfPresent([DailyBriefHandoff].self, forKey: .handoffs) ?? []
  }
}

/// Debug numbers about one run, shown at the bottom of the brief.
/// Everything except duration is optional because the CLI doesn't always report it.
struct DailyBriefRunStats: Codable, Equatable, Sendable {
  /// Wall-clock seconds from start to finish, measured by the app.
  var durationSeconds: Double = 0
  var model: String?
  var costUSD: Double?
  var inputTokens: Int?
  var outputTokens: Int?
  var cacheReadTokens: Int?
  var numTurns: Int?
  /// Tool name → number of calls, e.g. ["WebSearch": 6, "mcp__slack__search": 3].
  var toolCalls: [String: Int]?
  var cardCount: Int?
  var candidateImageCount: Int?
  var promptCharacters: Int?
  var usedPromptOverride = false
  var usedOverrideInstructions = false
  var trigger: String?
  /// Part name ("docket" or "extras") → why that run failed, when the brief was kept
  /// from the other run alone.
  var failedParts: [String: String]?

  init(
    durationSeconds: Double = 0, usedPromptOverride: Bool = false,
    usedOverrideInstructions: Bool = false, trigger: String? = nil
  ) {
    self.durationSeconds = durationSeconds
    self.usedPromptOverride = usedPromptOverride
    self.usedOverrideInstructions = usedOverrideInstructions
    self.trigger = trigger
  }

  // Missing keys fall back to defaults, so adding a field later doesn't make
  // older brief.json files fail to load.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
    model = try c.decodeIfPresent(String.self, forKey: .model)
    costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
    inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
    outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
    cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
    numTurns = try c.decodeIfPresent(Int.self, forKey: .numTurns)
    toolCalls = try c.decodeIfPresent([String: Int].self, forKey: .toolCalls)
    cardCount = try c.decodeIfPresent(Int.self, forKey: .cardCount)
    candidateImageCount = try c.decodeIfPresent(Int.self, forKey: .candidateImageCount)
    promptCharacters = try c.decodeIfPresent(Int.self, forKey: .promptCharacters)
    usedPromptOverride = try c.decodeIfPresent(Bool.self, forKey: .usedPromptOverride) ?? false
    usedOverrideInstructions =
      try c.decodeIfPresent(Bool.self, forKey: .usedOverrideInstructions) ?? false
    trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
    failedParts = try c.decodeIfPresent([String: String].self, forKey: .failedParts)
  }
}

struct DailyBrief: Codable, Equatable, Sendable {
  /// Logical day (4am boundary) the brief is for, yyyy-MM-dd.
  let day: String
  /// The day whose activity it was built from (usually yesterday), yyyy-MM-dd.
  let sourceDay: String
  let generatedAt: Date
  var content: DailyBriefContent
  var userState = DailyBriefUserState()
  /// Optional so briefs saved before stats existed still decode.
  var stats: DailyBriefRunStats?
}

// MARK: - Saved items

struct DailyBriefSavedItem: Codable, Hashable, Identifiable, Sendable {
  var id = UUID()
  var savedAt = Date()
  /// File name inside DailyBriefStore.savedDirectory().
  var imageFile: String
  var caption: String?
  var sourceDay: String
}

// MARK: - Feedback

enum DailyBriefFeedbackAction: String, Codable, Sendable {
  case opened  // clicked a link or opened an item
  case saved
  case dismissed  // pressed the X
  case checked  // checked off a docket item
  case expanded  // enlarged an image
}

struct DailyBriefFeedbackEvent: Codable, Hashable, Sendable {
  var day: String
  var section: String
  var itemTitle: String
  var action: DailyBriefFeedbackAction
  var at = Date()
}

// MARK: - Range summary ("Everything you completed")

enum DailyBriefSummaryRange: String, Codable, CaseIterable, Identifiable, Sendable {
  case last7Days = "last_7_days"
  case last30Days = "last_30_days"
  case quarterToDate = "quarter_to_date"
  case yearToDate = "year_to_date"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .last7Days: return "Last 7 days"
    case .last30Days: return "Last 30 days"
    case .quarterToDate: return "Quarter to date"
    case .yearToDate: return "Year to date"
    }
  }

  /// First logical day included (inclusive), relative to `today`.
  func startDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
    let startOfToday = calendar.startOfDay(for: today)
    switch self {
    case .last7Days:
      return calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
    case .last30Days:
      return calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
    case .quarterToDate:
      let month = calendar.component(.month, from: today)
      let quarterStartMonth = ((month - 1) / 3) * 3 + 1
      var components = calendar.dateComponents([.year], from: today)
      components.month = quarterStartMonth
      components.day = 1
      return calendar.date(from: components) ?? startOfToday
    case .yearToDate:
      var components = calendar.dateComponents([.year], from: today)
      components.month = 1
      components.day = 1
      return calendar.date(from: components) ?? startOfToday
    }
  }
}

struct DailyBriefSummaryProject: Codable, Hashable, Sendable {
  var title: String
  var bullets: [String]
  var impact: String?
  /// A brief image to illustrate the project, relative to DailyBriefStore.rootDirectory().
  var imageFile: String?
}

struct DailyBriefRangeSummary: Codable, Equatable, Sendable {
  var range: DailyBriefSummaryRange
  /// yyyy-MM-dd
  var startDay: String
  var endDay: String
  var generatedAt: Date
  var overview: String
  var milestones: [String]
  var projects: [DailyBriefSummaryProject]
}

/// One "completed" card shown on the Everything-you-completed page.
struct DailyBriefCompletedEntry: Identifiable, Hashable, Sendable {
  var id: String { "\(day)|\(item.title)" }
  /// The day the work happened (the brief's source day).
  let day: String
  /// The brief that reported it; its folder holds `item.imageFile`.
  let briefDay: String
  let item: DailyBriefCompletedItem

  var imageURL: URL? {
    item.imageFile.map { DailyBriefStore.briefImageURL(day: briefDay, file: $0) }
  }
}
