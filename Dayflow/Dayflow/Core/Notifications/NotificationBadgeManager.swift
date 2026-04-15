//
//  NotificationBadgeManager.swift
//  Dayflow
//
//  Manages badge state for Dock icon and sidebar indicator.
//

import AppKit
import SwiftUI

enum DailyBadgeExperiment {
  static let featureFlagKey = "daily_notification_badge_exp"
  static let controlVariant = "control"
  static let badgeVariant = "badge"
  static let exposureEvent = "daily_badge_exposure"
  static let shownEvent = "daily_badge_shown"
  static let openedAfterReadyEvent = "daily_opened_after_recap_ready"
}

@MainActor
final class NotificationBadgeManager: ObservableObject {
  struct PendingDailyRecapContext {
    let targetDay: String?
    let experimentVariant: String
  }

  static let shared = NotificationBadgeManager()

  /// Whether there's a pending journal reminder the user hasn't acknowledged
  @Published private(set) var hasPendingJournalReminder: Bool = false

  /// Whether there's a visible Daily badge the user hasn't acknowledged yet.
  @Published private(set) var hasPendingDailyRecap: Bool = false

  private let defaults = UserDefaults.standard
  private let pendingDailyReadyKey = "notificationBadge.pendingDailyReady"
  private let pendingDailyVisibleKey = "notificationBadge.pendingDailyVisible"
  private let pendingDailyTargetDayKey = "notificationBadge.pendingDailyTargetDay"
  private let pendingDailyVariantKey = "notificationBadge.pendingDailyVariant"

  private var hasPendingDailyReady = false
  private var pendingDailyTargetDay: String?
  private var pendingDailyExperimentVariant: String?

  private init() {
    restoreDailyState()
    refreshDockBadge()
  }

  // MARK: - Public Methods

  /// Shows the journal reminder badge in both the Dock and sidebar.
  func showJournalBadge() {
    hasPendingJournalReminder = true
    refreshDockBadge()
  }

  /// Clears the journal reminder badge from both the Dock and sidebar.
  func clearJournalBadge() {
    hasPendingJournalReminder = false
    refreshDockBadge()
  }

  /// Tracks that a Daily recap is ready and optionally shows a visible badge for it.
  func registerDailyRecapReady(
    forDay day: String,
    experimentVariant: String,
    showBadge: Bool
  ) {
    hasPendingDailyReady = true
    hasPendingDailyRecap = showBadge
    pendingDailyTargetDay = day.isEmpty ? nil : day
    pendingDailyExperimentVariant = experimentVariant
    persistDailyState()
    refreshDockBadge()
  }

  /// Clears the visible Daily badge from both the Dock and sidebar.
  func clearDailyBadge() {
    hasPendingDailyRecap = false
    persistDailyState()
    refreshDockBadge()
  }

  /// Returns the pending Daily recap context, then marks it as consumed.
  func consumePendingDailyRecapContext() -> PendingDailyRecapContext? {
    guard hasPendingDailyReady else { return nil }

    let context = PendingDailyRecapContext(
      targetDay: pendingDailyTargetDay,
      experimentVariant: pendingDailyExperimentVariant ?? DailyBadgeExperiment.controlVariant
    )
    clearPendingDailyRecap()
    return context
  }

  private func refreshDockBadge() {
    let hasPendingBadge = hasPendingJournalReminder || hasPendingDailyRecap
    NSApplication.shared.dockTile.badgeLabel = hasPendingBadge ? "1" : nil
  }

  private func clearPendingDailyRecap() {
    hasPendingDailyReady = false
    hasPendingDailyRecap = false
    pendingDailyTargetDay = nil
    pendingDailyExperimentVariant = nil
    persistDailyState()
    refreshDockBadge()
  }

  private func persistDailyState() {
    defaults.set(hasPendingDailyReady, forKey: pendingDailyReadyKey)
    defaults.set(hasPendingDailyRecap, forKey: pendingDailyVisibleKey)

    if let pendingDailyTargetDay {
      defaults.set(pendingDailyTargetDay, forKey: pendingDailyTargetDayKey)
    } else {
      defaults.removeObject(forKey: pendingDailyTargetDayKey)
    }

    if let pendingDailyExperimentVariant {
      defaults.set(pendingDailyExperimentVariant, forKey: pendingDailyVariantKey)
    } else {
      defaults.removeObject(forKey: pendingDailyVariantKey)
    }
  }

  private func restoreDailyState() {
    hasPendingDailyReady = defaults.bool(forKey: pendingDailyReadyKey)
    hasPendingDailyRecap = defaults.bool(forKey: pendingDailyVisibleKey)
    pendingDailyTargetDay = defaults.string(forKey: pendingDailyTargetDayKey)
    pendingDailyExperimentVariant = defaults.string(forKey: pendingDailyVariantKey)
  }
}
