//
//  FlowSessionMirror.swift
//  Dayflow
//
//  Holds the native mirror of Flow session state and decides what the desktop
//  overlay shows. State changes arrive from the hosted web UI over the bridge;
//  overlay pill actions are relayed back to the web UI (which owns talking to
//  the backend).
//

import AppKit
import Foundation

/// Implemented by the webview bridge so the mirror can push events to the
/// hosted page (overlay actions, native state changes). Weakly held: the Flow
/// tab may not be open.
@MainActor
protocol FlowBridgeForwarding: AnyObject {
  func sendEvent(_ event: String, payload: [String: Any])
}

@MainActor
final class FlowSessionMirror: ObservableObject {
  static let shared = FlowSessionMirror()

  @Published private(set) var snapshot: FlowNativeSnapshot
  @Published private(set) var overlay: FlowOverlayPresentation = .hidden {
    didSet {
      // The variant is fixed per appearance: picked when a nudge brings the
      // creature on screen, kept through the follow-up toast, and reset to
      // the side layout for anything that starts from hidden or needs the
      // tub (bath clips are authored for the bottom-right corner).
      if case .nudge = overlay {
        if oldValue == .hidden {
          overlayVariant = FlowNudgeVariant.current
          lastNudgeReply = nil
        }
      } else if overlay == .onBreak || oldValue == .hidden || overlay.isDemo {
        overlayVariant = .side
      }
    }
  }
  /// Layout/clip family for what's on screen right now (see FlowNudgeVariant).
  @Published private(set) var overlayVariant: FlowNudgeVariant = .side
  private(set) var lastNudgeReply: FlowNudgeReply?
  /// True between a (simulated) distraction firing and the user responding.
  @Published private(set) var isDistracted = false

  weak var webBridge: FlowBridgeForwarding?

  private var deadlineTimer: Timer?
  private var toastTimer: Timer?
  /// The tub only stays for its 8-second intro clip, then the creature climbs
  /// out and the overlay clears so the break doesn't sit on the screen.
  private var breakOverlayTimer: Timer?
  private var snoozeUntil: Date?
  /// Nudges shown for the current distraction incident; the second one in a
  /// row escalates the creature to the fire animation.
  private var nudgeStreak = 0

  private init() {
    // Survive a relaunch mid-session: restore the last snapshot, but drop
    // states that no longer make sense (an expired timed session).
    var restored = FlowNativeSnapshot.loadPersisted()
    let now = Int(Date().timeIntervalSince1970)
    if restored.phase != .idle, let endsAt = restored.sessionEndsAt, endsAt <= now {
      restored = .idle
    }
    snapshot = restored
    armDeadlineTimer()
    if restored.phase == .active {
      // Relaunched mid-session: the old Codex conversation is gone, start a
      // fresh one with the same session facts.
      FlowDistractionAgent.shared.start(with: restored)
    }
  }

  // MARK: - Updates from the web UI

  func apply(_ newSnapshot: FlowNativeSnapshot) {
    let previous = snapshot
    snapshot = newSnapshot
    newSnapshot.persist()

    switch (previous.phase, newSnapshot.phase) {
    case (.idle, .active), (.ended, .active):
      isDistracted = false
      snoozeUntil = nil
      nudgeStreak = 0
      showToast(String(localized: "Your flow session starts now!"))
      FlowDistractionAgent.shared.start(with: newSnapshot)
      AnalyticsService.shared.capture(
        "flow_session_started",
        [
          "alert_style": newSnapshot.alertStyle.rawValue,
          "always_on": newSnapshot.alwaysOn,
        ])
    case (_, .onBreak):
      showBreak()
      FlowDistractionAgent.shared.pause()
    case (.onBreak, .active):
      breakOverlayTimer?.invalidate()
      showToast(String(localized: "Break's over. Back to it!"))
      FlowDistractionAgent.shared.resume()
      FlowDistractionAgent.shared.goalsChanged(to: newSnapshot)
    case (.active, .active):
      // Tasks added by voice or checked off by hand mid-session.
      FlowDistractionAgent.shared.goalsChanged(to: newSnapshot)
    case (_, .idle), (_, .ended):
      isDistracted = false
      snoozeUntil = nil
      FlowSessionTimeline.shared.finish()
      FlowDistractionAgent.shared.stop()
      if case (_, .idle) = (previous.phase, newSnapshot.phase), !overlay.isDemo {
        overlay = .hidden
      }
    default:
      break
    }

    armDeadlineTimer()
  }

  // MARK: - Onboarding demo

  /// Onboarding's "I will appear on the side of your screen like this" beats:
  /// the Flow page asks for the real overlay instead of drawing a picture of it.
  func showDemo(message: String, reply: String, feisty: Bool) {
    guard snapshot.phase != .active, snapshot.phase != .onBreak else { return }
    toastTimer?.invalidate()
    overlay = .demo(message: message, reply: reply, feisty: feisty)
  }

  func hideDemo() {
    if overlay.isDemo { overlay = .hidden }
  }

  /// The reply pill under the demo bubble. The page decides what comes next
  /// (the feisty beat, or hiding the creature), so the overlay stays up.
  func replyToDemo() {
    webBridge?.sendEvent("onboardingAlertReply", payload: [:])
  }

  // MARK: - Distraction simulation (⌘⇧D fallback for testing)

  /// Debug panel: bring the creature in with the given layout, session or not.
  func debugNudge(variant: FlowNudgeVariant, escalated: Bool = false) {
    FlowNudgeVariant.current = variant
    FlowAgentSettings.shared.nudgeVariant = variant
    if overlay != .hidden {
      // The variant is fixed per appearance; clear first so the new layout
      // (and its entrance clip) applies.
      overlay = .hidden
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.debugNudge(variant: variant, escalated: escalated)
      }
      return
    }
    snoozeUntil = nil
    overlay = .nudge(
      message: String(localized: "Psst... I think you're getting distracted!"),
      escalated: escalated)
  }

  /// Debug panel: show the break tub with its normal auto-dismiss.
  func debugBreak() { showBreak() }

  /// Debug panel: a toast with arbitrary text.
  func debugToast(_ message: String) { showToast(message) }

  /// Debug panel: dismiss whatever is on screen (plays the exit clip).
  func debugHideOverlay() { overlay = .hidden }

  /// Fires the distraction nudge as if the detection agent had flagged the
  /// user. Quiet mode records nothing visible, matching the design.
  func simulateDistraction() {
    guard snapshot.phase == .active else { return }
    AnalyticsService.shared.capture(
      "flow_distraction_simulated", ["alert_style": snapshot.alertStyle.rawValue])
    isDistracted = true
    // Let the web UI record a distraction_started event with the backend.
    webBridge?.sendEvent("distractionSimulated", payload: [:])
    guard snapshot.alertStyle != .quiet else { return }
    snoozeUntil = nil
    nudgeStreak += 1
    overlay = .nudge(
      message: String(localized: "Psst... I think you're getting distracted!"),
      escalated: nudgeStreak >= 2)
    armDeadlineTimer()
  }

  // MARK: - Detection agent callbacks

  /// The agent's on-task/off-task read flipped: keep the backend's
  /// distraction intervals in sync (the web UI owns recording them).
  func agentReportedFocusChange(isDistracted distracted: Bool) {
    guard snapshot.phase == .active else { return }
    isDistracted = distracted
    if !distracted { nudgeStreak = 0 }
    webBridge?.sendEvent(distracted ? "distractionSimulated" : "distractionEnded", payload: [:])
    if !distracted, case .nudge = overlay {
      overlay = .hidden
    }
  }

  /// Show a nudge written by the agent. Quiet mode and an active snooze both
  /// suppress it (the distraction is still logged via the focus change above).
  func agentNudge(message: String) {
    guard snapshot.phase == .active, snapshot.alertStyle != .quiet else { return }
    if let snoozeUntil, snoozeUntil > Date() { return }
    AnalyticsService.shared.capture(
      "flow_agent_nudge", ["alert_style": snapshot.alertStyle.rawValue])
    nudgeStreak += 1
    overlay = .nudge(message: message, escalated: nudgeStreak >= 2)
  }

  /// The agent saw goals get finished on screen: the web UI checks them off
  /// (completed by Flow), and the creature celebrates unless it's quiet mode.
  func agentCompletedGoals(_ goals: [FlowGoalTask]) {
    guard snapshot.phase == .active, !goals.isEmpty else { return }
    webBridge?.sendEvent("tasksCompleted", payload: ["ids": goals.map(\.id)])
    AnalyticsService.shared.capture("flow_agent_goal_completed", ["count": goals.count])
    guard snapshot.alertStyle != .quiet else { return }
    if case .nudge = overlay { return }
    let title = goals[0].title
    let message =
      goals.count == 1
      ? String(localized: "Checked off: \(title)")
      : String(localized: "Checked off \(goals.count) tasks, including \(title)")
    showToast(message, seconds: FlowAgentSettings.shared.praiseSeconds)
  }

  /// Short encouragement from the agent, shown as an auto-dismissing toast.
  func agentPraise(message: String) {
    guard snapshot.phase == .active, snapshot.alertStyle != .quiet else { return }
    if case .nudge = overlay { return }
    showToast(message, seconds: FlowAgentSettings.shared.praiseSeconds)
  }

  // MARK: - Overlay pill actions

  func respondBackToWork() {
    lastNudgeReply = .backToWork
    isDistracted = false
    snoozeUntil = nil
    nudgeStreak = 0
    webBridge?.sendEvent("overlayAction", payload: ["action": "backToWork"])
    FlowDistractionAgent.shared.noteUserEvent(
      "The user tapped \"I'll get back to work\" on your nudge.", markRefocused: true)
    showToast(String(localized: "Nice! Keep at it"))
  }

  func snooze(minutes: Int) {
    lastNudgeReply = .snooze
    snoozeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
    webBridge?.sendEvent(
      "overlayAction", payload: ["action": "snooze", "minutes": minutes])
    FlowDistractionAgent.shared.noteUserEvent(
      "The user snoozed your nudge for \(minutes) minutes. Do not nudge again until the snooze is over unless they switch to something new."
    )
    overlay = .hidden
    armDeadlineTimer()
  }

  /// "Correct Flow's mistake": the agent misread the screen. Close the
  /// distraction interval and tell the agent so it recalibrates.
  func correctMistake() {
    lastNudgeReply = .correct
    isDistracted = false
    snoozeUntil = nil
    nudgeStreak = 0
    webBridge?.sendEvent("distractionEnded", payload: [:])
    FlowDistractionAgent.shared.noteUserEvent(
      "The user says your nudge was a mistake — they were on task. Trust them, and be more lenient about screens like the one that triggered it.",
      markRefocused: true)
    AnalyticsService.shared.capture("flow_agent_nudge_corrected")
    overlay = .hidden
  }

  func dismissOverlay() {
    overlay = .hidden
  }

  /// "Start a new session" from the session-ended bubble: bring up the app on
  /// the Flow tab; the web UI takes it from there.
  func openFlowTab() {
    overlay = .hidden
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .navigateToFlow, object: nil)
  }

  // MARK: - Menu bar controls

  /// Set when a session start was asked for before the Flow page existed;
  /// the page picks it up as soon as its bridge attaches.
  var pendingStartSession = false

  /// Opens the Flow tab on the session setup screen (the early-bird card's
  /// "Start session").
  func requestStartSession() {
    openFlowTab()
    if let webBridge {
      webBridge.sendEvent("sessionControl", payload: ["action": "start"])
    } else {
      pendingStartSession = true
    }
  }

  /// A session is running or on a break: the menu bar shows its Flow pill
  /// and session hero only while this holds.
  var isSessionOn: Bool { snapshot.phase == .active || snapshot.phase == .onBreak }

  /// Break, resume and end from the menu bar hero. The web UI owns sessions,
  /// so the press is relayed there with the break length picked; if the Flow
  /// page isn't loaded there is nobody to act on it, and opening Flow is the
  /// next best thing.
  func menuBarControl(_ action: String, minutes: Int? = nil) {
    var payload: [String: Any] = ["action": action]
    if let minutes { payload["minutes"] = minutes }
    AnalyticsService.shared.capture("flow_menu_bar_control", payload)
    guard let webBridge else {
      openFlowTab()
      return
    }
    webBridge.sendEvent("sessionControl", payload: payload)
  }

  // MARK: - Deadlines

  /// Re-arms a single timer for the nearest upcoming deadline: session end,
  /// break end, or snooze expiry. The web UI derives the same transitions from
  /// the same timestamps, so both sides agree without bridge chatter.
  private func armDeadlineTimer() {
    deadlineTimer?.invalidate()
    deadlineTimer = nil

    var deadlines: [Date] = []
    let now = Date()
    if snapshot.phase == .active, let endsAt = snapshot.sessionEndsAt {
      deadlines.append(Date(timeIntervalSince1970: TimeInterval(endsAt)))
    }
    if snapshot.phase == .onBreak, let endsAt = snapshot.breakEndsAt {
      deadlines.append(Date(timeIntervalSince1970: TimeInterval(endsAt)))
    }
    if let snoozeUntil {
      deadlines.append(snoozeUntil)
    }
    guard let nearest = deadlines.min() else { return }

    let interval = max(0.5, nearest.timeIntervalSince(now))
    deadlineTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
      MainActor.assumeIsolated {
        FlowSessionMirror.shared.handleDeadline()
      }
    }
  }

  private func handleDeadline() {
    let now = Int(Date().timeIntervalSince1970)

    if let snoozeDeadline = snoozeUntil, snoozeDeadline <= Date() {
      snoozeUntil = nil
      // Still marked distracted after the snooze ran out → nudge again.
      if isDistracted, snapshot.phase == .active, snapshot.alertStyle != .quiet {
        nudgeStreak += 1
        overlay = .nudge(
          message: String(localized: "Snooze is up. Ready to get back to it?"),
          escalated: nudgeStreak >= 2)
      }
    }

    if snapshot.phase == .active, let endsAt = snapshot.sessionEndsAt, endsAt <= now {
      snapshot.phase = .ended
      snapshot.persist()
      overlay = .sessionEnded
      FlowSessionTimeline.shared.finish()
      FlowDistractionAgent.shared.stop()
      AnalyticsService.shared.capture("flow_session_natural_end")
    }

    if snapshot.phase == .onBreak, let endsAt = snapshot.breakEndsAt, endsAt <= now {
      snapshot.phase = .active
      snapshot.breakEndsAt = nil
      snapshot.persist()
      breakOverlayTimer?.invalidate()
      showToast(String(localized: "Break's over. Back to it!"))
    }

    armDeadlineTimer()
  }

  // MARK: - Toasts

  private func showToast(_ message: String, seconds: TimeInterval? = nil) {
    let seconds = seconds ?? FlowAgentSettings.shared.toastSeconds
    overlay = .toast(message: message)
    toastTimer?.invalidate()
    toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
      MainActor.assumeIsolated {
        let mirror = FlowSessionMirror.shared
        if case .toast = mirror.overlay {
          mirror.overlay = .hidden
        }
      }
    }
  }

  // MARK: - Break

  /// Brings the tub out for the bath intro clip, then hides the overlay again
  /// (the controller plays the climb-out clip on the way).
  private func showBreak() {
    toastTimer?.invalidate()
    overlay = .onBreak
    breakOverlayTimer?.invalidate()
    breakOverlayTimer = Timer.scheduledTimer(
      withTimeInterval: FlowAgentSettings.shared.breakOverlaySeconds, repeats: false
    ) { _ in
      MainActor.assumeIsolated {
        let mirror = FlowSessionMirror.shared
        if mirror.overlay == .onBreak {
          mirror.overlay = .hidden
        }
      }
    }
  }
}
