import AppKit
import Sentry
import SwiftUI

private enum TimelineHeaderTrackedElement {
  static let dateSection = "date_section"
  static let pauseControl = "pause_control"
}

private struct TimelineHeaderFramesPreferenceKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]

  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

extension View {
  fileprivate func trackTimelineHeaderFrame(_ id: String) -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TimelineHeaderFramesPreferenceKey.self,
          value: [id: proxy.frame(in: .named("TimelineHeaderSpace"))]
        )
      }
    )
  }
}

extension MainView {
  var mainLayout: some View {
    contentStack
      .padding([.top, .trailing, .bottom], 15)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.clear)
      .ignoresSafeArea()
      // Hero animation overlay for video expansion (Emil Kowalski: shared element transitions)
      .overlay { overlayContent }
      .overlay(alignment: .bottomTrailing) {
        if let payload = timelineFailureToastPayload {
          TimelineFailureToastView(
            message: payload.message,
            onOpenSettings: { handleTimelineFailureToastOpenSettings(payload) },
            onDismiss: { handleTimelineFailureToastDismiss(payload) }
          )
          .padding(.trailing, 24)
          .padding(.bottom, 24)
          .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
      .sheet(isPresented: $showDatePicker) {
        DatePickerSheet(
          selectedDate: Binding(
            get: { selectedDate },
            set: {
              lastDateNavMethod = "picker"
              setSelectedDate($0)
            }
          ),
          isPresented: $showDatePicker
        )
      }
      .onAppear {
        // screen viewed and initial timeline view
        AnalyticsService.shared.screen("timeline")
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture(
            "timeline_viewed", ["date_bucket": dayString(selectedDate)])
        }
        // Orchestrated entrance animations following Emil Kowalski principles
        // Fast, under 300ms, natural spring motion

        // Logo appears first with scale and fade
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)) {
          logoScale = 1.0
          logoOpacity = 1
        }

        // Timeline text slides in from left
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.1)) {
          timelineOffset = 0
          timelineOpacity = 1
        }

        // Sidebar slides up
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.15)) {
          sidebarOffset = 0
          sidebarOpacity = 1
        }

        // Main content fades in last
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.2)) {
          contentOpacity = 1
        }

        // Perform initial scroll to current time on cold start
        if !didInitialScroll {
          performInitialScrollIfNeeded()
        }

        // Start minute-level tick to detect timeline-day rollover (4am boundary)
        startDayChangeTimer()

        // Load weekly activity hours
        loadWeeklyTrackedMinutes()
        updateCardsToReviewCount()
      }
      // Trigger reset when idle fired and timeline is visible
      .onChange(of: inactivity.pendingReset) { _, fired in
        if fired, selectedIcon != .settings {
          performIdleResetAndScroll()
          InactivityMonitor.shared.markHandledIfPending()
        }
      }
      .onChange(of: selectedIcon) { _, newIcon in
        // Clear journal notification badge when navigating to journal
        if newIcon == .journal {
          NotificationBadgeManager.shared.clearBadge()
        }

        // tab selected + screen viewed
        let tabName: String
        switch newIcon {
        case .timeline: tabName = "timeline"
        case .daily: tabName = "daily"
        case .weekly: tabName = "weekly"
        case .chat: tabName = "dashboard"
        case .journal: tabName = "journal"
        case .bug: tabName = "bug_report"
        case .settings: tabName = "settings"
        }

        // Add Sentry context for app state tracking
        SentryHelper.configureScope { scope in
          scope.setContext(
            value: [
              "active_view": tabName,
              "selected_date": dayString(selectedDate),
              "is_recording": appState.isRecording,
            ], key: "app_state")
        }

        // Add breadcrumb for view navigation
        let navBreadcrumb = Breadcrumb(level: .info, category: "navigation")
        navBreadcrumb.message = "Navigated to \(tabName)"
        navBreadcrumb.data = ["view": tabName]
        SentryHelper.addBreadcrumb(navBreadcrumb)

        AnalyticsService.shared.capture("tab_selected", ["tab": tabName])
        AnalyticsService.shared.screen(tabName)
        if newIcon == .timeline {
          AnalyticsService.shared.withSampling(probability: 0.01) {
            AnalyticsService.shared.capture(
              "timeline_viewed", ["date_bucket": dayString(selectedDate)])
          }
          updateCardsToReviewCount()
        } else {
          showTimelineReview = false
        }
      }
      // Handle navigation from journal reminder notification tap
      .onReceive(NotificationCenter.default.publisher(for: .navigateToJournal)) { _ in
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
          selectedIcon = .journal
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .showTimelineFailureToast)) {
        notification in
        guard let userInfo = notification.userInfo,
          let payload = TimelineFailureToastPayload(userInfo: userInfo)
        else {
          return
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
          timelineFailureToastPayload = payload
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { notification in
        guard selectedIcon == .timeline else { return }

        if let refreshedDay = notification.userInfo?["dayString"] as? String {
          let selectedTimelineDay = DateFormatter.yyyyMMdd.string(
            from: timelineDisplayDate(from: selectedDate, now: Date())
          )
          guard refreshedDay == selectedTimelineDay else { return }
        }

        updateCardsToReviewCount()
      }
      .onChange(of: selectedDate) { _, newDate in
        // If changed via picker, emit navigation now
        if let method = lastDateNavMethod, method == "picker" {
          AnalyticsService.shared.capture(
            "date_navigation",
            [
              "method": method,
              "from_day": dayString(previousDate),
              "to_day": dayString(newDate),
            ])
        }
        previousDate = newDate
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(newDate)])
        }
        updateCardsToReviewCount()
      }
      .onChange(of: refreshActivitiesTrigger) {
        updateCardsToReviewCount()
      }
      .onChange(of: selectedActivity?.id) {
        dismissFeedbackModal(animated: false)
        guard let a = selectedActivity else { return }
        let dur = a.endTime.timeIntervalSince(a.startTime)
        AnalyticsService.shared.capture(
          "activity_card_opened",
          [
            "activity_type": a.category,
            "duration_bucket": AnalyticsService.shared.secondsBucket(dur),
            "has_video": a.videoSummaryURL != nil,
          ])
      }
      // If user returns from Settings and a reset was pending, perform it once
      .onChange(of: selectedIcon) { _, newIcon in
        if newIcon != .settings, inactivity.pendingReset {
          performIdleResetAndScroll()
          InactivityMonitor.shared.markHandledIfPending()
        }
      }
      .onDisappear {
        // Safety: stop timer if view disappears
        stopDayChangeTimer()
        copyTimelineTask?.cancel()
        deleteTimelineTask?.cancel()
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        // Check if day changed while app was backgrounded
        handleMinuteTickForDayChange()
        // Ensure timer is running
        if dayChangeTimer == nil {
          startDayChangeTimer()
        }
        // Refresh weekly hours in case activities were added
        loadWeeklyTrackedMinutes()
      }
      .overlay { categoryEditorOverlay }
      .environmentObject(retryCoordinator)
  }

  private func handleTimelineFailureToastOpenSettings(_ payload: TimelineFailureToastPayload) {
    AnalyticsService.shared.capture(
      "llm_timeline_failure_toast_clicked_settings", payload.analyticsProps)
    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
      selectedIcon = .settings
      timelineFailureToastPayload = nil
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NotificationCenter.default.post(name: .openProvidersSettings, object: nil)
    }
  }

  private func handleTimelineFailureToastDismiss(_ payload: TimelineFailureToastPayload) {
    AnalyticsService.shared.capture("llm_timeline_failure_toast_dismissed", payload.analyticsProps)
    withAnimation(.spring(response: 0.25, dampingFraction: 0.92)) {
      timelineFailureToastPayload = nil
    }
  }

  private var contentStack: some View {
    // Two-column layout: left logo + sidebar; right white panel with header, filters, timeline
    HStack(alignment: .top, spacing: 0) {
      leftColumn
      rightPanel
    }
    .padding(0)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var leftColumn: some View {
    // Left column: Logo on top, sidebar centered
    VStack(spacing: 0) {
      // Logo area (keeps same animation)
      LogoBadgeView(imageName: "DayflowLogoMainApp", size: 36)
        .frame(height: 100)
        .frame(maxWidth: .infinity)
        .scaleEffect(logoScale)
        .opacity(logoOpacity)

      Spacer(minLength: 0)

      // Sidebar in fixed-width gutter
      VStack {
        Spacer()
        SidebarView(selectedIcon: $selectedIcon)
          .frame(maxWidth: .infinity, alignment: .center)
          .offset(y: sidebarOffset)
          .opacity(sidebarOpacity)
        Spacer()
      }
      Spacer(minLength: 0)
    }
    .frame(width: 100)
    .fixedSize(horizontal: true, vertical: false)
    .frame(maxHeight: .infinity)
    .layoutPriority(1)
  }

  @ViewBuilder
  private var rightPanel: some View {
    // Right column: Main white panel including header + content
    ZStack {
      switch selectedIcon {
      case .settings:
        SettingsView()
          .padding(15)
      case .chat:
        ChatPanelView()
      case .daily:
        DailyView(selectedDate: $selectedDate)
      case .weekly:
        WeeklyView()
      case .journal:
        JournalView()
          .padding(15)
      case .bug:
        BugReportView()
          .padding(15)
      case .timeline:
        GeometryReader { geo in
          timelinePanel(geo: geo)
        }
      }
    }
    .padding(0)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(mainPanelBackground)
  }

  private var mainPanelBackground: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 0)
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white)
        .blendMode(.destinationOut)
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.white.opacity(0.22))
    }
    .compositingGroup()
  }

  private func timelinePanel(geo: GeometryProxy) -> some View {
    HStack(alignment: .top, spacing: 0) {
      timelineLeftColumn
        .zIndex(1)
      Rectangle()
        .fill(Color(hex: "ECECEC"))
        .frame(width: 1)
        .frame(maxHeight: .infinity)
      timelineRightColumn(geo: geo)
    }
    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
  }

  private var timelineLeftColumn: some View {
    ZStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 18) {
        timelineHeader
        timelineContent
      }
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.top, 15)
      .padding(.bottom, 15)
      .padding(.leading, 15)
      .padding(.trailing, 5)

      timelineFooter
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .coordinateSpace(name: "TimelinePane")
    .onPreferenceChange(TimelineTimeLabelFramesPreferenceKey.self) { frames in
      timelineTimeLabelFrames = frames
    }
    .onPreferenceChange(WeeklyHoursFramePreferenceKey.self) { frame in
      weeklyHoursFrame = frame
    }
  }

  private var timelineHeader: some View {
    HStack(alignment: .center) {
      HStack(spacing: 12) {
        HStack(spacing: 3) {
          Button(action: {
            let from = selectedDate
            let to =
              Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            previousDate = selectedDate
            setSelectedDate(to)
            lastDateNavMethod = "prev"
            AnalyticsService.shared.capture(
              "date_navigation",
              [
                "method": "prev",
                "from_day": dayString(from),
                "to_day": dayString(to),
              ])
          }) {
            Image("CalendarLeftButton")
              .resizable()
              .scaledToFit()
              .frame(width: 26, height: 26)
          }
          .buttonStyle(PlainButtonStyle())
          .hoverScaleEffect(scale: 1.02)
          .pointingHandCursorOnHover(reassertOnPressEnd: true)

          Button(action: {
            guard canNavigateForward(from: selectedDate) else { return }
            let from = selectedDate
            let tomorrow =
              Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
            previousDate = selectedDate
            setSelectedDate(tomorrow)
            lastDateNavMethod = "next"
            AnalyticsService.shared.capture(
              "date_navigation",
              [
                "method": "next",
                "from_day": dayString(from),
                "to_day": dayString(tomorrow),
              ])
          }) {
            Image("CalendarRightButton")
              .resizable()
              .scaledToFit()
              .frame(width: 26, height: 26)
          }
          .buttonStyle(PlainButtonStyle())
          .disabled(!canNavigateForward(from: selectedDate))
          .hoverScaleEffect(
            enabled: canNavigateForward(from: selectedDate),
            scale: 1.02
          )
          .pointingHandCursorOnHover(
            enabled: canNavigateForward(from: selectedDate),
            reassertOnPressEnd: true
          )
        }

        HStack(spacing: 12) {
          Text(formatDateForDisplay(selectedDate))
            .font(.custom("InstrumentSerif-Regular", size: 36))
            .foregroundColor(Color.black)
            .frame(width: Self.maxDateTitleWidth, alignment: .leading)

          if !timelineIsToday(selectedDate) {
            Button(action: {
              let from = selectedDate
              let today = timelineDisplayDate(from: Date())
              previousDate = selectedDate
              setSelectedDate(today)
              lastDateNavMethod = "today"
              AnalyticsService.shared.capture(
                "date_navigation",
                [
                  "method": "today",
                  "from_day": dayString(from),
                  "to_day": dayString(today),
                ])
            }) {
              Text("Today")
                .font(Font.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "E8854A"))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(hex: "E8854A").opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
            .hoverScaleEffect(scale: 1.04)
            .pointingHandCursorOnHover(reassertOnPressEnd: true)
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
          }
        }
        .opacity(shouldHideTimelineDateSection ? 0 : 1)
        .allowsHitTesting(!shouldHideTimelineDateSection)
        .trackTimelineHeaderFrame(TimelineHeaderTrackedElement.dateSection)
      }
      .fixedSize(horizontal: true, vertical: false)
      .offset(x: timelineOffset)
      .opacity(timelineOpacity)

      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .trailing) {
      PausePillView()
        .trackTimelineHeaderFrame(TimelineHeaderTrackedElement.pauseControl)
    }
    .padding(.horizontal, 10)
    .coordinateSpace(name: "TimelineHeaderSpace")
    .onPreferenceChange(TimelineHeaderFramesPreferenceKey.self) { frames in
      updateTimelineHeaderOverlap(frames)
    }
    .background(
      GeometryReader { geo in
        Color.clear.onChange(of: geo.size.width) { _, newWidth in
          headerWidth = newWidth
        }
        .onAppear { headerWidth = geo.size.width }
      }
    )
  }

  private func updateTimelineHeaderOverlap(_ frames: [String: CGRect]) {
    guard
      let dateFrame = frames[TimelineHeaderTrackedElement.dateSection],
      let pauseFrame = frames[TimelineHeaderTrackedElement.pauseControl]
    else {
      if shouldHideTimelineDateSection {
        withAnimation(.easeOut(duration: 0.18)) {
          shouldHideTimelineDateSection = false
        }
      }
      return
    }

    let pausePillCollapsedRestoreWidth: CGFloat = 76
    let isOverlapping = dateFrame.intersects(pauseFrame)
    let isPausePillCollapsed = pauseFrame.width <= pausePillCollapsedRestoreWidth

    // Once the date hides, keep it hidden until the pause pill is basically back
    // to its idle width so the text doesn't pop back in mid-collapse.
    let shouldKeepHiddenWhileClosing =
      shouldHideTimelineDateSection && !isOverlapping && !isPausePillCollapsed

    let shouldHide = isOverlapping || shouldKeepHiddenWhileClosing
    guard shouldHide != shouldHideTimelineDateSection else { return }

    withAnimation(.easeOut(duration: 0.18)) {
      shouldHideTimelineDateSection = shouldHide
    }
  }

  private var timelineContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      TabFilterBar(
        categories: categoryStore.editableCategories,
        idleCategory: categoryStore.idleCategory,
        onManageCategories: { showCategoryEditor = true }
      )
      .padding(.leading, 10)
      .opacity(contentOpacity)

      CanvasTimelineDataView(
        selectedDate: $selectedDate,
        selectedActivity: $selectedActivity,
        scrollToNowTick: $scrollToNowTick,
        hasAnyActivities: $hasAnyActivities,
        refreshTrigger: $refreshActivitiesTrigger,
        weeklyHoursFrame: weeklyHoursFrame,
        weeklyHoursIntersectsCard: $weeklyHoursIntersectsCard
      )
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
      .environmentObject(categoryStore)
      .opacity(contentOpacity)
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var timelineFooter: some View {
    VStack(spacing: 0) {
      Spacer()

      // Bottom footer bar - all items bottom-aligned
      ZStack(alignment: .bottom) {
        // Left & right items
        HStack(alignment: .bottom) {
          weeklyHoursText
            .opacity(contentOpacity * weeklyHoursFadeOpacity * (weeklyHoursIntersectsCard ? 0 : 1))

          Spacer()

          copyTimelineButton
            .opacity(contentOpacity)
        }
        .padding(.horizontal, 24)

        // Centered badge (bottom-aligned with text)
        if cardsToReviewCount > 0 {
          CardsToReviewButton(count: cardsToReviewCount) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              showTimelineReview = true
            }
          }
          .opacity(contentOpacity)
        }
      }
      .padding(.bottom, 17)
    }
    .allowsHitTesting(true)
  }

  private func timelineRightColumn(geo: GeometryProxy) -> some View {
    // Right column: activity detail card OR day summary — spans full height
    ZStack(alignment: .topLeading) {
      Color.white.opacity(0.7)

      if let activity = selectedActivity {
        // Show activity details when a card is selected
        ZStack(alignment: .bottom) {
          ActivityCard(
            activity: activity,
            maxHeight: geo.size.height,
            scrollSummary: true,
            hasAnyActivities: hasAnyActivities,
            onCategoryChange: { category, activity in
              handleCategoryChange(to: category, for: activity)
            },
            onNavigateToCategoryEditor: {
              showCategoryEditor = true
            },
            onRetryBatchCompleted: { batchId in
              refreshActivitiesTrigger &+= 1
              if selectedActivity?.batchId == batchId {
                selectedActivity = nil
              }
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(!feedbackModalVisible)
          .padding(.bottom, rateSummaryFooterHeight)

          if !feedbackModalVisible {
            TimelineRateSummaryView(
              activityID: activity.id,
              onRate: handleTimelineRating,
              onDelete: handleTimelineDelete
            )
            .frame(maxWidth: .infinity)
            .allowsHitTesting(!feedbackModalVisible)
            .transition(
              .move(edge: .bottom)
                .combined(with: .opacity)
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
      } else {
        DaySummaryView(
          selectedDate: selectedDate,
          categories: categoryStore.categories,
          storageManager: StorageManager.shared,
          cardsToReviewCount: cardsToReviewCount,
          reviewRefreshToken: reviewSummaryRefreshToken,
          onReviewTap: {
            guard cardsToReviewCount > 0 else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              showTimelineReview = true
            }
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
      }
      if let direction = feedbackDirection, feedbackModalVisible {
        TimelineFeedbackModal(
          message: $feedbackMessage,
          shareLogs: $feedbackShareLogs,
          direction: direction,
          mode: feedbackMode,
          content: .timeline,
          onSubmit: handleFeedbackSubmit,
          onClose: { dismissFeedbackModal() }
        )
        .padding(.leading, 24)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(2)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(contentOpacity)
    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: selectedActivity?.id)
    .clipShape(
      UnevenRoundedRectangle(
        cornerRadii: .init(
          topLeading: 0,
          bottomLeading: 0, bottomTrailing: 8, topTrailing: 8
        )
      )
    )
    .contentShape(
      UnevenRoundedRectangle(
        cornerRadii: .init(
          topLeading: 0,
          bottomLeading: 0, bottomTrailing: 8, topTrailing: 8
        )
      )
    )
    .frame(minWidth: 240, idealWidth: 358, maxWidth: 358, maxHeight: .infinity)
  }

  private var overlayContent: some View {
    ZStack {
      VideoExpansionOverlay(
        expansionState: videoExpansionState,
        namespace: videoHeroNamespace
      )

      if selectedIcon == .timeline, showTimelineReview {
        TimelineReviewOverlay(
          isPresented: $showTimelineReview,
          selectedDate: selectedDate
        ) {
          updateCardsToReviewCount()
          reviewSummaryRefreshToken &+= 1
        }
        .environmentObject(categoryStore)
        .transition(.opacity)
        .zIndex(2)
      }
    }
  }

  @ViewBuilder
  private var categoryEditorOverlay: some View {
    if showCategoryEditor {
      ColorOrganizerRoot(
        presentationStyle: .sheet,
        onDismiss: { showCategoryEditor = false }, completionButtonTitle: "Save", showsTitles: true
      )
      .environmentObject(categoryStore)
      // Removed .contentShape(Rectangle()) and .onTapGesture to allow keyboard input
    }
  }

  private var weeklyHoursFadeOpacity: Double {
    guard weeklyHoursFrame != .zero, !timelineTimeLabelFrames.isEmpty else { return 1 }
    var maxOverlap: CGFloat = 0
    for frame in timelineTimeLabelFrames {
      let intersection = weeklyHoursFrame.intersection(frame)
      if !intersection.isNull {
        maxOverlap = max(maxOverlap, intersection.height)
      }
    }
    guard maxOverlap > 0 else { return 1 }
    let clamped = min(maxOverlap, weeklyHoursFadeDistance)
    return Double(1 - (clamped / weeklyHoursFadeDistance))
  }

  private var weeklyHoursText: some View {
    let hours = Int(weeklyTrackedMinutes / 60)
    let textColor = Color(red: 0.84, green: 0.65, blue: 0.52)

    return HStack(spacing: 4) {
      Text("\(hours) hours")
        .font(Font.custom("Nunito", size: 10).weight(.bold))
        .foregroundColor(textColor)
      Text("tracked this week")
        .font(Font.custom("Nunito", size: 10).weight(.regular))
        .foregroundColor(textColor)
    }
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: WeeklyHoursFramePreferenceKey.self,
          value: proxy.frame(in: .named("TimelinePane"))
        )
      }
    )
  }

  private var copyTimelineButton: some View {
    let background = Color(red: 0.99, green: 0.93, blue: 0.88)
    let stroke = Color(red: 0.97, green: 0.89, blue: 0.81)
    let textColor = Color(red: 0.84, green: 0.65, blue: 0.52)

    // Slide up + fade: no text scaling (scaling distorts letterforms)
    let enterTransition = AnyTransition.opacity
      .combined(with: .move(edge: .bottom))
    let exitTransition = AnyTransition.opacity
      .combined(with: .move(edge: .top))

    return Button(action: copyTimelineToClipboard) {
      ZStack {
        if copyTimelineState == .copying {
          ProgressView()
            .scaleEffect(0.6)
            .progressViewStyle(CircularProgressViewStyle(tint: textColor))
            .transition(.asymmetric(insertion: enterTransition, removal: exitTransition))
        } else if copyTimelineState == .copied {
          HStack(spacing: 4) {
            Image(systemName: "checkmark")
              .font(.system(size: 11.5, weight: .medium))
            Text("Copied")
              .font(Font.custom("Nunito", size: 11.5).weight(.medium))
          }
          .transition(.asymmetric(insertion: enterTransition, removal: exitTransition))
        } else {
          HStack(spacing: 4) {
            Image("Copy")
              .resizable()
              .interpolation(.high)
              .renderingMode(.template)
              .scaledToFit()
              .frame(width: 11.5, height: 11.5)
            Text("Copy timeline")
              .font(Font.custom("Nunito", size: 11.5).weight(.medium))
          }
          .transition(.asymmetric(insertion: enterTransition, removal: exitTransition))
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.85), value: copyTimelineState)
      .frame(width: 104, height: 23)
      .foregroundColor(textColor)
      .background(background)
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .inset(by: 0.5)
          .stroke(stroke, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(ShrinkButtonStyle())
    .disabled(copyTimelineState == .copying)
    .hoverScaleEffect(
      enabled: copyTimelineState != .copying,
      scale: 1.02
    )
    .pointingHandCursorOnHover(
      enabled: copyTimelineState != .copying,
      reassertOnPressEnd: true
    )
    .accessibilityLabel(Text("Copy timeline to clipboard"))
  }
}

private struct ShrinkButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

private struct TimelineFailureToastView: View {
  let message: String
  let onOpenSettings: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 14))
          .foregroundColor(Color(hex: "C04A00"))
          .padding(.top, 2)

        Text(message)
          .font(.custom("Nunito", size: 13))
          .foregroundColor(.black.opacity(0.82))
          .fixedSize(horizontal: false, vertical: true)

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.black.opacity(0.45))
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .hoverScaleEffect(scale: 1.02)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
      }

      DayflowSurfaceButton(
        action: onOpenSettings,
        content: {
          HStack(spacing: 6) {
            Image(systemName: "gearshape")
              .font(.system(size: 12))
            Text("Open Provider Settings")
              .font(.custom("Nunito", size: 12))
              .fontWeight(.semibold)
          }
        },
        background: Color(red: 0.25, green: 0.17, blue: 0),
        foreground: .white,
        borderColor: .clear,
        cornerRadius: 8,
        horizontalPadding: 14,
        verticalPadding: 8,
        showOverlayStroke: true
      )
    }
    .padding(14)
    .frame(width: 360, alignment: .leading)
    .background(Color(hex: "FFF8F2"))
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(hex: "F3D9C2"), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 6)
  }
}
