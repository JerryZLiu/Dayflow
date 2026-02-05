//
//  MainView.swift
//  Dayflow
//
//  Timeline UI with transparent design
//

import SwiftUI
import AVKit
import AVFoundation
import AppKit
import Foundation
import Sentry

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var categoryStore: CategoryStore
    @State var selectedIcon: SidebarIcon = .timeline
    @State var selectedDate = timelineDisplayDate(from: Date())
    @State var showDatePicker = false
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
    @StateObject var videoExpansionState = VideoExpansionState()

    // Track if we've performed the initial scroll to current time
    @State var didInitialScroll = false
    @State var previousDate = timelineDisplayDate(from: Date())
    @State var lastDateNavMethod: String? = nil
    // Minute tick to handle timeline-day rollover (4am boundary): header updates + jump to today
    @State var dayChangeTimer: Timer? = nil
    @State var lastObservedTimelineDay: String = cachedDayStringFormatter.string(from: timelineDisplayDate(from: Date()))
    @State var showCategoryEditor = false
    @State var feedbackModalVisible = false
    @State var feedbackMessage: String = ""
    @State var feedbackShareLogs = true
    @State var feedbackDirection: TimelineRatingDirection? = nil
    @State var feedbackActivitySnapshot: TimelineActivity? = nil
    @State var feedbackMode: TimelineFeedbackMode = .form
    @State var copyTimelineState: TimelineCopyState = .idle
    @State var copyTimelineTask: Task<Void, Never>? = nil
    @State var weeklyTrackedMinutes: Double = 0
    @State var cardsToReviewCount: Int = 0
    @State var showTimelineReview = false
    @State var reviewCountTask: Task<Void, Never>? = nil
    @State var reviewSummaryRefreshToken: Int = 0
    @StateObject var retryCoordinator = RetryCoordinator()
    @State var weeklyHoursFrame: CGRect = .zero
    @State var timelineTimeLabelFrames: [CGRect] = []
    @State var timelineFailureToastPayload: TimelineFailureToastPayload?

    let rateSummaryFooterHeight: CGFloat = 28
    let weeklyHoursFadeDistance: CGFloat = 12
    var rateSummaryFooterInset: CGFloat {
        selectedActivity == nil ? 0 : rateSummaryFooterHeight
    }

    static let maxDateTitleWidth: CGFloat = {
        let referenceText = "Today, Sep 30"
        let font = NSFont(name: "InstrumentSerif-Regular", size: 36) ?? NSFont.systemFont(ofSize: 36)
        let width = referenceText.size(withAttributes: [.font: font]).width
        return ceil(width) + 4 // small buffer so arrows never nudge
    }()
    let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var body: some View {
        mainLayout
    }
}
