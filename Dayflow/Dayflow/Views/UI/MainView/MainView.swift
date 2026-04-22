//
//  MainView.swift
//  Dayflow
//
//  Timeline UI with transparent design
//

import AVFoundation
import AVKit
import AppKit
import Foundation
import Sentry
import SwiftUI

struct MainView: View {
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var categoryStore: CategoryStore
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State var selectedIcon: SidebarIcon = .timeline
  @State var selectedDate = timelineDisplayDate(from: Date())
  @State var cachedTimelineWeekRange: TimelineWeekRange = TimelineWeekRange.containing(
    timelineDisplayDate(from: Date()))
  @State var timelineMode: TimelineMode = .day
  @State var hideWeekCardsDuringModeSwitch = false
  @State var showDatePicker = false
  // Arrowless calendar card anchored to the timeline header's calendar pill
  // (distinct from `showDatePicker`, which drives a modal sheet used only by
  // the daily-view date pill).
  @State var showTimelineCalendarPopover = false
  @State var timelineCalendarButtonFrame: CGRect = .zero
  @State var selectedActivity: TimelineActivity? = nil
  @State var scrollToNowTick: Int = 0
  @State var hasAnyActivities: Bool = true
  @State var refreshActivitiesTrigger: Int = 0
  @ObservedObject var inactivity = InactivityMonitor.shared

  // Animation states for orchestrated entrance - Emil Kowalski principles
  @State var logoScale: CGFloat = 0.8
  @State var logoOpacity: Double = 0
  @State var timelineOffset: CGFloat = -20
  @State var timelineOpacity: Double = 0
  @State var sidebarOffset: CGFloat = -30
  @State var sidebarOpacity: Double = 0
  @State var contentOpacity: Double = 0

  // Hero animation for video expansion (Emil Kowalski: shared element transitions)
  @Namespace var videoHeroNamespace
  @Namespace var timelineModeSwitchNamespace
  @StateObject var videoExpansionState = VideoExpansionState()

  // Track if we've performed the initial scroll to current time
  @State var didInitialScroll = false
  @State var previousDate = timelineDisplayDate(from: Date())
  @State var lastDateNavMethod: String? = nil
  // Minute tick to handle timeline-day rollover (4am boundary): header updates + jump to today
  @State var dayChangeTimer: Timer? = nil
  @State var lastObservedTimelineDay: String = cachedDayStringFormatter.string(
    from: timelineDisplayDate(from: Date()))
  @State var showCategoryEditor = false
  @State var feedbackModalVisible = false
  @State var feedbackMessage: String = ""
  @State var feedbackShareLogs = true
  @State var feedbackDirection: TimelineRatingDirection? = nil
  @State var feedbackActivitySnapshot: TimelineActivity? = nil
  @State var feedbackMode: TimelineFeedbackMode = .form
  @State var copyTimelineState: TimelineCopyState = .idle
  @State var copyTimelineTask: Task<Void, Never>? = nil
  @State var deleteTimelineTask: Task<Void, Never>? = nil
  @State var timelineHeaderTrailingWidth: CGFloat = 120
  @State var weeklyTrackedMinutes: Double = 0
  @State var cardsToReviewCount: Int = 0
  @State var showTimelineReview = false
  @State var reviewCountTask: Task<Void, Never>? = nil
  @State var reviewSummaryRefreshToken: Int = 0
  @StateObject var retryCoordinator = RetryCoordinator()
  @State var weeklyHoursFrame: CGRect = .zero
  @State var timelineTimeLabelFrames: [CGRect] = []
  @State var weeklyHoursIntersectsCard: Bool = false
  @State var timelineFailureToastPayload: TimelineFailureToastPayload?
  @State var showScreenRecordingPermissionNotice = false
  @State var didDismissScreenRecordingPermissionNoticeThisSession = false

  let rateSummaryFooterHeight: CGFloat = 28
  let weeklyHoursFadeDistance: CGFloat = 12
  var rateSummaryFooterInset: CGFloat {
    selectedActivity == nil ? 0 : rateSummaryFooterHeight
  }
  let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  var body: some View {
    mainLayout
      .onReceive(NotificationCenter.default.publisher(for: .navigateToDaily)) { notification in
        let wasAlreadyOnDaily = selectedIcon == .daily
        if let dayString = notification.userInfo?["day"] as? String,
          let dayDate = DateFormatter.yyyyMMdd.date(from: dayString)
        {
          setSelectedDate(dayDate)
        }
        if wasAlreadyOnDaily {
          consumePendingDailyRecapOpenIfNeeded(source: "daily_notification_navigation")
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
          selectedIcon = .daily
        }
      }
  }

  @discardableResult
  func consumePendingDailyRecapOpenIfNeeded(source: String) -> Bool {
    guard let pendingContext = NotificationBadgeManager.shared.consumePendingDailyRecapContext()
    else {
      return false
    }

    AnalyticsService.shared.capture(
      DailyBadgeExperiment.openedAfterReadyEvent,
      [
        "target_day": pendingContext.targetDay ?? "unknown",
        "experiment": DailyBadgeExperiment.featureFlagKey,
        "variant": pendingContext.experimentVariant,
        "badge_enabled": pendingContext.experimentVariant == DailyBadgeExperiment.badgeVariant,
        "source": source,
      ])
    return true
  }
}
