import AppKit
import SwiftUI

private enum WeekTimelineConfig {
  static let hourHeight: CGFloat = 111
  static let pixelsPerMinute: CGFloat = hourHeight / 60
  static let timeColumnWidth: CGFloat = 48
  static let startHour: Int = 4
  static let endHour: Int = 28
  static let weekHeaderHeight: CGFloat = 22
  static let headerSpacing: CGFloat = 2
  static let weekdayInlineSpacing: CGFloat = 6
  static let selectedDayLeadingMinutes: CGFloat = 60
  static let fallbackLeadingMinutes: CGFloat = 60
  static let cardLeadingGap: CGFloat = 3
  static let cardTrailingGap: CGFloat = 5
  static let minimumCardHeight: CGFloat = 16
  static let totalHeight: CGFloat = CGFloat(endHour - startHour) * hourHeight
  // Hover-expand tuning
  static let hoverEnterDelay: TimeInterval = 0.12
  static let hoverExitDelay: TimeInterval = 0.06
}

private struct WeekStatusCardStyle {
  let gradient: LinearGradient
  let gradientOpacity: Double
  let baseColor: Color
  let strokeColor: Color
  let strokeWidth: CGFloat
  let shadowColor: Color
  let shadowRadius: CGFloat
}

// Internal (not private) so the synthesized memberwise init of
// `WeekTimelineGridView` — which references this type via the
// `previewPositionedActivities` default param — stays internal and external
// callers (Layout.swift) continue to compile. The type itself isn't used
// outside this file.
struct WeekPositionedActivity: Identifiable {
  let id: String
  let activity: TimelineActivity
  let columnIndex: Int
  let yPosition: CGFloat
  let height: CGFloat
  let durationMinutes: Double
  let title: String
  let hoverTimeLabel: String
  let categoryName: String
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
}

// Published by each card's hidden measurement view; collected by the parent grid.
private struct CardExpandedHeightPreferenceKey: PreferenceKey {
  static var defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

// Published by the week view's cards layer; consumed locally to drive the
// weekly-hours-footer overlap check (mirrors the day view's equivalent key).
private struct WeekCardsLayerFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero {
      value = next
    }
  }
}

struct WeekTimelineGridView: View {
  @Binding var selectedDate: Date
  @Binding var selectedActivity: TimelineActivity?
  @Binding var hasAnyActivities: Bool
  @Binding var refreshTrigger: Int

  let weekRange: TimelineWeekRange
  let onSelectActivity: (TimelineActivity) -> Void
  let onClearSelection: () -> Void

  // Frame of the "X hours tracked" footer label in the TimelinePane coord
  // space; the grid compares against this to hide the label when it'd sit
  // over a card. Defaults to .zero so Xcode previews don't need to wire it.
  var weeklyHoursFrame: CGRect = .zero
  var weeklyHoursIntersectsCard: Binding<Bool> = .constant(false)
  var hideCardsForModeSwitch = false

  // Opt-in fake data for #Preview; nil in production so loadActivities() runs normally.
  var previewPositionedActivities: [WeekPositionedActivity]? = nil

  @State private var positionedActivities: [WeekPositionedActivity] = []
  @State private var recordingProjection: TimelineRecordingProjectionWindow?
  @State private var cardsLayerFrame: CGRect = .zero
  @State private var refreshTimer: Timer?
  @State private var loadTask: Task<Void, Never>?
  @State private var autoScrollWeekKey: String?
  // Gate the ScrollView's visibility on whether the initial auto-scroll has
  // fired. Prevents the flash-then-jump flicker where the ScrollView
  // momentarily renders at its default top position (~4 AM) and is then
  // yanked to the data-driven target hour (~10 AM). Flip-to-true is
  // sequenced one runloop after scrollToRelevantHour so the scroll offset
  // has committed before content becomes visible.
  @State private var hasPerformedInitialScroll: Bool = false

  // Hover-expand state. Parent owns it so the whole grid animates coherently.
  @State private var hoveredCardID: String?
  @State private var pendingHoverWorkItem: DispatchWorkItem?
  @State private var measuredExpandedHeights: [String: CGFloat] = [:]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @AppStorage("showTimelineAppIcons") private var showTimelineAppIcons = true
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var categoryStore: CategoryStore
  @EnvironmentObject private var retryCoordinator: RetryCoordinator
  @ObservedObject private var pauseManager = PauseManager.shared

  private var recordingControlMode: RecordingControlMode {
    RecordingControl.currentMode(appState: appState, pauseManager: pauseManager)
  }

  private var todayDayString: String {
    DateFormatter.yyyyMMdd.string(from: timelineDisplayDate(from: Date()))
  }

  private var selectedDayString: String {
    DateFormatter.yyyyMMdd.string(from: timelineDisplayDate(from: selectedDate))
  }

  private var weekAutoScrollKey: String {
    DateFormatter.yyyyMMdd.string(from: weekRange.weekStart)
  }

  private func effectiveHeight(for item: WeekPositionedActivity) -> CGFloat {
    guard hoveredCardID == item.id else { return item.height }
    let measured = measuredExpandedHeights[item.id] ?? item.height
    // +4pt safety buffer: the measurement view uses `.fixedSize(vertical: true)`
    // on its Text while the rendered card does not, which can produce a
    // sub-pixel difference in reported vs. actual natural height. Without
    // this buffer, some titles fit cleanly and others truncate the tail with
    // "..." — the ~0.5pt shortfall is enough for `.truncationMode(.tail)` to
    // kick in. 4pt is imperceptible visually but absorbs all observed drift.
    return max(item.height, measured + 4)
  }

  private var hoverAnimation: Animation {
    reduceMotion
      ? .linear(duration: 0.1)
      : .spring(response: 0.28, dampingFraction: 0.88)
  }

  private var collapseAnimation: Animation {
    reduceMotion
      ? .linear(duration: 0.08)
      : .spring(response: 0.28, dampingFraction: 0.88).speed(1.4)
  }

  var body: some View {
    GeometryReader { geometry in
      let gridWidth = max(0, geometry.size.width - WeekTimelineConfig.timeColumnWidth)
      let dayWidth = gridWidth / 7

      VStack(alignment: .leading, spacing: WeekTimelineConfig.headerSpacing) {
        weekHeader(dayWidth: dayWidth)
          .frame(height: WeekTimelineConfig.weekHeaderHeight, alignment: .topLeading)

        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            timelineContent(dayWidth: dayWidth, gridWidth: gridWidth)
          }
          .background(Color.clear)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          // Hidden until the first auto-scroll lands. The ScrollView is still
          // laid out and scrollable under the hood — opacity 0 just keeps
          // the pre-positioned default frame off-screen so the user never
          // sees the 4 AM → target hour flash.
          .opacity(hasPerformedInitialScroll ? 1 : 0)
          // Only auto-scroll the very first time the Week view mounts (oldValue
          // nil → first loadActivities sets the key). Subsequent week changes
          // preserve whatever scroll offset the user had, so navigating
          // between weeks doesn't feel like the time axis is jumping around.
          .onChange(of: autoScrollWeekKey) { oldValue, newValue in
            guard oldValue == nil, newValue != nil else { return }
            scrollToRelevantHour(with: proxy, animated: false)
            // Reveal content after the scroll has been applied. 50ms buffer
            // gives the ScrollView time to commit its offset (scrollToRelevantHour
            // already dispatches to the next runloop; we wait one more so
            // the scroll lands first, then the fade-in reveals the positioned
            // content). The 0.18s easeOut softens the reveal so the Week
            // view doesn't pop in hard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
              withAnimation(.easeOut(duration: 0.18)) {
                hasPerformedInitialScroll = true
              }
            }
          }
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
    .onAppear {
      loadActivities(trigger: "appear")
      startRefreshTimer()
    }
    .onDisappear {
      stopRefreshTimer()
      loadTask?.cancel()
      loadTask = nil
      pendingHoverWorkItem?.cancel()
      pendingHoverWorkItem = nil
      if weeklyHoursIntersectsCard.wrappedValue {
        weeklyHoursIntersectsCard.wrappedValue = false
      }
    }
    .onChange(of: selectedDate) { oldDate, newDate in
      let oldWeek = TimelineWeekRange.containing(oldDate)
      let newWeek = TimelineWeekRange.containing(newDate)
      let weekChanged = oldWeek != newWeek
      let oldDay = DateFormatter.yyyyMMdd.string(from: timelineDisplayDate(from: oldDate))
      let newDay = DateFormatter.yyyyMMdd.string(from: timelineDisplayDate(from: newDate))
      let visibleWeek = DateFormatter.yyyyMMdd.string(from: weekRange.weekStart)

      timelinePerfLog(
        "weekGrid.selectedDateChanged old=\(oldDay) new=\(newDay) visibleWeek=\(visibleWeek) weekChanged=\(weekChanged)"
      )
    }
    .onChange(of: weekRange) { oldWeek, newWeek in
      let oldWeekDay = DateFormatter.yyyyMMdd.string(from: oldWeek.weekStart)
      let newWeekDay = DateFormatter.yyyyMMdd.string(from: newWeek.weekStart)

      timelinePerfLog(
        "weekGrid.visibleWeekChanged old=\(oldWeekDay) new=\(newWeekDay)"
      )

      loadActivities(trigger: "weekRangeChanged")
    }
    .onChange(of: refreshTrigger) {
      loadActivities(trigger: "refreshTrigger")
    }
    .onChange(of: appState.isRecording) {
      loadActivities(trigger: "recordingStateChanged")
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      loadActivities(trigger: "appBecameActive")
      if refreshTimer == nil {
        startRefreshTimer()
      }
    }
    .onPreferenceChange(WeekCardsLayerFramePreferenceKey.self) { frame in
      cardsLayerFrame = frame
      updateWeeklyHoursIntersection()
    }
    .onChange(of: weeklyHoursFrame) {
      updateWeeklyHoursIntersection()
    }
  }

  private func weekHeader(dayWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
      Color.clear
        .frame(width: WeekTimelineConfig.timeColumnWidth)

      ForEach(weekRange.days) { day in
        HStack(spacing: WeekTimelineConfig.weekdayInlineSpacing) {
          Text(day.weekdayLabel)
            .font(.custom("Nunito", size: 12).weight(.medium))
            .foregroundColor(Color(hex: "333333"))

          dayNumberBadge(for: day)
        }
        .frame(width: dayWidth, alignment: .center)
      }
    }
  }

  @ViewBuilder
  private func dayNumberBadge(for day: TimelineWeekDay) -> some View {
    let isToday = day.dayString == todayDayString

    if isToday {
      Text(day.dayNumber)
        .font(.custom("Nunito", size: 12).weight(.semibold))
        .foregroundColor(.white)
        .frame(width: 18, height: 18)
        .background(
          Circle()
            .fill(Color(hex: "F96E00"))
        )
    } else {
      Text(day.dayNumber)
        .font(.custom("Nunito", size: 12).weight(.medium))
        .foregroundColor(Color(hex: "333333"))
    }
  }

  private func timelineContent(dayWidth: CGFloat, gridWidth: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture {
          onClearSelection()
        }

      weekGridLines(dayWidth: dayWidth, gridWidth: gridWidth)

      HStack(spacing: 0) {
        timeColumn
        weekCardsArea(dayWidth: dayWidth)
      }
      .zIndex(hoveredCardID != nil ? 4 : 0)

      if !hideCardsForModeSwitch,
        let recordingProjection,
        let todayIndex = weekRange.days.firstIndex(where: { $0.dayString == todayDayString })
      {
        statusCard(
          dayWidth: dayWidth,
          columnIndex: todayIndex,
          projection: recordingProjection
        )
      }
    }
    .frame(height: WeekTimelineConfig.totalHeight)
  }

  @ViewBuilder
  private func weekCardsArea(dayWidth: CGFloat) -> some View {
    if hideCardsForModeSwitch {
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      cardsLayer(dayWidth: dayWidth)
    }
  }

  private func weekGridLines(dayWidth: CGFloat, gridWidth: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
      VStack(spacing: 0) {
        ForEach(0..<(WeekTimelineConfig.endHour - WeekTimelineConfig.startHour), id: \.self) { _ in
          VStack(spacing: 0) {
            Rectangle()
              .fill(Color.black.opacity(0.1))
              .frame(height: 1)
            Spacer(minLength: 0)
          }
          .frame(height: WeekTimelineConfig.hourHeight)
        }
      }
      .padding(.leading, WeekTimelineConfig.timeColumnWidth)

      HStack(spacing: 0) {
        ForEach(0..<8, id: \.self) { index in
          Rectangle()
            .fill(Color.black.opacity(0.1))
            .frame(width: index == 0 ? 0 : 1)

          if index < 7 {
            Color.clear
              .frame(width: dayWidth)
          }
        }
      }
      .padding(.leading, WeekTimelineConfig.timeColumnWidth)
      .frame(width: gridWidth + WeekTimelineConfig.timeColumnWidth, alignment: .leading)
    }
  }

  private var timeColumn: some View {
    VStack(spacing: 0) {
      ForEach(WeekTimelineConfig.startHour..<WeekTimelineConfig.endHour, id: \.self) { hour in
        let hourIndex = hour - WeekTimelineConfig.startHour
        Text(formatHour(hour))
          .font(.custom("Figtree", size: 9))
          .foregroundColor(Color(hex: "594838"))
          .padding(.trailing, 6)
          .padding(.top, 2)
          .frame(width: WeekTimelineConfig.timeColumnWidth, alignment: .trailing)
          .background(
            GeometryReader { proxy in
              Color.clear.preference(
                key: TimelineTimeLabelFramesPreferenceKey.self,
                value: [proxy.frame(in: .named("TimelinePane"))]
              )
            }
          )
          .frame(height: WeekTimelineConfig.hourHeight, alignment: .top)
          .offset(y: -7)
          .id("week-hour-\(hourIndex)")
      }
    }
    .frame(width: WeekTimelineConfig.timeColumnWidth)
  }

  private func cardsLayer(dayWidth: CGFloat) -> some View {
    let cardWidth = weekCardWidth(for: dayWidth)

    return ZStack(alignment: .topLeading) {
      ForEach(positionedActivities) { item in
        let cardXPosition = weekCardXPosition(for: item.columnIndex, dayWidth: dayWidth)
        let isHov = hoveredCardID == item.id
        let cardEffectiveHeight = effectiveHeight(for: item)

        WeekTimelineActivityCard(
          cardId: item.id,
          title: item.title,
          hoverTimeLabel: item.hoverTimeLabel,
          height: item.height,
          effectiveHeight: cardEffectiveHeight,
          durationMinutes: item.durationMinutes,
          palette: palette(for: item.categoryName),
          isSelected: selectedActivity?.id == item.id,
          isHovered: isHov,
          showTimelineAppIcons: showTimelineAppIcons,
          faviconPrimaryRaw: item.faviconPrimaryRaw,
          faviconSecondaryRaw: item.faviconSecondaryRaw,
          faviconPrimaryHost: item.faviconPrimaryHost,
          faviconSecondaryHost: item.faviconSecondaryHost,
          statusLine: retryCoordinator.statusLine(for: item.activity.batchId),
          isRetryActive: retryCoordinator.isActive(batchId: item.activity.batchId),
          onHoverChanged: { hovering in
            scheduleHoverChange(cardID: item.id, hovering: hovering)
          }
        ) {
          if selectedActivity?.id == item.id {
            onClearSelection()
          } else {
            onSelectActivity(item.activity)
          }
        }
        .frame(width: cardWidth)
        .position(x: cardXPosition, y: item.yPosition + cardEffectiveHeight / 2)
        .animation(isHov ? hoverAnimation : collapseAnimation, value: hoveredCardID)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: WeekCardsLayerFramePreferenceKey.self,
          value: proxy.frame(in: .named("TimelinePane"))
        )
      }
    )
    // Defensive hover-exit handler. SwiftUI's per-card `.onHover(false)` can
    // miss the exit event when the mouse moves quickly or when the card
    // resizes mid-hover (the expand animation can reach under the cursor
    // before the card's `.onHover` registers the leave). This parent-level
    // `.onHover` fires (false) when the mouse leaves the whole cards layer,
    // clearing any stuck hover state and cancelling any pending
    // hover-intent work item.
    .onHover { hovering in
      guard !hovering else { return }
      pendingHoverWorkItem?.cancel()
      pendingHoverWorkItem = nil
      hoveredCardID = nil
    }
    .onPreferenceChange(CardExpandedHeightPreferenceKey.self) { values in
      measuredExpandedHeights = values
    }
  }

  // Debounced hover intent: filters out drive-by hovers when the mouse sweeps
  // across the grid. Enter delay (120ms) > exit delay (60ms) so collapse feels
  // snappy while expand requires intent.
  private func scheduleHoverChange(cardID: String, hovering: Bool) {
    pendingHoverWorkItem?.cancel()

    let work = DispatchWorkItem {
      if hovering {
        hoveredCardID = cardID
      } else if hoveredCardID == cardID {
        hoveredCardID = nil
      }
    }
    pendingHoverWorkItem = work

    let delay =
      hovering
      ? WeekTimelineConfig.hoverEnterDelay
      : WeekTimelineConfig.hoverExitDelay
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  @ViewBuilder
  private func statusCard(
    dayWidth: CGFloat,
    columnIndex: Int,
    projection: TimelineRecordingProjectionWindow
  ) -> some View {
    let cardWidth = weekCardWidth(for: dayWidth)
    let projectionHeight = recordingProjectionHeight(for: projection)
    let compact = projectionHeight < 24
    let style = statusCardStyle

    HStack(spacing: 0) {
      statusCardLabel(compact: compact)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(
      width: cardWidth,
      height: projectionHeight,
      alignment: .leading
    )
    .background(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(style.baseColor)
        .overlay(
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(style.gradient)
            .opacity(style.gradientOpacity)
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .inset(by: 0.375)
        .stroke(style.strokeColor, lineWidth: style.strokeWidth)
    )
    .shadow(color: style.shadowColor, radius: style.shadowRadius, x: 0, y: 0)
    .position(
      x: WeekTimelineConfig.timeColumnWidth
        + weekCardXPosition(for: columnIndex, dayWidth: dayWidth),
      y: calculateYPosition(for: projection.start) + 1 + projectionHeight / 2
    )
    .zIndex(3)
  }

  private var statusCardStyle: WeekStatusCardStyle {
    switch recordingControlMode {
    case .active:
      return WeekStatusCardStyle(
        gradient: LinearGradient(
          stops: [
            .init(color: Color(hex: "5E7FC0"), location: 0.00),
            .init(color: Color(hex: "D88ECE"), location: 0.35),
            .init(color: Color(hex: "FFC19E"), location: 0.68),
            .init(color: Color(hex: "FFEDE0"), location: 1.00),
          ],
          startPoint: .leading,
          endPoint: .trailing
        ),
        gradientOpacity: 0.70,
        baseColor: Color(hex: "D9C6BA"),
        strokeColor: Color.white.opacity(0.52),
        strokeWidth: 0.75,
        shadowColor: .black.opacity(0.10),
        shadowRadius: 4
      )

    case .pausedTimed, .pausedIndefinite, .stopped:
      return WeekStatusCardStyle(
        gradient: LinearGradient(
          stops: [
            .init(color: Color(hex: "F7E6D5"), location: 0.13),
            .init(color: Color(hex: "DADEE4"), location: 1.00),
          ],
          startPoint: .leading,
          endPoint: .trailing
        ),
        gradientOpacity: 1.0,
        baseColor: .clear,
        strokeColor: .white,
        strokeWidth: 1,
        shadowColor: .black.opacity(0.03),
        shadowRadius: 2
      )
    }
  }

  @ViewBuilder
  private func statusCardLabel(compact: Bool) -> some View {
    switch recordingControlMode {
    case .active:
      HStack(spacing: 6) {
        TimelineThinkingSpinner(config: spinnerConfig, visualScale: 0.4)
        if !compact {
          Text("Next card...")
            .font(.custom("Nunito", size: 10).weight(.semibold))
            .foregroundColor(.white)
            .lineLimit(1)
        }
      }
    case .pausedTimed, .pausedIndefinite:
      Label("Paused", systemImage: "pause.fill")
        .font(.custom("Nunito", size: 10).weight(.medium))
        .foregroundColor(Color(hex: "888D95"))
    case .stopped:
      Label("Resume", systemImage: "play.fill")
        .font(.custom("Nunito", size: 10).weight(.medium))
        .foregroundColor(Color(hex: "888D95"))
    }
  }

  private var spinnerConfig: TimelineSpinnerConfig {
    var config = TimelineSpinnerConfig.reference
    config.gap = 1.0
    config.colorDim = .init(0.263, 0.365, 0.592)
    config.colorMid = .init(0.722, 0.518, 0.737)
    config.colorHot = .init(0.965, 0.745, 0.455)
    return config
  }

  private func loadActivities(trigger: String = "unspecified") {
    let requestedSelectedDate = selectedDate
    let requestedSelectedDay = DateFormatter.yyyyMMdd.string(
      from: timelineDisplayDate(from: requestedSelectedDate)
    )
    let requestedWeekRange = TimelineWeekRange.containing(requestedSelectedDate)
    let requestedWeekID = DateFormatter.yyyyMMdd.string(from: requestedWeekRange.weekStart)

    // Preview short-circuit: skip DB entirely when fake data is injected.
    if let preview = previewPositionedActivities {
      loadTask?.cancel()
      loadTask = nil
      positionedActivities = preview
      recordingProjection = nil
      hasAnyActivities = !preview.isEmpty
      if autoScrollWeekKey != requestedWeekID {
        autoScrollWeekKey = requestedWeekID
      }
      timelinePerfLog(
        "weekGrid.load.preview trigger=\(trigger) week=\(requestedWeekID) selected=\(requestedSelectedDay) cards=\(preview.count)"
      )
      return
    }

    if loadTask != nil {
      timelinePerfLog("weekGrid.load.cancelPrevious trigger=\(trigger) week=\(requestedWeekID)")
    }
    loadTask?.cancel()

    timelinePerfLog(
      "weekGrid.load.begin trigger=\(trigger) week=\(requestedWeekID) selected=\(requestedSelectedDay)"
    )

    loadTask = Task.detached(priority: .userInitiated) {
      let overallStart = CFAbsoluteTimeGetCurrent()
      let fetchStart = CFAbsoluteTimeGetCurrent()
      let activities = TimelineActivityLoader.activities(in: requestedWeekRange)
      let fetchMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)
      let weekDays = requestedWeekRange.days
      let dayLookup = Dictionary(
        uniqueKeysWithValues: weekDays.enumerated().map { ($1.dayString, $0) })

      let positioningStart = CFAbsoluteTimeGetCurrent()
      var positioned: [WeekPositionedActivity] = []
      positioned.reserveCapacity(activities.count)

      for day in weekDays {
        let dayActivities = activities.filter {
          $0.startTime.getDayInfoFor4AMBoundary().dayString == day.dayString
        }
        let segments = TimelineActivityLoader.resolveDisplaySegments(from: dayActivities)

        for segment in segments {
          let durationMinutes = max(0, segment.end.timeIntervalSince(segment.start) / 60)
          let rawHeight = CGFloat(durationMinutes) * WeekTimelineConfig.pixelsPerMinute
          let height = max(WeekTimelineConfig.minimumCardHeight, rawHeight - 2)
          let primaryRaw = segment.activity.appSites?.primary
          let secondaryRaw = segment.activity.appSites?.secondary

          positioned.append(
            WeekPositionedActivity(
              id: segment.activity.id,
              activity: segment.activity,
              columnIndex: dayLookup[day.dayString] ?? 0,
              yPosition: calculateYPosition(for: segment.start) + 1,
              height: height,
              durationMinutes: durationMinutes,
              title: segment.activity.title,
              hoverTimeLabel: formatRange(start: segment.start, end: segment.end),
              categoryName: segment.activity.category,
              faviconPrimaryRaw: primaryRaw,
              faviconSecondaryRaw: secondaryRaw,
              faviconPrimaryHost: normalizeHost(primaryRaw),
              faviconSecondaryHost: normalizeHost(secondaryRaw)
            )
          )
        }
      }
      let positioningMs = Int((CFAbsoluteTimeGetCurrent() - positioningStart) * 1000)

      let projectionStart = CFAbsoluteTimeGetCurrent()
      let currentTimelineDay = timelineDisplayDate(from: Date())
      let currentDayString = DateFormatter.yyyyMMdd.string(from: currentTimelineDay)
      let currentDayActivities = activities.filter {
        $0.startTime.getDayInfoFor4AMBoundary().dayString == currentDayString
      }
      let currentDaySegments = TimelineActivityLoader.resolveDisplaySegments(
        from: currentDayActivities)
      let currentDayVisualBlockers = Self.visualBlockingSegments(from: currentDaySegments)
      let projection =
        requestedWeekRange.contains(Date())
        ? TimelineActivityLoader.recordingProjectionWindow(
          for: currentTimelineDay, displaySegments: currentDayVisualBlockers)
        : nil
      let projectionMs = Int((CFAbsoluteTimeGetCurrent() - projectionStart) * 1000)

      guard !Task.isCancelled else {
        timelinePerfLog(
          "weekGrid.load.cancelled trigger=\(trigger) week=\(requestedWeekID) selected=\(requestedSelectedDay)"
        )
        return
      }

      let currentSelectedDate = await MainActor.run { self.selectedDate }
      let currentWeekRange = TimelineWeekRange.containing(currentSelectedDate)

      guard currentWeekRange == requestedWeekRange else {
        let currentWeekID = DateFormatter.yyyyMMdd.string(from: currentWeekRange.weekStart)
        let currentSelectedDay = DateFormatter.yyyyMMdd.string(
          from: timelineDisplayDate(from: currentSelectedDate)
        )
        timelinePerfLog(
          "weekGrid.load.discardStale trigger=\(trigger) requestedWeek=\(requestedWeekID) currentWeek=\(currentWeekID) requestedSelected=\(requestedSelectedDay) currentSelected=\(currentSelectedDay)"
        )
        return
      }

      await MainActor.run {
        let commitStart = CFAbsoluteTimeGetCurrent()
        positionedActivities = positioned
        recordingProjection = projection
        hasAnyActivities = !positioned.isEmpty
        if let selectedActivity,
          !positioned.contains(where: { $0.activity.id == selectedActivity.id })
        {
          self.selectedActivity = nil
        }

        if autoScrollWeekKey != requestedWeekID {
          autoScrollWeekKey = requestedWeekID
        }

        updateWeeklyHoursIntersection(visibleWeekRange: requestedWeekRange)

        let commitMs = Int((CFAbsoluteTimeGetCurrent() - commitStart) * 1000)
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - overallStart) * 1000)
        timelinePerfLog(
          "weekGrid.load.end trigger=\(trigger) week=\(requestedWeekID) selected=\(requestedSelectedDay) activities=\(activities.count) cards=\(positioned.count) fetch_ms=\(fetchMs) position_ms=\(positioningMs) projection_ms=\(projectionMs) commit_ms=\(commitMs) total_ms=\(totalMs)"
        )
      }
    }
  }

  // Mirrors CanvasTimelineDataView.updateWeeklyHoursIntersection but rebuilds
  // each card's pane-space rect from (columnIndex × dayWidth) since the week
  // view lays cards across 7 columns instead of one stacked column.
  private func updateWeeklyHoursIntersection(visibleWeekRange: TimelineWeekRange? = nil) {
    guard weeklyHoursFrame != .zero,
      cardsLayerFrame != .zero,
      weeklyHoursFrame.intersects(cardsLayerFrame)
    else {
      if weeklyHoursIntersectsCard.wrappedValue {
        weeklyHoursIntersectsCard.wrappedValue = false
      }
      return
    }

    let dayWidth = cardsLayerFrame.width / 7
    let cardWidth = weekCardWidth(for: dayWidth)
    let activeWeekRange = visibleWeekRange ?? weekRange

    let intersectsTimelineCard = positionedActivities.contains { item in
      let cardFrame = CGRect(
        x: cardsLayerFrame.minX + CGFloat(item.columnIndex) * dayWidth
          + WeekTimelineConfig.cardLeadingGap,
        y: cardsLayerFrame.minY + item.yPosition,
        width: cardWidth,
        height: item.height
      )
      return cardFrame.intersects(weeklyHoursFrame)
    }

    let intersectsStatusCard: Bool
    if let projection = recordingProjection,
      let todayIndex = activeWeekRange.days.firstIndex(where: { $0.dayString == todayDayString })
    {
      let statusFrame = CGRect(
        x: cardsLayerFrame.minX + CGFloat(todayIndex) * dayWidth
          + WeekTimelineConfig.cardLeadingGap,
        y: cardsLayerFrame.minY + calculateYPosition(for: projection.start) + 1,
        width: cardWidth,
        height: recordingProjectionHeight(for: projection)
      )
      intersectsStatusCard = statusFrame.intersects(weeklyHoursFrame)
    } else {
      intersectsStatusCard = false
    }

    let intersects = intersectsTimelineCard || intersectsStatusCard
    if weeklyHoursIntersectsCard.wrappedValue != intersects {
      weeklyHoursIntersectsCard.wrappedValue = intersects
    }
  }

  private func startRefreshTimer() {
    stopRefreshTimer()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
      loadActivities(trigger: "refreshTimer")
    }
  }

  private func stopRefreshTimer() {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  private func scrollToRelevantHour(with proxy: ScrollViewProxy, animated: Bool) {
    let targetIndex = targetHourIndex()

    let action = {
      proxy.scrollTo("week-hour-\(targetIndex)", anchor: .top)
    }

    DispatchQueue.main.async {
      if animated {
        withAnimation(.easeInOut(duration: 0.26)) {
          action()
        }
      } else {
        action()
      }
    }
  }

  private func targetHourIndex() -> Int {
    if let selectedDayIndex = weekRange.days.firstIndex(where: {
      $0.dayString == selectedDayString
    }),
      let selectedDayYPosition = earliestContentYPosition(forDayAt: selectedDayIndex)
    {
      return hourIndex(
        forContentYPosition: selectedDayYPosition,
        leadingMinutes: WeekTimelineConfig.selectedDayLeadingMinutes
      )
    }

    if weekRange.containsToday {
      return hourIndex(
        forContentYPosition: calculateYPosition(for: Date()),
        leadingMinutes: WeekTimelineConfig.fallbackLeadingMinutes
      )
    }

    if let earliestWeekYPosition = earliestWeekContentYPosition() {
      return hourIndex(
        forContentYPosition: earliestWeekYPosition,
        leadingMinutes: WeekTimelineConfig.fallbackLeadingMinutes
      )
    }

    return 0
  }

  private func earliestContentYPosition(forDayAt dayIndex: Int) -> CGFloat? {
    let activityYPosition =
      positionedActivities
      .filter { $0.columnIndex == dayIndex }
      .map(\.yPosition)
      .min()

    guard dayIndex == currentDayIndex else {
      return activityYPosition
    }

    let projectionYPosition = recordingProjection.map { calculateYPosition(for: $0.start) }

    return [activityYPosition, projectionYPosition].compactMap { $0 }.min()
  }

  private func earliestWeekContentYPosition() -> CGFloat? {
    let projectionYPosition = recordingProjection.map { calculateYPosition(for: $0.start) }
    return [positionedActivities.map(\.yPosition).min(), projectionYPosition].compactMap { $0 }
      .min()
  }

  private var currentDayIndex: Int? {
    weekRange.days.firstIndex(where: { $0.dayString == todayDayString })
  }

  private func hourIndex(forContentYPosition yPosition: CGFloat, leadingMinutes: CGFloat) -> Int {
    let leadingOffset = leadingMinutes * WeekTimelineConfig.pixelsPerMinute
    let adjustedYPosition = max(0, yPosition - leadingOffset)
    let rawHourIndex = adjustedYPosition / WeekTimelineConfig.hourHeight
    return clampHourIndex(Int(rawHourIndex.rounded()))
  }

  private func clampHourIndex(_ hourIndex: Int) -> Int {
    let lastHourIndex = WeekTimelineConfig.endHour - WeekTimelineConfig.startHour - 1
    return min(max(0, hourIndex), lastHourIndex)
  }

  private func recordingProjectionHeight(for projection: TimelineRecordingProjectionWindow)
    -> CGFloat
  {
    let durationMinutes = max(0, projection.end.timeIntervalSince(projection.start) / 60)
    let rawHeight = CGFloat(durationMinutes) * WeekTimelineConfig.pixelsPerMinute
    return max(WeekTimelineConfig.minimumCardHeight, rawHeight - 2)
  }

  // Week cards have a minimum rendered height, so very short cards can occupy
  // more vertical space than their timestamp range. Use rendered height as the
  // projection blocker so the status card never visually intersects them.
  nonisolated private static func visualBlockingSegments(
    from segments: [TimelineDisplaySegment]
  ) -> [TimelineDisplaySegment] {
    segments.map { segment in
      let durationMinutes = max(0, segment.end.timeIntervalSince(segment.start) / 60)
      let rawHeight = CGFloat(durationMinutes) * WeekTimelineConfig.pixelsPerMinute
      let renderedHeight = max(WeekTimelineConfig.minimumCardHeight, rawHeight - 2)
      let renderedDurationMinutes = ceil(
        Double(renderedHeight / WeekTimelineConfig.pixelsPerMinute)
      )
      let renderedEnd = segment.start.addingTimeInterval(renderedDurationMinutes * 60)

      return TimelineDisplaySegment(
        activity: segment.activity,
        start: segment.start,
        end: max(segment.end, renderedEnd)
      )
    }
  }

  private func calculateYPosition(for time: Date) -> CGFloat {
    let calendar = Calendar.current
    let hour = calendar.component(.hour, from: time)
    let minute = calendar.component(.minute, from: time)

    let hoursSince4AM: Int
    if hour >= WeekTimelineConfig.startHour {
      hoursSince4AM = hour - WeekTimelineConfig.startHour
    } else {
      hoursSince4AM = (24 - WeekTimelineConfig.startHour) + hour
    }

    let totalMinutes = hoursSince4AM * 60 + minute
    return CGFloat(totalMinutes) * WeekTimelineConfig.pixelsPerMinute
  }

  private func formatHour(_ hour: Int) -> String {
    let normalizedHour = hour >= 24 ? hour - 24 : hour
    let adjustedHour =
      normalizedHour > 12 ? normalizedHour - 12 : (normalizedHour == 0 ? 12 : normalizedHour)
    let period = normalizedHour >= 12 ? "PM" : "AM"
    return "\(adjustedHour):00 \(period)"
  }

  private static let hoverTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  private func formatRange(start: Date, end: Date) -> String {
    let formatter = Self.hoverTimeFormatter
    return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
  }

  private func normalizeHost(_ site: String?) -> String? {
    guard var site, !site.isEmpty else { return nil }
    site = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let url = URL(string: site), let host = url.host {
      return host
    }
    if site.contains("://"), let url = URL(string: site), let host = url.host {
      return host
    }
    if site.contains("/"), let url = URL(string: "https://" + site), let host = url.host {
      return host
    }
    if !site.contains(".") {
      return site + ".com"
    }
    return site
  }

  private func weekCardWidth(for dayWidth: CGFloat) -> CGFloat {
    max(0, dayWidth - WeekTimelineConfig.cardLeadingGap - WeekTimelineConfig.cardTrailingGap)
  }

  private func weekCardXPosition(for columnIndex: Int, dayWidth: CGFloat) -> CGFloat {
    CGFloat(columnIndex) * dayWidth + WeekTimelineConfig.cardLeadingGap + weekCardWidth(
      for: dayWidth) / 2
  }

  private func palette(for rawCategory: String) -> WeekTimelineCardPalette {
    let normalizedCategory = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let matched = categoryStore.categories.first {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedCategory
    }
    let fallback = categoryStore.categories.first ?? CategoryPersistence.defaultCategories.first!
    let category = matched ?? fallback
    let accentNSColor = NSColor(hex: category.colorHex) ?? .systemBlue
    let fillColor =
      accentNSColor.blended(with: 0.88, of: .white) ?? accentNSColor.withAlphaComponent(0.12)
    let borderColor = accentNSColor.blended(with: 0.62, of: .white) ?? accentNSColor

    return WeekTimelineCardPalette(
      accent: Color(nsColor: accentNSColor),
      fill: Color(nsColor: fillColor),
      border: Color(nsColor: borderColor),
      title: Color(hex: "333333")
    )
  }
}

private struct WeekTimelineCardPalette {
  let accent: Color
  let fill: Color
  let border: Color
  let title: Color
}

private struct WeekTimelineActivityCard: View {
  let cardId: String
  let title: String
  let hoverTimeLabel: String
  let height: CGFloat
  // Parent-computed: equals `height` normally, or the measured natural height when hovered.
  let effectiveHeight: CGFloat
  let durationMinutes: Double
  let palette: WeekTimelineCardPalette
  let isSelected: Bool
  // Parent-driven (debounced via hover-intent at the parent).
  let isHovered: Bool
  let showTimelineAppIcons: Bool
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
  let statusLine: String?
  let isRetryActive: Bool
  let onHoverChanged: (Bool) -> Void
  let onTap: () -> Void

  private var isCompact: Bool {
    durationMinutes < 24 || height < 40
  }

  // Mirrors the Day view's detection (`title == "Processing failed"`) so
  // both views flip to the failed-card styling together. Intentionally
  // title-based rather than category-based to stay in lockstep with the
  // Day view — if the failed-card format ever changes, both stay synced
  // as long as the title string stays canonical.
  private var isFailedCard: Bool {
    title == "Processing failed"
  }

  // Title font size is a single constant across every card in the grid — no
  // compact/long split, no hover switch — so text never changes size for any
  // reason. The hover interaction handles "too small to read" by revealing
  // more lines, not by shrinking the font.
  private var titleFontSize: CGFloat { 10 }

  // Vertical padding still varies by card size (compact cards need a tighter
  // fit at rest), but it's stable across hover states so the first line's Y
  // position doesn't shift when the card expands.
  private var verticalPadding: CGFloat {
    isCompact ? 2 : 4
  }

  private var showsRetryStatus: Bool {
    isFailedCard && statusLine != nil
  }

  // Max lines the title can wrap to *at rest* (not hovered) — bounded by
  // how much vertical space the card actually has. Previously we binary-
  // gated on `isCompact` and forced 1 line for any "short-duration" card,
  // which truncated titles even when 2+ lines would clearly fit. Here we
  // derive the line count from the real text-area height: card height
  // minus both vertical paddings, divided by Nunito 10's line-height
  // (~12pt). `max(1, …)` guarantees at least one line for the smallest
  // cards.
  private var maxUnhoveredTitleLines: Int {
    let reservedStatusHeight: CGFloat = showsRetryStatus ? 14 : 0
    let available = height - 2 * verticalPadding - reservedStatusHeight
    let perLine: CGFloat = 12
    return max(1, Int(available / perLine))
  }

  private var hasFavicon: Bool {
    showTimelineAppIcons && (faviconPrimaryRaw != nil || faviconSecondaryRaw != nil)
  }

  var body: some View {
    Button(action: {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
        onTap()
      }
    }) {
      cardCanvas(renderingExpanded: isHovered)
        .frame(
          maxWidth: .infinity,
          minHeight: effectiveHeight,
          maxHeight: effectiveHeight,
          alignment: .topLeading
        )
    }
    .buttonStyle(CanvasCardButtonStyle())
    .pointingHandCursor()
    .hoverScaleEffect(scale: 1.01)
    .zIndex(isHovered ? 10 : (isSelected ? 2 : 0))
    .onHover { hovering in
      onHoverChanged(hovering)
    }
    // Hidden natural-height measurement published to parent via preference.
    .background(alignment: .topLeading) {
      expandedHeightMeasurement
    }
  }

  // Shared visual canvas — identical layout whether compact or hovered, so no
  // existing text shifts when the card expands. Only the line limit changes:
  // compact clamps to 1 line with tail truncation; hovered unlocks the wrap.
  @ViewBuilder
  private func cardCanvas(renderingExpanded: Bool) -> some View {
    HStack(alignment: .top, spacing: 4) {
      if hasFavicon {
        WeekTimelineFaviconView(
          primaryRaw: faviconPrimaryRaw,
          secondaryRaw: faviconSecondaryRaw,
          primaryHost: faviconPrimaryHost,
          secondaryHost: faviconSecondaryHost
        )
        .frame(width: 12, height: 12)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.custom("Nunito", size: titleFontSize).weight(.semibold))
          .foregroundColor(palette.title)
          .multilineTextAlignment(.leading)
          .lineLimit(renderingExpanded ? nil : maxUnhoveredTitleLines)
          .truncationMode(.tail)

        if let statusLine, isFailedCard {
          retryStatusRow(statusLine: statusLine, renderingExpanded: renderingExpanded)
        }

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      Spacer(minLength: 0)
    }
    .padding(.leading, 9)
    .padding(.trailing, 6)
    .padding(.vertical, verticalPadding)
    // Failed-card styling (matches Day view): peach background, red dashed
    // stroke, and no left accent bar. Kept as three inline branches rather
    // than a dedicated Modifier so it's obvious at read-time what's
    // special-cased.
    .background(isFailedCard ? Color(hex: "FFECE4") : palette.fill)
    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .stroke(
          isFailedCard
            ? Color(red: 1, green: 0.16, blue: 0.11)
            : (isSelected ? palette.accent : palette.border),
          style: isFailedCard
            ? StrokeStyle(lineWidth: 0.5, dash: [2.5, 2.5])
            : StrokeStyle(lineWidth: isSelected ? 1 : 0.5)
        )
    )
    .overlay(alignment: .leading) {
      if !isFailedCard {
        UnevenRoundedRectangle(
          topLeadingRadius: 2,
          bottomLeadingRadius: 2,
          bottomTrailingRadius: 0,
          topTrailingRadius: 0,
          style: .continuous
        )
        .fill(palette.accent)
        .frame(width: 5)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .stroke(Color.black.opacity(isHovered ? 0.10 : 0), lineWidth: 1)
    )
    // Shadow deepens when hovered — the "card lifts toward you" cue. Opacity
    // halved (0.12→0.06, 0.10→0.05) so the lift reads as a subtle cue rather
    // than a prominent drop-shadow. Radius and offsets kept so the shadow's
    // spread/direction is unchanged; only intensity drops.
    .shadow(
      color: .black.opacity(isHovered ? 0.06 : 0),
      radius: isHovered ? 4 : 1,
      x: 0,
      y: isHovered ? 2 : 1
    )
    .shadow(
      color: .black.opacity(isHovered ? 0.05 : 0),
      radius: isHovered ? 8 : 2,
      x: 0,
      y: isHovered ? 4 : 2
    )
  }

  // Hidden measurement of the expanded card's natural height. Structurally
  // identical to `cardCanvas(renderingExpanded: true)` so the measured height
  // matches the actual rendered height exactly — no font, no padding, no
  // component differences, otherwise the two disagree and text gets clipped.
  @ViewBuilder
  private var expandedHeightMeasurement: some View {
    HStack(alignment: .top, spacing: 4) {
      if hasFavicon {
        Color.clear.frame(width: 12, height: 12)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.custom("Nunito", size: titleFontSize).weight(.semibold))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)

        if let statusLine, isFailedCard {
          retryStatusRow(statusLine: statusLine, renderingExpanded: true)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.leading, 9)
    .padding(.trailing, 6)
    .padding(.vertical, verticalPadding)
    .fixedSize(horizontal: false, vertical: true)
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: CardExpandedHeightPreferenceKey.self,
          value: [cardId: proxy.size.height]
        )
      }
    )
    .hidden()
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func retryStatusRow(statusLine: String, renderingExpanded: Bool) -> some View {
    HStack(alignment: .center, spacing: 4) {
      if isRetryActive {
        ProgressView()
          .controlSize(.mini)
          .scaleEffect(0.5)
          .frame(width: 8, height: 8)
      }

      Text(statusLine)
        .font(.custom("Nunito", size: 9))
        .foregroundColor(Color(hex: "7A6254"))
        .lineLimit(renderingExpanded ? nil : 1)
        .truncationMode(.tail)
    }
  }
}

private struct WeekTimelineFaviconView: View {
  let primaryRaw: String?
  let secondaryRaw: String?
  let primaryHost: String?
  let secondaryHost: String?

  @State private var image: NSImage?
  @State private var didStart = false

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
      } else {
        Color.clear
      }
    }
    .onAppear {
      guard !didStart else { return }
      didStart = true
      Task { @MainActor in
        image = await FaviconService.shared.fetchFavicon(
          primaryRaw: primaryRaw,
          secondaryRaw: secondaryRaw,
          primaryHost: primaryHost,
          secondaryHost: secondaryHost
        )
      }
    }
  }
}

// MARK: - Hover-expand prototype preview

/// Xcode Preview harness for experimenting with the hover-expand interaction.
/// The segmented control at the top lets you flip between Overlay (card lifts,
/// neighbours unaffected) and Displace (overlapped neighbours temporarily hide).
private struct WeekTimelineHoverPrototypeHarness: View {
  @State private var selectedDate: Date = Date()
  @State private var selectedActivity: TimelineActivity? = nil
  @State private var hasAny: Bool = true
  @State private var refresh: Int = 0

  private static let weekRange = TimelineWeekRange.containing(Date())

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Hover-expand prototype")
          .font(.custom("Nunito", size: 13).weight(.semibold))
          .foregroundColor(Color(hex: "333333"))
        Text(
          "Hover a short card — the card grows to reveal the full title. No text shifts; only new lines appear below."
        )
        .font(.custom("Nunito", size: 11))
        .foregroundColor(Color(hex: "6B5548"))
      }

      WeekTimelineGridView(
        selectedDate: $selectedDate,
        selectedActivity: $selectedActivity,
        hasAnyActivities: $hasAny,
        refreshTrigger: $refresh,
        weekRange: Self.weekRange,
        onSelectActivity: { selectedActivity = $0 },
        onClearSelection: { selectedActivity = nil },
        previewPositionedActivities: Self.mockActivities()
      )
      .background(Color(hex: "FFF6EE"))
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(hex: "FAF3EB"))
    .preferredColorScheme(.light)
  }

  private static func mockActivities() -> [WeekPositionedActivity] {
    // Build a synthetic day of cards around late morning with several stacked
    // short cards so both modes have something interesting to show.
    // yPosition is minutes-from-4AM * pixelsPerMinute.
    let ppm = WeekTimelineConfig.pixelsPerMinute

    struct Spec {
      let column: Int
      let startMinutes: Int  // minutes after 4:00 AM
      let durationMinutes: Int
      let title: String
      let category: String
      let favicon: String?
    }

    let specs: [Spec] = [
      // Monday (col 1) — one long card, easy baseline
      Spec(
        column: 1, startMinutes: 6 * 60, durationMinutes: 45,
        title: "Refining UI mockups for the weekly view",
        category: "Work", favicon: "figma.com"),

      // Tuesday (col 2) — stacked cluster of short cards (displace showcase)
      Spec(
        column: 2, startMinutes: 6 * 60, durationMinutes: 12,
        title: "Refining UI mockups — iteration 1 of the hover card",
        category: "Work", favicon: "figma.com"),
      Spec(
        column: 2, startMinutes: 6 * 60 + 12, durationMinutes: 10,
        title: "Refining UI mockups — iteration 2",
        category: "Work", favicon: "figma.com"),
      Spec(
        column: 2, startMinutes: 6 * 60 + 22, durationMinutes: 8,
        title: "Refining UI mockups — quick pass",
        category: "Work", favicon: "figma.com"),
      Spec(
        column: 2, startMinutes: 6 * 60 + 30, durationMinutes: 11,
        title: "Refining UI mockups — small tweaks",
        category: "Work", favicon: "figma.com"),

      // Wednesday (col 3) — medium card followed closely by a tiny one
      Spec(
        column: 3, startMinutes: 7 * 60, durationMinutes: 30,
        title: "Browsing X looking for design inspiration around calendars",
        category: "Distraction", favicon: "x.com"),
      Spec(
        column: 3, startMinutes: 7 * 60 + 32, durationMinutes: 6,
        title: "Quick Slack check",
        category: "Communication", favicon: "slack.com"),

      // Thursday (col 4) — mid-length card that fits comfortably
      Spec(
        column: 4, startMinutes: 8 * 60, durationMinutes: 28,
        title:
          "Researching, creating roadmap, and summarizing documents with Chat GPT for the next planning cycle",
        category: "Research", favicon: "chat.openai.com"),

      // Friday (col 5) — very short card isolated
      Spec(
        column: 5, startMinutes: 7 * 60 + 30, durationMinutes: 5,
        title: "Messaging Alex on Slack about the design review",
        category: "Communication", favicon: "slack.com"),

      // Saturday (col 6) — two back-to-back short cards
      Spec(
        column: 6, startMinutes: 9 * 60, durationMinutes: 9,
        title: "Comparing screenshots",
        category: "Work", favicon: nil),
      Spec(
        column: 6, startMinutes: 9 * 60 + 9, durationMinutes: 7,
        title: "Next card preview",
        category: "Work", favicon: nil),
    ]

    return specs.enumerated().map { index, spec in
      let startDate = Date(timeIntervalSinceReferenceDate: Double(index * 3600))
      let endDate = startDate.addingTimeInterval(Double(spec.durationMinutes * 60))
      let activity = TimelineActivity(
        id: "preview-\(index)",
        recordId: nil,
        batchId: nil,
        startTime: startDate,
        endTime: endDate,
        title: spec.title,
        summary: spec.title,
        detailedSummary: spec.title,
        category: spec.category,
        subcategory: "",
        distractions: nil,
        videoSummaryURL: nil,
        screenshot: nil,
        appSites: spec.favicon.map { AppSites(primary: $0, secondary: nil) },
        isBackupGenerated: false
      )

      let yPos = CGFloat(spec.startMinutes) * ppm + 1
      let rawHeight = CGFloat(spec.durationMinutes) * ppm
      let height = max(WeekTimelineConfig.minimumCardHeight, rawHeight - 2)
      let hoverTimeLabel =
        "\(Self.minutesLabel(fromFourAM: spec.startMinutes)) - \(Self.minutesLabel(fromFourAM: spec.startMinutes + spec.durationMinutes))"

      return WeekPositionedActivity(
        id: activity.id,
        activity: activity,
        columnIndex: spec.column,
        yPosition: yPos,
        height: height,
        durationMinutes: Double(spec.durationMinutes),
        title: spec.title,
        hoverTimeLabel: hoverTimeLabel,
        categoryName: spec.category,
        faviconPrimaryRaw: spec.favicon,
        faviconSecondaryRaw: nil,
        faviconPrimaryHost: spec.favicon,
        faviconSecondaryHost: nil
      )
    }
  }

  private static func minutesLabel(fromFourAM minutes: Int) -> String {
    let absoluteMinutes = minutes + 4 * 60
    let hour24 = (absoluteMinutes / 60) % 24
    let minute = absoluteMinutes % 60
    let period = hour24 >= 12 ? "PM" : "AM"
    let hour12: Int = {
      let raw = hour24 % 12
      return raw == 0 ? 12 : raw
    }()
    return String(format: "%d:%02d %@", hour12, minute, period)
  }
}

#Preview("Week timeline hover prototype") {
  WeekTimelineHoverPrototypeHarness()
    .environmentObject(AppState.shared)
    .environmentObject(CategoryStore.shared)
    .frame(width: 980, height: 640)
}
