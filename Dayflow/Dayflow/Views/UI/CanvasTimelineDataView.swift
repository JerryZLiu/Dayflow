import AppKit
import Foundation
import SwiftUI

// MARK: - Cached DateFormatter (creating DateFormatters is expensive due to ICU initialization)

private let cachedTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  formatter.locale = Locale(identifier: "en_US_POSIX")
  return formatter
}()

private struct CanvasConfig {
  static let timeColumnWidth: CGFloat = 60
  static let startHour: Int = 4  // 4 AM baseline
  static let endHour: Int = 28  // 4 AM next day
}

private struct TimelineCardsLayerFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero {
      value = next
    }
  }
}

// Positioned activity for Canvas rendering
private struct CanvasPositionedActivity: Identifiable {
  let id: String
  let activity: TimelineActivity
  let yPosition: CGFloat
  let height: CGFloat
  let durationMinutes: Double
  let title: String
  let timeLabel: String
  let categoryName: String
  // Raw values for pattern matching (may contain paths like "developer.apple.com/xcode")
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  // Normalized hosts for network fetch (just domain)
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
  let failureCount: Int
  let batchIds: [Int64]
}

struct CanvasTimelineDataView: View {
  @Binding var selectedDate: Date
  @Binding var selectedActivity: TimelineActivity?
  @Binding var scrollToNowTick: Int
  @Binding var hasAnyActivities: Bool
  @Binding var refreshTrigger: Int
  let weeklyHoursFrame: CGRect
  @Binding var weeklyHoursIntersectsCard: Bool
  let contentLeadingInset: CGFloat
  let hourHeight: CGFloat
  let cardTextFontSize: CGFloat
  let cardTextFontWeight: TimelineCardTextWeight
  let timeLabelFontSize: CGFloat
  let cardIconLeadingInset: CGFloat
  let cardIconTextSpacing: CGFloat
  let cardFaviconSize: CGFloat
  let cardFaviconVerticalOffset: CGFloat
  let cardCompactDurationThreshold: CGFloat
  let cardCompactVerticalPadding: CGFloat
  let cardNormalVerticalPadding: CGFloat
  let cardHoverScale: CGFloat
  let cardPressedScale: CGFloat

  @State private var selectedCardId: String? = nil
  @State private var positionedActivities: [CanvasPositionedActivity] = []
  @State private var recordingProjection: TimelineRecordingProjectionWindow?
  @State private var cardsLayerFrame: CGRect = .zero
  @State private var refreshTimer: Timer?
  @State private var didInitialScrollInView: Bool = false
  // Gate the ScrollView's visibility on whether the initial auto-scroll has
  // fired. Mirrors the Week view's fix for the "starts at 8 AM then flashes
  // to 10 AM" flicker. Only flips true once per mount; never flips back, so
  // date navigation within a mounted view doesn't re-hide content.
  @State private var hasPerformedInitialScroll: Bool = false
  @State private var loadTask: Task<Void, Never>?
  // Staggered entrance animation state (Emil Kowalski principle: sequential reveal)
  @State private var cardEntranceProgress: [String: Bool] = [:]
  @ObservedObject private var pauseManager = PauseManager.shared
  @EnvironmentObject private var categoryStore: CategoryStore
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var retryCoordinator: RetryCoordinator

  private var pixelsPerMinute: CGFloat {
    hourHeight / 60
  }

  private var timelineHeight: CGFloat {
    CGFloat(CanvasConfig.endHour - CanvasConfig.startHour) * hourHeight
  }

  private var recordingControlMode: RecordingControlMode {
    RecordingControl.currentMode(appState: appState, pauseManager: pauseManager)
  }

  // Which hour-marker id the Day view should scroll to land "now" ~25% down
  // from the viewport top — i.e. 2 hours before the current clock hour. Used
  // by every scroll-to-now trigger (idle reset, initial load, onAppear,
  // date-change-back-to-today). Having one source of truth avoids drift
  // between triggers and keeps the body's inline closures tiny (fixes a
  // Swift type-checker timeout that appeared when each closure inlined its
  // own copy of this calculation).
  private func nowCenteredTargetHourIndex() -> Int {
    let currentHour = Calendar.current.component(.hour, from: Date())
    let hoursSince4AM = currentHour >= 4 ? currentHour - 4 : (24 - 4) + currentHour
    return max(0, hoursSince4AM - 2)
  }

  private func scrollToNowCenteredHour(with proxy: ScrollViewProxy, animated: Bool = false) {
    let targetIndex = nowCenteredTargetHourIndex()
    let action = {
      proxy.scrollTo("hour-\(targetIndex)", anchor: UnitPoint(x: 0, y: 0.25))
    }
    if animated {
      withAnimation(.easeInOut(duration: 0.35)) { action() }
    } else {
      action()
    }
  }

  // `body` is split into two chained computed properties for the same reason
  // `MainView.mainLayout` is: the combined modifier chain + inline closures
  // was exceeding Swift's per-expression type-check budget. Closures with
  // meaningful bodies (onReceive, onDisappear, the outer onAppear) are
  // extracted to named methods below — each `some View` boundary + each
  // function boundary gives the solver a fresh anchor point.
  var body: some View {
    dayTimelineScrollContainer
      .background(Color.clear)
      .onAppear(perform: performDayTimelineOnAppear)
      .onDisappear(perform: performDayTimelineOnDisappear)
      .onChange(of: selectedDate) { loadActivities() }
      .onChange(of: refreshTrigger) { loadActivities() }
      .onChange(of: appState.isRecording) { loadActivities(animate: false) }
      .onChange(of: hourHeight) { loadActivities(animate: false) }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        handleDayTimelineDidBecomeActive()
      }
      .onPreferenceChange(TimelineCardsLayerFramePreferenceKey.self) { frame in
        cardsLayerFrame = frame
        updateWeeklyHoursIntersection()
      }
      .onChange(of: weeklyHoursFrame) {
        updateWeeklyHoursIntersection()
      }
  }

  // Inner ScrollViewReader + scroll-trigger handlers. Held in its own `some
  // View` property so the outer chain above sees a single opaque type.
  // Visibility is gated on `hasPerformedInitialScroll` so the "starts at 8 AM
  // then flashes to 10 AM" flicker can't happen — the ScrollView stays
  // invisible until the first auto-scroll lands, then fades in.
  private var dayTimelineScrollContainer: some View {
    VStack(spacing: 0) {
      deviceLaneHeader
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          timelineScrollContent()
        }
        .background(Color.clear)
        .opacity(hasPerformedInitialScroll ? 1 : 0)
        .onChange(of: scrollToNowTick) {
          scrollToNowCenteredHour(with: proxy)
        }
        .onChange(of: positionedActivities.count) {
          guard !didInitialScrollInView, timelineIsToday(selectedDate) else { return }
          didInitialScrollInView = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            scrollToNowCenteredHour(with: proxy)
            revealInitialScroll()
          }
        }
        .onAppear {
          if timelineIsToday(selectedDate) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
              scrollToNowCenteredHour(with: proxy)
              revealInitialScroll()
            }
          } else {
            revealInitialScroll()
          }
        }
        .onChange(of: selectedDate) { _, newDate in
          guard timelineIsToday(newDate) else { return }
          didInitialScrollInView = false
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            scrollToNowCenteredHour(with: proxy, animated: true)
          }
        }
      }
    }
  }

  private var deviceLaneHeader: some View {
    HStack(spacing: 0) {
      Color.clear.frame(width: CanvasConfig.timeColumnWidth)
      deviceLaneLabel("Mac", systemImage: "laptopcomputer")
      Rectangle()
        .fill(Color.black.opacity(0.08))
        .frame(width: 1, height: 18)
      deviceLaneLabel("Android", systemImage: "smartphone")
    }
    .frame(height: 30)
    .padding(.leading, contentLeadingInset)
  }

  private func deviceLaneLabel(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .medium))
      Text(title)
        .font(.custom("Figtree", size: 12).weight(.semibold))
    }
    .foregroundStyle(Color(hex: "594838").opacity(0.82))
    .frame(maxWidth: .infinity)
  }

  private func revealInitialScroll() {
    guard !hasPerformedInitialScroll else { return }
    withAnimation(.easeOut(duration: 0.18)) {
      hasPerformedInitialScroll = true
    }
  }

  // MARK: - Extracted body event handlers (type-checker load reduction)

  private func performDayTimelineOnAppear() {
    loadActivities()
    startRefreshTimer()
  }

  private func performDayTimelineOnDisappear() {
    stopRefreshTimer()
    loadTask?.cancel()
    loadTask = nil
    weeklyHoursIntersectsCard = false
  }

  private func handleDayTimelineDidBecomeActive() {
    loadActivities(animate: false)
    if refreshTimer == nil {
      startRefreshTimer()
    }
    AnalyticsService.shared.capture(
      "app_became_active",
      [
        "screen": "timeline",
        "selected_date_is_today": timelineIsToday(selectedDate),
      ])
  }

  @ViewBuilder
  private func timelineScrollContent() -> some View {
    ZStack(alignment: .topLeading) {
      // Transparent background to let panel show through
      Color.clear
      // Invisible anchor positioned for "now" scroll target
      nowAnchorView()
        .zIndex(-1)  // Behind other content

      // Hour lines layer
      hourLines
        .padding(.leading, CanvasConfig.timeColumnWidth)

      // Main content with time labels and cards
      mainTimelineRow

      // Current time indicator/status card (kept above cards so paused taps work)
      currentTimeIndicator
        .zIndex(10)
    }
    .frame(height: timelineHeight)
    .padding(.leading, contentLeadingInset)
    .background(Color.clear)
  }

  private var hourLines: some View {
    VStack(spacing: 0) {
      ForEach(0..<(CanvasConfig.endHour - CanvasConfig.startHour), id: \.self) { _ in
        VStack(spacing: 0) {
          Rectangle()
            .fill(Color.black.opacity(0.1))
            .frame(height: 0.75)
          Spacer()
        }
        .frame(height: hourHeight)
      }
    }
  }

  private var timeColumn: some View {
    VStack(spacing: 0) {
      ForEach(CanvasConfig.startHour..<CanvasConfig.endHour, id: \.self) { hour in
        let hourIndex = hour - CanvasConfig.startHour
        Text(formatHour(hour))
          .font(.custom("Figtree", size: timeLabelFontSize))
          .foregroundColor(Color(hex: "594838"))
          .padding(.trailing, 5)
          .padding(.top, 2)
          .frame(width: CanvasConfig.timeColumnWidth, alignment: .trailing)
          .multilineTextAlignment(.trailing)
          .lineLimit(1)
          .minimumScaleFactor(0.95)
          .allowsTightening(true)
          .background(
            GeometryReader { proxy in
              Color.clear.preference(
                key: TimelineTimeLabelFramesPreferenceKey.self,
                value: [proxy.frame(in: .named("TimelinePane"))]
              )
            }
          )
          .frame(height: hourHeight, alignment: .top)
          .offset(y: -8)
          .id("hour-\(hourIndex)")
      }
    }
    .frame(width: CanvasConfig.timeColumnWidth)
    .contentShape(Rectangle())
    .onTapGesture {
      clearSelection()
    }
    .pointingHandCursor(enabled: selectedCardId != nil || selectedActivity != nil)
  }

  private func cardsLayer(for platform: CapturePlatform) -> some View {
    let laneActivities = positionedActivities.filter { $0.activity.platform == platform }
    return GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture {
            clearSelection()
          }
          .pointingHandCursor(enabled: selectedCardId != nil || selectedActivity != nil)
        ForEach(Array(laneActivities.enumerated()), id: \.element.id) { index, item in
          let isVisible = cardEntranceProgress[item.id] ?? false
          CanvasActivityCard(
            title: item.title,
            time: item.timeLabel,
            height: item.height,
            durationMinutes: item.durationMinutes,
            style: style(for: item.categoryName),
            isSelected: selectedCardId == item.id,
            isSystemCategory: item.categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
              .caseInsensitiveCompare("System") == .orderedSame,
            isBackupGenerated: item.activity.isBackupGenerated == true,
            onTap: {
              if selectedCardId == item.id {
                clearSelection()
              } else {
                selectedCardId = item.id
                selectedActivity = item.activity
              }
            },
            faviconPrimaryRaw: item.faviconPrimaryRaw,
            faviconSecondaryRaw: item.faviconSecondaryRaw,
            faviconPrimaryHost: item.faviconPrimaryHost,
            faviconSecondaryHost: item.faviconSecondaryHost,
            statusLine: retryCoordinator.statusLine(for: item.batchIds),
            failureCount: item.failureCount,
            fontSize: cardTextFontSize,
            fontWeight: cardTextFontWeight,
            iconLeadingInset: cardIconLeadingInset,
            iconTextSpacing: cardIconTextSpacing,
            faviconSize: cardFaviconSize,
            faviconVerticalOffset: cardFaviconVerticalOffset,
            compactDurationThreshold: cardCompactDurationThreshold,
            compactVerticalPadding: cardCompactVerticalPadding,
            normalVerticalPadding: cardNormalVerticalPadding,
            hoverScale: cardHoverScale,
            pressedScale: cardPressedScale
          )
          .frame(width: geo.size.width, height: item.height)
          .position(x: geo.size.width / 2, y: item.yPosition + (item.height / 2))
          // Staggered entrance animation (Emil Kowalski: sequential reveal creates polish)
          .opacity(isVisible ? 1 : 0)
          .offset(x: isVisible ? 0 : 12)
          .animation(
            .spring(response: 0.35, dampingFraction: 0.8)
              .delay(Double(index) * 0.03),  // 30ms stagger between cards
            value: isVisible
          )
        }
      }
    }
    // `.clipped()` was here previously with the comment "Prevent shadows/
    // animations from affecting scroll geometry." Removing it because the
    // hovered card's `.hoverScaleEffect(scale: 1.01)` rendered ~0.5% past
    // the cards-layer bounds on each side, and the clip was chopping the
    // scaled card's edges. Watch for any regression in vertical scroll
    // behavior or the weekly-hours-footer overlap logic — those are the
    // paths most likely to have depended on the old clipping.
    .frame(minWidth: 0, maxWidth: .infinity)
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TimelineCardsLayerFramePreferenceKey.self,
          value: proxy.frame(in: .named("TimelinePane"))
        )
      }
    )
  }

  private var mainTimelineRow: some View {
    HStack(spacing: 0) {
      timeColumn
      cardsLayer(for: .macOS)
      Rectangle()
        .fill(Color.black.opacity(0.08))
        .frame(width: 1)
      cardsLayer(for: .android)
    }
  }

  @ViewBuilder
  private var currentTimeIndicator: some View {
    if timelineIsToday(selectedDate), let projection = recordingProjection {
      switch recordingControlMode {
      case .active:
        let projectionHeight = recordingProjectionHeight(for: projection)
        let isCompactProjection = projectionHeight < 24
        timelineStatusCard(
          height: projectionHeight,
          yPosition: calculateYPosition(for: projection.start) + 1,
          gradient: recordingStatusGradient,
          gradientOpacity: 0.70,
          baseColor: Color(hex: "D9C6BA"),
          strokeColor: Color.white.opacity(0.52),
          strokeWidth: 0.75,
          shadowColor: .black.opacity(0.10),
          shadowRadius: 4
        ) {
          if !isCompactProjection {
            generatingStatusText
          }
        }
      case .pausedTimed, .pausedIndefinite:
        let projectionHeight = recordingProjectionHeight(for: projection)
        timelineStatusCard(
          height: projectionHeight,
          yPosition: calculateYPosition(for: projection.start) + 1,
          gradient: pausedStatusGradient,
          gradientOpacity: 1.0,
          baseColor: .clear,
          strokeColor: .white,
          strokeWidth: 1,
          shadowColor: .black.opacity(0.03),
          shadowRadius: 2,
          onTap: handlePausedStatusCardTap
        ) {
          pausedStatusText
        }
      case .stopped:
        let projectionHeight = recordingProjectionHeight(for: projection)
        timelineStatusCard(
          height: projectionHeight,
          yPosition: calculateYPosition(for: projection.start) + 1,
          gradient: pausedStatusGradient,
          gradientOpacity: 1.0,
          baseColor: .clear,
          strokeColor: .white,
          strokeWidth: 1,
          shadowColor: .black.opacity(0.03),
          shadowRadius: 2,
          onTap: handlePausedStatusCardTap
        ) {
          stoppedStatusText
        }
      }
    }
  }

  @ViewBuilder
  private func timelineStatusCard<Content: View>(
    height: CGFloat,
    yPosition: CGFloat,
    gradient: LinearGradient,
    gradientOpacity: Double,
    baseColor: Color,
    strokeColor: Color,
    strokeWidth: CGFloat,
    shadowColor: Color,
    shadowRadius: CGFloat,
    onTap: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 0) {
      content()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .frame(
      maxWidth: .infinity,
      minHeight: height,
      maxHeight: height,
      alignment: .leading
    )
    .background(
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(baseColor)
        .overlay(
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(gradient)
            .opacity(gradientOpacity)
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .inset(by: 0.375)
        .stroke(strokeColor, lineWidth: strokeWidth)
    )
    .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 0)
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .offset(y: yPosition)
    .padding(.leading, CanvasConfig.timeColumnWidth)
    .pointingHandCursor(enabled: onTap != nil)
    .onTapGesture {
      onTap?()
    }
    .allowsHitTesting(onTap != nil)
  }

  private var recordingStatusGradient: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: Color(hex: "5E7FC0"), location: 0.00),
        .init(color: Color(hex: "D88ECE"), location: 0.35),
        .init(color: Color(hex: "FFC19E"), location: 0.68),
        .init(color: Color(hex: "FFEDE0"), location: 1.00),
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private var pausedStatusGradient: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: Color(hex: "F7E6D5"), location: 0.13),
        .init(color: Color(hex: "DADEE4"), location: 1.00),
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private var generatingStatusText: some View {
    HStack(spacing: 8) {
      TimelineThinkingSpinner(
        config: timelineSpinnerConfig,
        visualScale: 0.5
      )
      Text("Generating your next card")
    }
    .font(
      Font.custom("Figtree", size: 12)
        .weight(.semibold)
    )
    .lineSpacing(2.4)
    .tracking(0)
    .foregroundColor(.white)
    .lineLimit(1)
    .truncationMode(.tail)
  }

  private var pausedStatusText: some View {
    statusText(
      iconName: "pause.fill",
      message: "Dayflow is paused. Click 'Resume' to generate new activity cards."
    )
  }

  private var stoppedStatusText: some View {
    statusText(
      iconName: "play.fill",
      message: "Dayflow isn't recording. Click 'Resume' to generate new activity cards."
    )
  }

  private func statusText(iconName: String, message: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: iconName)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Color(hex: "888D95"))
      Text(message)
    }
    .font(
      Font.custom("Figtree", size: 12)
        .weight(.regular)
    )
    .lineSpacing(2.4)
    .tracking(0)
    .foregroundColor(Color(hex: "888D95"))
    .lineLimit(1)
    .truncationMode(.tail)
  }

  @MainActor
  private func handlePausedStatusCardTap() {
    switch recordingControlMode {
    case .active:
      return
    case .pausedTimed, .pausedIndefinite:
      AnalyticsService.shared.capture(
        "timeline_paused_card_clicked",
        [
          "action": "resume_recording"
        ])
      PauseManager.shared.resume(source: .userClickedMainApp)
    case .stopped:
      AnalyticsService.shared.capture(
        "timeline_stopped_card_clicked",
        [
          "action": "start_recording"
        ])
      RecordingControl.start(reason: "user_main_app")
    }
  }

  private func clearSelection() {
    guard selectedCardId != nil || selectedActivity != nil else { return }
    selectedCardId = nil
    selectedActivity = nil
  }

  private var timelineSpinnerConfig: TimelineSpinnerConfig {
    var config = TimelineSpinnerConfig.reference
    config.gap = 1.0
    config.colorDim = .init(0.263, 0.365, 0.592)  // #435D97
    config.colorMid = .init(0.722, 0.518, 0.737)  // #B884BC
    config.colorHot = .init(0.965, 0.745, 0.455)  // #F6BE74
    return config
  }

  private func loadActivities(animate: Bool = true) {
    // Cancel any in-flight database read to prevent query pileup
    loadTask?.cancel()

    loadTask = Task.detached(priority: .userInitiated) {
      let calendar = Calendar.current

      // Normalize to noon so time components do not leak into day jumps
      let requestedSelectedDate = await MainActor.run { self.selectedDate }
      let logicalDate =
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: requestedSelectedDate)
        ?? requestedSelectedDate

      // Check for cancellation before expensive database read
      guard !Task.isCancelled else { return }

      // Shared loader handles the 4 AM boundary, failed-card filtering, and
      // card -> activity conversion (same path the Week view uses).
      let payload = TimelineActivityLoader.dayPayload(for: logicalDate)
      let dayString = payload.dayString

      // Check for cancellation before expensive processing
      guard !Task.isCancelled else { return }

      // Mitigation transform: resolve visual overlaps by trimming larger cards
      // so that smaller cards "win". This is a display-only fix to handle
      // upstream card-generation overlap bugs without touching stored data.
      let segments = Dictionary(grouping: payload.activities, by: \.deviceId)
        .values
        .flatMap { TimelineActivityLoader.resolveDisplaySegments(from: $0) }
        .sorted { $0.start < $1.start }
      let recordingProjection = TimelineActivityLoader.recordingProjectionWindow(
        for: payload.timelineDate,
        displaySegments: segments,
        now: Date()
      )

      let positioned = segments.map { seg -> CanvasPositionedActivity in
        let y = self.calculateYPosition(for: seg.start)
        // Card spacing: -2 total (1px top + 1px bottom)
        let durationMinutes = max(0, seg.end.timeIntervalSince(seg.start) / 60)
        let rawHeight = CGFloat(durationMinutes) * pixelsPerMinute
        let height = max(10, rawHeight - 2)
        // Raw values for pattern matching, normalized for network fetch
        let primaryRaw = seg.activity.appSites?.primary
        let secondaryRaw = seg.activity.appSites?.secondary
        let primaryHost = FaviconService.normalizedHost(from: primaryRaw)
        let secondaryHost = FaviconService.normalizedHost(from: secondaryRaw)

        return CanvasPositionedActivity(
          id: seg.activity.id,
          activity: seg.activity,
          yPosition: y + 1,  // 1px top spacing
          height: height,
          durationMinutes: durationMinutes,
          title: seg.activity.title,
          timeLabel: self.formatRange(start: seg.start, end: seg.end),
          categoryName: seg.activity.category,
          faviconPrimaryRaw: primaryRaw,
          faviconSecondaryRaw: secondaryRaw,
          faviconPrimaryHost: primaryHost,
          faviconSecondaryHost: secondaryHost,
          failureCount: seg.failureCount,
          batchIds: seg.batchIds
        )
      }

      // Final cancellation check before updating UI
      guard !Task.isCancelled else { return }

      let currentDayString = await MainActor.run {
        DateFormatter.yyyyMMdd.string(
          from: timelineDisplayDate(from: self.selectedDate, now: Date()))
      }

      guard currentDayString == dayString else {
        timelinePerfLog(
          "dayTimeline.load.discardStale requestedDay=\(dayString) currentDay=\(currentDayString)"
        )
        return
      }

      await MainActor.run {
        if animate {
          // Clear entrance progress for new activities (triggers stagger animation)
          self.cardEntranceProgress = [:]
        }
        self.positionedActivities = positioned
        self.recordingProjection = recordingProjection
        self.hasAnyActivities = !positioned.isEmpty
        if let selectedActivity,
          !positioned.contains(where: { $0.activity.id == selectedActivity.id })
        {
          clearSelection()
        }
        self.updateWeeklyHoursIntersection()

        if animate {
          // Trigger staggered entrance animation after a brief layout delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for activity in positioned {
              self.cardEntranceProgress[activity.id] = true
            }
          }
        } else {
          // Silent refresh: ensure all cards are visible immediately (no animation)
          for activity in positioned {
            self.cardEntranceProgress[activity.id] = true
          }
        }

        NotificationCenter.default.post(
          name: .timelineDataUpdated,
          object: nil,
          userInfo: ["dayString": dayString]
        )
      }
    }
  }

  private func updateWeeklyHoursIntersection() {
    guard weeklyHoursFrame != .zero,
      cardsLayerFrame != .zero,
      weeklyHoursFrame.intersects(cardsLayerFrame)
    else {
      if weeklyHoursIntersectsCard {
        weeklyHoursIntersectsCard = false
      }
      return
    }

    let intersectsTimelineCard = positionedActivities.contains { item in
      let cardFrame = CGRect(
        x: cardsLayerFrame.minX,
        y: cardsLayerFrame.minY + item.yPosition,
        width: cardsLayerFrame.width,
        height: item.height
      )
      return cardFrame.intersects(weeklyHoursFrame)
    }

    let intersectsStatusCard: Bool
    if let projection = recordingProjection {
      let statusFrame = CGRect(
        x: cardsLayerFrame.minX,
        y: cardsLayerFrame.minY + calculateYPosition(for: projection.start) + 1,
        width: cardsLayerFrame.width,
        height: recordingProjectionHeight(for: projection)
      )
      intersectsStatusCard = statusFrame.intersects(weeklyHoursFrame)
    } else {
      intersectsStatusCard = false
    }

    let intersects = intersectsTimelineCard || intersectsStatusCard

    if weeklyHoursIntersectsCard != intersects {
      weeklyHoursIntersectsCard = intersects
    }
  }

  private func recordingProjectionHeight(for projection: TimelineRecordingProjectionWindow)
    -> CGFloat
  {
    let durationMinutes = max(0, projection.end.timeIntervalSince(projection.start) / 60)
    let rawHeight = CGFloat(durationMinutes) * pixelsPerMinute
    return max(10, rawHeight - 2)
  }

  private func startRefreshTimer() {
    stopRefreshTimer()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
      loadActivities(animate: false)
    }
  }

  private func stopRefreshTimer() {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  private func calculateYPosition(for time: Date) -> CGFloat {
    let calendar = Calendar.current
    let hour = calendar.component(.hour, from: time)
    let minute = calendar.component(.minute, from: time)

    let hoursSince4AM: Int
    if hour >= CanvasConfig.startHour {
      hoursSince4AM = hour - CanvasConfig.startHour
    } else {
      hoursSince4AM = (24 - CanvasConfig.startHour) + hour
    }

    let totalMinutes = hoursSince4AM * 60 + minute
    return CGFloat(totalMinutes) * pixelsPerMinute
  }

  private func formatHour(_ hour: Int) -> String {
    let normalizedHour = hour >= 24 ? hour - 24 : hour
    let adjustedHour =
      normalizedHour > 12 ? normalizedHour - 12 : (normalizedHour == 0 ? 12 : normalizedHour)
    let period = normalizedHour >= 12 ? "PM" : "AM"
    return "\(adjustedHour):00 \(period)"
  }

  private func formatRange(start: Date, end: Date) -> String {
    let s = cachedTimeFormatter.string(from: start)
    let e = cachedTimeFormatter.string(from: end)
    return "\(s) - \(e)"
  }

  private func style(for rawCategory: String) -> CanvasActivityCardStyle {
    let normalized = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let categories = categoryStore.categories
    let matched = categories.first {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }
    let fallback = categories.first ?? CategoryPersistence.defaultCategories.first!
    let category = matched ?? fallback

    let baseNSColor = NSColor(hex: category.colorHex) ?? NSColor(hex: "#4F80EB") ?? .systemBlue

    return CanvasActivityCardStyle(
      text: Color.black.opacity(0.9),
      time: Color.black.opacity(0.7),
      accent: Color(nsColor: baseNSColor),
      isIdle: category.isIdle
    )
  }
}

extension CanvasTimelineDataView {
  // Places a hidden view at a position slightly above "now" so that scrolling reveals "now" plus more below
  @ViewBuilder
  private func nowAnchorView() -> some View {
    // Position anchor ABOVE current time for 80% down viewport positioning
    let yNow = calculateYPosition(for: Date())

    // Place anchor ~6 hours above current time
    // When scrolled to .top, this positions current time at ~80% down the viewport
    // Adjust hoursAbove to fine-tune: 5 = current time appears higher, 7 = lower
    let hoursAbove: CGFloat = 6
    let anchorY = yNow - (hoursAbove * hourHeight)

    // Create a frame that spans the full timeline height
    // Then position the anchor absolutely within it
    Color.clear
      .frame(
        width: 1,
        height: timelineHeight
      )
      .overlay(
        Rectangle()
          .fill(Color.red.opacity(0.001))
          .frame(width: 10, height: 20)
          .position(x: 5, y: anchorY)
          .id("nowAnchor"),
        alignment: .topLeading
      )
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

#Preview("Canvas Timeline Data View") {
  struct PreviewWrapper: View {
    @State private var date = Date()
    @State private var selected: TimelineActivity? = nil
    @State private var tick: Int = 0
    @State private var refresh: Int = 0
    @State private var weeklyHoursIntersectsCard = false
    var body: some View {
      CanvasTimelineDataView(
        selectedDate: $date,
        selectedActivity: $selected,
        scrollToNowTick: $tick,
        hasAnyActivities: .constant(true),
        refreshTrigger: $refresh,
        weeklyHoursFrame: .zero,
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
      .frame(width: 800, height: 600)
      .environmentObject(CategoryStore())
      .environmentObject(AppState.shared)
      .environmentObject(RetryCoordinator())
    }
  }
  return PreviewWrapper()
}
