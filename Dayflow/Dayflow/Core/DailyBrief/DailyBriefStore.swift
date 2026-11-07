//
//  DailyBriefStore.swift
//  Dayflow
//
//  Owns the Daily brief: decides when to run it, stores each day's brief and
//  what the user did with it, keeps saved images and feedback, and drives
//  which brief screen is on top.
//
//  Files live in ~/Library/Application Support/Dayflow/daily_brief/:
//    <day>/brief.json        one brief per logical day (4am boundary)
//    <day>/images/           screenshots the brief shows (copied, so they outlive recordings)
//    saved/saved.json        saved images index, plus the image files
//    feedback.json           what the user opened, saved, dismissed, or checked
//    summaries/<range>.json  the latest "Everything you completed" summary per range
//

import AppKit

@MainActor
final class DailyBriefStore: ObservableObject {
  static let shared = DailyBriefStore()

  // MARK: - Access

  /// Signed-in Dayflow account emails that get the brief. Widen this when it rolls out.
  static let allowlistedEmails: Set<String> = [
    "zhengyu.j.liu@gmail.com",
    "maggiechangjx@gmail.com",
  ]

  /// The brief runs when yesterday had at least this much recorded activity.
  static let minimumSourceMinutes: Double = 60
  /// Automatic runs per day before giving up. The Retry button ignores this.
  static let maxAutomaticAttemptsPerDay = 2

  var isFeatureEnabled: Bool {
    guard let email = DayflowAuthManager.shared.signedInEmail?.lowercased() else { return false }
    return Self.allowlistedEmails.contains(email)
  }

  // MARK: - State

  enum RunState: Equatable {
    case idle
    case running(startedAt: Date)
    case failed(String)
  }

  /// A screen layered on top of the brief page.
  enum Route: Equatable {
    case enlargedImage(DailyBriefImage)
    case saved
    case completedHistory
    case rangeSummary(DailyBriefSummaryRange)
  }

  enum SummaryState: Equatable {
    case idle
    case running(DailyBriefSummaryRange)
    case failed(String)
  }

  @Published private(set) var brief: DailyBrief?
  @Published private(set) var runState: RunState = .idle
  @Published private(set) var savedItems: [DailyBriefSavedItem] = []
  @Published private(set) var summaries: [DailyBriefSummaryRange: DailyBriefRangeSummary] = [:]
  @Published private(set) var summaryState: SummaryState = .idle

  /// The brief overlay is on screen.
  @Published var isPresented = false
  @Published var route: Route?
  /// The top-right "your brief is ready" notice is on screen.
  @Published var showsReadyNotice = false

  var isRunning: Bool {
    if case .running = runState { return true }
    return false
  }

  private var feedbackEvents: [DailyBriefFeedbackEvent] = []

  private init() {
    loadToday()
    savedItems = Self.loadSavedItems()
    feedbackEvents = Self.loadFeedback()
    loadSummaries()
  }

  // MARK: - Override instructions

  private static let overrideInstructionsKey = "dailyBriefOverrideInstructions"

  /// Extra preferences typed into "Override instructions"; injected into every run's prompt.
  var overrideInstructions: String {
    get { UserDefaults.standard.string(forKey: Self.overrideInstructionsKey) ?? "" }
    set {
      objectWillChange.send()
      UserDefaults.standard.set(newValue, forKey: Self.overrideInstructionsKey)
    }
  }

  private static func promptOverrideKey(_ part: DailyBriefGenerator.Part) -> String {
    "dailyBriefPromptOverride.\(part.rawValue)"
  }

  /// A full replacement for one part's default prompt (same {{PLACEHOLDERS}}).
  /// Empty means use the part's defaultTemplate.
  func promptOverride(for part: DailyBriefGenerator.Part) -> String {
    UserDefaults.standard.string(forKey: Self.promptOverrideKey(part)) ?? ""
  }

  func setPromptOverride(_ text: String, for part: DailyBriefGenerator.Part) {
    objectWillChange.send()
    UserDefaults.standard.set(text, forKey: Self.promptOverrideKey(part))
  }

  func hasPromptOverride(for part: DailyBriefGenerator.Part) -> Bool {
    !promptOverride(for: part).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var hasAnyPromptOverride: Bool {
    DailyBriefGenerator.Part.allCases.contains { hasPromptOverride(for: $0) }
  }

  /// Stats from the most recent failed run, so the debug footer can show them.
  @Published private(set) var lastFailedRunStats: DailyBriefRunStats?

  // MARK: - Days

  static func todayDayString() -> String {
    Date().getDayInfoFor4AMBoundary().dayString
  }

  /// The logical day before `day`, plus its start and end.
  static func previousDay(before startOfDay: Date) -> (
    dayString: String, startOfDay: Date, endOfDay: Date
  ) {
    startOfDay.addingTimeInterval(-60 * 60).getDayInfoFor4AMBoundary()
  }

  // MARK: - Files

  nonisolated static func rootDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/Dayflow/daily_brief", isDirectory: true)
  }

  nonisolated static func briefDirectory(for day: String) -> URL {
    rootDirectory().appendingPathComponent(day, isDirectory: true)
  }

  nonisolated static func briefFileURL(for day: String) -> URL {
    briefDirectory(for: day).appendingPathComponent("brief.json")
  }

  /// One part's full Claude transcript from the last run for that day, readable text.
  nonisolated static func transcriptURL(for day: String, part: DailyBriefGenerator.Part) -> URL {
    briefDirectory(for: day).appendingPathComponent("transcript-\(part.rawValue).txt")
  }

  nonisolated static func savedDirectory() -> URL {
    rootDirectory().appendingPathComponent("saved", isDirectory: true)
  }

  nonisolated static func summariesDirectory() -> URL {
    rootDirectory().appendingPathComponent("summaries", isDirectory: true)
  }

  private nonisolated static var savedIndexURL: URL {
    savedDirectory().appendingPathComponent("saved.json")
  }

  private nonisolated static var feedbackURL: URL {
    rootDirectory().appendingPathComponent("feedback.json")
  }

  /// Absolute URL of an image in a day's brief (completed or site-seeing).
  nonisolated static func briefImageURL(day: String, file: String) -> URL {
    briefDirectory(for: day).appendingPathComponent(file)
  }

  nonisolated static func savedImageURL(_ item: DailyBriefSavedItem) -> URL {
    savedDirectory().appendingPathComponent(item.imageFile)
  }

  private nonisolated static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private nonisolated static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private nonisolated static func write<T: Encodable>(_ value: T, to url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder().encode(value).write(to: url, options: .atomic)
    } catch {
      print("[DailyBrief] Failed to write \(url.lastPathComponent): \(error)")
    }
  }

  private nonisolated static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? decoder().decode(type, from: data)
  }

  nonisolated static func loadBrief(for day: String) -> DailyBrief? {
    read(DailyBrief.self, from: briefFileURL(for: day))
  }

  /// Every stored brief, newest first.
  nonisolated static func loadAllBriefs() -> [DailyBrief] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: rootDirectory().path)) ?? []
    return
      names
      .filter { $0.count == 10 && $0.first?.isNumber == true }  // yyyy-MM-dd folders
      .sorted(by: >)
      .compactMap { loadBrief(for: $0) }
  }

  nonisolated static func loadFeedback() -> [DailyBriefFeedbackEvent] {
    read([DailyBriefFeedbackEvent].self, from: feedbackURL) ?? []
  }

  private nonisolated static func loadSavedItems() -> [DailyBriefSavedItem] {
    read([DailyBriefSavedItem].self, from: savedIndexURL) ?? []
  }

  func loadToday() {
    let today = Self.todayDayString()
    if brief?.day != today {
      brief = Self.loadBrief(for: today)
    }
  }

  private func persistBrief() {
    guard let brief else { return }
    Self.write(brief, to: Self.briefFileURL(for: brief.day))
  }

  private func loadSummaries() {
    var loaded: [DailyBriefSummaryRange: DailyBriefRangeSummary] = [:]
    for range in DailyBriefSummaryRange.allCases {
      let url = Self.summariesDirectory().appendingPathComponent("\(range.rawValue).json")
      if let summary = Self.read(DailyBriefRangeSummary.self, from: url) {
        loaded[range] = summary
      }
    }
    summaries = loaded
  }

  // MARK: - Running

  private static let attemptsKey = "dailyBriefAutomaticAttempts"

  private func automaticAttempts(for day: String) -> Int {
    let all = UserDefaults.standard.dictionary(forKey: Self.attemptsKey) as? [String: Int] ?? [:]
    return all[day] ?? 0
  }

  private func recordAutomaticAttempt(for day: String) {
    // Only today's count matters, so older days are dropped.
    let count = automaticAttempts(for: day) + 1
    UserDefaults.standard.set([day: count], forKey: Self.attemptsKey)
  }

  /// Called when the app becomes active and on a timer. Runs the brief in the
  /// background the first time it is eligible each day.
  func runIfNeeded(trigger: String) {
    guard isFeatureEnabled, !isRunning else { return }
    loadToday()

    let today = Date().getDayInfoFor4AMBoundary()
    guard brief?.day != today.dayString else { return }
    guard automaticAttempts(for: today.dayString) < Self.maxAutomaticAttemptsPerDay else { return }

    let source = Self.previousDay(before: today.startOfDay)
    let recordedMinutes = StorageManager.shared.fetchTotalMinutesTracked(
      from: source.startOfDay, to: source.endOfDay)
    guard recordedMinutes >= Self.minimumSourceMinutes else { return }

    recordAutomaticAttempt(for: today.dayString)
    start(day: today.dayString, sourceDay: source.dayString, trigger: trigger)
  }

  /// The Retry button: regenerate today's brief from scratch.
  func retry() {
    guard isFeatureEnabled, !isRunning else { return }
    let today = Date().getDayInfoFor4AMBoundary()
    let source = Self.previousDay(before: today.startOfDay)
    start(day: today.dayString, sourceDay: source.dayString, trigger: "retry")
  }

  private func start(day: String, sourceDay: String, trigger: String) {
    let startedAt = Date()
    runState = .running(startedAt: startedAt)

    var promptOverrides: [DailyBriefGenerator.Part: String] = [:]
    for part in DailyBriefGenerator.Part.allCases where hasPromptOverride(for: part) {
      promptOverrides[part] = promptOverride(for: part)
    }
    let input = DailyBriefGenerator.Input(
      day: day,
      sourceDay: sourceDay,
      trigger: trigger,
      overrideInstructions: overrideInstructions,
      promptOverrides: promptOverrides,
      feedbackEvents: feedbackEvents,
      recentBriefs: Self.loadAllBriefs().filter { $0.day != day }.prefix(5).map { $0 }
    )
    AnalyticsService.shared.capture(
      "daily_brief_run_started", ["trigger": trigger, "day": day, "source_day": sourceDay])

    Task.detached(priority: .utility) {
      let result: Result<DailyBriefGeneration, Error>
      if let problem = DailyBriefGenerator.claudeReadinessProblem() {
        result = .failure(DailyBriefGenerator.GenerationError(message: problem))
      } else {
        result = Result { try DailyBriefGenerator.generate(input) }
      }
      await MainActor.run {
        DailyBriefStore.shared.finishRun(
          day: day, sourceDay: sourceDay, startedAt: startedAt, trigger: trigger, result: result)
      }
    }
  }

  private func finishRun(
    day: String, sourceDay: String, startedAt: Date, trigger: String,
    result: Result<DailyBriefGeneration, Error>
  ) {
    let elapsed = Date().timeIntervalSince(startedAt)
    let durationSeconds = Int(elapsed)
    switch result {
    case .success(let generation):
      var content = generation.content
      var stats = generation.stats
      // A retry where one part failed keeps that part's sections from the brief already here.
      if let existing = brief, existing.day == day, let failedParts = stats.failedParts {
        let parts = failedParts.keys.compactMap { DailyBriefGenerator.Part(rawValue: $0) }
        content = Self.content(content, keepingSectionsOf: parts, from: existing.content)
      }
      stats.durationSeconds = elapsed
      stats.trigger = trigger
      // A retry replaces the content but keeps what the user already did today.
      var userState = DailyBriefUserState()
      if let existing = brief, existing.day == day {
        userState = existing.userState
      }
      if isPresented {
        userState.hasBeenShown = true
      }
      let newBrief = DailyBrief(
        day: day, sourceDay: sourceDay, generatedAt: Date(), content: content,
        userState: userState, stats: stats)
      lastFailedRunStats = nil
      brief = newBrief
      persistBrief()
      runState = .idle
      // A retry happens while the brief is open, so only announce automatic runs.
      if trigger != "retry" && !isPresented {
        showsReadyNotice = true
      }
      AnalyticsService.shared.capture(
        "daily_brief_run_succeeded",
        [
          "trigger": trigger,
          "day": day,
          "duration_seconds": durationSeconds,
          "sections": content.orderedKinds.map(\.rawValue).joined(separator: ","),
          "section_count": content.orderedKinds.count,
          "cost_usd": stats.costUSD ?? 0,
          "num_turns": stats.numTurns ?? 0,
          "used_prompt_override": stats.usedPromptOverride,
          "failed_parts": (stats.failedParts ?? [:]).keys.sorted().joined(separator: ","),
        ])
    case .failure(let error):
      let message =
        (error as? DailyBriefGenerator.GenerationError)?.message ?? error.localizedDescription
      runState = .failed(message)
      lastFailedRunStats = DailyBriefRunStats(
        durationSeconds: elapsed, usedPromptOverride: hasAnyPromptOverride,
        usedOverrideInstructions: !overrideInstructions.isEmpty, trigger: trigger)
      AnalyticsService.shared.capture(
        "daily_brief_run_failed",
        ["trigger": trigger, "day": day, "duration_seconds": durationSeconds])
    }
  }

  /// `new` with the sections of `parts` taken from `old`. The docket stays first.
  private static func content(
    _ new: DailyBriefContent, keepingSectionsOf parts: [DailyBriefGenerator.Part],
    from old: DailyBriefContent
  ) -> DailyBriefContent {
    var result = new
    if parts.contains(.docket) {
      result.docket = old.docket
    }
    var otherOrder = new.order
    if parts.contains(.extras) {
      result.keepTracking = old.keepTracking
      result.completedYesterday = old.completedYesterday
      result.teamDecisions = old.teamDecisions
      result.relatedReadingIntro = old.relatedReadingIntro
      result.relatedReading = old.relatedReading
      result.industryNews = old.industryNews
      result.siteSeeing = old.siteSeeing
      otherOrder = old.order
    }
    let docketName = DailyBriefSectionKind.docket.rawValue
    result.order =
      (result.hasItems(.docket) ? [docketName] : []) + otherOrder.filter { $0 != docketName }
    return result
  }

  // MARK: - Presentation

  /// Whether opening the Timeline should pop the brief up on its own: today's
  /// brief exists and hasn't been seen yet.
  var shouldAutoPresent: Bool {
    guard isFeatureEnabled, let brief else { return false }
    return brief.day == Self.todayDayString() && !brief.userState.hasBeenShown
  }

  /// Users who get the brief don't also get the daily goal pop-up.
  var suppressesDailyGoalPrompt: Bool {
    isFeatureEnabled
  }

  func present(source: String) {
    guard isFeatureEnabled else { return }
    loadToday()
    route = nil
    isPresented = true
    showsReadyNotice = false
    if brief != nil && brief?.userState.hasBeenShown == false {
      brief?.userState.hasBeenShown = true
      persistBrief()
    }
    AnalyticsService.shared.capture(
      "daily_brief_opened",
      ["source": source, "has_brief": brief != nil])
  }

  func dismiss() {
    route = nil
    isPresented = false
  }

  func dismissReadyNotice() {
    showsReadyNotice = false
  }

  // MARK: - Item actions

  /// A stable key for one item in today's brief, used for checks and dismissals.
  static func itemKey(_ kind: DailyBriefSectionKind, _ title: String) -> String {
    "\(kind.rawValue)|\(title)"
  }

  func isChecked(_ kind: DailyBriefSectionKind, _ title: String) -> Bool {
    brief?.userState.checkedItemKeys.contains(Self.itemKey(kind, title)) ?? false
  }

  func isDismissed(_ kind: DailyBriefSectionKind, _ title: String) -> Bool {
    brief?.userState.dismissedItemKeys.contains(Self.itemKey(kind, title)) ?? false
  }

  func toggleChecked(_ kind: DailyBriefSectionKind, _ title: String) {
    guard brief != nil else { return }
    let key = Self.itemKey(kind, title)
    if brief!.userState.checkedItemKeys.contains(key) {
      brief!.userState.checkedItemKeys.remove(key)
    } else {
      brief!.userState.checkedItemKeys.insert(key)
      recordFeedback(kind, title, .checked)
    }
    persistBrief()
  }

  func dismissItem(_ kind: DailyBriefSectionKind, _ title: String) {
    guard brief != nil else { return }
    brief!.userState.dismissedItemKeys.insert(Self.itemKey(kind, title))
    persistBrief()
    recordFeedback(kind, title, .dismissed)
  }

  func addTask(_ title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard brief != nil, !trimmed.isEmpty else { return }
    brief!.userState.addedTasks.append(DailyBriefAddedTask(title: trimmed))
    persistBrief()
  }

  func removeAddedTask(_ task: DailyBriefAddedTask) {
    guard brief != nil else { return }
    brief!.userState.addedTasks.removeAll { $0.id == task.id }
    persistBrief()
  }

  func recordFeedback(
    _ kind: DailyBriefSectionKind, _ title: String, _ action: DailyBriefFeedbackAction
  ) {
    let event = DailyBriefFeedbackEvent(
      day: brief?.day ?? Self.todayDayString(), section: kind.rawValue, itemTitle: title,
      action: action)
    feedbackEvents.append(event)
    // Keep about two months; the prompt only reads the recent part.
    if feedbackEvents.count > 2000 {
      feedbackEvents.removeFirst(feedbackEvents.count - 2000)
    }
    Self.write(feedbackEvents, to: Self.feedbackURL)
    AnalyticsService.shared.capture(
      "daily_brief_item_action", ["section": kind.rawValue, "action": action.rawValue])
  }

  // MARK: - Docket hand-off

  /// What a docket task shows in the list's Status column.
  enum DocketStatus: Equatable {
    case new
    case dismissed
    case inProgress(agent: DailyBriefAgent)
    case ready(agent: DailyBriefAgent)
    case reviewed(agent: DailyBriefAgent)
    case failed(agent: DailyBriefAgent)
  }

  private static let docketAgentKey = "dailyBriefDocketAgent"
  private static let docketMethodKey = "dailyBriefDocketHandoffMethod"
  private static let docketViewKey = "dailyBriefDocketShowsList"
  private static let pickedFoldersKey = "dailyBriefDocketPickedFolders"

  /// The agent Hand off sends to (the gear menu's Providers).
  var docketAgent: DailyBriefAgent {
    get {
      DailyBriefAgent(rawValue: UserDefaults.standard.string(forKey: Self.docketAgentKey) ?? "")
        ?? .claude
    }
    set {
      objectWillChange.send()
      UserDefaults.standard.set(newValue.rawValue, forKey: Self.docketAgentKey)
    }
  }

  /// How Hand off sends the prompt (the gear menu's Hand-off method).
  var docketHandoffMethod: DailyBriefHandoff.Method {
    get {
      DailyBriefHandoff.Method(
        rawValue: UserDefaults.standard.string(forKey: Self.docketMethodKey) ?? "") ?? .paste
    }
    set {
      objectWillChange.send()
      UserDefaults.standard.set(newValue.rawValue, forKey: Self.docketMethodKey)
    }
  }

  /// The docket shows as a list instead of the card stack.
  var docketShowsList: Bool {
    get { UserDefaults.standard.bool(forKey: Self.docketViewKey) }
    set {
      objectWillChange.send()
      UserDefaults.standard.set(newValue, forKey: Self.docketViewKey)
    }
  }

  /// Today's docket tasks, in the model's order.
  var docketItems: [DailyBriefDocketItem] {
    brief?.content.docket ?? []
  }

  /// The latest hand-off or dismissal for a task, if any.
  func handoff(for title: String) -> DailyBriefHandoff? {
    brief?.userState.handoffs.last { $0.title == title }
  }

  /// True once a task has been handed off or dismissed, so it leaves the card stack.
  func isDocketDone(_ title: String) -> Bool {
    handoff(for: title) != nil
  }

  func docketStatus(for title: String) -> DocketStatus {
    guard let entry = handoff(for: title) else { return .new }
    if entry.dismissed { return .dismissed }
    let agent = DailyBriefAgent(rawValue: entry.agent ?? "") ?? .claude
    if entry.reviewed { return .reviewed(agent: agent) }
    if entry.failed { return .failed(agent: agent) }
    if entry.method == .run && entry.finishedAt != nil { return .ready(agent: agent) }
    return .inProgress(agent: agent)
  }

  /// The prompt as the user last left it.
  func docketPrompt(for item: DailyBriefDocketItem) -> String {
    brief?.userState.promptEdits[item.title] ?? item.prompt ?? ""
  }

  func setDocketPrompt(_ text: String, for item: DailyBriefDocketItem) {
    guard brief != nil else { return }
    brief!.userState.promptEdits[item.title] = text == item.prompt ? nil : text
    persistBrief()
  }

  /// The folder the task's agent works in; nil means "No folder". New tasks start with no
  /// folder, so a run never edits a project the user didn't pick for it.
  func docketFolder(for title: String) -> String? {
    guard let picked = brief?.userState.folders[title], !picked.isEmpty else { return nil }
    return picked
  }

  func setDocketFolder(_ path: String?, for title: String) {
    guard brief != nil else { return }
    brief!.userState.folders[title] = path ?? ""
    if let path { rememberPickedFolder(path) }
    persistBrief()
  }

  /// Folders for the folder menu: ones picked with "Open folder…" first, then the
  /// projects Claude Code was used in most recently. At most five.
  var recentFolders: [String] {
    let picked = UserDefaults.standard.stringArray(forKey: Self.pickedFoldersKey) ?? []
    var result: [String] = []
    for path in picked + cachedClaudeProjects where !result.contains(path) {
      if FileManager.default.fileExists(atPath: path) { result.append(path) }
      if result.count == 5 { break }
    }
    return result
  }

  private lazy var cachedClaudeProjects: [String] = Self.recentClaudeProjects()

  private func rememberPickedFolder(_ path: String) {
    var picked = UserDefaults.standard.stringArray(forKey: Self.pickedFoldersKey) ?? []
    picked.removeAll { $0 == path }
    picked.insert(path, at: 0)
    UserDefaults.standard.set(Array(picked.prefix(5)), forKey: Self.pickedFoldersKey)
  }

  /// Project folders from ~/.claude.json, newest first by when their session folder in
  /// ~/.claude/projects last changed (that folder's name is the path with / and . as -).
  private nonisolated static func recentClaudeProjects() -> [String] {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let projects = json["projects"] as? [String: Any]
    else { return [] }

    let sessions = home.appendingPathComponent(".claude/projects")
    let dated: [(path: String, date: Date)] = projects.keys.compactMap { path in
      guard path != NSHomeDirectory(), path != "/" else { return nil }
      let encoded = path.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ".", with: "-")
      let folder = sessions.appendingPathComponent(encoded)
      guard
        let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
      else { return nil }
      return (path, date)
    }
    return dated.sorted { $0.date > $1.date }.map(\.path)
  }

  /// Hands a task to the chosen agent: pastes it into the agent's app, or runs it in
  /// the background in the task's folder.
  /// `card` is the front card as it left the deck, for transitions that carry it.
  func handOffDocket(_ item: DailyBriefDocketItem, card: DocketLiftedCard? = nil) {
    guard brief != nil else { return }
    // A task that continues an earlier thread goes to that thread's app, whichever agent
    // the gear menu has picked. A new thread goes to the app the brief picked for it, when
    // that app is installed, and otherwise to the gear menu's agent.
    let thread = item.thread.flatMap { id in DailyBriefAgent(threadID: id).map { (id, $0) } }
    let pickedApp = item.newThreadApp.flatMap(DailyBriefAgent.init(appName:))
      .flatMap { $0.isInstalled ? $0 : nil }
    let agent = thread?.1 ?? pickedApp ?? docketAgent
    let method = docketHandoffMethod
    let prompt = docketPrompt(for: item)
    let folder = docketFolder(for: item.title)
    var entry = DailyBriefHandoff(
      title: item.title, dismissed: false, agent: agent.rawValue, method: method)

    switch method {
    case .paste:
      let link = agent.threadLink(thread: thread?.0, folder: folder)
      DocketHandoffDirector.paste(prompt: prompt, agent: agent, link: link, card: card)
    case .run:
      let file = "handoffs/\(Self.fileSafe(item.title))-\(Int(Date().timeIntervalSince1970)).txt"
      entry.outputFile = file
      let day = brief!.day
      let title = item.title
      DailyBriefHandoffRunner.run(
        prompt: prompt, agent: agent, folder: folder,
        outputURL: Self.briefImageURL(day: day, file: file)
      ) { exitCode in
        DailyBriefStore.shared.finishDocketRun(day: day, title: title, exitCode: exitCode)
      }
    }

    brief!.userState.handoffs.append(entry)
    persistBrief()
    recordFeedback(.docket, item.title, .opened)
    AnalyticsService.shared.capture(
      "daily_brief_docket_handoff",
      [
        "agent": agent.rawValue, "method": method.rawValue, "has_folder": folder != nil,
        "continues_thread": thread != nil, "brief_picked_app": thread == nil && pickedApp != nil,
      ])
  }

  private func finishDocketRun(day: String, title: String, exitCode: Int32) {
    guard brief?.day == day,
      let index = brief!.userState.handoffs.lastIndex(where: { $0.title == title })
    else { return }
    brief!.userState.handoffs[index].finishedAt = Date()
    brief!.userState.handoffs[index].failed = exitCode != 0
    persistBrief()
    AnalyticsService.shared.capture(
      "daily_brief_docket_run_finished", ["succeeded": exitCode == 0])
  }

  /// Runs that ended while Dayflow wasn't watching (it quit, or the run outlived it) leave
  /// an exit code next to their output, so pick those up.
  func refreshDocketRuns() {
    guard let day = brief?.day else { return }
    for (index, entry) in brief!.userState.handoffs.enumerated()
    where entry.method == .run && entry.finishedAt == nil {
      guard let file = entry.outputFile,
        !DailyBriefHandoffRunner.isRunning(outputURL: Self.briefImageURL(day: day, file: file))
      else { continue }
      let exitURL = Self.briefImageURL(day: day, file: file + ".exit")
      if let text = try? String(contentsOf: exitURL, encoding: .utf8) {
        let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        brief!.userState.handoffs[index].finishedAt = Date()
        brief!.userState.handoffs[index].failed = code != 0
      } else if Date().timeIntervalSince(entry.at) > 3 * 60 * 60 {
        brief!.userState.handoffs[index].finishedAt = Date()
        brief!.userState.handoffs[index].failed = true
      }
    }
    persistBrief()
  }

  /// Opens what the agent did: a run's output, or the agent's app for a pasted prompt.
  func openDocketResult(_ title: String) {
    guard let entry = handoff(for: title), !entry.dismissed, let day = brief?.day else { return }
    if let file = entry.outputFile {
      NSWorkspace.shared.open(Self.briefImageURL(day: day, file: file))
    } else {
      DailyBriefHandoffRunner.openApp(DailyBriefAgent(rawValue: entry.agent ?? "") ?? .claude)
    }
    // A finished run, or a pasted prompt (which never reports back), counts as reviewed
    // once the user opens it. A run still going stays In progress.
    let isFinishedRun = entry.method == .run && entry.finishedAt != nil
    guard isFinishedRun || entry.method == .paste,
      let index = brief!.userState.handoffs.lastIndex(where: { $0.title == title })
    else { return }
    brief!.userState.handoffs[index].reviewed = true
    persistBrief()
  }

  func dismissDocket(_ title: String) {
    guard brief != nil else { return }
    brief!.userState.handoffs.append(DailyBriefHandoff(title: title, dismissed: true))
    persistBrief()
    recordFeedback(.docket, title, .dismissed)
  }

  /// Debug: puts every docket task back in the stack as new, forgetting hand-offs,
  /// dismissals, prompt edits and folders. Runs already started keep going.
  func resetDocket() {
    guard brief != nil else { return }
    brief!.userState.handoffs = []
    brief!.userState.promptEdits = [:]
    brief!.userState.folders = [:]
    persistBrief()
  }

  /// Undo: forgets the task's last dismissal so it's back in the stack.
  func undoDocketDismiss(_ title: String) {
    guard brief != nil,
      let index = brief!.userState.handoffs.lastIndex(where: { $0.title == title && $0.dismissed })
    else { return }
    brief!.userState.handoffs.remove(at: index)
    persistBrief()
    AnalyticsService.shared.capture("daily_brief_docket_dismiss_undone")
  }

  func setDocketDismissReason(_ reason: String, for title: String) {
    guard brief != nil,
      let index = brief!.userState.handoffs.lastIndex(where: { $0.title == title && $0.dismissed })
    else { return }
    brief!.userState.handoffs[index].reason = reason
    persistBrief()
    AnalyticsService.shared.capture("daily_brief_docket_dismiss_reason", ["reason": reason])
  }

  /// "Prototype card-swipe…" → "prototype-card-swipe", for file names.
  private static func fileSafe(_ text: String) -> String {
    let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
    return words.filter { !$0.isEmpty }.prefix(6).joined(separator: "-")
  }

  // MARK: - Saved images

  func isSaved(_ image: DailyBriefImage) -> Bool {
    savedItems.contains { $0.imageFile == image.savedFileName }
  }

  func save(_ image: DailyBriefImage) {
    guard !isSaved(image) else { return }
    let destination = Self.savedDirectory().appendingPathComponent(image.savedFileName)
    do {
      try FileManager.default.createDirectory(
        at: Self.savedDirectory(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.copyItem(at: image.url, to: destination)
      }
    } catch {
      print("[DailyBrief] Failed to save image: \(error)")
      return
    }
    savedItems.insert(
      DailyBriefSavedItem(
        imageFile: image.savedFileName, caption: image.caption, sourceDay: image.day),
      at: 0)
    Self.write(savedItems, to: Self.savedIndexURL)
    recordFeedback(image.section, image.caption ?? image.file, .saved)
  }

  func unsave(_ item: DailyBriefSavedItem) {
    savedItems.removeAll { $0.id == item.id }
    Self.write(savedItems, to: Self.savedIndexURL)
    try? FileManager.default.removeItem(at: Self.savedImageURL(item))
  }

  // MARK: - Everything you completed

  /// Completed items from every stored brief, newest day first. `day` is the
  /// day the work happened (the brief's source day).
  func completedEntries(since startDay: String? = nil) -> [DailyBriefCompletedEntry] {
    Self.loadAllBriefs().flatMap { brief -> [DailyBriefCompletedEntry] in
      if let startDay, brief.sourceDay < startDay { return [] }
      return (brief.content.completedYesterday ?? []).map {
        DailyBriefCompletedEntry(day: brief.sourceDay, briefDay: brief.day, item: $0)
      }
    }
  }

  func summarize(_ range: DailyBriefSummaryRange) {
    if case .running = summaryState { return }
    let startDay = DateFormatter.yyyyMMdd.string(from: range.startDate())
    let endDay = Self.todayDayString()
    let entries = completedEntries(since: startDay)
    summaryState = .running(range)
    AnalyticsService.shared.capture("daily_brief_summary_started", ["range": range.rawValue])

    Task.detached(priority: .userInitiated) {
      let result = Result {
        try DailyBriefRangeSummarizer.summarize(
          range: range, entries: entries, startDay: startDay, endDay: endDay)
      }
      await MainActor.run {
        DailyBriefStore.shared.finishSummary(range: range, result: result)
      }
    }
  }

  private func finishSummary(
    range: DailyBriefSummaryRange, result: Result<DailyBriefRangeSummary, Error>
  ) {
    switch result {
    case .success(let summary):
      summaries[range] = summary
      Self.write(
        summary, to: Self.summariesDirectory().appendingPathComponent("\(range.rawValue).json"))
      summaryState = .idle
      route = .rangeSummary(range)
      AnalyticsService.shared.capture("daily_brief_summary_succeeded", ["range": range.rawValue])
    case .failure(let error):
      let message =
        (error as? DailyBriefGenerator.GenerationError)?.message ?? error.localizedDescription
      summaryState = .failed(message)
      AnalyticsService.shared.capture("daily_brief_summary_failed", ["range": range.rawValue])
    }
  }
}

/// An image shown somewhere in a brief, enough to enlarge it or save it.
struct DailyBriefImage: Equatable, Hashable, Sendable {
  /// Brief day the image belongs to.
  let day: String
  let section: DailyBriefSectionKind
  /// Path relative to the brief folder, e.g. "images/1234_1342.jpg".
  let file: String
  let caption: String?

  var url: URL { DailyBriefStore.briefImageURL(day: day, file: file) }

  /// Unique name for the copy in the saved folder.
  var savedFileName: String {
    "\(day)_" + file.replacingOccurrences(of: "/", with: "_")
  }
}
