//
//  FlowDistractionAgent.swift
//  Dayflow
//
//  Real distraction detection for Flow sessions. Each session gets one
//  conversation with the model: an initial briefing with the user's
//  goals, session length, and alert style, then a screenshot every ~15 seconds
//  with the current time and time remaining. The model replies with a strict
//  one-object JSON verdict; nudges drive the desktop overlay and
//  on-task/off-task flips drive the session's distraction log (via
//  FlowSessionMirror → web UI → backend).
//
//  Which model does the watching follows the provider the user picked for
//  Dayflow itself (see `Engine`): their own `codex` CLI (streaming for the
//  first turn to capture the thread id, then `codex exec resume <id> --image
//  <shot>` per tick), their own `claude` CLI (a resumable session that Reads
//  each screenshot), or Dayflow Pro (a stateless backend call per tick that
//  carries the briefing and the recent turns). Other providers aren't
//  supported yet and the agent says so instead of starting.
//

import AppKit
import Combine
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class FlowDistractionAgent: ObservableObject {
  static let shared = FlowDistractionAgent()

  /// One line of the debug transcript: what the model said on a turn.
  struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
  }

  /// Model replies (and turn failures) for the DEBUG log panel in FlowView.
  @Published private(set) var transcript: [TranscriptEntry] = []
  /// One-line state for the debug panel ("Watching · tick 12s ago").
  @Published private(set) var statusLine = "Not running"
  @Published private(set) var lastTickAt: Date?
  @Published private(set) var lastTickSeconds: Double?

  /// The model's per-turn reply. Anything unparseable is treated as
  /// on-task/no-action so a flaky turn can never fire a bogus nudge.
  private struct Verdict: Decodable {
    /// Models sometimes answer with the timeline's word for it.
    var isOffTask: Bool { status == "off_task" || status == "distracted" }
    let status: String?
    let seeing: String?
    let action: String?
    let message: String?
    let reason: String?
    /// Short goal ids ("g2") the model saw finished on screen this turn.
    let completed_goals: [String]?
  }

  /// The optional second object in a reply: the model's revised timeline.
  private struct TimelineReply: Decodable {
    let timeline: [FlowSessionTimeline.ModelItem]?
  }

  /// What runs the conversation, picked from the user's primary provider
  /// when a session starts.
  private enum Engine: Equatable {
    case codex
    case claude
    case dayflow

    static func current() -> Engine? {
      switch (try? LLMProviderRoutingStore.load())?.primary {
      case .chatGPT: return .codex
      case .claude: return .claude
      case .dayflow: return .dayflow
      default: return nil
      }
    }

    /// Codex and Claude keep the session timeline as a file they edit in
    /// place; Dayflow Pro has no file system, so it answers inline.
    var editsTimelineFile: Bool { self != .dayflow }

    var label: String {
      switch self {
      case .codex: return "Codex"
      case .claude: return "Claude"
      case .dayflow: return "Dayflow Pro"
      }
    }
  }

  /// Claude's own model alias: small and fast, since a turn runs every tick.
  private static let claudeModel = "haiku"
  /// Past turns (text only, never the screenshots) resent to the backend on
  /// each Dayflow Pro tick so the model can see a pattern across checks.
  private static let dayflowHistoryTurns = 12

  private struct BackendTurn: Codable, Sendable {
    let role: String
    let content: String
  }

  private struct BackendCheckRequest: Encodable {
    let briefing: String
    let history: [BackendTurn]
    let message: String
    let image_base64: String?
    let want_timeline: Bool
  }

  private struct BackendCheckResponse: Decodable {
    let text: String
  }

  private let runner = ChatCLIProcessRunner()

  private var engine: Engine = .codex
  /// Codex thread id, Claude session id, or a local id for Dayflow Pro
  /// (which keeps no conversation on the server). Nil until briefed.
  private var conversationId: String?
  /// Dayflow Pro only: the briefing and recent turns resent on each tick.
  private var backendBriefing = ""
  private var backendHistory: [BackendTurn] = []
  private var tickTimer: Timer?
  private var tickInFlight = false
  private var paused = false
  private var lastNudgeAt: Date?
  private var offTaskSince: Date?
  private var backOnTaskSince: Date?
  private var unansweredNudges = 0
  private var focusedSince: Date?
  /// Bumped on every start/stop so results from a superseded session's
  /// in-flight process are ignored when they land.
  private var generation = 0
  private var consecutiveFailures = 0
  /// The display from the last good screenshot, reused so each tick costs one
  /// ScreenCaptureKit request instead of two. Dropped when a capture fails.
  private var cachedCaptureDisplay: SCDisplay?
  /// Screenshot failures back off instead of counting toward `maxFailures`:
  /// retrying ScreenCaptureKit right away is what makes macOS show a spurious
  /// Screen Recording prompt (issue #381).
  private var captureFailureCount = 0
  private var captureBackoffUntil: Date?
  private static let captureBackoffDelays: [TimeInterval] = [30, 60, 120, 300]
  /// One-shot context lines (snooze, back-to-work, break) folded into the
  /// next tick's message.
  private var pendingNotes: [String] = []
  private var lastReportedOffTask = false

  private var goals: [String] = []
  /// Open tasks with ids; the briefing labels them g1, g2… and the model
  /// reports those short ids back in `completed_goals`.
  private var goalTasks: [FlowGoalTask] = []
  private var reportedGoalIds: Set<String> = []
  private var alertStyle: FlowAlertStyle = .friendly
  private var sessionStartedAt = Date()
  private var sessionEndsAt: Date?
  private var workDirectory: URL?
  /// The snapshot the current conversation was briefed with, so a lost Codex
  /// thread (or a settings change) can re-brief without the mirror's help.
  private var lastSnapshot: FlowNativeSnapshot?
  /// Number of re-briefs this session, so a broken Codex install can't loop.
  private var rebriefs = 0
  private var timeline: FlowSessionTimeline { FlowSessionTimeline.shared }
  /// Debug panel: make the next tick ask for a timeline update.
  private var forceTimelineUpdate = false

  /// Model, reasoning, cadence, prompt… all live in FlowAgentSettings so the
  /// debug panel can change them while a session runs.
  private var settings: FlowAgentSettings { FlowAgentSettings.shared }
  private var cancellables: Set<AnyCancellable> = []

  /// Some models reject reasoning summaries (a user's global config.toml may
  /// set model_reasoning_summary = "detailed"), and the agent never wants
  /// them anyway — ticks should produce nothing but the JSON verdict.
  /// workspace-write lets the model edit the session timeline file that
  /// native drops into its working directory (nothing else is in there).
  private static let codexConfigOverrides = [
    "model_reasoning_summary=none", "sandbox_mode=workspace-write",
  ]

  /// The model-facing timeline file, inside the Codex working directory.
  private var timelineFileURL: URL? {
    workDirectory?.appendingPathComponent("timeline.json")
  }

  private init() {
    // A new cadence applies to the running session immediately.
    FlowAgentSettings.shared.$tickSeconds
      .dropFirst()
      .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self, self.conversationId != nil else { return }
        self.scheduleTimer()
      }
      .store(in: &cancellables)
  }

  var isRunning: Bool { generationIsLive && conversationId != nil }
  private var generationIsLive: Bool { tickTimer != nil || tickInFlight }

  // MARK: - Lifecycle (driven by FlowSessionMirror phase transitions)

  func start(with snapshot: FlowNativeSnapshot) {
    start(with: snapshot, rebrief: false)
  }

  /// `rebrief` keeps the transcript and counts toward the re-brief cap; used
  /// when the Codex thread is lost mid-session or the debug panel restarts
  /// the agent with new settings.
  private func start(with snapshot: FlowNativeSnapshot, rebrief: Bool) {
    stop()
    lastSnapshot = snapshot
    sessionStartedAt =
      snapshot.sessionStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
    // Before anything can bail out: a session the agent never watches must
    // still drop the previous session's log, or its summary would show it.
    // The same session on a re-brief or relaunch keeps what's been logged.
    timeline.begin(sessionStartedAt: sessionStartedAt)
    guard settings.agentEnabled else {
      statusLine = "Disabled"
      return
    }
    if !rebrief {
      rebriefs = 0
      transcript = []
    }

    goals = snapshot.goals ?? []
    goalTasks =
      snapshot.goalTasks
      ?? goals.enumerated().map { FlowGoalTask(id: "goal-\($0.offset)", title: $0.element) }
    if !rebrief {
      reportedGoalIds = []
      lastNudgeAt = nil
      offTaskSince = nil
      backOnTaskSince = nil
      focusedSince = nil
      unansweredNudges = 0
    }
    alertStyle = snapshot.alertStyle
    sessionEndsAt = snapshot.sessionEndsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    lastReportedOffTask = false
    pendingNotes = []
    consecutiveFailures = 0
    paused = false

    guard let engine = Engine.current() else {
      print("[FlowAgent] Not starting: the primary provider can't run the Flow agent")
      appendTranscript(
        "Flow's screen watching needs ChatGPT (Codex), Claude or Dayflow Pro as your provider.")
      statusLine = "Needs Codex, Claude or Dayflow Pro"
      AnalyticsService.shared.capture("flow_agent_unsupported_provider")
      return
    }
    self.engine = engine

    let directory = FileManager.default.temporaryDirectory
      .resolvingSymlinksInPath()
      .appendingPathComponent("DayflowFlowAgent-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    workDirectory = directory

    generation += 1
    let gen = generation
    let prompt = initialPrompt()
    let runner = self.runner

    print("[FlowAgent] Starting \(engine.label) conversation (style: \(alertStyle.rawValue))")
    let modelName = modelLabel
    statusLine = rebrief ? "Re-briefing \(modelName)…" : "Briefing \(modelName)…"

    // Dayflow Pro keeps nothing on the server, so there's no briefing turn:
    // the briefing rides along with every tick instead.
    if engine == .dayflow {
      guard Self.dayflowCredentials() != nil else {
        appendTranscript("Couldn't start the agent: not signed in to Dayflow Pro.")
        statusLine = "Sign in to Dayflow Pro"
        AnalyticsService.shared.capture("flow_agent_start_failed", ["engine": "dayflow"])
        cleanupWorkDirectory()
        return
      }
      backendBriefing = prompt
      backendHistory = []
      finishStart(generation: gen, sessionId: UUID().uuidString, reply: "", error: nil)
      return
    }

    tickInFlight = true
    let model = settings.model
    let effort = settings.reasoningEffort
    Task.detached(priority: .utility) {
      var sessionId: String?
      var replyText = ""
      var errorText: String?
      if engine == .claude {
        // The id is ours, so the first turn doesn't need to stream to learn it.
        let id = UUID().uuidString.lowercased()
        do {
          let result = try runner.run(
            tool: .claude,
            prompt: prompt,
            workingDirectory: directory,
            model: Self.claudeModel,
            claudeProfile: ClaudeCLIExecutionProfile.flowAgent.allowingFlowWorkspace(
              at: directory.path),
            claudeSessionMode: .start(id: id)
          )
          if result.exitCode == 0 {
            sessionId = id
            replyText = result.stdout
          } else {
            errorText = result.failureMessage(toolName: "Claude CLI")
            ClaudeSessionCleanup(sessionID: id).cleanup()
          }
        } catch {
          errorText = error.localizedDescription
        }
        await MainActor.run {
          FlowDistractionAgent.shared.finishStart(
            generation: gen, sessionId: sessionId, reply: replyText, error: errorText)
        }
        return
      }
      do {
        let stream = runner.runStreaming(
          tool: .codex,
          prompt: prompt,
          workingDirectory: directory,
          model: model,
          reasoningEffort: effort,
          codexConfigOverrides: Self.codexConfigOverrides
        )
        for try await event in stream {
          switch event {
          case .sessionStarted(let id): sessionId = id
          case .textDelta(let text): replyText += text
          case .complete(let text): replyText = text
          case .error(let message): errorText = message
          default: break
          }
        }
      } catch {
        errorText = error.localizedDescription
      }

      await MainActor.run {
        FlowDistractionAgent.shared.finishStart(
          generation: gen, sessionId: sessionId, reply: replyText, error: errorText)
      }
    }
  }

  private func finishStart(generation gen: Int, sessionId: String?, reply: String, error: String?) {
    guard gen == generation else { return }
    tickInFlight = false

    guard let sessionId else {
      print(
        "[FlowAgent] Could not start \(engine.label) session: \(error ?? "no thread id in output")")
      appendTranscript("Couldn't start the agent: \(error ?? "no thread id in output")")
      statusLine = "Failed to start"
      AnalyticsService.shared.capture("flow_agent_start_failed", ["engine": engineKey])
      cleanupWorkDirectory()
      return
    }
    statusLine = "Watching (\(modelLabel))"

    print(
      "[FlowAgent] \(engine.label) session started: \(sessionId), first reply: \(reply.prefix(200))"
    )
    appendTranscript(reply)
    AnalyticsService.shared.capture("flow_agent_started", ["engine": engineKey])
    conversationId = sessionId
    scheduleTimer()
  }

  func pause() {
    guard generationIsLive || conversationId != nil else { return }
    paused = true
    timeline.beginBreak()
    noteUserEvent("The user is taking a break; screenshots were paused while it lasted.")
  }

  func resume() {
    guard conversationId != nil else { return }
    paused = false
    timeline.endBreak()
    noteUserEvent("The user just came back from their break.")
  }

  func stop() {
    generation += 1
    tickTimer?.invalidate()
    tickTimer = nil
    tickInFlight = false
    // Claude keeps the conversation (screenshots included) in its own session
    // file; nothing of a Flow session should outlive it.
    if engine == .claude, let id = conversationId {
      Task.detached(priority: .utility) { ClaudeSessionCleanup(sessionID: id).cleanup() }
    }
    conversationId = nil
    backendBriefing = ""
    backendHistory = []
    paused = false
    pendingNotes = []
    lastReportedOffTask = false
    cachedCaptureDisplay = nil
    captureFailureCount = 0
    captureBackoffUntil = nil
    cleanupWorkDirectory()
    statusLine = "Not running"
  }

  // MARK: - Debug panel controls

  /// Starts a fresh Codex conversation for the current session with whatever
  /// the settings say now (model, prompt, cadence…).
  func restart() {
    let mirror = FlowSessionMirror.shared
    guard mirror.snapshot.phase == .active || mirror.snapshot.phase == .onBreak else {
      appendTranscript("No active session to watch.")
      return
    }
    appendTranscript("Restarting the agent with the current settings.")
    start(with: mirror.snapshot, rebrief: true)
    if mirror.snapshot.phase == .onBreak { paused = true }
  }

  /// Take a screenshot and ask the model right now, off the timer.
  func tickNow() {
    guard conversationId != nil else {
      appendTranscript("Agent isn't running.")
      return
    }
    let wasPaused = paused
    paused = false
    tick()
    paused = wasPaused
  }

  func clearTranscript() {
    transcript = []
  }

  /// Debug panel: tick right now and ask for the timeline in the same turn.
  func requestTimelineNow() {
    forceTimelineUpdate = true
    tickNow()
  }

  /// The briefing exactly as it would be sent now (for the debug panel).
  var currentBriefing: String { initialPrompt() }

  /// The open task list changed mid-session (voice additions, manual
  /// check-offs): tell the model on its next tick, with fresh short ids.
  func goalsChanged(to snapshot: FlowNativeSnapshot) {
    guard conversationId != nil else { return }
    let next = snapshot.goalTasks ?? []
    guard next != goalTasks else { return }
    let finished = goalTasks.filter { old in !next.contains(where: { $0.id == old.id }) }
    let added = next.filter { new in !goalTasks.contains(where: { $0.id == new.id }) }
    goalTasks = next
    goals = next.map(\.title)
    lastSnapshot = snapshot
    var note = "GOALS UPDATED. Open goals are now:\n" + goalsList()
    if !finished.isEmpty {
      note += "\nNo longer open (done or removed): " + finished.map(\.title).joined(separator: "; ")
    }
    if !added.isEmpty {
      note += "\nNewly added: " + added.map(\.title).joined(separator: "; ")
    }
    pendingNotes.append(note)
  }

  /// "- [g1] title" lines; the short id is the position in the current list.
  private func goalsList() -> String {
    goalTasks.enumerated().map { "- [g\($0.offset + 1)] \($0.element.title)" }
      .joined(separator: "\n")
  }

  /// Queue a line of context (snooze, back-to-work…) for the next tick.
  /// `markRefocused` also resets the off-task flag so a later distraction
  /// opens a fresh interval in the session log.
  func noteUserEvent(_ note: String, markRefocused: Bool = false) {
    guard conversationId != nil else { return }
    pendingNotes.append(note)
    if markRefocused { lastReportedOffTask = false }
  }

  // MARK: - Ticks

  private func scheduleTimer() {
    tickTimer?.invalidate()
    tickTimer = Timer.scheduledTimer(
      withTimeInterval: max(5, settings.tickSeconds), repeats: true
    ) { _ in
      MainActor.assumeIsolated {
        FlowDistractionAgent.shared.tick()
      }
    }
  }

  private func tick() {
    guard let sessionId = conversationId, let directory = workDirectory else { return }
    guard !paused, !tickInFlight else { return }
    // Nothing to see on a locked or sleeping screen, and ScreenCaptureKit
    // requests right then are the ones that trigger the spurious prompt.
    guard !ScreenCaptureMonitor.shared.isCaptureBlocked else { return }
    if let until = captureBackoffUntil, Date() < until { return }
    // Without the grant every capture attempt would show the real system prompt.
    guard CGPreflightScreenCaptureAccess() else {
      statusLine = "No Screen Recording permission"
      return
    }

    tickInFlight = true
    let gen = generation
    let askTimeline =
      forceTimelineUpdate || timeline.wantsUpdate(every: settings.timelineEverySeconds)
    forceTimelineUpdate = false
    if askTimeline, engine.editsTimelineFile, let file = timelineFileURL {
      // The model reads and edits this file during the turn.
      try? timeline.promptTimelineJSON().write(to: file, atomically: true, encoding: .utf8)
    }
    let message = tickMessage(askTimeline: askTimeline)
    pendingNotes = []
    let runner = self.runner
    let shotURL = directory.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).jpg")
    let model = settings.model
    let effort = settings.reasoningEffort
    let shotHeight = settings.screenshotHeight
    let quality = settings.jpegQuality
    let timeout = settings.tickTimeoutSeconds
    let startedAt = Date()
    // Which app is in front goes on the timeline entry (icon + merge key).
    let front = FlowSessionTimeline.frontmostApp()
    let display = cachedCaptureDisplay
    let engine = self.engine
    let briefing = backendBriefing
    let history = backendHistory

    Task.detached(priority: .utility) {
      var replyText: String?
      var errorText: String?
      var capturedDisplay: SCDisplay?
      var sentPrompt = ""
      do {
        capturedDisplay = try await Self.captureScreenshotJPEG(
          to: shotURL, height: shotHeight, quality: quality, display: display)
        let prompt = message + "\n" + Self.replyReminder
        let imagePaths = [shotURL.path]
        sentPrompt = prompt
        switch engine {
        case .codex:
          let result = try runner.run(
            tool: .codex,
            prompt: prompt,
            workingDirectory: directory,
            imagePaths: imagePaths,
            model: model,
            reasoningEffort: effort,
            codexResumeSessionId: sessionId,
            codexConfigOverrides: Self.codexConfigOverrides,
            timeoutSeconds: timeout
          )
          if result.exitCode == 0 {
            replyText = result.stdout
          } else {
            errorText = result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr
          }
        case .claude:
          // Claude gets the screenshot as a path and Reads it; its tools
          // only reach this session's working directory.
          let result = try runner.run(
            tool: .claude,
            prompt: prompt,
            workingDirectory: directory,
            imagePaths: imagePaths,
            model: Self.claudeModel,
            claudeProfile: ClaudeCLIExecutionProfile.flowAgent.allowingFlowWorkspace(
              at: directory.path),
            claudeSessionMode: .resume(id: sessionId),
            timeoutSeconds: timeout
          )
          if result.exitCode == 0 {
            replyText = result.stdout
          } else {
            errorText = result.failureMessage(toolName: "Claude CLI")
          }
        case .dayflow:
          let image = try Data(contentsOf: shotURL).base64EncodedString()
          replyText = try await Self.backendCheck(
            BackendCheckRequest(
              briefing: briefing, history: history, message: prompt, image_base64: image,
              want_timeline: askTimeline),
            timeout: timeout)
        }
      } catch {
        errorText = error.localizedDescription
        // No display yet means the screenshot itself failed, not the model.
        let domain = (error as NSError).domain
        if capturedDisplay == nil, domain != "FlowAgent", domain != NSCocoaErrorDomain {
          ScreenCaptureMonitor.shared.recordFailure(error, source: .flow)
        }
      }
      try? FileManager.default.removeItem(at: shotURL)

      let elapsed = Date().timeIntervalSince(startedAt)
      await MainActor.run {
        FlowDistractionAgent.shared.finishTick(
          generation: gen, prompt: sentPrompt, reply: replyText, error: errorText,
          seconds: elapsed, front: front, askedTimeline: askTimeline,
          captureDisplay: capturedDisplay)
      }
      // The session ended (or was re-briefed) while this turn ran, after its
      // Claude session file was already removed: the turn wrote it back.
      if engine == .claude {
        let stale = await MainActor.run { FlowDistractionAgent.shared.generation != gen }
        if stale { ClaudeSessionCleanup(sessionID: sessionId).cleanup() }
      }
    }
  }

  private func finishTick(
    generation gen: Int, prompt: String, reply: String?, error: String?, seconds: Double,
    front: FlowSessionTimeline.FrontApp, askedTimeline: Bool, captureDisplay: SCDisplay?
  ) {
    guard gen == generation else { return }
    tickInFlight = false
    lastTickAt = Date()
    lastTickSeconds = seconds

    // The screenshot itself failed: back off rather than spending the
    // failure budget, and fetch the display list again next time.
    guard let captureDisplay else {
      cachedCaptureDisplay = nil
      captureFailureCount += 1
      let delays = Self.captureBackoffDelays
      let delay = delays[min(captureFailureCount - 1, delays.count - 1)]
      captureBackoffUntil = Date().addingTimeInterval(delay)
      print("[FlowAgent] Screenshot failed (\(captureFailureCount)): \(error ?? "unknown")")
      appendTranscript("Screenshot failed: \(error ?? "unknown"). Trying again in \(Int(delay))s.")
      return
    }
    cachedCaptureDisplay = captureDisplay
    captureFailureCount = 0
    captureBackoffUntil = nil

    guard let reply else {
      consecutiveFailures += 1
      print("[FlowAgent] Tick failed (\(consecutiveFailures)): \(error ?? "unknown")")
      appendTranscript("Turn failed: \(error ?? "unknown")")
      // Codex lost the conversation (its rollout file is gone, e.g. a full
      // disk or a pruned sessions dir). Resuming will never work again, so
      // start a fresh thread instead of burning through the failure budget.
      if let error, Self.conversationWasLost(error), let snapshot = lastSnapshot, rebriefs < 3 {
        rebriefs += 1
        appendTranscript(
          "\(engine.label) conversation was lost; re-briefing on a new one (\(rebriefs)/3).")
        start(with: snapshot, rebrief: true)
        pendingNotes.append("(Re-briefed mid-session after the previous conversation was lost.)")
        return
      }
      if consecutiveFailures >= settings.maxFailures {
        print("[FlowAgent] Stopping after \(consecutiveFailures) consecutive failures")
        appendTranscript("Agent stopped after \(consecutiveFailures) consecutive failures.")
        AnalyticsService.shared.capture("flow_agent_gave_up")
        stop()
        statusLine = "Stopped after \(consecutiveFailures) failures"
      }
      return
    }
    consecutiveFailures = 0
    appendTranscript(reply)
    if engine == .dayflow {
      backendHistory.append(BackendTurn(role: "user", content: prompt))
      backendHistory.append(BackendTurn(role: "assistant", content: reply))
      let limit = Self.dayflowHistoryTurns * 2
      if backendHistory.count > limit { backendHistory.removeFirst(backendHistory.count - limit) }
    }

    let objects = Self.jsonObjects(in: reply)
    guard let first = objects.first,
      let verdict = try? JSONDecoder().decode(Verdict.self, from: Data(first.utf8))
    else {
      print("[FlowAgent] Unparseable reply, treating as on-task: \(reply.prefix(200))")
      return
    }
    // The verdict comes first and is acted on first; the timeline (when the
    // tick asked for one) rides behind it in a second object.
    handle(verdict: verdict)
    timeline.observe(
      offTask: verdict.isOffTask, front: front, reason: verdict.reason ?? verdict.seeing)
    if askedTimeline { readBackTimeline(fallback: Array(objects.dropFirst())) }
  }

  /// After a timeline turn: take the file the model edited (or, if it
  /// answered inline instead, a {"timeline": [...]} object in its reply).
  private func readBackTimeline(fallback objects: [String]) {
    if engine.editsTimelineFile, let file = timelineFileURL, let data = try? Data(contentsOf: file),
      let items = Self.decodeTimelineItems(data), !items.isEmpty
    {
      timeline.apply(modelItems: items)
      return
    }
    for object in objects {
      if let parsed = try? JSONDecoder().decode(TimelineReply.self, from: Data(object.utf8)),
        let items = parsed.timeline
      {
        timeline.apply(modelItems: items)
        return
      }
    }
    appendTranscript("Timeline update: the model didn't leave a usable timeline.")
  }

  /// The file may be a bare array or wrapped in {"timeline": [...]}.
  private static func decodeTimelineItems(_ data: Data) -> [FlowSessionTimeline.ModelItem]? {
    let decoder = JSONDecoder()
    if let items = try? decoder.decode([FlowSessionTimeline.ModelItem].self, from: data) {
      return items
    }
    return (try? decoder.decode(TimelineReply.self, from: data))?.timeline
  }

  /// When the creature may speak. Friendly waits one minute into a drift,
  /// then backs off instead of nagging: a nudge that doesn't bring them back
  /// is followed 5 minutes later, then every 10 minutes. Feisty starts after two
  /// checks and repeats every two minutes.
  private func nudgeDue(at now: Date) -> Bool {
    guard let since = offTaskSince, backOnTaskSince == nil else { return false }
    let drift = now.timeIntervalSince(since)
    let sinceLast = lastNudgeAt.map { now.timeIntervalSince($0) } ?? .infinity
    switch alertStyle {
    case .quiet:
      return false
    case .friendly:
      let waits: [TimeInterval] = [240, 300, 600]
      return drift >= 60 && sinceLast >= waits[min(unansweredNudges, waits.count - 1)]
    case .feisty:
      return drift >= Double(settings.tickSeconds) && sinceLast >= 120
    }
  }

  private func handle(verdict: Verdict) {
    let offTask = verdict.isOffTask
    // A drift starts at the first off-task check and only ends after a full
    // minute back on task, so one glance at work doesn't restart the count.
    let now = Date()
    if offTask {
      if offTaskSince == nil { offTaskSince = now }
      backOnTaskSince = nil
    } else if offTaskSince != nil {
      if let back = backOnTaskSince, now.timeIntervalSince(back) >= 60 {
        offTaskSince = nil
        backOnTaskSince = nil
        focusedSince = back
      } else if backOnTaskSince == nil {
        backOnTaskSince = now
      }
    } else if let focused = focusedSince, now.timeIntervalSince(focused) >= 180 {
      // Three minutes of real work: the last nudge landed.
      unansweredNudges = 0
    }
    if offTask != lastReportedOffTask {
      lastReportedOffTask = offTask
      FlowSessionMirror.shared.agentReportedFocusChange(isDistracted: offTask)
      if offTask {
        print("[FlowAgent] Off task: \(verdict.reason ?? "no reason given")")
      }
    }

    // Goals the model saw finished: resolve g-ids, relay once each.
    let finished = (verdict.completed_goals ?? []).compactMap { short -> FlowGoalTask? in
      let digits = short.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "g[] "))
      guard let index = Int(digits), index >= 1, index <= goalTasks.count else { return nil }
      let task = goalTasks[index - 1]
      guard !reportedGoalIds.contains(task.id) else { return nil }
      return task
    }
    if !finished.isEmpty {
      reportedGoalIds.formUnion(finished.map(\.id))
      print("[FlowAgent] Goals completed: \(finished.map(\.title))")
      FlowSessionMirror.shared.agentCompletedGoals(finished)
    }

    switch verdict.action {
    case "nudge":
      // Someone else can see this screen right now, most likely in a meeting.
      guard !FlowScreenShareDetector.isSharing() else {
        print("[FlowAgent] Nudge held back: the screen is being shared")
        break
      }
      // Dayflow times the nudges; the model only writes them.
      guard offTask, nudgeDue(at: now) else {
        print("[FlowAgent] Nudge held back: none is due")
        break
      }
      unansweredNudges += 1
      focusedSince = nil
      lastNudgeAt = now
      let message =
        verdict.message ?? String(localized: "Psst... I think you're getting distracted!")
      FlowSessionMirror.shared.agentNudge(message: message)
    default:
      break
    }
  }

  // MARK: - Prompts

  private func initialPrompt() -> String {
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    let started = timeFormatter.string(from: sessionStartedAt)

    let lengthLine: String
    if let endsAt = sessionEndsAt {
      let minutes = max(1, Int(endsAt.timeIntervalSince(sessionStartedAt) / 60))
      lengthLine =
        "Planned length: \(minutes) minutes (ends around \(timeFormatter.string(from: endsAt)))."
    } else {
      lengthLine = "Open-ended: no timer, the user works until they choose to stop."
    }

    let goalsBlock: String
    if goals.isEmpty {
      goalsBlock = """
        The user didn't list specific goals. Judge by continuity instead: sustained work in \
        one arena (coding, writing, design, research...) is on task; entertainment, social \
        feeds, and aimless browsing are off task.
        """
    } else {
      goalsBlock = goalsList()
    }

    let styleBlock: String
    switch alertStyle {
    case .quiet:
      styleBlock = """
        Quiet. The user asked for zero interruptions. NEVER use "nudge": keep action \
        "none" on every turn. Your status field still matters: distractions are \
        logged silently for their session summary.
        """
    case .friendly:
      styleBlock = """
        Friendly. They get slack: a nudge only comes due after about a minute of drift, \
        with follow-ups spaced further apart. Tone: warm and light, like a friend at the next desk. \
        The follow-up can be a little more direct. Never guilt-trippy.
        """
    case .feisty:
      styleBlock = """
        Feisty. Nudges come due quickly and keep coming while they stay off task. Tone: \
        stern and no-nonsense, a coach who won't let it slide, each one more direct than \
        the last. Blunt is fine; insulting is not.
        """
    }

    let template = settings.briefingTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    var prompt = template.isEmpty ? Self.briefingTemplate : template
    let values: [String: String] = [
      "{{started}}": started,
      "{{length}}": lengthLine,
      "{{style}}": alertStyle.rawValue,
      "{{goals}}": goalsBlock,
      "{{style_rules}}": styleBlock,
      "{{tick_seconds}}": String(Int(settings.tickSeconds)),
      "{{categories}}": Self.categoriesBlock(),
      "{{timeline_mechanics}}": (Engine.current() ?? .codex).editsTimelineFile
        ? Self.timelineByFile : Self.timelineInline,
    ]
    for (key, value) in values {
      prompt = prompt.replacingOccurrences(of: key, with: value)
    }
    let extra = settings.extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !extra.isEmpty {
      prompt += "\n\nADDITIONAL INSTRUCTIONS\n" + extra
    }
    return prompt
  }

  /// The built-in briefing. Placeholders: {{started}}, {{length}}, {{style}},
  /// {{goals}}, {{style_rules}}, {{tick_seconds}}, {{categories}}, {{timeline_mechanics}}. The debug panel can replace the whole thing.
  static let briefingTemplate = """
    You are the focus companion inside Dayflow, a Mac time-tracking app. The user just \
    started a Flow focus session and you're watching over it. Roughly every {{tick_seconds}} seconds \
    you'll get a message with a screenshot of their screen, the current time, and the time \
    left. Your job: judge whether they're on task, and decide whether their focus buddy (a \
    small pixel creature that peeks in from the screen edge) should say something.

    SESSION
    - Started at {{started}}.
    - {{length}}
    - Alert style: {{style}}.

    THE USER'S STATED FOCUS
    {{goals}}

    HOW TO JUDGE
    - Work that plausibly serves the goals is on task, including the docs, searches, \
    terminal work and Slack or email replies that go with it.
    - Other real work that isn't on their list (a different project, helping a \
    colleague) is on task too. You guard against distraction, not against a change of plan.
    - Off task means leisure: social feeds, YouTube, shopping, personal chats, news \
    rabbit holes. One glance at those is not a distraction; a pattern across \
    consecutive checks is.
    - The screenshot is your only evidence.
    - If you're unsure, assume on task.

    HOW TO REPLY
    Reply to every message with exactly one JSON object and nothing else — no prose, no \
    code fences, no explanation:
    {"seeing": "...", "status": "on_task" | "off_task", "action": "none" | "nudge", "message": "...", "reason": "..."}
    - seeing: 3 to 6 words naming the app in front and what it shows ("X home feed", \
    "Xcode, editing a Swift file"). Always first, so the verdict comes from this \
    screenshot and not from the last one.
    - status: your read of the current check.
    - action "nudge" makes the creature appear at the side of their screen with your \
    message, like a notification. Write the message yourself: one short sentence, 12 \
    words at most, because it renders in a small speech bubble. Think from the user's \
    side: what would be useful for them to see right now. Usually that is the next \
    concrete step on the one goal they were last working on, in plain words. Name one \
    goal, never two ("X or Y" is wrong), don't say how long they've been away or how much time is left, and \
    don't describe what they're looking at. Never preachy, and never the same \
    wording as a nudge you already sent this session.
    - Dayflow decides when a nudge is due and says so in the message ("NUDGE DUE"). On \
    those turns, if the screenshot is still off task, use "nudge". On every other turn \
    keep action "none".
    - message is required whenever action is "nudge". reason: a few words of evidence \
    whenever status is "off_task".
    - completed_goals: optional. Each goal above has a short id in brackets. When the \
    screen shows a goal has been FINISHED — the PR is merged, the email is in Sent, the \
    doc is published, the ticket is closed, they typed "done" — include its id, e.g. \
    "completed_goals": ["g2"], in that turn's verdict. Working on a goal is not finishing \
    it: only report on clear evidence of completion, and report each goal once. Dayflow \
    checks the task off for them, so a false positive is worse than a miss.

    ALERT STYLE
    {{style_rules}}

    THE SESSION TIMELINE
    You also keep the user's session log. Flow turns focus into a game, a bit like Guitar \
    Hero: the longer they stay focused the higher their multiplier climbs, and a \
    distraction knocks it back down. The timeline is the record of that run, shown to \
    them when the session ends, so it should answer two questions at a glance: what did \
    they get done in each stretch, and what pulled them away.
    - It is a JSON array of entries \
    {"start": "HH:mm", "end": "HH:mm", "kind": "focused" | "distracted" | "break", "category": "...", "site": "...", "title": "..."}, \
    plus an optional "completed" list on focused entries (see below).
    - category files the entry under one of the user's own Dayflow categories. Use one \
    of these names exactly as written, never a name of your own:
    {{categories}}
    Pick the one that fits most of the stretch. Every focused and distracted entry \
    gets one; a break gets none. A change of category within focused work is a \
    different kind of stretch, so once it has lasted two minutes it is its own entry.
    - site is the one website or app the stretch was mostly about, and it picks the \
    icon shown beside the entry. For anything in a browser give the site's domain, \
    lower-case with no protocol or path ("youtube.com", "github.com", "docs.google.com"), \
    never the browser's name. For a desktop app give its name ("Xcode", "Figma", \
    "Slack"). One value, the one they spent the most time in; leave it out on breaks.
    - Keep it high level. An entry is a block of time and what it was for, not a list of \
    apps or windows: a stretch of work on one thing is a single entry even if they \
    bounced between docs, terminal and editor for it.
    - Rule of thumb: at most about 10 entries an hour. Someone locked in on one thing all \
    session is 1 or 2 entries; someone bouncing around will have more. If the timeline \
    is already past that pace, merge the smallest neighbours before adding anything.
    - Never put two entries of the same kind next to each other, unless they are focused \
    work on clearly different things. A run of distraction is ONE "distracted" entry \
    however many sites it wandered through: title it by the main one or two ("YouTube \
    and X") and keep extending it until they are back at work.
    - Ignore blips. A check or two of something else in the middle of a stretch (under \
    about two minutes) doesn't split it, in either direction: a quick look at X during \
    work stays part of the work, and a quick look at work during a YouTube binge stays \
    part of the distraction. Anything that lasts two minutes or more gets its own entry.
    - Breaks always stay as their own entries.
    - When they finish one of the goals on their list during an entry, add \
    "completed": ["<that goal's title>"] to it. Their summary calls these out as wins, so \
    use the same bar as completed_goals: clear evidence it's done, not just worked on.
    - Entries must stay contiguous (each starts where the previous ended, 24h HH:mm), the \
    first at the session start, the last ending at the current time.
    - Titles are concrete, 3 to 7 words, like "Address feedback on PR", "Scrolling on X", \
    "Reviewing checkout flow mockups in Figma". Rename an earlier entry once you \
    understand what they were really doing.
    {{timeline_mechanics}}

    Don't overthink the checks: no analysis, no chain of reasoning in your reply, but do \
    look at every screenshot fresh. Acknowledge this briefing now with \
    {"status":"on_task","action":"none"}.
    """

  /// Ends every check. Small models drift off the format over a long session
  /// unless it is restated each turn.
  static let replyReminder = """
    Screenshot attached. Look at it before you answer, then reply with only this JSON \
    object: {"seeing": "<3 to 6 words: the app and what it shows>", "status": "on_task" \
    | "off_task", "action": "none" | "nudge", "message": "<12 words at most, only with \
    nudge>", "reason": "<a few words, only when off_task>"}
    """

  /// Restated on every timeline turn, for the same reason.
  static let timelineReminder = """
    Rules: extend the last entry unless they have switched to a different kind of \
    stretch for two minutes or more. Never one entry per check. No two "distracted" \
    entries in a row. Entries stay contiguous with no gaps. Every focused and \
    distracted entry carries a "category" from the briefing's list, spelled exactly, \
    and a "site": the domain or app it was mostly about.
    """

  /// The user's categories as the briefing lists them, one per line with the
  /// description they wrote for it.
  static func categoriesBlock() -> String {
    let categories = CategoryStore.shared.categories
      .filter { !$0.isIdle && !$0.isSystem }
      .sorted { $0.order < $1.order }
    guard !categories.isEmpty else { return "    (none set up: leave category out)" }
    return categories.map { category in
      let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let details = category.details.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
      return details.isEmpty ? "    · \(name)" : "    · \(name): \(String(details.prefix(160)))"
    }.joined(separator: "\n")
  }

  /// How the timeline gets updated, for engines with a working directory.
  private static let timelineByFile = """
    - It lives in a file, timeline.json, in your working directory. About once a minute \
    a message will end with "TIMELINE UPDATE" and give you the file's path plus the check \
    log since your last edit. On those turns edit the file in place: usually that means \
    moving the last entry's end time forward. Add an entry only when they have moved to \
    a different kind of stretch for two minutes or more. Leave the rest alone unless it needs merging or renaming; don't rewrite the \
    whole file. Then reply with the verdict object as usual. The file is the timeline, \
    so don't repeat it in your reply.
    """

  /// The same, for Dayflow Pro: the timeline travels in the messages.
  private static let timelineInline = """
    - About once a minute a message will end with "TIMELINE UPDATE" and include the \
    current timeline plus the check log since your last update. On those turns reply with \
    the verdict object first and then a second JSON object, {"timeline": [...]}, holding \
    the full revised array. On every other turn reply with the verdict object alone.
    """

  private func tickMessage(askTimeline: Bool) -> String {
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    let now = Date()

    var line = "Current time: \(timeFormatter.string(from: now))."
    if let endsAt = sessionEndsAt {
      let remaining = max(0, Int(endsAt.timeIntervalSince(now) / 60))
      line += " Time remaining: \(Self.formatMinutes(remaining))."
    } else {
      let elapsed = max(0, Int(now.timeIntervalSince(sessionStartedAt) / 60))
      line += " Elapsed: \(Self.formatMinutes(elapsed)) (open-ended session)."
    }

    if nudgeDue(at: now), let since = offTaskSince {
      let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
      line +=
        " NUDGE DUE: they have been off task for about \(minutes)m. If this screenshot is "
        + "still off task, set action to \"nudge\" and write the message."
    }

    var parts = [line]
    parts.append(contentsOf: pendingNotes)
    if askTimeline, !engine.editsTimelineFile {
      let since = timeline.lastModelUpdateAt
      parts.append(
        """
        TIMELINE UPDATE — revise the session timeline so it covers the whole session \
        (started \(FlowSessionTimeline.clock(sessionStartedAt))) up to now, and reply with \
        the verdict object followed by {"timeline": [...]}.
        Current timeline:
        \(timeline.promptTimelineJSON())
        \(Self.timelineReminder)
        Check log since your last edit (time · verdict · frontmost app · reason):
        \(timeline.promptObservations(since: since))
        Breaks (exact, from the app): \(timeline.promptBreaks())
        """)
    } else if askTimeline {
      let since = timeline.lastModelUpdateAt
      parts.append(
        """
        TIMELINE UPDATE — read \(timelineFileURL?.path ?? "timeline.json") and edit it in \
        place so it covers the whole session (started \
        \(FlowSessionTimeline.clock(sessionStartedAt))) up to now, then reply with the \
        verdict object.
        \(Self.timelineReminder)
        Check log since your last edit (time · verdict · frontmost app · reason):
        \(timeline.promptObservations(since: since))
        Breaks (exact, from the app): \(timeline.promptBreaks())
        """)
    }
    // The screenshot line is appended in tick(), where
    // the capture happens.
    return parts.joined(separator: "\n")
  }

  /// "gpt-… , low" for Codex; the other engines choose their own model.
  private var modelLabel: String {
    switch engine {
    case .codex: return "\(settings.model), \(settings.reasoningEffort)"
    case .claude: return "Claude \(Self.claudeModel)"
    case .dayflow: return "Dayflow Pro"
    }
  }

  private var engineKey: String {
    switch engine {
    case .codex: return "codex"
    case .claude: return "claude"
    case .dayflow: return "dayflow"
    }
  }

  /// The CLI can no longer resume this conversation (Codex's rollout file or
  /// Claude's session file is gone), so retrying the same id will never work.
  private static func conversationWasLost(_ error: String) -> Bool {
    error.contains("no rollout found") || error.contains("thread/resume")
      || error.contains("No conversation found")
  }

  // MARK: - Dayflow Pro

  private nonisolated static func dayflowCredentials() -> (endpoint: String, token: String)? {
    let token = DayflowAuthManager.storedSessionToken()?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let token, !token.isEmpty,
      let endpoint = DayflowBackendConfiguration.endpoint(
        legacySavedEndpoint: DayflowEndpointPreferences.load())
    else { return nil }
    let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return (trimmed, token)
  }

  /// One stateless check: briefing, recent turns, this tick's message and
  /// screenshot in; the model's raw reply out.
  private nonisolated static func backendCheck(
    _ payload: BackendCheckRequest, timeout: TimeInterval
  ) async throws -> String {
    guard let credentials = dayflowCredentials(),
      let url = URL(string: "\(credentials.endpoint)/v1/dayflow/flow-check")
    else {
      throw NSError(
        domain: "FlowAgent", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Not signed in to Dayflow Pro"])
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await LocalOnlyNetworking.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200...299).contains(status) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw NSError(
        domain: "FlowAgent", code: status,
        userInfo: [
          NSLocalizedDescriptionKey: "Dayflow Pro check failed (\(status)): \(body.prefix(200))"
        ])
    }
    return try JSONDecoder().decode(BackendCheckResponse.self, from: data).text
  }

  private static func formatMinutes(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
  }

  private func appendTranscript(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    transcript.append(TranscriptEntry(date: Date(), text: trimmed))
    if transcript.count > 200 {
      transcript.removeFirst(transcript.count - 200)
    }
  }

  // MARK: - Verdict parsing

  /// Every top-level {...} in the reply, in order, tolerating fences and
  /// stray prose around them. Strings are skipped so braces inside a title
  /// don't confuse the depth count.
  private static func jsonObjects(in reply: String) -> [String] {
    var objects: [String] = []
    var depth = 0
    var start: String.Index?
    var inString = false
    var escaped = false
    var index = reply.startIndex
    while index < reply.endIndex {
      let character = reply[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else if character == "\"" {
        inString = true
      } else if character == "{" {
        if depth == 0 { start = index }
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0, let begin = start {
          objects.append(String(reply[begin...index]))
          start = nil
        }
        if depth < 0 { depth = 0 }
      }
      index = reply.index(after: index)
    }
    return objects
  }

  // MARK: - Screenshot capture

  /// One-shot capture of the main display, scaled to ~720p JPEG. Independent
  /// of the timeline recorder so Flow works even when recording is paused.
  /// Reuses `cachedDisplay` when given (skipping the SCShareableContent fetch)
  /// and returns the display it captured so the caller can cache it.
  private nonisolated static func captureScreenshotJPEG(
    to url: URL, height: Int, quality: Double, display cachedDisplay: SCDisplay?
  ) async throws -> SCDisplay {
    let display: SCDisplay
    if let cachedDisplay {
      display = cachedDisplay
    } else {
      ScreenCaptureMonitor.shared.recordRequest(.shareableContent, source: .flow)
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      guard let first = content.displays.first else {
        throw NSError(
          domain: "FlowAgent", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
      }
      display = first
    }

    let configuration = SCStreamConfiguration()
    let aspectRatio = Double(display.width) / Double(max(1, display.height))
    configuration.height = height
    configuration.width = Int(Double(height) * aspectRatio)
    configuration.scalesToFit = true
    configuration.showsCursor = true

    ScreenCaptureMonitor.shared.recordRequest(.screenshot, source: .flow)
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(display: display, excludingWindows: []),
      configuration: configuration
    )

    let bitmap = NSBitmapImageRep(cgImage: image)
    guard
      let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    else {
      throw NSError(
        domain: "FlowAgent", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "JPEG conversion failed"])
    }
    try jpegData.write(to: url)
    return display
  }

  // MARK: - Cleanup

  private func cleanupWorkDirectory() {
    if let directory = workDirectory {
      try? FileManager.default.removeItem(at: directory)
    }
    workDirectory = nil
  }
}

/// Whether the user is sharing their screen in a call. macOS has no API for
/// this, and its own recording indicator is always on because Dayflow records,
/// so this looks for the floating controls meeting apps put up while sharing.
enum FlowScreenShareDetector {
  /// Window titles that only exist while sharing, lowercased, by owning app
  /// ("" matches any app, which covers browsers running Meet and the like).
  private static let markers: [(owner: String, title: String)] = [
    ("zoom.us", "zoom share statusbar window"),
    ("zoom.us", "zoom share toolbar window"),
    ("microsoft teams", "sharing control bar"),
    ("microsoft teams", "sharing toolbar"),
    ("webex", "sharing control bar"),
    ("", "is sharing your screen"),
    ("", "is sharing a window"),
  ]

  static func isSharing() -> Bool {
    guard
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    return windows.contains { window in
      let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
      let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
      guard !title.isEmpty else { return false }
      return markers.contains { marker in
        (marker.owner.isEmpty || owner.contains(marker.owner)) && title.contains(marker.title)
      }
    }
  }
}
