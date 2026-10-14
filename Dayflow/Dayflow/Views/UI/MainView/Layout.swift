import AppKit
import SwiftUI

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
      .blur(radius: goalFlowPresentation == nil ? 0 : 10)
      .allowsHitTesting(goalFlowPresentation == nil)
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
      .onReceive(NotificationCenter.default.publisher(for: .navigateToWeekly)) { _ in
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
          selectedIcon = .weekly
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .showTimelineFailureToast)) {
        handleShowTimelineFailureToastNotification($0)
      }
      .onReceive(NotificationCenter.default.publisher(for: .hideTimelineFailureToast)) { _ in
        handleHideTimelineFailureToastNotification()
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
        payload: payload,
        onOpenSettings: { handleTimelineFailureToastOpenSettings(payload) },
        onCopyCommand: {
          AnalyticsService.shared.capture(
            "llm_timeline_failure_toast_copied_command", payload.analyticsProps)
        },
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
    requestDailyGoalPromptIfNeeded()
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
    if newIcon == .daily {
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
    GettingStarted.markCardOpened()
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

  private func handleHideTimelineFailureToastNotification() {
    guard timelineFailureToastPayload != nil else { return }
    withAnimation(.spring(response: 0.25, dampingFraction: 0.92)) {
      timelineFailureToastPayload = nil
    }
  }

  private func handleShowScreenRecordingPermissionNoticeNotification(_ notification: Notification) {
    let reason = notification.userInfo?["reason"] as? String
    if reason == ScreenRecordingPermissionNotice.captureFailingReason {
      screenCaptureIsFailing = true
    }
    showScreenRecordingNoticeIfNeeded()
  }

  private func showScreenRecordingNoticeIfNeeded() {
    guard !didDismissScreenRecordingPermissionNoticeThisSession else { return }
    guard !ScreenRecordingPermissionNotice.isGranted || screenCaptureIsFailing else {
      showScreenRecordingPermissionNotice = false
      return
    }
    guard AppState.shared.getSavedPreference() == true || appState.isRecording else { return }

    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
      showScreenRecordingPermissionNotice = true
    }
  }

  private func handleAppDidBecomeActive() {
    if ScreenRecordingPermissionNotice.isGranted && !screenCaptureIsFailing {
      showScreenRecordingPermissionNotice = false
      didDismissScreenRecordingPermissionNoticeThisSession = false
    }

    // Check if day changed while app was backgrounded
    handleMinuteTickForDayChange()
    requestDailyGoalPromptIfNeeded()
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
    let settingsTab: Notification.Name =
      payload.destination == .account ? .openAccountSettings : .openProvidersSettings
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NotificationCenter.default.post(name: settingsTab, object: nil)
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
    screenCaptureIsFailing = false
    withAnimation(.spring(response: 0.25, dampingFraction: 0.92)) {
      showScreenRecordingPermissionNotice = false
    }
    ScreenRecordingPermissionNotice.openSystemSettings()
  }

  private func handleScreenRecordingPermissionNoticeDismiss() {
    AnalyticsService.shared.capture("screen_permission_notice_dismissed")
    didDismissScreenRecordingPermissionNoticeThisSession = true
    screenCaptureIsFailing = false
    withAnimation(.spring(response: 0.25, dampingFraction: 0.92)) {
      showScreenRecordingPermissionNotice = false
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
        onDismiss: { showCategoryEditor = false }, completionButtonTitle: String(localized: "Done"),
        showsTitles: true
      )
      .environmentObject(categoryStore)
      // Removed .contentShape(Rectangle()) and .onTapGesture to allow keyboard input
    }
  }
}

/// Bottom-right card for timeline failures the person has to fix themselves
/// (signed out, out of credits...). Shows numbered steps when there's a
/// concrete fix, otherwise a button into Settings.
private struct TimelineFailureToastView: View {
  @Environment(\.dayflowTheme) private var theme
  let payload: TimelineFailureToastPayload
  let onOpenSettings: () -> Void
  let onCopyCommand: () -> Void
  let onDismiss: () -> Void
  @State private var didCopy = false

  private var actionTitle: String {
    payload.destination == .account
      ? String(localized: "Open Account") : String(localized: "Open Provider Settings")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      Text(payload.message)
        .font(.custom("Figtree", size: 13))
        .foregroundStyle(theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if payload.steps.isEmpty {
        buttons
      } else {
        steps
      }

      footer
    }
    .promptCardStyle(width: 360)
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      providerLogo
        .frame(width: 22, height: 22)

      Text(payload.title ?? String(localized: "Dayflow needs a hand"))
        .font(.custom("Figtree", size: 15).weight(.semibold))
        .foregroundStyle(theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(theme.textMuted)
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
  }

  @ViewBuilder
  private var providerLogo: some View {
    let name = payload.providerName.lowercased()
    if name.contains("claude") {
      Image("ClaudeLogo").resizable().scaledToFit()
    } else if name.contains("chatgpt") || name.contains("codex") {
      Image("ChatGPTLogo").resizable().scaledToFit()
    } else if name.contains("gemini") || name.contains("gemma") {
      Image("GeminiLogo").resizable().scaledToFit()
    } else if name.contains("dayflow") {
      Image("DayflowLogo").resizable().scaledToFit()
    } else {
      Image(systemName: "cpu")
        .font(.system(size: 15))
        .foregroundStyle(theme.textSecondary)
    }
  }

  // MARK: Steps

  private var steps: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(payload.steps.enumerated()), id: \.offset) { index, step in
        HStack(alignment: .top, spacing: 10) {
          stepNumber(index + 1)

          VStack(alignment: .leading, spacing: 8) {
            Text(step)
              .font(.custom("Figtree", size: 13))
              .foregroundStyle(theme.textPrimary)
              .fixedSize(horizontal: false, vertical: true)

            if index == 0, let command = payload.command {
              commandBox(command)
            }
          }
        }
      }

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 18))
          .foregroundStyle(theme.accent)
          .frame(width: 20, height: 20)

        Text("Dayflow catches up automatically")
          .font(.custom("Figtree", size: 13))
          .foregroundStyle(theme.textPrimary)
          .padding(.top, 1)
      }
    }
  }

  private func stepNumber(_ number: Int) -> some View {
    Text("\(number)")
      .font(.custom("Figtree", size: 11).weight(.semibold))
      .foregroundStyle(theme.accent)
      .frame(width: 20, height: 20)
      .background(Circle().fill(theme.accent.opacity(0.14)))
  }

  private func commandBox(_ command: String) -> some View {
    HStack(spacing: 8) {
      Text(command)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(theme.textPrimary)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer(minLength: 4)

      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        onCopyCommand()
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          didCopy = false
        }
      } label: {
        HStack(spacing: 4) {
          if didCopy {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .semibold))
          } else {
            Image("Copy")
              .resizable()
              .scaledToFit()
              .frame(width: 11, height: 11)
          }
          Text(didCopy ? String(localized: "Copied") : String(localized: "Copy"))
            .font(.custom("Figtree", size: 11).weight(.medium))
        }
        .foregroundStyle(theme.secondaryButtonText)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.secondaryButtonFill))
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(theme.secondaryButtonBorder, lineWidth: 0.75)
        )
        .fixedSize()
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
    .padding(.leading, 10)
    .padding(.trailing, 5)
    .frame(height: 32)
    .background(RoundedRectangle(cornerRadius: 6).fill(theme.controlFill))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(theme.controlBorder, lineWidth: 0.75)
    )
  }

  // MARK: Buttons (no steps)

  private var buttons: some View {
    HStack(spacing: 8) {
      Button(action: onDismiss) {
        Text("Not now")
          .font(.custom("Figtree", size: 13).weight(theme.isDark ? .medium : .regular))
          .foregroundStyle(theme.secondaryButtonText)
          .frame(maxWidth: .infinity)
          .frame(height: 34)
          .background(Capsule().fill(theme.secondaryButtonFill))
          .overlay(
            Capsule().strokeBorder(theme.secondaryButtonBorder, lineWidth: theme.isDark ? 1 : 0.75))
      }
      .buttonStyle(.plain)
      .pointingHandCursor()

      Button(action: onOpenSettings) {
        Text(actionTitle)
          .font(.custom("Figtree", size: 13).weight(.medium))
          .foregroundStyle(theme.primaryButtonText)
          .lineLimit(1)
          .frame(maxWidth: .infinity)
          .frame(height: 34)
          .background(Capsule().fill(theme.primaryButtonFill))
          .overlay(InnerGlow(shape: Capsule(), color: theme.primaryButtonInnerGlow, radius: 3))
          .overlay(
            Capsule().strokeBorder(theme.primaryButtonBorder, lineWidth: theme.isDark ? 0.5 : 0.75))
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(theme.accent)
        .frame(width: 6, height: 6)

      if let waiting = waitingText {
        Text("\(waiting) waiting to process")
          .font(.custom("Figtree", size: 12))
          .foregroundStyle(theme.textSecondary)
        Spacer(minLength: 8)
        Text("Retries on its own")
          .font(.custom("Figtree", size: 12))
          .foregroundStyle(theme.textMuted)
      } else {
        Text("Dayflow catches up automatically")
          .font(.custom("Figtree", size: 12))
          .foregroundStyle(theme.textSecondary)
        Spacer(minLength: 0)
      }
    }
    .padding(.top, 10)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(theme.controlBorder)
        .frame(height: 0.5)
    }
  }

  /// "25 min", "3 hrs", "1 day". Nil when nothing is waiting.
  private var waitingText: String? {
    let minutes = payload.waitingSeconds / 60
    guard minutes > 0 else { return nil }
    if minutes < 60 {
      return String(localized: "\(minutes) min")
    }
    let hours = minutes / 60
    if hours < 24 {
      return hours == 1 ? String(localized: "1 hr") : String(localized: "\(hours) hrs")
    }
    return String(localized: "1 day")
  }
}

private struct ScreenRecordingPermissionNoticeView: View {
  @Environment(\.dayflowTheme) private var theme
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
            .font(.custom("Figtree", size: 13))
            .fontWeight(.semibold)
            .foregroundColor(theme.textPrimary)

          Text("Dayflow cannot update your timeline until access is restored.")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(theme.textMuted)
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
              .font(.custom("Figtree", size: 12))
              .fontWeight(.semibold)
          }
        },
        background: theme.primaryButtonFill,
        foreground: theme.primaryButtonText,
        borderColor: .clear,
        cornerRadius: 8,
        horizontalPadding: 14,
        verticalPadding: 8,
        showOverlayStroke: true
      )
    }
    .padding(14)
    .frame(width: 360, alignment: .leading)
    .background(theme.popoverFill)
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(theme.popoverBorder, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 6)
  }
}
