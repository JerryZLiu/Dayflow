//
//  DailyBriefGenerator.swift
//  Dayflow
//
//  Builds one day's Daily brief: gathers yesterday's cards and a screenshot per
//  card, then runs two `claude -p` (Opus) runs at the same time, each with web
//  search, the user's own connectors (read-only), and Dayflow's MCP server. One
//  run writes the docket; the other writes every other section and is the only
//  one that sees the screenshots. The two answers are merged in code into one
//  DailyBriefContent, checked, and the images it uses are copied into the brief
//  folder. If one run fails, the brief keeps the other run's sections.
//
//  Everything here is synchronous and blocking; DailyBriefStore calls it from a
//  detached task.
//

import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// What one brief run produced: the cleaned content plus numbers about the run.
struct DailyBriefGeneration: Sendable {
  var content: DailyBriefContent
  var stats: DailyBriefRunStats
}

enum DailyBriefGenerator {
  /// The two Claude runs that write a brief. Each has its own prompt, schema, and transcript.
  enum Part: String, CaseIterable, Sendable {
    /// "Your docket today" only.
    case docket
    /// Every other section, using the candidate screenshots.
    case extras

    var displayName: String {
      switch self {
      case .docket: return "Docket"
      case .extras: return "Other sections"
      }
    }

    /// The built-in prompt with its `{{PLACEHOLDERS}}` intact. The prompt editor starts from it.
    var defaultTemplate: String {
      switch self {
      case .docket: return DailyBriefPrompt.docketTemplate
      case .extras: return DailyBriefPrompt.extrasTemplate
      }
    }

    /// Every placeholder the app fills in for this part, for the prompt editor to list.
    var placeholderNames: [String] {
      switch self {
      case .docket: return DailyBriefPrompt.docketPlaceholderNames
      case .extras: return DailyBriefPrompt.extrasPlaceholderNames
      }
    }

    /// The sections this part writes.
    var kinds: [DailyBriefSectionKind] {
      switch self {
      case .docket: return [.docket]
      case .extras: return DailyBriefSectionKind.allCases.filter { $0 != .docket }
      }
    }
  }

  struct Input: Sendable {
    /// The logical day the brief is for, yyyy-MM-dd.
    let day: String
    /// The day whose activity it is built from (usually yesterday), yyyy-MM-dd.
    let sourceDay: String
    let trigger: String
    let overrideInstructions: String
    /// Full replacements for a part's default prompt, with the same placeholders. A part
    /// that's missing or empty uses its default.
    let promptOverrides: [Part: String]
    let feedbackEvents: [DailyBriefFeedbackEvent]
    let recentBriefs: [DailyBrief]
  }

  /// A failure with a short, plain message the brief can show as is.
  struct GenerationError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
  }

  static let model = "opus"
  static let runTimeoutSeconds: TimeInterval = 20 * 60
  /// More candidates than this are evenly sampled down, to keep the run's reading sane.
  static let maxCandidates = 60
  static let candidateMaxPixelSize = 1280
  static let feedbackDays = 21
  static let maxFeedbackLines = 30

  /// Dayflow's own MCP tools the brief may call without asking. The hook below also
  /// allows them, and blocks the ones that change data.
  static let dayflowReadTools = [
    "get_time_breakdown", "get_timeline", "get_activity_detail", "search_activities",
    "get_daily", "get_weekly", "list_categories", "get_status",
  ]

  // MARK: - Readiness

  private static let readinessLock = NSLock()
  private nonisolated(unsafe) static var claudeSupportsJSONSchema = false

  /// nil when the Claude CLI can run the brief; otherwise a plain sentence saying why not.
  /// A passing check is cached for the life of the process; a failing one is re-checked
  /// next time, so installing or updating Claude fixes it without a relaunch.
  static func claudeReadinessProblem() -> String? {
    readinessLock.lock()
    let alreadyChecked = claudeSupportsJSONSchema
    readinessLock.unlock()
    if alreadyChecked { return nil }

    let help = LoginShellRunner.run("claude --help", timeout: 20)
    let output = help.stdout + help.stderr
    if help.exitCode != 0 && !output.contains("--print") {
      return "Claude Code isn't installed on this Mac, so the brief can't run. "
        + "Install it with `npm install -g @anthropic-ai/claude-code`, then sign in."
    }
    guard output.contains("--json-schema") else {
      return
        "Your Claude Code is too old for the brief. Run `claude update` in Terminal, then try again."
    }

    readinessLock.lock()
    claudeSupportsJSONSchema = true
    readinessLock.unlock()
    return nil
  }

  // MARK: - Generate

  static func generate(_ input: Input) throws -> DailyBriefGeneration {
    let runDirectory = try makeRunDirectory(for: input.day)
    defer { try? FileManager.default.removeItem(at: runDirectory) }
    let candidatesDirectory = runDirectory.appendingPathComponent("candidates", isDirectory: true)
    // So the footer never opens an older run's transcript for a part that failed early.
    for part in Part.allCases {
      try? FileManager.default.removeItem(
        at: DailyBriefStore.transcriptURL(for: input.day, part: part))
    }

    let categories = CategoryPersistence.loadPersistedCategories()
    let cards = nonIdleCards(
      StorageManager.shared.fetchTimelineCards(forDay: input.sourceDay), categories: categories)
    guard !cards.isEmpty else {
      throw GenerationError(message: "There's no activity from yesterday to build a brief from.")
    }

    let candidates = exportCandidates(for: cards, into: candidatesDirectory)
    let values: [String: String] = [
      "USER_NAME": userName(),
      "TODAY_LONG": longDate(input.day),
      "YESTERDAY_LONG": longDate(input.sourceDay),
      "TIMEZONE": TimeZone.current.identifier,
      "YESTERDAY_CARDS": cardLines(cards),
      "CATEGORIES_WITH_DESCRIPTIONS": categoryLines(categories),
      "FEEDBACK_DAYS": String(feedbackDays),
      "CANDIDATES_DIR": candidatesDirectory.path,
      "OVERRIDE_INSTRUCTIONS": DailyBriefPrompt.overrideInstructionsBlock(
        input.overrideInstructions),
    ]

    // The Spring run gets every card's full summary and detail lines; the other run keeps the short lines.
    let detailedCardLines = cardLines(cards, includesDetail: true)

    // Both runs go at once, so the wait is the slower of the two, not the sum.
    let parts = Part.allCases
    var outcomes: [Part: Result<PartRun, Error>] = [:]
    let outcomesLock = NSLock()
    DispatchQueue.concurrentPerform(iterations: parts.count) { index in
      let part = parts[index]
      var partValues = values
      if part == .docket {
        partValues["YESTERDAY_CARDS"] = detailedCardLines
        // Read here, on the docket's own thread, so the scan overlaps the other run.
        partValues["RECENT_AGENT_THREADS"] = DailyBriefThreadIndex.promptBlock()
      }
      let outcome = Result {
        try runPart(
          part, input: input, values: partValues, runDirectory: runDirectory,
          candidatesDirectory: candidatesDirectory)
      }
      outcomesLock.withLock { outcomes[part] = outcome }
    }

    // Merge in code: the docket goes first, then the other run's sections in its order.
    var content = DailyBriefContent(order: [])
    var stats = DailyBriefRunStats()
    var failures: [String: String] = [:]
    for part in parts {
      switch outcomes[part] {
      case .success(let run):
        switch part {
        case .docket:
          content.docket = run.docket
        case .extras:
          if let extras = run.extras {
            let docket = content.docket
            content = extras
            content.docket = docket
          }
        }
        stats = combined(stats, run.stats)
      case .failure(let error):
        failures[part.rawValue] =
          (error as? GenerationError)?.message ?? error.localizedDescription
      case nil:
        failures[part.rawValue] = "It didn't run."
      }
    }
    content.order = (content.docket == nil ? [] : [Part.docket.rawValue]) + content.order

    // Both failed. They usually fail for the same reason, so say it once.
    var failureMessage: String {
      var unique: [String] = []
      for message in parts.compactMap({ failures[$0.rawValue] }) where !unique.contains(message) {
        unique.append(message)
      }
      return unique.joined(separator: " ")
    }
    if failures.count == parts.count {
      throw GenerationError(message: failureMessage)
    }

    stats.cardCount = cards.count
    stats.candidateImageCount = candidates.count
    stats.usedOverrideInstructions =
      !input.overrideInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    stats.failedParts = failures.isEmpty ? nil : failures

    let cleanedContent = cleaned(
      content, candidates: candidates, candidatesDirectory: candidatesDirectory, day: input.day)
    // One run failed and the other found nothing, so this is a failure, not a quiet day.
    if !failures.isEmpty && cleanedContent.orderedKinds.isEmpty {
      throw GenerationError(message: failureMessage)
    }
    return DailyBriefGeneration(content: cleanedContent, stats: stats)
  }

  /// What one part's run produced. Only the field for that part is set.
  private struct PartRun {
    var docket: [DailyBriefDocketItem]?
    var extras: DailyBriefContent?
    var stats: DailyBriefRunStats
  }

  /// The Spring run's answer (stored as the docket). `notes` and `why` are only for the transcript.
  private struct DocketAnswer: Decodable {
    let items: [DailyBriefDocketItem]?
  }

  /// Fills in one part's prompt, runs Claude, and decodes the answer.
  private static func runPart(
    _ part: Part, input: Input, values: [String: String], runDirectory: URL,
    candidatesDirectory: URL
  ) throws -> PartRun {
    let override =
      input.promptOverrides[part]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let usesPromptOverride = !override.isEmpty
    var template = usesPromptOverride ? override : part.defaultTemplate
    // A custom prompt without the slot still gets the user's extra instructions, at the end.
    if !template.contains("{{OVERRIDE_INSTRUCTIONS}}") {
      template += "\n\n{{OVERRIDE_INSTRUCTIONS}}"
    }
    // Feedback and past items only cover the sections this part writes.
    var partValues = values
    partValues["FEEDBACK_SUMMARY"] = feedbackSummary(input.feedbackEvents, kinds: part.kinds)
    partValues["RECENT_BRIEF_ITEMS"] = recentBriefItems(input.recentBriefs, kinds: part.kinds)
    let prompt = DailyBriefPrompt.build(template: template, values: partValues)

    let options = try commandOptions(
      part: part, runDirectory: runDirectory, candidatesDirectory: candidatesDirectory)
    let run = try runStructuredClaude(
      prompt: prompt,
      options: options,
      workingDirectory: runDirectory,
      timeoutSeconds: runTimeoutSeconds,
      transcriptURL: DailyBriefStore.transcriptURL(for: input.day, part: part),
      tooLongMessage:
        "Claude took longer than 20 minutes on your brief, so Dayflow stopped it. Try again."
    )

    var stats = run.stats
    stats.promptCharacters = prompt.count
    stats.usedPromptOverride = usesPromptOverride

    do {
      switch part {
      case .docket:
        let answer = try JSONDecoder().decode(DocketAnswer.self, from: run.json)
        return PartRun(docket: answer.items, stats: stats)
      case .extras:
        var content = try JSONDecoder().decode(DailyBriefContent.self, from: run.json)
        content.docket = nil
        return PartRun(extras: content, stats: stats)
      }
    } catch {
      print("[DailyBrief] Could not decode the \(part.rawValue) answer: \(error)")
      throw GenerationError(message: "Claude's answer came back in an unexpected shape. Try again.")
    }
  }

  /// Adds up two runs' numbers. Duration is set later by the store (wall-clock time).
  private static func combined(_ a: DailyBriefRunStats, _ b: DailyBriefRunStats)
    -> DailyBriefRunStats
  {
    func sum(_ x: Int?, _ y: Int?) -> Int? {
      x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0)
    }
    var result = a
    result.model = a.model ?? b.model
    if a.costUSD != nil || b.costUSD != nil {
      result.costUSD = (a.costUSD ?? 0) + (b.costUSD ?? 0)
    }
    result.inputTokens = sum(a.inputTokens, b.inputTokens)
    result.outputTokens = sum(a.outputTokens, b.outputTokens)
    result.cacheReadTokens = sum(a.cacheReadTokens, b.cacheReadTokens)
    result.numTurns = sum(a.numTurns, b.numTurns)
    result.promptCharacters = sum(a.promptCharacters, b.promptCharacters)
    if a.toolCalls != nil || b.toolCalls != nil {
      result.toolCalls = (a.toolCalls ?? [:]).merging(b.toolCalls ?? [:], uniquingKeysWith: +)
    }
    result.usedPromptOverride = a.usedPromptOverride || b.usedPromptOverride
    return result
  }

  // MARK: - Run directory

  /// A fresh temp folder for this run. The path is fully resolved (/private/var/...)
  /// so Claude's permission rule for the candidates folder matches the files it reads.
  private static func makeRunDirectory(for day: String) throws -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-daily-brief", isDirectory: true)
      .appendingPathComponent(day, isDirectory: true)
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: base)
    do {
      try fileManager.createDirectory(
        at: base.appendingPathComponent("candidates", isDirectory: true),
        withIntermediateDirectories: true)
    } catch {
      throw GenerationError(message: "Dayflow couldn't create a temporary folder for the brief.")
    }
    return URL(fileURLWithPath: resolvedPath(base.path), isDirectory: true)
  }

  private static func resolvedPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  // MARK: - Cards

  private static func nonIdleCards(_ cards: [TimelineCard], categories: [TimelineCategory])
    -> [TimelineCard]
  {
    let idleNames = Set(categories.filter(\.isIdle).map { $0.name.lowercased() })
    return cards.filter { card in
      let category = card.category.trimmingCharacters(in: .whitespaces).lowercased()
      // "System" cards are failed-processing placeholders, not activity.
      return category != "idle" && category != "system" && !idleNames.contains(category)
    }
  }

  /// One compact line per card:
  /// `[cardId 123] 9:05 AM–10:20 AM · Work · Title — summary · apps: figma.com, slack`
  /// With `includesDetail`, the summary isn't cut and the card's detail lines follow it, indented.
  private static func cardLines(_ cards: [TimelineCard], includesDetail: Bool = false) -> String {
    cards.map { card in
      var line = "[cardId \(card.recordId.map { String($0) } ?? "?")] "
      line += "\(card.startTimestamp)–\(card.endTimestamp) · \(card.category) · \(card.title)"
      let summary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
      if !summary.isEmpty {
        line += " — " + (includesDetail ? summary : String(summary.prefix(400)))
      }
      let apps = [card.appSites?.primary, card.appSites?.secondary]
        .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      if !apps.isEmpty {
        line += " · apps: " + apps.joined(separator: ", ")
      }
      if includesDetail {
        let detailLines = card.detailedSummary
          .split(separator: "\n")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        for detailLine in detailLines {
          line += "\n    " + detailLine
        }
      }
      return line
    }
    .joined(separator: "\n")
  }

  private static func categoryLines(_ categories: [TimelineCategory]) -> String {
    let lines =
      categories
      .filter { !$0.isIdle }
      .sorted { $0.order < $1.order }
      .map { category -> String in
        let details = category.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return "- \(category.name): " + (details.isEmpty ? "(no description)" : details)
      }
    return lines.isEmpty ? "No categories set up." : lines.joined(separator: "\n")
  }

  // MARK: - Candidate screenshots

  struct Candidate: Codable {
    let file: String
    let cardId: Int64
    let start: String
    let end: String
    let title: String
  }

  /// Writes the middle screenshot of each card as `<cardId>_<HHmm>.jpg`, plus index.json.
  private static func exportCandidates(for cards: [TimelineCard], into directory: URL)
    -> [Candidate]
  {
    let sampled = evenlySampled(cards.filter { $0.recordId != nil }, limit: maxCandidates)
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HHmm"

    var candidates: [Candidate] = []
    for card in sampled {
      guard let cardId = card.recordId,
        let stored = StorageManager.shared.fetchTimelineCard(byId: cardId)
      else { continue }

      let screenshots = StorageManager.shared.fetchScreenshotsInTimeRange(
        startTs: stored.startTs, endTs: stored.endTs)
      guard !screenshots.isEmpty else { continue }
      let middle = screenshots[screenshots.count / 2]
      guard let image = FrameStore.shared.image(for: middle, maxPixelSize: candidateMaxPixelSize)
      else { continue }

      let start = Date(timeIntervalSince1970: TimeInterval(stored.startTs))
      let file = "\(cardId)_\(timeFormatter.string(from: start)).jpg"
      guard writeJPEG(image, to: directory.appendingPathComponent(file), quality: 0.8) else {
        continue
      }
      candidates.append(
        Candidate(
          file: file, cardId: cardId, start: card.startTimestamp, end: card.endTimestamp,
          title: card.title))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    if let data = try? encoder.encode(candidates) {
      try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
    return candidates
  }

  private static func evenlySampled<T>(_ items: [T], limit: Int) -> [T] {
    guard items.count > limit else { return items }
    return (0..<limit).map { items[$0 * items.count / limit] }
  }

  private static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat) -> Bool {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination)
  }

  // MARK: - Prompt pieces

  /// The Mac account's first name, since Dayflow doesn't ask for one.
  private static func userName() -> String {
    let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    let firstName = fullName.split(separator: " ").first.map(String.init) ?? ""
    return firstName.isEmpty ? "the user" : firstName
  }

  /// "2026-10-22" -> "Thursday, October 22, 2026"
  private static func longDate(_ day: String) -> String {
    guard let date = DateFormatter.yyyyMMdd.date(from: day) else { return day }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    return formatter.string(from: date)
  }

  private static func feedbackSummary(
    _ events: [DailyBriefFeedbackEvent], kinds: [DailyBriefSectionKind]
  ) -> String {
    let cutoff = Date().addingTimeInterval(-Double(feedbackDays) * 24 * 60 * 60)
    let sections = Set(kinds.map(\.rawValue))
    let recent =
      events
      .filter { $0.at >= cutoff && sections.contains($0.section) }
      .sorted { $0.at < $1.at }
    guard !recent.isEmpty else { return "No feedback yet." }

    var lines = ["Counts by section:"]
    let bySection = Dictionary(grouping: recent, by: \.section)
    for section in bySection.keys.sorted() {
      let counts = Dictionary(grouping: bySection[section] ?? [], by: \.action.rawValue)
        .map { "\($0.key) \($0.value.count)" }
        .sorted()
        .joined(separator: ", ")
      lines.append("- \(section): \(counts)")
    }

    lines.append("")
    lines.append("Latest actions:")
    for event in recent.suffix(maxFeedbackLines) {
      lines.append(
        "- \(event.day) · \(event.section) · \(event.action.rawValue) · \"\(event.itemTitle)\"")
    }
    return lines.joined(separator: "\n")
  }

  private static func recentBriefItems(
    _ briefs: [DailyBrief], kinds: [DailyBriefSectionKind]
  ) -> String {
    var blocks: [String] = []
    for brief in briefs.sorted(by: { $0.day > $1.day }) {
      let content = brief.content
      var lines: [String] = []
      for kind in kinds {
        switch kind {
        case .docket:
          lines += (content.docket ?? []).map { "- docket: \($0.title)" }
        case .keepTracking:
          lines += (content.keepTracking ?? []).map {
            "- keep_tracking: \($0.label) — \($0.status)"
          }
        case .completedYesterday:
          lines += (content.completedYesterday ?? []).map { "- completed_yesterday: \($0.title)" }
        case .teamDecisions:
          lines += (content.teamDecisions ?? []).map { "- team_decisions: \($0.decision)" }
        case .relatedReading:
          lines += (content.relatedReading ?? []).map {
            "- related_reading: \($0.title) (\($0.url))"
          }
        case .industryNews:
          lines += (content.industryNews ?? []).map {
            "- industry_news: \($0.headline) (\($0.url))"
          }
        case .siteSeeing:
          lines += (content.siteSeeing ?? []).map { "- site_seeing: \($0.caption ?? $0.file)" }
        }
      }
      guard !lines.isEmpty else { continue }
      blocks.append("#### \(brief.day)\n" + lines.joined(separator: "\n"))
    }
    return blocks.isEmpty ? "None yet." : blocks.joined(separator: "\n\n")
  }

  // MARK: - Command

  /// The docket run can read the person's Claude Code and Codex transcripts, to check whether
  /// a task was already started; the other run can read its screenshots.
  private static func commandOptions(part: Part, runDirectory: URL, candidatesDirectory: URL)
    throws -> ClaudeCLIStructuredOutputOptions
  {
    // Each part writes its own files, since both runs start at the same time.
    let hookURL = runDirectory.appendingPathComponent("\(part.rawValue)_read_only_hook.sh")
    do {
      try readOnlyHookScript.write(to: hookURL, atomically: true, encoding: .utf8)
    } catch {
      throw GenerationError(message: "Dayflow couldn't prepare the brief's safety check.")
    }

    // Every MCP tool call goes through the read-only hook first.
    let hook: [String: Any] = [
      "matcher": "mcp__.*",
      "hooks": [["type": "command", "command": "/bin/sh '\(hookURL.path)'"]],
    ]
    var settings: [String: Any] = ["hooks": ["PreToolUse": [hook]]]
    // Spring runs at medium effort: in testing it matched high and max for far less time and cost.
    if part == .docket {
      settings["effortLevel"] = "medium"
    }

    var tools = "WebSearch,WebFetch"
    var allowedTools = ["WebSearch", "WebFetch"]
    // Claude permission rules use // for absolute paths; / is project-relative.
    switch part {
    case .docket:
      tools = "Read," + tools
      allowedTools += DailyBriefThreadIndex.transcriptFolders.map { "Read(/\($0.path)/**)" }
    case .extras:
      tools = "Read," + tools
      allowedTools.append("Read(/\(candidatesDirectory.path)/**)")
    }
    allowedTools += dayflowReadTools.map { "mcp__dayflow__\($0)" }

    return ClaudeCLIStructuredOutputOptions(
      tools: tools,
      jsonSchema: jsonString(schema(for: part)),
      name: "dayflow-daily-brief-\(part.rawValue)",
      allowedTools: allowedTools,
      mcpConfigPath: dayflowMCPConfigPath(in: runDirectory, part: part),
      settingsJSON: jsonString(settings),
      loadsUserMCPServers: true
    )
  }

  /// Writes an `--mcp-config` file that adds Dayflow's bundled MCP server, or nil
  /// when the bundled CLI is missing (e.g. some debug builds).
  private static func dayflowMCPConfigPath(in runDirectory: URL, part: Part) -> String? {
    // Same path as AgentClientRegistration.cliPath, which is main-actor isolated.
    let cliPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dayflow").path
    guard FileManager.default.isExecutableFile(atPath: cliPath) else { return nil }

    let server: [String: Any] = ["command": cliPath, "args": ["mcp"]]
    let config: [String: Any] = ["mcpServers": ["dayflow": server]]
    let url = runDirectory.appendingPathComponent("\(part.rawValue)_mcp.json")
    do {
      try jsonString(config).write(to: url, atomically: true, encoding: .utf8)
      return url.path
    } catch {
      return nil
    }
  }

  /// PreToolUse hook that keeps MCP tools read-only. It reads the hook JSON on
  /// stdin, takes the tool's own name (after the last "__"), and splits it into
  /// words. Dayflow's server is allowed except its write tools. Other tools are
  /// denied when any word is a write verb, allowed when a word is a read verb,
  /// and denied otherwise. Deny is exit 2 with the reason on stderr; allow prints
  /// an explicit allow so connector reads don't stall on a permission prompt.
  static let readOnlyHookScript = #"""
    #!/bin/sh
    # Dayflow Daily brief: keeps MCP tools (the user's connectors) read-only.

    input=$(cat | tr '\n' ' ')
    tool=$(printf '%s' "$input" \
      | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -n 1 \
      | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/')

    deny() {
      echo "Dayflow's daily brief can only read from your tools, so $tool was blocked." >&2
      exit 2
    }

    allow() {
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
      exit 0
    }

    [ -n "$tool" ] || deny

    lower=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')

    # Dayflow's own server: everything except the tools that change data.
    case "$lower" in
      mcp__dayflow__create_category | mcp__dayflow__delete_category | \
      mcp__dayflow__update_category | mcp__dayflow__delete_activity | \
      mcp__dayflow__update_activity | mcp__dayflow__set_day_goal)
        deny ;;
      mcp__dayflow__*)
        allow ;;
    esac

    # Other tools: split the name after the last "__" into words,
    # breaking on camelCase and punctuation ("sendMessage" -> "send message").
    short=${tool##*__}
    words=$(printf '%s' "$short" \
      | sed 's/\([a-z0-9]\)\([A-Z]\)/\1 \2/g' \
      | tr '[:upper:]' '[:lower:]' \
      | tr -c 'a-z0-9' ' ')

    for word in $words; do
      case "$word" in
        send | post | create | update | delete | write | edit | remove | add | reply | \
        archive | move | upload | set | schedule | invite | comment | react | mark | \
        publish | share | assign | close | merge | approve | draft | submit | cancel | \
        rename | transfer | pay | run | execute | exec | insert | replace | append | \
        patch | put | save | import | apply | trigger | respond | accept | decline | \
        complete | resolve | star | follow | subscribe | label | tag | forward | \
        duplicate | restore | revert | deploy | kill | start | stop | enable | disable | \
        toggle | unsubscribe | unfollow | pin | unpin | snooze | mute)
          deny ;;
      esac
    done

    for word in $words; do
      case "$word" in
        get | list | search | read | fetch | query | find | view | retrieve | describe | \
        lookup | download)
          allow ;;
      esac
    done

    deny

    """#

  // MARK: - Schema

  private static let stringSchema: [String: Any] = ["type": "string"]

  private static func arraySchema(_ items: [String: Any]) -> [String: Any] {
    ["type": "array", "items": items]
  }

  private static func objectSchema(_ properties: [String: Any], required: [String])
    -> [String: Any]
  {
    [
      "type": "object",
      "properties": properties,
      "required": required,
      "additionalProperties": false,
    ]
  }

  /// JSON Schema for one part's answer. The Spring run returns `notes` and `items`; the
  /// other run returns every other section, each optional, plus a required `order`.
  /// `imageFile` on completed items is filled in by the app, so it isn't offered here.
  /// `notes` and each item's `why` are the model's justifications. The app doesn't show or
  /// decode them; they're there so the transcript explains each choice (the CLI hides thinking).
  static func schema(for part: Part) -> [String: Any] {
    let person = objectSchema(["name": stringSchema, "note": stringSchema], required: ["name"])
    let link = objectSchema(
      ["title": stringSchema, "url": stringSchema, "app": stringSchema], required: ["title"])

    let feedbackNote = objectSchema(
      ["name": stringSchema, "source": stringSchema, "text": stringSchema, "url": stringSchema],
      required: ["name", "text"])

    let docketItem = objectSchema(
      [
        "title": stringSchema,
        "detail": stringSchema,
        "due": stringSchema,
        "people": arraySchema(person),
        "links": arraySchema(link),
        "prompt": stringSchema,
        "agent": ["type": "boolean"],
        "feedback": arraySchema(feedbackNote),
        "feedbackSummary": stringSchema,
        "feedbackUrl": stringSchema,
        "attach": arraySchema(stringSchema),
        "thread": stringSchema,
        "newThreadApp": ["type": "string", "enum": ["claude", "codex"]],
        "why": stringSchema,
      ], required: ["title", "prompt", "agent", "why"])
    let trackingItem = objectSchema(
      [
        "label": stringSchema,
        "status": stringSchema,
        "app": stringSchema,
        "asOf": stringSchema,
        "url": stringSchema,
        "why": stringSchema,
      ], required: ["label", "status", "why"])
    let completedItem = objectSchema(
      [
        "project": stringSchema,
        "title": stringSchema,
        "apps": arraySchema(stringSchema),
        "cardId": ["type": "integer"],
        "why": stringSchema,
      ], required: ["title", "why"])
    let decisionItem = objectSchema(
      [
        "decision": stringSchema,
        "date": stringSchema,
        "people": arraySchema(stringSchema),
        "place": stringSchema,
        "app": stringSchema,
        "url": stringSchema,
        "why": stringSchema,
      ], required: ["decision", "why"])
    let readingItem = objectSchema(
      [
        "title": stringSchema,
        "source": stringSchema,
        "url": stringSchema,
        "reason": stringSchema,
        "imageUrl": stringSchema,
        "why": stringSchema,
      ], required: ["title", "url", "why"])
    let newsItem = objectSchema(
      [
        "headline": stringSchema,
        "source": stringSchema,
        "url": stringSchema,
        "published": stringSchema,
        "why": stringSchema,
      ], required: ["headline", "url", "why"])
    let siteSeeingItem = objectSchema(
      ["file": stringSchema, "caption": stringSchema, "why": stringSchema],
      required: ["file", "why"])

    if part == .docket {
      return objectSchema(
        ["notes": stringSchema, "items": arraySchema(docketItem)], required: ["notes", "items"])
    }

    let sectionNames = part.kinds.map(\.rawValue)
    return objectSchema(
      [
        "notes": stringSchema,
        "order": arraySchema(["type": "string", "enum": sectionNames]),
        "keep_tracking": arraySchema(trackingItem),
        "completed_yesterday": arraySchema(completedItem),
        "team_decisions": arraySchema(decisionItem),
        "related_reading_intro": stringSchema,
        "related_reading": arraySchema(readingItem),
        "industry_news": arraySchema(newsItem),
        "site_seeing": arraySchema(siteSeeingItem),
      ], required: ["notes", "order"])
  }

  static func jsonString(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }

  // MARK: - Running Claude

  struct StructuredClaudeResult {
    /// The JSON the model produced.
    let json: Data
    /// Model, cost, tokens, turns, and tool calls. The caller fills in the rest.
    let stats: DailyBriefRunStats
  }

  /// Runs `claude -p` with a structured-output profile and returns the JSON the
  /// model produced (the envelope's `structured_output`, or JSON found in `result`).
  /// Throws GenerationError with a plain message on any failure.
  static func runStructuredClaude(
    prompt: String,
    options: ClaudeCLIStructuredOutputOptions,
    workingDirectory: URL,
    timeoutSeconds: TimeInterval,
    transcriptURL: URL? = nil,
    tooLongMessage: String
  ) throws -> StructuredClaudeResult {
    let runner = ChatCLIProcessRunner()
    let run: ChatCLIRunResult
    do {
      run = try runner.run(
        tool: .claude,
        prompt: prompt,
        workingDirectory: workingDirectory,
        model: model,
        claudeProfile: .structuredOutput(options),
        timeoutSeconds: timeoutSeconds
      )
    } catch let error as NSError where error.domain == "ChatCLI" && error.code == -3 {
      throw GenerationError(message: tooLongMessage)
    } catch {
      throw GenerationError(message: friendlyMessage(for: error.localizedDescription))
    }

    let events = outputEvents(in: run.rawStdout, runner: runner)
    if let transcriptURL {
      writeTranscript(prompt: prompt, events: events, run: run, to: transcriptURL)
    }
    let envelope = events.last { $0["type"] as? String == "result" }
    let isError = (envelope?["is_error"] as? Bool) == true
    let subtype = envelope?["subtype"] as? String ?? ""

    if let envelope, !isError, subtype == "success" || subtype.isEmpty {
      if let structured = envelope["structured_output"],
        JSONSerialization.isValidJSONObject(structured),
        let data = try? JSONSerialization.data(withJSONObject: structured)
      {
        return StructuredClaudeResult(
          json: data, stats: runStats(envelope: envelope, events: events))
      }
      if let text = envelope["result"] as? String,
        let data = jsonObjectData(in: text, runner: runner)
      {
        return StructuredClaudeResult(
          json: data, stats: runStats(envelope: envelope, events: events))
      }
    }

    let resultText = envelope?["result"] as? String ?? ""
    print(
      "[DailyBrief] Claude run failed. exit=\(run.exitCode) subtype=\(subtype) "
        + "result=\(resultText.prefix(500)) stderr=\(run.stderr.suffix(500))")

    if subtype == "error_max_turns" {
      throw GenerationError(message: "Claude ran out of steps before finishing. Try again.")
    }
    if subtype.contains("structured_output") {
      throw GenerationError(message: "Claude's answer came back in an unexpected shape. Try again.")
    }
    let rawMessage =
      [resultText, run.stderr, run.stdout]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""
    throw GenerationError(message: friendlyMessage(for: rawMessage))
  }

  /// The events in Claude's JSON output (a single result object, or with --verbose an
  /// array of every event), even with login-shell noise around it. Empty when there's
  /// no result event.
  private static func outputEvents(in rawStdout: String, runner: ChatCLIProcessRunner)
    -> [[String: Any]]
  {
    let trimmed = rawStdout.trimmingCharacters(in: .whitespacesAndNewlines)
    for candidate in [trimmed] + runner.balancedJSONValues(in: trimmed) {
      guard let data = candidate.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data)
      else { continue }
      let events = (json as? [[String: Any]]) ?? [json as? [String: Any]].compactMap { $0 }
      if events.contains(where: { $0["type"] as? String == "result" }) {
        return events
      }
    }
    return []
  }

  // MARK: - Transcript

  /// Saves the whole run as readable text (prompt, every message, tool call, and
  /// tool result, then the final result) for the footer's Transcript button.
  /// Written for failed runs too, since those are the ones worth reading.
  private static func writeTranscript(
    prompt: String, events: [[String: Any]], run: ChatCLIRunResult, to url: URL
  ) {
    var sections: [String] = ["# Prompt\n\n" + prompt]

    if events.isEmpty {
      // No parseable events, so show what the CLI printed instead.
      sections.append("# Raw output\n\n" + run.rawStdout)
    }

    for event in events {
      switch event["type"] as? String {
      case "system":
        var lines = ["# Session started"]
        if let model = event["model"] as? String { lines.append("model: \(model)") }
        if let tools = event["tools"] as? [String] {
          lines.append("tools: " + tools.joined(separator: ", "))
        }
        if let servers = event["mcp_servers"] as? [[String: Any]] {
          let names = servers.map { "\($0["name"] ?? "?") (\($0["status"] ?? "?"))" }
          lines.append("connectors: " + names.joined(separator: ", "))
        }
        sections.append(lines.joined(separator: "\n"))

      case "assistant":
        let message = event["message"] as? [String: Any]
        for block in message?["content"] as? [[String: Any]] ?? [] {
          switch block["type"] as? String {
          case "text":
            sections.append("## Claude\n\n" + (block["text"] as? String ?? ""))
          case "thinking":
            // The CLI currently sends thinking blocks with the text left out, so skip empty ones.
            let thinking = block["thinking"] as? String ?? ""
            guard !thinking.isEmpty else { continue }
            sections.append("## Claude (thinking)\n\n" + thinking)
          case "tool_use":
            let name = block["name"] as? String ?? "?"
            sections.append("## Tool call: \(name)\n\n" + prettyJSON(block["input"] ?? [:]))
          default:
            continue
          }
        }

      case "user":
        let message = event["message"] as? [String: Any]
        for block in message?["content"] as? [[String: Any]] ?? [] {
          guard block["type"] as? String == "tool_result" else { continue }
          let heading = (block["is_error"] as? Bool) == true ? "## Tool error" : "## Tool result"
          sections.append(heading + "\n\n" + toolResultText(block["content"]))
        }

      case "result":
        var lines = ["# Result"]
        if let subtype = event["subtype"] as? String { lines.append("subtype: \(subtype)") }
        if let structured = event["structured_output"] {
          lines.append("\n" + prettyJSON(structured))
        } else if let text = event["result"] as? String {
          lines.append("\n" + text)
        }
        sections.append(lines.joined(separator: "\n"))

      default:
        continue
      }
    }

    let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stderr.isEmpty {
      sections.append("# stderr\n\n" + stderr)
    }

    let text = sections.joined(separator: "\n\n---\n\n") + "\n"
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Tool results are either a string or a list of content blocks.
  private static func toolResultText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    let blocks = content as? [[String: Any]] ?? []
    return blocks.map { block in
      if let text = block["text"] as? String { return text }
      return "[\(block["type"] as? String ?? "unknown") block]"
    }
    .joined(separator: "\n")
  }

  private static func prettyJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      let string = String(data: data, encoding: .utf8)
    else { return String(describing: value) }
    return string
  }

  /// Cost, tokens, turns, model, and tool-call counts from the result envelope and
  /// the --verbose event stream.
  private static func runStats(envelope: [String: Any], events: [[String: Any]])
    -> DailyBriefRunStats
  {
    var stats = DailyBriefRunStats()
    stats.costUSD = (envelope["total_cost_usd"] as? NSNumber)?.doubleValue
    stats.numTurns = (envelope["num_turns"] as? NSNumber)?.intValue
    if let usage = envelope["usage"] as? [String: Any] {
      stats.inputTokens = (usage["input_tokens"] as? NSNumber)?.intValue
      stats.outputTokens = (usage["output_tokens"] as? NSNumber)?.intValue
      stats.cacheReadTokens = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue
    }

    // modelUsage is keyed by full model id; the one that wrote the most is the main model.
    func outputTokens(_ usage: Any) -> Int {
      ((usage as? [String: Any])?["outputTokens"] as? NSNumber)?.intValue ?? 0
    }
    let modelUsage = envelope["modelUsage"] as? [String: Any] ?? [:]
    let mainModel = modelUsage.max(by: { outputTokens($0.value) < outputTokens($1.value) })
    let initEvent = events.first(where: { $0["type"] as? String == "system" })
    stats.model = mainModel?.key ?? (initEvent?["model"] as? String) ?? model

    var toolCalls: [String: Int] = [:]
    for event in events where event["type"] as? String == "assistant" {
      let message = event["message"] as? [String: Any]
      for block in message?["content"] as? [[String: Any]] ?? [] {
        // StructuredOutput is how the CLI returns the answer, not a real tool call.
        guard block["type"] as? String == "tool_use", let name = block["name"] as? String,
          name != "StructuredOutput"
        else {
          continue
        }
        toolCalls[name, default: 0] += 1
      }
    }
    stats.toolCalls = toolCalls.isEmpty ? nil : toolCalls
    return stats
  }

  /// The first JSON object in model text, ignoring ``` fences and prose around it.
  private static func jsonObjectData(in text: String, runner: ChatCLIProcessRunner) -> Data? {
    let cleaned =
      text
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
    for candidate in runner.balancedJSONValues(in: cleaned) where candidate.hasPrefix("{") {
      if let data = candidate.data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
      {
        return data
      }
    }
    return nil
  }

  /// Turns raw CLI output into one plain sentence, using the timeline's failure patterns.
  static func friendlyMessage(for raw: String) -> String {
    let error = NSError(
      domain: "DailyBrief", code: 0, userInfo: [NSLocalizedDescriptionKey: raw])
    switch TimelineFailureClassifier.classify(error).kind {
    case .usageLimitHit:
      return "Claude hit its usage limit. Try again after it resets."
    case .providerLoginExpired:
      return "Claude isn't signed in. Open Terminal, run `claude`, then type /login."
    case .cliNotInstalled:
      return "Dayflow couldn't find Claude Code on this Mac."
    case .outOfCredits, .apiKeyProblem, .accountBlocked:
      return "Claude's account has a billing or API key problem, so the brief couldn't run."
    case .modelMisconfigured:
      return "Your Claude account can't use the Opus model the brief needs."
    case .transient:
      return "Dayflow couldn't reach Claude. Try again in a bit."
    case .modelFlaky:
      return "Claude's answer came back in an unexpected shape. Try again."
    default:
      return "Claude couldn't finish the brief. Try again."
    }
  }

  // MARK: - Clean up the model's answer

  /// Trims text, drops empty or unlinkable items, keeps only real screenshots, and
  /// copies the images the brief shows into `<day>/images/`.
  private static func cleaned(
    _ content: DailyBriefContent, candidates: [Candidate], candidatesDirectory: URL, day: String
  ) -> DailyBriefContent {
    let imagesDirectory = DailyBriefStore.briefDirectory(for: day)
      .appendingPathComponent("images", isDirectory: true)
    let candidateFiles = Set(candidates.map(\.file))
    var copiedFiles: Set<String> = []

    // Old images stay until replaced, so the brief on screen during a retry keeps its pictures.
    try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

    /// Copies a candidate into images/ and returns "images/<file>", or nil on failure.
    func copyCandidate(_ file: String) -> String? {
      if !copiedFiles.contains(file) {
        let source = candidatesDirectory.appendingPathComponent(file)
        let destination = imagesDirectory.appendingPathComponent(file)
        do {
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.copyItem(at: source, to: destination)
        } catch {
          print("[DailyBrief] Failed to copy \(file): \(error)")
          return nil
        }
        copiedFiles.insert(file)
      }
      return "images/\(file)"
    }

    var result = DailyBriefContent(order: [])

    result.docket = nonEmpty(
      (content.docket ?? []).compactMap { item -> DailyBriefDocketItem? in
        guard let title = clean(item.title) else { return nil }
        let people = (item.people ?? []).compactMap { person -> DailyBriefPerson? in
          guard let name = clean(person.name) else { return nil }
          return DailyBriefPerson(name: name, note: clean(person.note))
        }
        let links = (item.links ?? []).compactMap { link -> DailyBriefLink? in
          guard let title = clean(link.title) else { return nil }
          return DailyBriefLink(title: title, url: webURL(link.url), app: cleanApp(link.app))
        }
        let feedback = (item.feedback ?? []).compactMap { note -> DailyBriefFeedbackNote? in
          guard let name = clean(note.name), let text = clean(note.text) else { return nil }
          return DailyBriefFeedbackNote(
            name: name, source: clean(note.source), text: text, url: webURL(note.url))
        }
        let attach = (item.attach ?? []).compactMap { clean($0) }
        // A thread id that isn't shaped like a Codex or Claude Code one is dropped, so the
        // task starts a new thread.
        let thread = clean(item.thread).flatMap { DailyBriefAgent(threadID: $0) == nil ? nil : $0 }
        // Only a new thread needs an app picked; an existing thread already has one.
        let newThreadApp =
          thread == nil
          ? clean(item.newThreadApp).flatMap { DailyBriefAgent(appName: $0) == nil ? nil : $0 }
          : nil
        return DailyBriefDocketItem(
          title: title, detail: clean(item.detail), due: clean(item.due),
          people: nonEmpty(people), links: nonEmpty(links),
          prompt: clean(item.prompt), agent: item.agent, feedback: nonEmpty(feedback),
          feedbackSummary: clean(item.feedbackSummary), feedbackUrl: webURL(item.feedbackUrl),
          attach: nonEmpty(attach), thread: thread, newThreadApp: newThreadApp)
      })

    result.keepTracking = nonEmpty(
      (content.keepTracking ?? []).compactMap { item -> DailyBriefTrackingItem? in
        guard let label = clean(item.label), let status = clean(item.status) else { return nil }
        return DailyBriefTrackingItem(
          label: label, status: status, app: cleanApp(item.app), asOf: clean(item.asOf),
          url: webURL(item.url))
      })

    result.completedYesterday = nonEmpty(
      (content.completedYesterday ?? []).compactMap { item -> DailyBriefCompletedItem? in
        guard let title = clean(item.title) else { return nil }
        let candidate = candidates.first { $0.cardId == item.cardId }
        let apps = (item.apps ?? []).compactMap { cleanApp($0) }
        return DailyBriefCompletedItem(
          project: clean(item.project), title: title, apps: nonEmpty(apps),
          cardId: candidate?.cardId, imageFile: candidate.flatMap { copyCandidate($0.file) })
      })

    result.teamDecisions = nonEmpty(
      (content.teamDecisions ?? []).compactMap { item -> DailyBriefDecisionItem? in
        guard let decision = clean(item.decision) else { return nil }
        let people = (item.people ?? []).compactMap { clean($0) }
        return DailyBriefDecisionItem(
          decision: decision, date: clean(item.date), people: nonEmpty(people),
          place: clean(item.place), app: cleanApp(item.app), url: webURL(item.url))
      })

    result.relatedReading = nonEmpty(
      (content.relatedReading ?? []).compactMap { item -> DailyBriefReadingItem? in
        guard let title = clean(item.title), let url = webURL(item.url) else { return nil }
        return DailyBriefReadingItem(
          title: title, source: clean(item.source), url: url, reason: clean(item.reason),
          imageUrl: webURL(item.imageUrl))
      })
    result.relatedReadingIntro =
      result.relatedReading == nil ? nil : clean(content.relatedReadingIntro)

    result.industryNews = nonEmpty(
      (content.industryNews ?? []).compactMap { item -> DailyBriefNewsItem? in
        guard let headline = clean(item.headline), let url = webURL(item.url) else { return nil }
        return DailyBriefNewsItem(
          headline: headline, source: clean(item.source), url: url,
          published: clean(item.published))
      })

    var seenSiteSeeingFiles: Set<String> = []
    result.siteSeeing = nonEmpty(
      (content.siteSeeing ?? []).compactMap { item -> DailyBriefSiteSeeingItem? in
        // The model may echo a path; only the file name has to match a candidate.
        guard let raw = clean(item.file) else { return nil }
        let file = (raw as NSString).lastPathComponent
        guard candidateFiles.contains(file), !seenSiteSeeingFiles.contains(file),
          let copied = copyCandidate(file)
        else { return nil }
        seenSiteSeeingFiles.insert(file)
        return DailyBriefSiteSeeingItem(file: copied, caption: clean(item.caption))
      })

    var order: [String] = []
    for name in content.order {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if let kind = DailyBriefSectionKind(rawValue: trimmed), result.hasItems(kind),
        !order.contains(trimmed)
      {
        order.append(trimmed)
      }
    }
    result.order = order
    return result
  }

  private static func clean(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  private static func cleanApp(_ app: String?) -> String? {
    clean(app)?.lowercased()
  }

  /// The URL when it's a real http(s) link, otherwise nil.
  private static func webURL(_ text: String?) -> String? {
    guard let trimmed = clean(text), let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host != nil
    else { return nil }
    return trimmed
  }

  private static func nonEmpty<T>(_ items: [T]) -> [T]? {
    items.isEmpty ? nil : items
  }
}
