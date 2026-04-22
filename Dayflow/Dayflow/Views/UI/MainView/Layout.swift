import AppKit
import Sentry
import SwiftUI

private struct TimelineHeaderTrailingWidthPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct TimelineCalendarButtonFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

extension View {
  fileprivate func trackTimelineHeaderTrailingWidth() -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TimelineHeaderTrailingWidthPreferenceKey.self,
          value: proxy.size.width
        )
      }
    )
  }

  fileprivate func trackTimelineCalendarButtonFrame() -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TimelineCalendarButtonFramePreferenceKey.self,
          value: proxy.frame(in: .named("TimelinePanel"))
        )
      }
    )
  }
}

// Priority-based visibility gates for the timeline header's leading controls.
// Computed once per render from available width + trailing reservation; every
// conditional in `timelineLeadingControls` reads this, so the full header
// renders as a single variant (no `ViewThatFits` shuffle).
private struct TimelineHeaderVisibility {
  var showTodayButton: Bool
  var showDayWeekToggle: Bool
  var showInlineDate: Bool
}

extension MainView {
  // `mainLayout` is split into two chained computed properties because the
  // full modifier stack (20+ modifiers, several large inline closures) was
  // exceeding Swift's per-expression type-check budget. Each `some View`
  // boundary gives the solver a fresh, opaque anchor so the inner chain is
  // type-checked in isolation. Closure bodies that ran long (onAppear, the
  // tab-selection onChange, selectedDate onChange, toast overlay) are also
  // extracted to named methods / computed properties below for the same
  // reason.
  var mainLayout: some View {
    mainLayoutCore
      .environmentObject(retryCoordinator)
  }

  // Layer 1: layout + visual overlays.
  private var mainLayoutWithOverlays: some View {
    contentStack
      .padding([.top, .trailing, .bottom], 15)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.clear)
      .ignoresSafeArea()
      // Hero animation overlay for video expansion (Emil Kowalski: shared element transitions)
      .overlay { overlayContent }
      .overlay(alignment: .bottomTrailing) { timelineFailureToastOverlayContent }
      .overlay(alignment: .bottomTrailing) { screenRecordingPermissionNoticeOverlayContent }
      .overlay { categoryEditorOverlay }
  }

  // Layer 2: sheet + lifecycle + notifications + state-change reactions.
  private var mainLayoutCore: some View {
    mainLayoutWithOverlays
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
      .onAppear(perform: performMainLayoutOnAppear)
      .onDisappear(perform: performMainLayoutOnDisappear)
      .onChange(of: inactivity.pendingReset) { _, fired in
        if fired, selectedIcon != .settings {
          performIdleResetAndScroll()
          InactivityMonitor.shared.markHandledIfPending()
        }
      }
      .onChange(of: selectedIcon) { _, newIcon in
        handleTabSelectionChange(newIcon)
      }
      .onChange(of: selectedDate) { _, newDate in
        handleSelectedDateChange(newDate)
      }
      .onChange(of: refreshActivitiesTrigger) {
        updateCardsToReviewCount()
        loadWeeklyTrackedMinutes()
      }
      .onChange(of: selectedActivity?.id) {
        handleSelectedActivityIdChange()
      }
      // Second observer on selectedIcon: if user returns from Settings and a
      // reset was pending, perform it once. SwiftUI allows multiple onChange
      // handlers for the same value — they fire in declaration order.
      .onChange(of: selectedIcon) { _, newIcon in
        if newIcon != .settings, inactivity.pendingReset {
          performIdleResetAndScroll()
          InactivityMonitor.shared.markHandledIfPending()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .navigateToJournal)) { _ in
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
          selectedIcon = .weekly
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .showTimelineFailureToast)) {
        handleShowTimelineFailureToastNotification($0)
      }
      .onReceive(NotificationCenter.default.publisher(for: .showScreenRecordingPermissionNotice)) {
        handleShowScreenRecordingPermissionNoticeNotification($0)
      }
      .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) {
        handleTimelineDataUpdatedNotification($0)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        handleAppDidBecomeActive()
      }
  }

  // MARK: - Extracted overlays and event handlers
  //
  // Each of these corresponds to a closure or inline view that used to live
  // inline in the `mainLayout` modifier chain. Extraction is load-bearing:
  // without it, the combined type-check of `mainLayout`'s modifier chain +
  // each closure's body exceeded Swift's per-expression solver budget.

  @ViewBuilder
  private var timelineFailureToastOverlayContent: some View {
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

  @ViewBuilder
  private var screenRecordingPermissionNoticeOverlayContent: some View {
    if showScreenRecordingPermissionNotice {
      ScreenRecordingPermissionNoticeView(
        onOpenSettings: handleScreenRecordingPermissionNoticeOpenSettings,
        onDismiss: handleScreenRecordingPermissionNoticeDismiss
      )
      .padding(.trailing, 24)
      .padding(.bottom, 24)
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }
  }

  private func performMainLayoutOnAppear() {
    syncCurrentUIContext()

    // screen viewed and initial timeline view
    AnalyticsService.shared.screen("timeline")
    AnalyticsService.shared.withSampling(probability: 0.01) {
      AnalyticsService.shared.capture(
        "timeline_viewed", ["date_bucket": dayString(selectedDate)])
    }
    // Orchestrated entrance animations following Emil Kowalski principles —
    // fast, under 300ms, natural spring motion, staggered by 50ms.
    withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)) {
      logoScale = 1.0
      logoOpacity = 1
    }
    withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.1)) {
      timelineOffset = 0
      timelineOpacity = 1
    }
    withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.15)) {
      sidebarOffset = 0
      sidebarOpacity = 1
    }
    withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.2)) {
      contentOpacity = 1
    }

    if !didInitialScroll {
      performInitialScrollIfNeeded()
    }
    showScreenRecordingNoticeIfNeeded()
    startDayChangeTimer()
    loadWeeklyTrackedMinutes()
    updateCardsToReviewCount()
  }

  private func performMainLayoutOnDisappear() {
    // Safety: stop timer if view disappears
    stopDayChangeTimer()
    reviewCountTask?.cancel()
    reviewCountTask = nil
    copyTimelineTask?.cancel()
    deleteTimelineTask?.cancel()
  }

  private func handleTabSelectionChange(_ newIcon: SidebarIcon) {
    // Clear tab-specific notification badges once the user visits the destination.
    if newIcon == .journal {
      NotificationBadgeManager.shared.clearJournalBadge()
    } else if newIcon == .daily {
      if !consumePendingDailyRecapOpenIfNeeded(source: "daily_tab_selected") {
        NotificationBadgeManager.shared.clearDailyBadge()
      }
    }

    let tabName = newIcon.analyticsTabName
    syncCurrentUIContext(selectedTab: newIcon)

    SentryHelper.configureScope { scope in
      scope.setContext(
        value: [
          "active_view": tabName,
          "selected_date": dayString(selectedDate),
          "is_recording": appState.isRecording,
        ], key: "app_state")
    }

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
      loadWeeklyTrackedMinutes()
    } else {
      showTimelineReview = false
    }
  }

  private func handleSelectedDateChange(_ newDate: Date) {
    let changeStart = CFAbsoluteTimeGetCurrent()
    let oldDate = previousDate
    let oldDay = dayString(oldDate)
    let newDay = dayString(newDate)
    let oldWeekRange = cachedTimelineWeekRange

    if let method = lastDateNavMethod, method == "picker" {
      AnalyticsService.shared.capture(
        "date_navigation",
        [
          "method": method,
          "timeline_mode": timelineMode.rawValue,
          "from_day": oldDay,
          "to_day": newDay,
        ])
    }

    previousDate = newDate
    AnalyticsService.shared.withSampling(probability: 0.01) {
      AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": newDay])
    }

    let newWeekRange = TimelineWeekRange.containing(newDate)
    let weekRangeChanged = newWeekRange != oldWeekRange

    timelinePerfLog(
      "selectedDateChange.begin mode=\(timelineMode.rawValue) old=\(oldDay) new=\(newDay) weekChanged=\(weekRangeChanged) navMethod=\(lastDateNavMethod ?? "nil")"
    )

    cachedTimelineWeekRange = newWeekRange
    updateCardsToReviewCount(trigger: "selectedDateChange")
    if weekRangeChanged {
      loadWeeklyTrackedMinutes(trigger: "selectedDateChange")
    }

    let durationMs = Int((CFAbsoluteTimeGetCurrent() - changeStart) * 1000)
    timelinePerfLog(
      "selectedDateChange.end mode=\(timelineMode.rawValue) old=\(oldDay) new=\(newDay) weekChanged=\(weekRangeChanged) duration_ms=\(durationMs)"
    )
  }

  private func handleSelectedActivityIdChange() {
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

  private func handleTimelineDataUpdatedNotification(_ notification: Notification) {
    guard selectedIcon == .timeline else { return }
    if let refreshedDay = notification.userInfo?["dayString"] as? String {
      let selectedTimelineDay = DateFormatter.yyyyMMdd.string(
        from: timelineDisplayDate(from: selectedDate, now: Date())
      )
      guard refreshedDay == selectedTimelineDay else { return }
    }
    updateCardsToReviewCount()
    loadWeeklyTrackedMinutes()
  }

  private func handleShowTimelineFailureToastNotification(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let payload = TimelineFailureToastPayload(userInfo: userInfo)
    else {
      return
    }
    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
      timelineFailureToastPayload = payload
    }
  }

  private func handleShowScreenRecordingPermissionNoticeNotification(_ notification: Notification) {
    showScreenRecordingNoticeIfNeeded()
  }

  private func showScreenRecordingNoticeIfNeeded() {
    guard !didDismissScreenRecordingPermissionNoticeThisSession else { return }
    guard !ScreenRecordingPermissionNotice.isGranted else {
      showScreenRecordingPermissionNotice = false
      return
    }
    guard AppState.shared.getSavedPreference() == true || appState.isRecording else { return }

    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
      showScreenRecordingPermissionNotice = true
    }
  }

  private func handleAppDidBecomeActive() {
    if ScreenRecordingPermissionNotice.isGranted {
      showScreenRecordingPermissionNotice = false
      didDismissScreenRecordingPermissionNoticeThisSession = false
    }

    // Check if day changed while app was backgrounded
    handleMinuteTickForDayChange()
    // Ensure timer is running
    if dayChangeTimer == nil {
      startDayChangeTimer()
    }
    // Refresh weekly hours in case activities were added
    loadWeeklyTrackedMinutes()
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

  private func handleScreenRecordingPermissionNoticeOpenSettings() {
    AnalyticsService.shared.capture("screen_permission_notice_clicked_settings")
    didDismissScreenRecordingPermissionNoticeThisSession = true
    withAnimation(.spring(response: 0.25, dampingFraction: 0.92)) {
      showScreenRecordingPermissionNotice = false
    }
    ScreenRecordingPermissionNotice.openSystemSettings()
  }

  private func handleScreenRecordingPermissionNoticeDismiss() {
    AnalyticsService.shared.capture("screen_permission_notice_dismissed")
    didDismissScreenRecordingPermissionNoticeThisSession = true
    withAnimation(.spring(response: 0.25, dampingFraction: 0.92)) {
      showScreenRecordingPermissionNotice = false
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
        .frame(width: timelineInspectorDividerWidth)
        .opacity(timelineInspectorDividerWidth == 0 ? 0 : 1)
        .frame(maxHeight: .infinity)
      timelineRightColumn(geo: geo)
    }
    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    .coordinateSpace(name: "TimelinePanel")
    .overlay(alignment: .topLeading) {
      timelineCalendarPopoverOverlay(panelWidth: geo.size.width)
    }
    .onPreferenceChange(TimelineCalendarButtonFramePreferenceKey.self) { frame in
      timelineCalendarButtonFrame = frame
    }
  }

  private var timelineLeftColumn: some View {
    VStack(alignment: .leading, spacing: 18) {
      timelineHeader
      timelineContent
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(.top, 15)
    .padding(.bottom, 15)
    .padding(.leading, 15)
    .padding(.trailing, 5)
    .overlay(alignment: .bottom) {
      timelineFooter
    }
    .coordinateSpace(name: "TimelinePane")
    .onPreferenceChange(TimelineTimeLabelFramesPreferenceKey.self) { frames in
      timelineTimeLabelFrames = frames
    }
    .onPreferenceChange(WeeklyHoursFramePreferenceKey.self) { frame in
      weeklyHoursFrame = frame
    }
  }

  // Priority-based responsive layout.
  //
  // The trailing Pause pill is *right-pinned and inviolable* — its measured
  // width (including expanded duration chips or "paused for HH:MM" status
  // text) feeds `timelineHeaderTrailingReservation`, which we subtract from
  // the GeometryReader's reported width to get how much room the leading
  // cluster has. `computeHeaderVisibility` then walks a priority ladder
  // (Today → Day/Week → inline date) and decides which optional elements
  // fit. A single variant of `timelineLeadingControls` renders — no
  // `ViewThatFits` branch-flipping, no `.fixedSize(horizontal:)` fighting
  // child widths, no `.animation(...value: trailingReservation)` firing
  // concurrently with the Day/Week matchedGeometryEffect toggle.
  private var timelineHeader: some View {
    ZStack(alignment: .trailing) {
      GeometryReader { geo in
        let visibility = computeHeaderVisibility(availableWidth: geo.size.width)
        timelineLeadingControls(visibility: visibility)
          .padding(.trailing, timelineHeaderTrailingReservation)
          // maxHeight: .infinity is load-bearing — without it the HStack pins
          // to the GR's top edge while the Pause pill sits center-vertically
          // in the sibling ZStack, visibly misaligning the two clusters.
          // `Alignment.leading` = horizontal .leading + vertical .center.
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }

      timelineTrailingControls
        .trackTimelineHeaderTrailingWidth()
    }
    .frame(height: 36)
    .padding(.horizontal, 10)
    .onPreferenceChange(TimelineHeaderTrailingWidthPreferenceKey.self) { width in
      timelineHeaderTrailingWidth = width
    }
  }

  // Actual pixel width of the current date label text, measured via NSFont
  // metrics. Replaces a conservative 240pt estimate — "Today, Apr 16" is
  // ~170pt, "September 12 - September 18" is ~330pt, so a single estimate
  // either over- or under-reserves. This matches the measurement pattern
  // used in `DateNavigationControls.swift:calculateOptimalPillWidth()`.
  private var measuredDateLabelWidth: CGFloat {
    let font =
      NSFont(name: "InstrumentSerif-Regular", size: 26)
      ?? NSFont.systemFont(ofSize: 26)
    return timelineTitleText.size(withAttributes: [.font: font]).width
  }

  // Walks from "always visible" core upward, adding each optional element
  // if it fits in the remaining budget. Order matters: Today (smallest,
  // most task-relevant) is added first; Day/Week is added next; the inline
  // date is added last. When Pause expands, trailing reservation grows,
  // `usable` shrinks, and elements drop off in reverse priority order —
  // automatic, no explicit "if Pause expanded hide X" logic needed.
  private func computeHeaderVisibility(availableWidth: CGFloat) -> TimelineHeaderVisibility {
    let reservation = timelineHeaderTrailingReservation
    let usable = max(0, availableWidth - reservation)

    // Matches the pinned widths of each control (Figma-spec accurate).
    let chevronsWidth: CGFloat = 42  // 20 + 2 + 20
    let calendarWidth: CGFloat = 36
    let dayWeekWidth: CGFloat = 104
    let todayWidth: CGFloat = 56
    let gap: CGFloat = 4
    let datePad: CGFloat = 10

    var used = chevronsWidth + gap + calendarWidth
    var vis = TimelineHeaderVisibility(
      showTodayButton: false,
      showDayWeekToggle: false,
      showInlineDate: false
    )

    if shouldShowTodayButton, used + gap + todayWidth <= usable {
      used += gap + todayWidth
      vis.showTodayButton = true
    }
    if used + gap + dayWeekWidth <= usable {
      used += gap + dayWeekWidth
      vis.showDayWeekToggle = true
    }
    // The liberal allowance (date shows 55pt earlier than strict fit) only
    // applies when the trailing cluster is in its *compact* state. When
    // Pause expands — either the duration-chip menu (~250pt) or the
    // paused-status text "Dayflow paused for HH:MM" (~290pt) — the trailing
    // cluster's leftward occupation already fills the header; piling on
    // a date-allowance at that point produces overlap with the status
    // text. Threshold of 100pt safely partitions compact (idle 73, paused
    // 84) from expanded (menu 250+, paused+status 290).
    let trailingIsCompact = timelineHeaderTrailingWidth < 100
    let dateLiberalAllowance: CGFloat = trailingIsCompact ? 55 : 0
    if used + datePad + measuredDateLabelWidth <= usable + dateLiberalAllowance {
      vis.showInlineDate = true
    }
    return vis
  }

  // Single-variant rendering. Every optional element is gated by the
  // visibility flags computed in `computeHeaderVisibility`. No
  // `.fixedSize(horizontal:)` — element widths are all explicit (see the
  // in-file comments on `timelineModeSwitch` and `timelineCalendarButton`
  // for the history of that decision).
  //
  // `.frame(height: 30)` on the HStack pins its vertical dimension to the
  // pill height so the date label (which has a ~31pt natural line height
  // at InstrumentSerif 26pt) can't grow the HStack when it appears. Without
  // this pin, the pills visibly shifted by ~0.5pt when the date entered.
  private func timelineLeadingControls(visibility: TimelineHeaderVisibility) -> some View {
    HStack(spacing: 4) {
      timelineNavigationButtons
      timelineCalendarButton

      if visibility.showDayWeekToggle {
        timelineModeSwitch
      }

      if visibility.showTodayButton {
        timelineTodayButton
          .transition(.opacity.combined(with: .scale(scale: 0.94)))
      }

      if visibility.showInlineDate {
        timelineHeaderDateLabel
          .padding(.leading, 10)
      }
    }
    .frame(height: 30)
    .offset(x: timelineOffset)
    .opacity(timelineOpacity)
  }

  private var timelineTrailingControls: some View {
    PausePillView()
  }

  private var timelineHeaderTrailingReservation: CGFloat {
    let measuredWidth = max(timelineHeaderTrailingWidth, 120)
    return measuredWidth + 18
  }

  private var timelineNavigationButtons: some View {
    HStack(spacing: 2) {
      // Back — plain chevron matching the Figma, with a 28×28 hit box around
      // the 14×14 glyph. `.contentShape(Rectangle())` makes the entire outer
      // frame tappable (including transparent space around the glyph).
      Button(action: {
        navigateTimeline(to: previousTimelineDate(), method: "prev")
      }) {
        Image("LeftArrow")
          .resizable()
          .scaledToFit()
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(DayflowPressScaleButtonStyle())
      .hoverScaleEffect(scale: 1.02)
      .pointingHandCursorOnHover(reassertOnPressEnd: true)

      // Forward — same pattern; stays disabled when we're already on today.
      Button(action: {
        guard canNavigateTimelineForward else { return }
        navigateTimeline(to: nextTimelineDate(), method: "next")
      }) {
        Image("RightArrow")
          .resizable()
          .scaledToFit()
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
          .opacity(canNavigateTimelineForward ? 1 : 0.35)
      }
      .buttonStyle(DayflowPressScaleButtonStyle())
      .disabled(!canNavigateTimelineForward)
      .hoverScaleEffect(
        enabled: canNavigateTimelineForward,
        scale: 1.02
      )
      .pointingHandCursorOnHover(
        enabled: canNavigateTimelineForward,
        reassertOnPressEnd: true
      )
    }
  }

  // Calendar pill — Figma 1:1 visuals (fill #FFA777, icon 16×16, h=30, border
  // #F2D2BD). The arrowless card itself is rendered at the panel level so it
  // can own outside-click dismissal without taps leaking through to the
  // timeline below.
  private var timelineCalendarButton: some View {
    Button(action: {
      if showTimelineCalendarPopover {
        closeTimelineCalendarPopover()
      } else {
        openTimelineCalendarPopover()
      }
    }) {
      ZStack {
        Capsule(style: .continuous)
          .fill(timelineCalendarButtonFillColor)
          .overlay(
            Capsule(style: .continuous)
              .stroke(timelineCalendarButtonBorderColor, lineWidth: 1)
          )
          .shadow(
            color: timelineCalendarButtonShadowColor,
            radius: showTimelineCalendarPopover ? 8 : 0,
            x: 0,
            y: showTimelineCalendarPopover ? 2 : 0
          )

        Image("CalendarIcon")
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)
      }
      .frame(width: 36, height: 30)
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(
      DayflowPressScaleButtonStyle(
        pressedScale: 0.985,
        animation: .spring(response: 0.18, dampingFraction: 0.88)
      )
    )
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .animation(timelineCalendarButtonStateAnimation, value: showTimelineCalendarPopover)
    .trackTimelineCalendarButtonFrame()
  }

  private var timelineCalendarButtonFillColor: Color {
    showTimelineCalendarPopover ? Color(hex: "FFB38E") : Color(hex: "FFA777")
  }

  private var timelineCalendarButtonBorderColor: Color {
    showTimelineCalendarPopover ? Color(hex: "E8BDA1") : Color(hex: "F2D2BD")
  }

  private var timelineCalendarButtonShadowColor: Color {
    showTimelineCalendarPopover ? .black.opacity(0.10) : .clear
  }

  private var timelineCalendarButtonStateAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14)
  }

  private var timelineCalendarPopoverOpenAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.18)
  }

  private var timelineCalendarPopoverCloseAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.12)
  }

  private var timelineCalendarPopoverTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }

    return .asymmetric(
      insertion: .opacity
        .combined(with: .offset(y: -6))
        .animation(timelineCalendarPopoverOpenAnimation),
      removal: .opacity
        .combined(with: .offset(y: -4))
        .animation(timelineCalendarPopoverCloseAnimation)
    )
  }

  private func openTimelineCalendarPopover() {
    withAnimation(timelineCalendarPopoverOpenAnimation) {
      showTimelineCalendarPopover = true
    }
  }

  private func closeTimelineCalendarPopover() {
    withAnimation(timelineCalendarPopoverCloseAnimation) {
      showTimelineCalendarPopover = false
    }
  }

  private func timelineCalendarPopoverOverlay(panelWidth: CGFloat) -> some View {
    let cardWidth = TimelineCalendarPopover.preferredWidth
    let horizontalPadding: CGFloat = 12
    let maxX = max(
      horizontalPadding,
      panelWidth - cardWidth - horizontalPadding
    )
    let cardX = min(
      max(horizontalPadding, timelineCalendarButtonFrame.midX - (cardWidth / 2)),
      maxX
    )

    return ZStack(alignment: .topLeading) {
      if showTimelineCalendarPopover {
        Rectangle()
          .fill(Color.black.opacity(0.001))
          .contentShape(Rectangle())
          .onTapGesture {
            closeTimelineCalendarPopover()
          }

        TimelineCalendarPopover(
          isPresented: $showTimelineCalendarPopover,
          selectedDate: selectedDate,
          canSelectFutureDates: false,
          highlightsSelectedWeek: timelineMode == .week,
          onSelect: { date in
            let tappedDay = dayString(date)
            let currentDay = dayString(selectedDate)
            let tappedWeek = TimelineWeekRange.containing(date)
            let currentWeek = timelineWeekRange
            let weekChanged = tappedWeek != currentWeek

            timelinePerfLog(
              "calendarPopover.select tapped=\(tappedDay) current=\(currentDay) mode=\(timelineMode.rawValue) weekChanged=\(weekChanged)"
            )

            timelinePerfLog(
              "calendarPopover.navigateDispatch tapped=\(tappedDay) mode=\(timelineMode.rawValue) weekChanged=\(weekChanged)"
            )
            navigateTimeline(to: date, method: "picker")
            DispatchQueue.main.async {
              closeTimelineCalendarPopover()
            }
          }
        )
        .offset(x: cardX, y: timelineCalendarButtonFrame.maxY + 55)
        .transition(timelineCalendarPopoverTransition)
        .zIndex(1)
      }
    }
    .allowsHitTesting(showTimelineCalendarPopover)
  }

  private var timelineModeSwitch: some View {
    HStack(spacing: 0) {
      ForEach(TimelineMode.allCases) { mode in
        let isSelected = timelineMode == mode

        Button(action: {
          setTimelineMode(mode)
        }) {
          ZStack {
            if isSelected {
              Capsule(style: .continuous)
                .fill(
                  LinearGradient(
                    colors: [
                      Color(hex: "FFB18D").opacity(0.6),
                      Color(hex: "FFA46F"),
                      Color(hex: "FFB18D"),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                  )
                )
                .shadow(color: Color(hex: "E89A6C").opacity(0.18), radius: 4, x: 0, y: 1)
                .matchedGeometryEffect(
                  id: "timeline_mode_highlight",
                  in: timelineModeSwitchNamespace
                )
            }

            Text(mode.title)
              .font(.custom("Nunito", size: 12).weight(.medium))
              .foregroundColor(isSelected ? .white : Color(hex: "796E64"))
              // Concrete width (52pt × 2 = 104pt container) instead of
              // `.frame(maxWidth: .infinity)`. The infinity was being fought
              // by the `.fixedSize(horizontal: true)` ancestor on
              // `timelineLeadingControls`, which resolved the toggle's
              // ideal width as ~0 and collapsed the cream background +
              // "Day" label. Three independent parallel investigations
              // converged on this exact change.
              .frame(width: 52, height: 30)
          }
          .contentShape(Capsule(style: .continuous))
        }
        // Reverted to PlainButtonStyle: DayflowPressScaleButtonStyle — even
        // with `enabled: false` — still wraps the label in `.animation(...)`,
        // which appears to conflict with the outer `.animation(...)` tied to
        // the matchedGeometryEffect gradient. The press-darkening flash is
        // the accepted tradeoff for a correctly-behaving matched slide.
        .buttonStyle(PlainButtonStyle())
        .hoverScaleEffect(scale: 1.01)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
      }
    }
    .frame(width: 104, height: 30)
    .background(Color(hex: "FFEFE4"))
    .clipShape(Capsule(style: .continuous))
    .overlay(
      Capsule(style: .continuous)
        .stroke(Color(hex: "F2D2BD"), lineWidth: 1)
    )
    .animation(timelineModeSwitchAnimation, value: timelineMode)
  }

  private var timelineTodayButton: some View {
    Button(action: {
      navigateTimeline(to: timelineDisplayDate(from: Date()), method: "today")
    }) {
      Text("Today")
        .font(.custom("Nunito", size: 12).weight(.medium))
        .foregroundColor(Color(hex: "796E64"))
        .padding(.horizontal, 10)
        // Explicit width pinned (natural ~52pt + 4pt safety margin). Same
        // rationale as the calendar pill: under the ancestor's `.fixedSize`
        // inside a `ViewThatFits`, implicit widths can resolve to unstable
        // values mid-transition, nudging the Day/Week toggle's position and
        // desyncing its `matchedGeometryEffect` anchors during a mode flip.
        .frame(width: 56, height: 30)
        .background(Color(hex: "FFEFE4"))
        .clipShape(Capsule(style: .continuous))
        .overlay(
          Capsule(style: .continuous)
            .stroke(Color(hex: "F2D2BD"), lineWidth: 1)
        )
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }

  private var timelineHeaderDateLabel: some View {
    Text(timelineTitleText)
      .font(.custom("InstrumentSerif-Regular", size: 26))
      .foregroundColor(Color.black)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .onTapGesture {
        guard timelineMode == .day else { return }
        showDatePicker = true
        lastDateNavMethod = "picker"
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

      ZStack(alignment: .topLeading) {
        switch timelineMode {
        case .day:
          CanvasTimelineDataView(
            selectedDate: $selectedDate,
            selectedActivity: $selectedActivity,
            scrollToNowTick: $scrollToNowTick,
            hasAnyActivities: $hasAnyActivities,
            refreshTrigger: $refreshActivitiesTrigger,
            weeklyHoursFrame: weeklyHoursFrame,
            weeklyHoursIntersectsCard: $weeklyHoursIntersectsCard
          )
          // Day is the zoomed-IN view (1/7 of a week). Entering Day feels
          // like diving into a single column: grow from 0.95 → 1 + fade in.
          // Exiting Day (to Week) shrinks 1 → 0.95 + fade out, matching the
          // "pull back to see more" feel when Week slides in behind it.
          .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
          .zIndex(timelineMode == .day ? 1 : 0)

        case .week:
          WeekTimelineGridView(
            selectedDate: $selectedDate,
            selectedActivity: $selectedActivity,
            hasAnyActivities: $hasAnyActivities,
            refreshTrigger: $refreshActivitiesTrigger,
            weekRange: timelineWeekRange,
            onSelectActivity: selectTimelineActivity,
            onClearSelection: { clearTimelineSelection() },
            weeklyHoursFrame: weeklyHoursFrame,
            weeklyHoursIntersectsCard: $weeklyHoursIntersectsCard,
            hideCardsForModeSwitch: hideWeekCardsDuringModeSwitch
          )
          // Week is the zoomed-OUT view (7 days). Entering Week from Day
          // feels like pulling back: start at 1.05 (slightly too large) and
          // settle to 1 + fade in. Exiting Week grows to 1.05 + fade out,
          // matching the "dive in" feel when Day settles to 1 behind it.
          .transition(.opacity.combined(with: .scale(scale: 1.05, anchor: .center)))
          .zIndex(timelineMode == .week ? 1 : 0)
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .environmentObject(categoryStore)
      .opacity(contentOpacity)
      .animation(timelineModeContentAnimation, value: timelineMode)
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var timelineFooter: some View {
    let weeklyHoursOpacity =
      weeklyHoursFadeOpacity * (weeklyHoursIntersectsCard ? 0 : 1)

    return ZStack(alignment: .bottom) {
      HStack(alignment: .bottom) {
        weeklyHoursText
          .opacity(contentOpacity * weeklyHoursOpacity)

        Spacer()

        copyTimelineButton
          .opacity(contentOpacity)
      }
      .padding(.horizontal, 24)

      if timelineMode == .day, cardsToReviewCount > 0 {
        CardsToReviewButton(count: cardsToReviewCount) {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showTimelineReview = true
          }
        }
        .opacity(contentOpacity)
      }
    }
    .padding(.bottom, 17)
    .allowsHitTesting(true)
  }

  private func timelineRightColumn(geo: GeometryProxy) -> some View {
    ZStack(alignment: .topLeading) {
      if timelineInspectorWidth > 0 {
        Color.white.opacity(0.7)
      }

      switch timelineMode {
      case .day:
        dayTimelineInspectorContent(geo: geo)
      case .week:
        weekTimelineInspectorContent(geo: geo)
      }
    }
    .frame(width: timelineInspectorWidth)
    .frame(maxHeight: .infinity)
    .opacity(contentOpacity)
    .clipped()
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
  }

  @ViewBuilder
  private func dayTimelineInspectorContent(geo: GeometryProxy) -> some View {
    if let activity = selectedActivity {
      timelineActivityInspector(activity: activity, geo: geo)
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
  }

  @ViewBuilder
  private func weekTimelineInspectorContent(geo: GeometryProxy) -> some View {
    if let activity = selectedActivity, isWeekTimelineInspectorVisible {
      timelineActivityInspector(activity: activity, geo: geo)
        .id(activity.id)
        .transition(.opacity.combined(with: .offset(x: 10)))
    }
  }

  private func timelineActivityInspector(activity: TimelineActivity, geo: GeometryProxy)
    -> some View
  {
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
            clearTimelineSelection()
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
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottomLeading) {
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
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
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
    let textColor = Color(red: 0.84, green: 0.65, blue: 0.52)
    let parts = timelineTrackedMinutesParts

    return
      (Text(parts.bold)
      .font(Font.custom("Nunito", size: 10).weight(.bold))
      .foregroundColor(textColor)
      + Text(parts.rest)
      .font(Font.custom("Nunito", size: 10).weight(.regular))
      .foregroundColor(textColor))
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
      .dayflowPressScale(
        configuration.isPressed,
        pressedScale: 0.97,
        animation: .spring(response: 0.25, dampingFraction: 0.7)
      )
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

private struct ScreenRecordingPermissionNoticeView: View {
  let onOpenSettings: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "record.circle.fill")
          .font(.system(size: 15))
          .foregroundColor(Color(hex: "C7352D"))
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 3) {
          Text("Screen recording access needed")
            .font(.custom("Nunito", size: 13))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.86))

          Text("Dayflow cannot update your timeline until access is restored.")
            .font(.custom("Nunito", size: 12))
            .foregroundColor(.black.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
        }

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
            Text("Open System Settings")
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

// Compact month calendar popover (Figma 4291:4828).
// Single-variant rendering: every day is a cell in a flat grid, with the
// selected date shown as an 18pt orange circle. No week-pill; week-mode
// indication is conveyed elsewhere in the UI (the Day/Week toggle + the
// header title). Self-contained: tracks its own displayed month, reports
// picks via `onSelect`.
private struct TimelineCalendarPopover: View {
  static let horizontalPadding: CGFloat = 28
  static let topPadding: CGFloat = 20
  static let bottomPadding: CGFloat = 20
  static let contentSpacing: CGFloat = 16
  static let columnWidth: CGFloat = 30
  static let columnSpacing: CGFloat = 12
  static let weekdayHeight: CGFloat = 20
  static let dayCellHeight: CGFloat = 24
  static let rowSpacing: CGFloat = 12
  static let selectedCircleSize: CGFloat = 24
  static let selectedWeekHighlightHeight: CGFloat = 30
  static let contentWidth: CGFloat = (columnWidth * 7) + (columnSpacing * 6)
  static let preferredWidth: CGFloat = contentWidth + (horizontalPadding * 2)

  @Binding var isPresented: Bool
  let selectedDate: Date
  let canSelectFutureDates: Bool
  let highlightsSelectedWeek: Bool
  let onSelect: (Date) -> Void

  @State private var displayMonth: Date

  // Monday-first ordering matches the timeline's week model, so each row in the
  // popover corresponds to a real Monday-Sunday week.
  private static let mondayCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .autoupdatingCurrent
    c.firstWeekday = 2
    return c
  }()

  private static let monthYearFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM yyyy"
    return f
  }()

  init(
    isPresented: Binding<Bool>,
    selectedDate: Date,
    canSelectFutureDates: Bool,
    highlightsSelectedWeek: Bool,
    onSelect: @escaping (Date) -> Void
  ) {
    self._isPresented = isPresented
    self.selectedDate = selectedDate
    self.canSelectFutureDates = canSelectFutureDates
    self.highlightsSelectedWeek = highlightsSelectedWeek
    self.onSelect = onSelect

    // Seed display month to the month containing the current selection.
    let calendar = Self.mondayCalendar
    let comps = calendar.dateComponents([.year, .month], from: selectedDate)
    let monthStart = calendar.date(from: comps) ?? selectedDate
    self._displayMonth = State(initialValue: monthStart)
  }

  var body: some View {
    let weeks = weeksToDisplay()

    VStack(alignment: .leading, spacing: Self.contentSpacing) {
      monthHeader
      weekdayRow
      dateGrid(weeks: weeks)
    }
    .frame(width: Self.contentWidth, alignment: .leading)
    .padding(.horizontal, Self.horizontalPadding)
    .padding(.top, Self.topPadding)
    .padding(.bottom, Self.bottomPadding)
    .frame(width: Self.preferredWidth, alignment: .topLeading)
    // Figma node 4291:4828: backdrop-blur 10pt + rgba(255,255,255,0.5) tint.
    .background {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.ultraThinMaterial)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.white.opacity(0.5))
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color(hex: "E9DAD1"), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 1)
    // Force the light variant of `.ultraThinMaterial` regardless of the
    // system appearance. Without this, macOS dark mode causes the material
    // to render as a dark blur — the popover looks like a gray slab even
    // though the rest of the app is light. Dayflow's palette is tuned for
    // light mode; the Figma explicitly specifies a light translucent card.
    .environment(\.colorScheme, .light)
  }

  private var monthHeader: some View {
    HStack(spacing: 0) {
      Text(Self.monthYearFormatter.string(from: displayMonth))
        .font(.custom("Nunito", size: 14))
        .foregroundColor(.black)
        .lineLimit(1)

      Spacer(minLength: 0)

      HStack(spacing: 2) {
        monthNavButton(systemName: "chevron.left") { shiftMonth(by: -1) }
        monthNavButton(systemName: "chevron.right") { shiftMonth(by: 1) }
      }
    }
    .frame(height: 20)
  }

  // Figma nav chevrons are plain gray glyphs, not the app's orange header
  // arrows. Using SF Symbols here keeps the size and tint exact while
  // avoiding extra asset work for a tiny 16pt icon.
  private func monthNavButton(
    systemName: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(Color(hex: "A8A09A"))
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  // Weekday header uses Instrument Serif 12pt per Figma (not Nunito).
  private var weekdayRow: some View {
    // `id: \.self` on ["S","M","T","W","T","F","S"] duplicates the "T" and
    // "S" IDs — SwiftUI logs "the ID T occurs multiple times" and the diff
    // becomes undefined. Keying by index is correct here: labels are
    // position-bound, not identity-bound.
    let labels = weekdayLabels()
    return HStack(spacing: Self.columnSpacing) {
      ForEach(labels.indices, id: \.self) { i in
        Text(labels[i])
          .font(.custom("InstrumentSerif-Regular", size: 12))
          .foregroundColor(.black)
          .frame(width: Self.columnWidth, height: Self.weekdayHeight)
      }
    }
  }

  // Fixed column widths keep weekday labels and dates perfectly aligned.
  private func dateGrid(weeks: [[CalendarDay]]) -> some View {
    return VStack(alignment: .leading, spacing: Self.rowSpacing) {
      ForEach(weeks.indices, id: \.self) { rowIndex in
        let week = weeks[rowIndex]
        let isSelectedWeek = highlightsSelectedWeek && isWeekSelected(week)

        ZStack {
          if isSelectedWeek {
            Capsule(style: .continuous)
              .fill(Color(hex: "FC7103"))
              .frame(
                width: Self.contentWidth,
                height: Self.selectedWeekHighlightHeight
              )
          }

          HStack(spacing: Self.columnSpacing) {
            ForEach(week) { day in
              dateCell(day: day, isInSelectedWeek: isSelectedWeek)
            }
          }
        }
        .frame(
          width: Self.contentWidth,
          height: Self.selectedWeekHighlightHeight
        )
      }
    }
  }

  private func dateCell(day: CalendarDay, isInSelectedWeek: Bool) -> some View {
    let calendar = Self.mondayCalendar
    let isSelected = calendar.isDate(day.date, inSameDayAs: selectedDate)
    let showsSelectedDayCircle = isSelected && !highlightsSelectedWeek
    let isDisabled: Bool = {
      guard !canSelectFutureDates else { return false }
      let todayStart = calendar.startOfDay(for: Date())
      let cellStart = calendar.startOfDay(for: day.date)
      return cellStart > todayStart
    }()
    let foregroundColor: Color = {
      if isInSelectedWeek {
        return (!day.isCurrentMonth || isDisabled) ? .white.opacity(0.55) : .white
      }
      if !day.isCurrentMonth || isDisabled {
        return Color(hex: "C1B5AC")
      }
      return showsSelectedDayCircle ? .white : .black
    }()

    return Button {
      guard !isDisabled else { return }
      onSelect(day.date)
    } label: {
      ZStack {
        if showsSelectedDayCircle {
          Circle()
            .fill(Color(hex: "FC7103"))
            .frame(width: Self.selectedCircleSize, height: Self.selectedCircleSize)
        }
        Text(day.label)
          .font(.custom("Nunito", size: 12))
          .foregroundColor(foregroundColor)
      }
      .frame(width: Self.columnWidth, height: Self.dayCellHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .pointingHandCursor(enabled: !isDisabled)
  }

  // MARK: - Data & navigation

  private struct CalendarDay: Identifiable {
    let date: Date
    let label: String
    let isCurrentMonth: Bool

    var id: Date { date }
  }

  private func shiftMonth(by months: Int) {
    let calendar = Self.mondayCalendar
    if let newMonth = calendar.date(byAdding: .month, value: months, to: displayMonth) {
      displayMonth = newMonth
    }
  }

  // Locale weekday symbols, rotated so Monday appears first.
  private func weekdayLabels() -> [String] {
    let calendar = Self.mondayCalendar
    let symbols = calendar.veryShortWeekdaySymbols
    let offset = calendar.firstWeekday - 1
    guard offset >= 0, offset < symbols.count else { return symbols }
    return Array(symbols[offset...]) + Array(symbols[..<offset])
  }

  // Build the visible month grid with leading/trailing days as needed to fill
  // complete Monday-Sunday weeks.
  private func daysToDisplay() -> [CalendarDay] {
    let calendar = Self.mondayCalendar
    let monthStart = displayMonth
    guard let monthRange = calendar.range(of: .day, in: .month, for: monthStart) else {
      return []
    }

    let firstWeekday = calendar.component(.weekday, from: monthStart)
    let leadingCount = (firstWeekday - calendar.firstWeekday + 7) % 7

    var days: [CalendarDay] = []

    // Leading days from the previous month.
    if leadingCount > 0,
      let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart),
      let prevMonthRange = calendar.range(of: .day, in: .month, for: prevMonthStart)
    {
      let prevLast = prevMonthRange.count
      let startDay = prevLast - leadingCount + 1
      for offset in 0..<leadingCount {
        if let date = calendar.date(
          byAdding: .day, value: startDay - 1 + offset, to: prevMonthStart)
        {
          days.append(
            CalendarDay(
              date: date,
              label: "\(calendar.component(.day, from: date))",
              isCurrentMonth: false
            )
          )
        }
      }
    }

    // Current month.
    for offset in 0..<monthRange.count {
      if let date = calendar.date(byAdding: .day, value: offset, to: monthStart) {
        days.append(
          CalendarDay(
            date: date,
            label: "\(calendar.component(.day, from: date))",
            isCurrentMonth: true
          )
        )
      }
    }

    // Trailing days from next month to complete the last visible week.
    let trailingNeeded = (7 - (days.count % 7)) % 7
    if trailingNeeded > 0,
      let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)
    {
      for offset in 0..<trailingNeeded {
        if let date = calendar.date(byAdding: .day, value: offset, to: nextMonthStart) {
          days.append(
            CalendarDay(
              date: date,
              label: "\(calendar.component(.day, from: date))",
              isCurrentMonth: false
            )
          )
        }
      }
    }

    return days
  }

  private func weeksToDisplay() -> [[CalendarDay]] {
    let days = daysToDisplay()
    return stride(from: 0, to: days.count, by: 7).map { start in
      Array(days[start..<min(start + 7, days.count)])
    }
  }

  private func isWeekSelected(_ week: [CalendarDay]) -> Bool {
    guard let firstDay = week.first else { return false }
    return isDateInSelectedWeek(firstDay.date)
  }

  private func isDateInSelectedWeek(_ date: Date) -> Bool {
    let calendar = Self.mondayCalendar
    return calendar.isDate(date, equalTo: selectedDate, toGranularity: .weekOfYear)
  }
}
