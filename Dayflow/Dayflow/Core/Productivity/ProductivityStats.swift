//
//  ProductivityStats.swift
//  Dayflow
//
//  Aggregates today's processed timeline cards into a focused-time total and
//  exposes a live-optimistic count-up for the focus Mini Timer.
//
//  Dayflow categorizes activity in batches (~15 min lag), so "live" here means:
//  take everything already analyzed today, then optimistically extend the most
//  recent focused segment forward to *now* while the user is actively at the
//  machine (recording on, not paused, not idle). When the next batch lands, the
//  processed total absorbs that gap and the live extension shrinks back.
//
//  All time math uses epoch start_ts/end_ts (ground truth), never the display
//  "h:mm a" text.
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class ProductivityStats: ObservableObject {
  static let shared = ProductivityStats()

  /// Focused seconds from analyzed cards for the current (4 AM boundary) day.
  @Published private(set) var focusedSecondsToday: Double = 0

  /// End of the most recent analyzed card today, used to extend the live count.
  private(set) var lastSegmentEnd: Date?
  /// Whether that most recent segment was focused (so we keep counting up).
  private(set) var lastSegmentIsFocused: Bool = false

  /// Cap on the optimistic forward extension so a stalled analysis pipeline can't
  /// run the counter away indefinitely (slightly above typical batch cadence).
  private let liveExtensionCapSeconds: Double = 30 * 60
  /// Treat the user as away after this much system-wide input inactivity.
  private let idleThresholdSeconds: Double = 5 * 60

  private var timer: Timer?
  private var observer: NSObjectProtocol?

  private init() {}

  func start() {
    recompute()
    let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.recompute() }
    }
    self.timer = timer

    observer = NotificationCenter.default.addObserver(
      forName: .timelineDataUpdated,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.recompute() }
    }
  }

  /// Focused seconds to display, including the live-optimistic extension.
  func liveFocusedSeconds(asOf now: Date) -> Double {
    focusedSecondsToday + liveExtensionSeconds(asOf: now)
  }

  /// Whether the timer is actively counting up right now (for the live dot).
  func isActivelyCounting(asOf now: Date) -> Bool {
    liveExtensionSeconds(asOf: now) > 0
  }

  private func liveExtensionSeconds(asOf now: Date) -> Double {
    guard
      lastSegmentIsFocused,
      let end = lastSegmentEnd,
      AppState.shared.isRecording,
      !PauseManager.shared.isPaused,
      !userIsIdle()
    else { return 0 }
    return min(max(0, now.timeIntervalSince(end)), liveExtensionCapSeconds)
  }

  /// System-wide input idle, via CGEventSource — no permission, no latch.
  private func userIsIdle() -> Bool {
    let types: [CGEventType] = [
      .mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel,
    ]
    let idle =
      types
      .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
      .min() ?? .greatestFiniteMagnitude
    return idle >= idleThresholdSeconds
  }

  // MARK: - Recompute

  private func recompute() {
    let now = Date()
    let dayInfo = now.getDayInfoFor4AMBoundary()
    let spans = StorageManager.shared.fetchTimelineActivity(forDay: dayInfo.dayString)

    let idleKey = normalizedCategoryKey(CategoryStore.shared.idleCategory?.name ?? "Idle")
    let distractionKey = normalizedCategoryKey("Distraction")

    var focused: Double = 0
    var latestEnd: Date?
    var latestIsFocused = false

    for span in spans {
      let duration = Double(span.endTs - span.startTs)
      guard duration > 0 else { continue }

      let categoryKey = normalizedCategoryKey(
        span.category.trimmingCharacters(in: .whitespacesAndNewlines))
      let isIdle = categoryKey == idleKey
      let isDistraction = categoryKey == distractionKey

      if !isIdle && !isDistraction {
        focused += duration
      }

      let endDate = Date(timeIntervalSince1970: TimeInterval(span.endTs))
      if latestEnd == nil || endDate > latestEnd! {
        latestEnd = endDate
        latestIsFocused = !isIdle && !isDistraction
      }
    }

    focusedSecondsToday = focused
    lastSegmentEnd = latestEnd
    lastSegmentIsFocused = latestIsFocused
  }
}
