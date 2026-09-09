//
//  Layout+Panels.swift
//  Dayflow
//

import SwiftUI

struct TimelineCalendarButtonFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

enum TimelineAlignment {
  static let topInset: CGFloat = 24
  static let pickerRowOffset: CGFloat = -10
  static let categoryRowInset: CGFloat = 55
  static let headerContentGap: CGFloat = 18
}

enum TimelineNavigationLayout {
  static let arrowSize: CGFloat = 24
  static let hoverCircleSize: CGFloat = 30
  static let calendarGap: CGFloat = 4
}

enum LogoPosition {
  static let logoSize: CGFloat = 48
  static let logoVerticalOffset: CGFloat = 8
}

extension MainView {
  var contentStack: some View {
    // Two-column layout: left logo + sidebar; right white panel with header, filters, timeline
    HStack(alignment: .top, spacing: 0) {
      leftColumn
      rightPanel
    }
    .padding(0)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var leftColumn: some View {
    // Left column: sidebar centered vertically in the gutter. The logo badge
    // that used to sit above it is hidden for now.
    VStack {
      Spacer()
      SidebarView(selectedIcon: $selectedIcon)
        .frame(maxWidth: .infinity, alignment: .center)
        .offset(y: sidebarOffset)
        .opacity(sidebarOpacity)
      Spacer()
    }
    .frame(width: 80)
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
      case .flow:
        FlowView()
      case .agents:
        AgentPlaybackView()
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
    .background {
      if selectedIcon != .agents || !theme.isDark {
        mainPanelBackground
      }
    }
  }

  private var mainPanelBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return
      shape
      .fill(theme.panelFill)
      .overlay(
        // Light-mode-only inner shadow (white 25%, 4px fade); dark keeps
        // its shipped panel look.
        InnerGlow(shape: shape, color: theme.isDark ? .clear : theme.panelInnerGlow, radius: 4)
      )
      .overlay(shape.strokeBorder(theme.panelBorder, lineWidth: 1))
      .shadow(color: theme.panelShadow, radius: 12, x: 0, y: 0)
  }

  private func timelinePanel(geo: GeometryProxy) -> some View {
    ZStack(alignment: .topLeading) {
      HStack(alignment: .top, spacing: 0) {
        timelineLeftColumn
          .zIndex(1)
        Color.clear
          .frame(width: timelineInspectorDividerWidth)
          .frame(maxHeight: .infinity)
        timelineRightColumn(geo: geo)
      }
    }
    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    .coordinateSpace(name: "TimelinePanel")
    .overlay(alignment: .topLeading) {
      if goalFlowPresentation == nil {
        timelineCalendarPopoverOverlay(panelWidth: geo.size.width)
      }
    }
    .animation(.spring(response: 0.32, dampingFraction: 0.9), value: goalFlowPresentation?.id)
    .onPreferenceChange(TimelineCalendarButtonFramePreferenceKey.self) { frame in
      timelineCalendarButtonFrame = frame
    }
  }

  private var timelineLeftColumn: some View {
    VStack(alignment: .leading, spacing: TimelineAlignment.headerContentGap) {
      timelineHeader
      timelineContent
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(.top, TimelineAlignment.topInset)
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
      // Deferred for the same reason as the cards-layer frame in
      // CanvasTimelineDataView: avoid state writes during the layout pass.
      DispatchQueue.main.async {
        weeklyHoursFrame = frame
      }
    }
  }

  private var timelineContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      TabFilterBar(
        categories: categoryStore.editableCategories,
        idleCategory: categoryStore.idleCategory,
        onManageCategories: { showCategoryEditor = true }
      )
      .padding(.leading, 10 + TimelineAlignment.categoryRowInset)
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
            weeklyHoursIntersectsCard: $weeklyHoursIntersectsCard,
            contentLeadingInset: 0,
            hourHeight: TimelineScale.hourHeight,
            cardTextFontSize: TimelineTypography.cardTextFontSize,
            cardTextFontWeight: TimelineTypography.cardTextFontWeight,
            timeLabelFontSize: TimelineTypography.timeLabelFontSize,
            cardIconLeadingInset: TimelineCardLayout.iconLeadingInset,
            cardIconTextSpacing: TimelineCardLayout.iconTextSpacing,
            cardFaviconSize: TimelineCardLayout.faviconSize,
            cardFaviconVerticalOffset: TimelineCardLayout.faviconVerticalOffset,
            cardCompactDurationThreshold: TimelineCardLayout.compactDurationThreshold,
            cardCompactVerticalPadding: TimelineCardLayout.compactVerticalPadding,
            cardNormalVerticalPadding: TimelineCardLayout.normalVerticalPadding,
            cardHoverScale: TimelineCardLayout.hoverScale,
            cardPressedScale: TimelineCardLayout.pressedScale
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

  private var cardsToReviewPromptCount: Int {
    guard cardsToReviewCount > 0 else { return 0 }
    if hasRecentTimelineReviewRating || hasAnyTimelineReviewRating == false {
      return cardsToReviewCount
    }
    return 0
  }

  private var timelineFooter: some View {
    let weeklyHoursOpacity =
      weeklyHoursFadeOpacity * (weeklyHoursIntersectsCard ? 0 : 1)
    let reviewPromptCount = cardsToReviewPromptCount

    return ZStack(alignment: .bottom) {
      HStack(alignment: .bottom) {
        weeklyHoursText
          .opacity(contentOpacity * weeklyHoursOpacity)

        Spacer()

        copyTimelineButton
          .opacity(contentOpacity)
      }
      .padding(.horizontal, 24)

      if timelineMode == .day, reviewPromptCount > 0 {
        CardsToReviewButton(count: reviewPromptCount) {
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

  // Figma: the right panel is its own inset card (5pt from the panel edges,
  // 6pt radius, hairline border) rather than a flush column.
  private func timelineRightColumn(geo: GeometryProxy) -> some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    let inset: CGFloat = 5

    return ZStack(alignment: .topLeading) {
      switch timelineMode {
      case .day:
        dayTimelineInspectorContent(geo: geo)
      case .week:
        weekTimelineInspectorContent(geo: geo)
      }
    }
    .frame(width: max(0, timelineInspectorWidth - inset))
    .frame(maxHeight: .infinity)
    .clipShape(shape)
    .background {
      if timelineInspectorWidth > 0 {
        shape
          .fill(theme.rightPanelFill)
          .overlay(shape.strokeBorder(theme.rightPanelBorder, lineWidth: 0.75))
          .shadow(color: theme.rightPanelShadow, radius: 4, x: 0, y: 0)
      }
    }
    .contentShape(shape)
    .padding(.vertical, inset)
    .padding(.trailing, inset)
    .frame(width: timelineInspectorWidth)
    .opacity(contentOpacity)
  }

  @ViewBuilder
  private func dayTimelineInspectorContent(geo: GeometryProxy) -> some View {
    let reviewPromptCount = cardsToReviewPromptCount

    if let activity = selectedActivity {
      timelineActivityInspector(activity: activity, geo: geo)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    } else {
      DaySummaryView(
        selectedDate: selectedDate,
        categories: categoryStore.categories,
        storageManager: StorageManager.shared,
        cardsToReviewCount: reviewPromptCount,
        reviewRefreshToken: reviewSummaryRefreshToken,
        recordingControlMode: RecordingControl.currentMode(
          appState: appState,
          pauseManager: pauseManager
        ),
        goalPromptDay: pendingGoalPromptDay,
        onGoalPromptHandled: { day in
          markDailyGoalPromptHandled(day: day)
        },
        onReviewTap: {
          guard reviewPromptCount > 0 else { return }
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showTimelineReview = true
          }
        },
        onShowGoalFlow: { presentation in
          withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            goalFlowPresentation = presentation
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
        .opacity(weekInspectorContentVisible ? 1 : 0)
        .offset(x: weekInspectorContentVisible ? 0 : 10)
        .animation(inspectorContentAnimation, value: weekInspectorContentVisible)
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
        onTitleChange: { newTitle, activity in
          handleTitleChange(to: newTitle, for: activity)
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
    let textColor = theme.textTertiary
    let parts = timelineTrackedMinutesParts

    return
      (Text(parts.bold)
      .font(Font.custom("Figtree", size: stylePreviewAfter ? 14 : 10).weight(.bold))
      .foregroundColor(textColor)
      + Text(parts.rest)
      .font(Font.custom("Figtree", size: stylePreviewAfter ? 14 : 10).weight(.regular))
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
    let background = theme.secondaryButtonFill
    let stroke = theme.secondaryButtonBorder
    let textColor = theme.secondaryButtonText

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
              .font(Font.custom("Figtree", size: stylePreviewAfter ? 14 : 11.5).weight(.medium))
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
              .font(Font.custom("Figtree", size: stylePreviewAfter ? 14 : 11.5).weight(.medium))
          }
          .transition(.asymmetric(insertion: enterTransition, removal: exitTransition))
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.85), value: copyTimelineState)
      .frame(width: stylePreviewAfter ? 122 : 104, height: stylePreviewAfter ? 26 : 23)
      .foregroundColor(textColor)
      .background(background)
      .background {
        if theme.isDark {
          Rectangle().fill(.ultraThinMaterial)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(stroke, lineWidth: 1)
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
