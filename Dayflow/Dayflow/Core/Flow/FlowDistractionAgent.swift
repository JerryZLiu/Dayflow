//
//  FlowDistractionAgent.swift
//  Dayflow
//
//  Real distraction detection for Flow sessions. Each session gets one
//  continuous Codex CLI conversation: an initial briefing with the user's
//  goals, session length, and alert style, then a screenshot every ~15 seconds
//  with the current time and time remaining. The model replies with a strict
//  one-object JSON verdict; nudges/praise drive the desktop overlay and
//  on-task/off-task flips drive the session's distraction log (via
//  FlowSessionMirror → web UI → backend).
//
//  Runs entirely through the user's own `codex` CLI at low reasoning effort,
//  reusing ChatCLIProcessRunner (streaming for the first turn to capture the
//  thread id, then `codex exec resume <id> --image <shot>` per tick).
//

import AppKit
import Foundation
import ScreenCaptureKit

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

  /// The model's per-turn reply. Anything unparseable is treated as
  /// on-task/no-action so a flaky turn can never fire a bogus nudge.
  private struct Verdict: Decodable {
    let status: String?
    let action: String?
    let message: String?
    let reason: String?
  }

  private let runner = ChatCLIProcessRunner()

  private var codexSessionId: String?
  private var tickTimer: Timer?
  private var tickInFlight = false
  private var paused = false
  /// Bumped on every start/stop so results from a superseded session's
  /// in-flight process are ignored when they land.
  private var generation = 0
  private var consecutiveFailures = 0
  /// One-shot context lines (snooze, back-to-work, break) folded into the
  /// next tick's message.
  private var pendingNotes: [String] = []
  private var lastReportedOffTask = false

  private var goals: [String] = []
  private var alertStyle: FlowAlertStyle = .friendly
  private var sessionStartedAt = Date()
  private var sessionEndsAt: Date?
  private var workDirectory: URL?

  private static var tickInterval: TimeInterval {
    let stored = UserDefaults.standard.double(forKey: "flowAgentTickSeconds")
    return stored >= 5 ? stored : 15
  }

  /// Model for distraction ticks: fast, cheap, and takes the screenshot
  /// directly (same model the Codex transcription path uses).
  private static let model: String? = "gpt-5.6-luna"

  /// Set to a text-only model (e.g. "gpt-5.3-codex-spark") to send Apple
  /// Vision OCR text instead of the screenshot. nil = normal image ticks.
  private static let temporaryTextOnlyModel: String? = nil

  /// Spark rejects reasoning summaries (a user's global config.toml may set
  /// model_reasoning_summary = "detailed"), and the agent never wants them
  /// anyway — ticks should produce nothing but the JSON verdict.
  private static let codexConfigOverrides = ["model_reasoning_summary=none"]

  private init() {}

  var isRunning: Bool { generationIsLive && codexSessionId != nil }
  private var generationIsLive: Bool { tickTimer != nil || tickInFlight }

  // MARK: - Lifecycle (driven by FlowSessionMirror phase transitions)

  func start(with snapshot: FlowNativeSnapshot) {
    stop()

    goals = snapshot.goals ?? []
    alertStyle = snapshot.alertStyle
    sessionStartedAt =
      snapshot.sessionStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
    sessionEndsAt = snapshot.sessionEndsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    lastReportedOffTask = false
    pendingNotes = []
    consecutiveFailures = 0
    paused = false
    transcript = []

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DayflowFlowAgent-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    workDirectory = directory

    generation += 1
    let gen = generation
    let prompt = initialPrompt()
    let runner = self.runner

    print("[FlowAgent] Starting Codex conversation (style: \(alertStyle.rawValue))")
    tickInFlight = true
    Task.detached(priority: .utility) {
      var sessionId: String?
      var replyText = ""
      var errorText: String?
      do {
        let stream = runner.runStreaming(
          tool: .codex,
          prompt: prompt,
          workingDirectory: directory,
          model: Self.temporaryTextOnlyModel ?? Self.model,
          reasoningEffort: "low",
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
      print("[FlowAgent] Could not start Codex session: \(error ?? "no thread id in output")")
      appendTranscript("Couldn't start the agent: \(error ?? "no thread id in output")")
      AnalyticsService.shared.capture("flow_agent_start_failed")
      cleanupWorkDirectory()
      return
    }

    print("[FlowAgent] Codex session started: \(sessionId), first reply: \(reply.prefix(200))")
    appendTranscript(reply)
    AnalyticsService.shared.capture("flow_agent_started")
    codexSessionId = sessionId
    scheduleTimer()
  }

  func pause() {
    guard generationIsLive || codexSessionId != nil else { return }
    paused = true
    noteUserEvent("The user is taking a break; screenshots were paused while it lasted.")
  }

  func resume() {
    guard codexSessionId != nil else { return }
    paused = false
    noteUserEvent("The user just came back from their break.")
  }

  func stop() {
    generation += 1
    tickTimer?.invalidate()
    tickTimer = nil
    tickInFlight = false
    codexSessionId = nil
    paused = false
    pendingNotes = []
    lastReportedOffTask = false
    cleanupWorkDirectory()
  }

  /// Queue a line of context (snooze, back-to-work…) for the next tick.
  /// `markRefocused` also resets the off-task flag so a later distraction
  /// opens a fresh interval in the session log.
  func noteUserEvent(_ note: String, markRefocused: Bool = false) {
    guard codexSessionId != nil else { return }
    pendingNotes.append(note)
    if markRefocused { lastReportedOffTask = false }
  }

  // MARK: - Ticks

  private func scheduleTimer() {
    tickTimer?.invalidate()
    tickTimer = Timer.scheduledTimer(
      withTimeInterval: Self.tickInterval, repeats: true
    ) { _ in
      MainActor.assumeIsolated {
        FlowDistractionAgent.shared.tick()
      }
    }
  }

  private func tick() {
    guard let sessionId = codexSessionId, let directory = workDirectory else { return }
    guard !paused, !tickInFlight else { return }

    tickInFlight = true
    let gen = generation
    let message = tickMessage()
    pendingNotes = []
    let runner = self.runner
    let shotURL = directory.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).jpg")

    Task.detached(priority: .utility) {
      var replyText: String?
      var errorText: String?
      do {
        try await Self.captureScreenshotJPEG(to: shotURL)
        // TEMPORARY (see temporaryTextOnlyModel): OCR text instead of the image.
        var prompt = message
        var imagePaths = [shotURL.path]
        if Self.temporaryTextOnlyModel != nil {
          let screenText = Self.recognizeScreenText(at: shotURL)
          prompt +=
            "\nScreen text (Apple OCR of the current screenshot):\n\(screenText)\nReply with the JSON object only."
          imagePaths = []
        } else {
          prompt += "\nScreenshot attached. Reply with the JSON object only."
        }
        let result = try runner.run(
          tool: .codex,
          prompt: prompt,
          workingDirectory: directory,
          imagePaths: imagePaths,
          model: Self.temporaryTextOnlyModel ?? Self.model,
          reasoningEffort: "low",
          codexResumeSessionId: sessionId,
          codexConfigOverrides: Self.codexConfigOverrides,
          timeoutSeconds: 60
        )
        if result.exitCode == 0 {
          replyText = result.stdout
        } else {
          errorText = result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr
        }
      } catch {
        errorText = error.localizedDescription
      }
      try? FileManager.default.removeItem(at: shotURL)

      await MainActor.run {
        FlowDistractionAgent.shared.finishTick(generation: gen, reply: replyText, error: errorText)
      }
    }
  }

  private func finishTick(generation gen: Int, reply: String?, error: String?) {
    guard gen == generation else { return }
    tickInFlight = false

    guard let reply else {
      consecutiveFailures += 1
      print("[FlowAgent] Tick failed (\(consecutiveFailures)): \(error ?? "unknown")")
      appendTranscript("Turn failed: \(error ?? "unknown")")
      if consecutiveFailures >= 3 {
        print("[FlowAgent] Stopping after 3 consecutive failures")
        appendTranscript("Agent stopped after 3 consecutive failures.")
        AnalyticsService.shared.capture("flow_agent_gave_up")
        stop()
      }
      return
    }
    consecutiveFailures = 0
    appendTranscript(reply)

    guard let verdict = Self.parseVerdict(from: reply) else {
      print("[FlowAgent] Unparseable reply, treating as on-task: \(reply.prefix(200))")
      return
    }
    handle(verdict: verdict)
  }

  private func handle(verdict: Verdict) {
    let offTask = verdict.status == "off_task"
    if offTask != lastReportedOffTask {
      lastReportedOffTask = offTask
      FlowSessionMirror.shared.agentReportedFocusChange(isDistracted: offTask)
      if offTask {
        print("[FlowAgent] Off task: \(verdict.reason ?? "no reason given")")
      }
    }

    switch verdict.action {
    case "nudge":
      let message = verdict.message ?? "Psst... I think you're getting distracted!"
      FlowSessionMirror.shared.agentNudge(message: message)
    case "praise":
      if let message = verdict.message, !message.isEmpty {
        FlowSessionMirror.shared.agentPraise(message: message)
      }
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
      goalsBlock = goals.map { "- \($0)" }.joined(separator: "\n")
    }

    let styleBlock: String
    switch alertStyle {
    case .quiet:
      styleBlock = """
        Quiet. The user asked for zero interruptions. NEVER use "nudge" or "praise" — keep \
        action "none" on every turn. Your status field still matters: distractions are \
        logged silently for their session summary.
        """
    case .friendly:
      styleBlock = """
        Friendly. Give them slack: don't nudge until they've clearly been off task for a \
        few minutes straight (many consecutive off-task checks — a quick detour that \
        ends on its own never earns a nudge). One nudge per incident; if they're still \
        distracted several minutes later, one firmer follow-up is okay. Tone: warm and \
        encouraging, like a supportive friend. Never guilt-trippy.
        """
    case .feisty:
      styleBlock = """
        Feisty. Quick and stern. Nudge as soon as you're confident they're off task — one \
        clearly off-task check is enough. Persistent reminders until they're back on \
        track: if they stay distracted, nudge again every minute or two, each one more \
        direct than the last. Tone: stern and no-nonsense, a coach who won't let it slide. \
        Blunt is fine; insulting is not.
        """
    }

    // TEMPORARY (see temporaryTextOnlyModel): the evidence wording flips
    // between screenshots and OCR text.
    let evidenceIntro: String
    let evidenceJudging: String
    if Self.temporaryTextOnlyModel != nil {
      evidenceIntro =
        "text extracted from a screenshot of their screen (Apple's OCR), the current time, "
        + "and the time left"
      evidenceJudging = """
        - The OCR text is your only evidence, and it's imperfect: expect garbled fragments, \
        menu bars, timestamps, and UI chrome mixed together. Anchor on the strong signals — \
        app names, window and tab titles, site names, video or post titles.
        """
    } else {
      evidenceIntro = "a screenshot of their screen, the current time, and the time left"
      evidenceJudging = "- The screenshot is your only evidence."
    }

    return """
      You are the focus companion inside Dayflow, a Mac time-tracking app. The user just \
      started a Flow focus session and you're watching over it. Roughly every 15 seconds \
      you'll get a message with \(evidenceIntro). Your job: judge whether they're on task, \
      and decide whether their focus buddy (a small pixel creature that peeks in from the \
      screen edge) should say something.

      SESSION
      - Started at \(started).
      - \(lengthLine)
      - Alert style: \(alertStyle.rawValue).

      THE USER'S STATED FOCUS
      \(goalsBlock)

      HOW TO JUDGE
      - Be generous. Docs, searches, terminal work, Slack or email replies, and quick \
      utility checks all plausibly serve the goals — count them as on task.
      - One glance at something unrelated is not a distraction; a pattern across \
      consecutive checks is (social feeds, YouTube, shopping, news rabbit holes).
      \(evidenceJudging)
      - If you're unsure, assume on task.

      HOW TO REPLY
      Reply to every message with exactly one JSON object and nothing else — no prose, no \
      code fences, no explanation:
      {"status": "on_task" | "off_task", "action": "none" | "nudge" | "praise", "message": "...", "reason": "..."}
      - status: your read of the current check.
      - action "nudge" makes the creature appear with your message. Write it yourself in \
      the alert style's tone, but keep it SHORT: one sentence, 10 words max — it renders \
      in a tiny speech bubble ("Twitter can wait — 12 minutes left!").
      - action "praise" shows a brief encouragement, same 10-word cap. Use it sparingly — \
      at most once every ten minutes or so, e.g. after a long on-task stretch or right \
      after they recover from a distraction.
      - message is required whenever action isn't "none". reason: a few words of evidence \
      whenever status is "off_task".

      ALERT STYLE
      \(styleBlock)

      Don't overthink the ticks: no analysis, no chain of reasoning in your reply. Most \
      turns the correct answer is exactly {"status":"on_task","action":"none"}. Acknowledge \
      this briefing now with that same JSON object.
      """
  }

  private func tickMessage() -> String {
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

    var parts = [line]
    parts.append(contentsOf: pendingNotes)
    // The evidence line (screenshot vs OCR text) is appended in tick(), where
    // the capture happens.
    return parts.joined(separator: "\n")
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

  private static func parseVerdict(from reply: String) -> Verdict? {
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
      let verdict = try? JSONDecoder().decode(Verdict.self, from: data)
    {
      return verdict
    }
    // Fall back to the outermost {...} in case the model wrapped the JSON in
    // fences or stray text.
    guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
      start < end,
      let data = String(trimmed[start...end]).data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(Verdict.self, from: data)
  }

  // MARK: - Screenshot capture

  /// One-shot capture of the main display, scaled to ~720p JPEG. Independent
  /// of the timeline recorder so Flow works even when recording is paused.
  private nonisolated static func captureScreenshotJPEG(to url: URL) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
      throw NSError(
        domain: "FlowAgent", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
    }

    let configuration = SCStreamConfiguration()
    let aspectRatio = Double(display.width) / Double(max(1, display.height))
    configuration.height = 720
    configuration.width = Int(720 * aspectRatio)
    configuration.scalesToFit = true
    configuration.showsCursor = true

    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(display: display, excludingWindows: []),
      configuration: configuration
    )

    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    else {
      throw NSError(
        domain: "FlowAgent", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "JPEG conversion failed"])
    }
    try jpegData.write(to: url)
  }

  // TEMPORARY (see temporaryTextOnlyModel): full-screen OCR via the same Apple
  // Vision recognizer the Claude transcription path uses.
  private nonisolated static func recognizeScreenText(at url: URL) -> String {
    let blocks = (try? AppleVisionClaudeFrameTextRecognizer().recognizeText(in: url)) ?? []
    let lines = blocks.filter { $0.confidence >= 0.3 }.map(\.text)
    var text = lines.joined(separator: "\n")
    if text.count > 4000 {
      text = String(text.prefix(4000)) + "\n[truncated]"
    }
    return text.isEmpty ? "[no text detected on screen]" : text
  }

  // MARK: - Cleanup

  private func cleanupWorkDirectory() {
    if let directory = workDirectory {
      try? FileManager.default.removeItem(at: directory)
    }
    workDirectory = nil
  }
}
