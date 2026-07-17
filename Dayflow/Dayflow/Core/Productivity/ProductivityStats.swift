//
//  ProductivityStats.swift
//  Dayflow
//
//  Tracks how much distraction has occurred in a recent trailing window, which
//  drives the distraction nudges. Uses epoch start_ts/end_ts (ground truth),
//  never the display "h:mm a" text.
//

import Combine
import Foundation

@MainActor
final class ProductivityStats: ObservableObject {
  static let shared = ProductivityStats()

  /// Distraction seconds within the trailing nudge window. Drives nudges.
  @Published private(set) var distractedSecondsInNudgeWindow: Double = 0

  private var timer: Timer?
  private var observer: NSObjectProtocol?

  private init() {}

  func start() {
    recompute()
    // Refresh the window once a minute; the nudge service also re-evaluates
    // on its own cadence and reads this published value.
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

  // MARK: - Recompute

  private func recompute() {
    let now = Date()
    let dayInfo = now.getDayInfoFor4AMBoundary()
    let spans = StorageManager.shared.fetchTimelineActivity(forDay: dayInfo.dayString)

    let distractionKey = normalizedCategoryKey("Distraction")
    let windowStart = now.addingTimeInterval(-ProductivityPreferences.nudgeWindowSeconds)

    distractedSecondsInNudgeWindow = spans.reduce(0) { acc, span in
      let categoryKey = normalizedCategoryKey(
        span.category.trimmingCharacters(in: .whitespacesAndNewlines))
      guard categoryKey == distractionKey else { return acc }

      let spanStart = Date(timeIntervalSince1970: TimeInterval(span.startTs))
      let spanEnd = Date(timeIntervalSince1970: TimeInterval(span.endTs))
      let overlapStart = max(spanStart, windowStart)
      let overlapEnd = min(spanEnd, now)
      return acc + max(0, overlapEnd.timeIntervalSince(overlapStart))
    }
  }
}
