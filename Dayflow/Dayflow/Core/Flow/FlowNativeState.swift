//
//  FlowNativeState.swift
//  Dayflow
//
//  Thin native mirror of Flow session state. The backend (via the hosted web
//  UI) owns the real data; the app only keeps enough to drive the desktop
//  overlay and survive a relaunch mid-session.
//

import Foundation

enum FlowAlertStyle: String, Codable, CaseIterable {
  case quiet
  case friendly
  case feisty
}

enum FlowPhase: String, Codable {
  case idle
  case active
  case onBreak = "break"
  case ended
}

/// Snapshot the web UI pushes over the bridge whenever session state changes.
/// Timestamps are unix seconds so the overlay can count down locally without
/// chatty bridge traffic.
struct FlowNativeSnapshot: Codable, Equatable {
  var phase: FlowPhase = .idle
  var alertStyle: FlowAlertStyle = .friendly
  /// nil when idle or when the session is "always on".
  var sessionEndsAt: Int?
  var breakEndsAt: Int?
  var alwaysOn: Bool = false
  /// When the active session began (unix seconds); nil when idle.
  var sessionStartedAt: Int?
  /// The user's stated focus for the session (priority task titles).
  var goals: [String]?

  static let idle = FlowNativeSnapshot()

  private static let defaultsKey = "flowNativeSnapshot"

  static func loadPersisted(defaults: UserDefaults = .standard) -> FlowNativeSnapshot {
    guard let data = defaults.data(forKey: defaultsKey),
      let snapshot = try? JSONDecoder().decode(FlowNativeSnapshot.self, from: data)
    else { return .idle }
    return snapshot
  }

  func persist(defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }

  init() {}

  init?(bridgePayload payload: [String: Any]) {
    guard let phaseRaw = payload["phase"] as? String,
      let phase = FlowPhase(rawValue: phaseRaw)
    else { return nil }
    self.phase = phase
    self.alertStyle =
      (payload["alertStyle"] as? String).flatMap(FlowAlertStyle.init(rawValue:)) ?? .friendly
    self.sessionEndsAt = payload["sessionEndsAt"] as? Int
    self.breakEndsAt = payload["breakEndsAt"] as? Int
    self.alwaysOn = payload["alwaysOn"] as? Bool ?? false
    self.sessionStartedAt = payload["sessionStartedAt"] as? Int
    self.goals = payload["goals"] as? [String]
  }

  var bridgePayload: [String: Any] {
    var payload: [String: Any] = [
      "phase": phase.rawValue,
      "alertStyle": alertStyle.rawValue,
      "alwaysOn": alwaysOn,
    ]
    if let sessionEndsAt { payload["sessionEndsAt"] = sessionEndsAt }
    if let breakEndsAt { payload["breakEndsAt"] = breakEndsAt }
    if let sessionStartedAt { payload["sessionStartedAt"] = sessionStartedAt }
    if let goals { payload["goals"] = goals }
    return payload
  }
}

/// What the overlay panel is currently showing.
enum FlowOverlayPresentation: Equatable {
  case hidden
  /// Short auto-dismissing speech bubble ("Your flow session starts now!").
  case toast(message: String)
  /// Distraction nudge with quick-reply pills. The message is written by the
  /// detection agent (or a stock line for the ⌘⇧D simulation).
  case nudge(message: String)
  /// Break in progress: tub + countdown driven by `breakEndsAt`.
  case onBreak
  /// Timed session hit its natural end.
  case sessionEnded
}
