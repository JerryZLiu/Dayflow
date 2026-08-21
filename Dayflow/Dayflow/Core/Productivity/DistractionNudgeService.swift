//
//  DistractionNudgeService.swift
//  Dayflow
//
//  Gentle, non‑blocking distraction nudges. Watches ProductivityStats and fires
//  a local notification when distraction in the trailing window crosses the
//  threshold — respecting a cooldown, pause/idle state, and the user toggle.
//
//  This is intentionally not rule‑based blocking: it relies on Dayflow's existing
//  AI categorization rather than URL/app blocklists.
//

import AppKit
import Combine
import Foundation

@MainActor
final class DistractionNudgeService: ObservableObject {
  static let shared = DistractionNudgeService()

  private var timer: Timer?
  private var lastNudgeAt: Date?

  private init() {}

  func start() {
    evaluate()
    // Re‑evaluate every 5 minutes. ProductivityStats keeps its window fresh on
    // its own minute timer, so reading its published value here is enough.
    let timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.evaluate() }
    }
    self.timer = timer
  }

  func evaluate() {
    guard ProductivityPreferences.distractionNudgesEnabled else { return }
    // Don't nag while paused or after the user has gone idle.
    guard AppState.shared.isRecording else { return }
    guard !PauseManager.shared.isPaused else { return }
    guard !InactivityMonitor.shared.pendingReset else { return }

    let distracted = ProductivityStats.shared.distractedSecondsInNudgeWindow
    guard distracted >= ProductivityPreferences.nudgeThresholdSeconds else { return }

    if let last = lastNudgeAt,
      Date().timeIntervalSince(last) < ProductivityPreferences.nudgeCooldownSeconds
    {
      return
    }

    lastNudgeAt = Date()
    let minutes = Int((distracted / 60).rounded())
    NotificationService.shared.sendDistractionNudge(distractionMinutes: minutes)
  }
}
