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
  @Published private(set) var overlay: FlowOverlayPresentation = .hidden
  /// True between a (simulated) distraction firing and the user responding.
  @Published private(set) var isDistracted = false

  weak var webBridge: FlowBridgeForwarding?

  private var deadlineTimer: Timer?
  private var toastTimer: Timer?
  private var snoozeUntil: Date?

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
      showToast("Your flow session starts now!")
      FlowDistractionAgent.shared.start(with: newSnapshot)
      AnalyticsService.shared.capture(
        "flow_session_started",
        [
          "alert_style": newSnapshot.alertStyle.rawValue,
          "always_on": newSnapshot.alwaysOn,
        ])
    case (_, .onBreak):
      overlay = .onBreak
      FlowDistractionAgent.shared.pause()
    case (.onBreak, .active):
      showToast("Break's over. Back to it!")
      FlowDistractionAgent.shared.resume()
    case (_, .idle), (_, .ended):
      isDistracted = false
      snoozeUntil = nil
      FlowDistractionAgent.shared.stop()
      if case (_, .idle) = (previous.phase, newSnapshot.phase) {
        overlay = .hidden
      }
    default:
      break
    }

    armDeadlineTimer()
  }

  // MARK: - Distraction simulation (⌘⇧D fallback for testing)

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
    overlay = .nudge(message: "Psst... I think you're getting distracted!")
    armDeadlineTimer()
  }

  // MARK: - Detection agent callbacks

  /// The agent's on-task/off-task read flipped: keep the backend's
  /// distraction intervals in sync (the web UI owns recording them).
  func agentReportedFocusChange(isDistracted distracted: Bool) {
    guard snapshot.phase == .active else { return }
    isDistracted = distracted
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
    overlay = .nudge(message: message)
  }

  /// Short encouragement from the agent, shown as an auto-dismissing toast.
  func agentPraise(message: String) {
    guard snapshot.phase == .active, snapshot.alertStyle != .quiet else { return }
    if case .nudge = overlay { return }
    showToast(message, seconds: 5)
  }

  // MARK: - Overlay pill actions

  func respondBackToWork() {
    isDistracted = false
    snoozeUntil = nil
    webBridge?.sendEvent("overlayAction", payload: ["action": "backToWork"])
    FlowDistractionAgent.shared.noteUserEvent(
      "The user tapped \"I'll get back to work\" on your nudge.", markRefocused: true)
    showToast("Nice! Keep at it")
  }

  func snooze(minutes: Int) {
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
    isDistracted = false
    snoozeUntil = nil
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
        overlay = .nudge(message: "Snooze is up — ready to get back to it?")
      }
    }

    if snapshot.phase == .active, let endsAt = snapshot.sessionEndsAt, endsAt <= now {
      snapshot.phase = .ended
      snapshot.persist()
      overlay = .sessionEnded
      FlowDistractionAgent.shared.stop()
      AnalyticsService.shared.capture("flow_session_natural_end")
    }

    if snapshot.phase == .onBreak, let endsAt = snapshot.breakEndsAt, endsAt <= now {
      snapshot.phase = .active
      snapshot.breakEndsAt = nil
      snapshot.persist()
      showToast("Break's over. Back to it!")
    }

    armDeadlineTimer()
  }

  // MARK: - Toasts

  private func showToast(_ message: String, seconds: TimeInterval = 4) {
    overlay = .toast(message: message)
    toastTimer?.invalidate()
    toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
      MainActor.assumeIsolated {
        let mirror = FlowSessionMirror.shared
        if case .toast = mirror.overlay {
          // A break that started while the toast was up takes precedence.
          mirror.overlay = mirror.snapshot.phase == .onBreak ? .onBreak : .hidden
        }
      }
    }
  }
}
