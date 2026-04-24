import AppKit
import Foundation
import SwiftUI
import UserNotifications

extension DailyView {
  var unlockedContent: some View {
    GeometryReader { geometry in
      let maxLayoutWidth: CGFloat = 1320
      let availableWidth = max(320, geometry.size.width)
      let layoutWidth = min(availableWidth, maxLayoutWidth)
      let scale: CGFloat = 1.1
      let horizontalInset = 16 * scale
      let topInset = max(22, 20 * scale)
      let bottomInset = 16 * scale
      let sectionSpacing = 20 * scale
      let contentWidth = max(320, layoutWidth - (horizontalInset * 2))
      let useSingleColumn = false
      let isViewingToday = isTodaySelection(selectedDate)

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: sectionSpacing) {
          topControls(scale: scale)
          workflowSection(scale: scale, isViewingToday: isViewingToday)
          actionRow(scale: scale)
          highlightsAndTasksSection(
            useSingleColumn: useSingleColumn,
            contentWidth: contentWidth,
            scale: scale,
            heading: standupSectionHeading(for: selectedDate),
            titles: standupSectionTitles(for: selectedDate, sourceDay: standupSourceDay)
          )
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .onAppear {
      dailyRecapProvider = DailyRecapGenerator.shared.selectedProvider()
      refreshProviderAvailability()
      refreshWorkflowData()
    }
    .onDisappear {
      workflowLoadTask?.cancel()
      workflowLoadTask = nil
      standupDraftSaveTask?.cancel()
      standupDraftSaveTask = nil
      standupCopyResetTask?.cancel()
      standupCopyResetTask = nil
      standupRegenerateTask?.cancel()
      standupRegenerateTask = nil
      standupRegenerateResetTask?.cancel()
      standupRegenerateResetTask = nil
      standupRegeneratingDotsPhase = 1
      providerAvailabilityTask?.cancel()
      providerAvailabilityTask = nil
    }
    .onChange(of: selectedDate) { oldDate, newDate in
      handleSelectedDateChange(oldDate: oldDate, newDate: newDate)
    }
    .onChange(of: standupDraft) { _, _ in
      scheduleStandupDraftSave()
    }
    .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { notification in
      guard let dayString = notification.userInfo?["dayString"] as? String else {
        return
      }
      if isRelevantTimelineDayUpdate(dayString, for: selectedDate) {
        refreshWorkflowData()
      }
    }
  }
  func topControls(scale: CGFloat) -> some View {
    let canMoveToNextDay = canNavigateForward(from: selectedDate)

    return HStack {
      HStack(spacing: 8 * scale) {
        Button(action: { shiftDate(by: -1) }) {
          Image("LeftArrow")
            .resizable()
            .scaledToFit()
            .frame(width: 18 * scale, height: 18 * scale)
            .frame(width: 32 * scale, height: 32 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .hoverScaleEffect(scale: 1.02)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)

        Text(dailyDateTitle(for: selectedDate))
          .font(.custom("InstrumentSerif-Regular", size: 26 * scale))
          .foregroundStyle(Color(hex: "1E1B18"))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .allowsTightening(true)
          .frame(width: Self.maxDateTitleWidth * scale, alignment: .center)

        Button(action: {
          guard canMoveToNextDay else { return }
          shiftDate(by: 1)
        }) {
          Image("RightArrow")
            .resizable()
            .scaledToFit()
            .frame(width: 18 * scale, height: 18 * scale)
            .frame(width: 32 * scale, height: 32 * scale)
            .contentShape(Rectangle())
            .opacity(canMoveToNextDay ? 1 : 0.35)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canMoveToNextDay)
        .hoverScaleEffect(enabled: canMoveToNextDay, scale: 1.02)
        .pointingHandCursorOnHover(enabled: canMoveToNextDay, reassertOnPressEnd: true)
      }
      .frame(maxWidth: .infinity)
    }
  }
  func isTodaySelection(_ date: Date) -> Bool {
    let displayDate = timelineDisplayDate(from: date)
    let timelineToday = timelineDisplayDate(from: Date())
    return Calendar.current.isDate(displayDate, inSameDayAs: timelineToday)
  }
  func isYesterdaySelection(_ date: Date) -> Bool {
    let calendar = Calendar.current
    let displayDate = timelineDisplayDate(from: date)
    let timelineToday = timelineDisplayDate(from: Date())
    guard let timelineYesterday = calendar.date(byAdding: .day, value: -1, to: timelineToday) else {
      return false
    }
    return calendar.isDate(displayDate, inSameDayAs: timelineYesterday)
  }
  func workflowSection(scale: CGFloat, isViewingToday: Bool) -> some View {
    let headingText: String
    if isViewingToday {
      headingText = "Today so far. Come back tomorrow for the full day view."
    } else if isYesterdaySelection(selectedDate) {
      headingText = "Your workflow yesterday"
    } else {
      let displayDate = timelineDisplayDate(from: selectedDate)
      headingText = "Your workflow on \(dailyStandupSectionDayFormatter.string(from: displayDate))"
    }

    return VStack(alignment: .leading, spacing: 8 * scale) {
      HStack {
        Text(headingText)
          .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
          .foregroundStyle(Color(hex: "B46531"))

        Spacer()
      }

      VStack(spacing: 0) {
        DailyWorkflowGrid(
          rows: workflowRows,
          timelineWindow: workflowWindow,
          distractionMarkers: workflowDistractionMarkers,
          showDistractionRow: workflowHasDistractionCategory,
          scale: scale,
          hoveredDistractionId: $workflowHoveredDistractionId,
          hoveredCellKey: $workflowHoveredCellKey
        )

        Divider()
          .overlay(Color(hex: "E5DFD9"))

        workflowTotalsView(scale: scale, isViewingToday: isViewingToday)
          .padding(.horizontal, 16 * scale)
          .padding(.top, 14 * scale)
          .padding(.bottom, 12 * scale)
      }
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.white.opacity(0.78))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(Color(hex: "E8E1DA"), lineWidth: max(0.7, 1 * scale))
          .allowsHitTesting(false)
      )
      .overlayPreferenceValue(DailyWorkflowHoverBoundsPreferenceKey.self) { anchors in
        workflowTooltipOverlay(scale: scale, anchors: anchors)
      }
    }
  }
  @ViewBuilder
  func workflowTooltipOverlay(
    scale: CGFloat,
    anchors: [DailyWorkflowHoverTargetID: Anchor<CGRect>]
  ) -> some View {
    let layoutScale = scale
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        if let cellKey = workflowHoveredCellKey,
          let anchor = anchors[.cell(cellKey)],
          let cardInfo = workflowCardInfo(for: cellKey)
        {
          let frame = proxy[anchor]

          Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: .bottom) {
              workflowTooltip(
                durationMinutes: cardInfo.durationMinutes,
                title: cardInfo.title,
                accentColor: Color(hex: "D77A43"),
                layoutScale: layoutScale
              )
            }
            .position(x: frame.midX, y: frame.minY - (4 * layoutScale))
        }

        if let hoveredId = workflowHoveredDistractionId,
          let anchor = anchors[.distraction(hoveredId)],
          let marker = workflowDistractionMarkers.first(where: { $0.id == hoveredId })
        {
          let frame = proxy[anchor]

          Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: .bottom) {
              workflowTooltip(
                durationMinutes: marker.endMinute - marker.startMinute,
                title: marker.title,
                accentColor: Color(hex: "FF5950"),
                layoutScale: layoutScale
              )
            }
            .position(x: frame.midX, y: frame.minY - (4 * layoutScale))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .animation(.easeOut(duration: 0.12), value: workflowHoveredCellKey)
    .animation(.easeOut(duration: 0.12), value: workflowHoveredDistractionId)
    .allowsHitTesting(false)
  }
  var workflowTooltipRows: [DailyWorkflowGridRow] {
    if workflowHasDistractionCategory {
      return workflowRows.filter { !isDistractionCategoryKey($0.id) }
    }
    return workflowRows
  }
  func workflowCardInfo(for cellKey: String) -> DailyWorkflowSlotCardInfo? {
    let parts = cellKey.split(separator: "-")
    guard parts.count == 2,
      let rowIndex = Int(parts[0]),
      let slotIndex = Int(parts[1]),
      rowIndex < workflowTooltipRows.count,
      slotIndex < workflowTooltipRows[rowIndex].slotCardInfos.count
    else {
      return nil
    }

    return workflowTooltipRows[rowIndex].slotCardInfos[slotIndex]
  }
  func workflowTotalsView(scale: CGFloat, isViewingToday: Bool) -> some View {
    let totalTitle = workflowTotalsTitle(for: selectedDate)

    return Group {
      if workflowTotals.isEmpty {
        let emptyDescription =
          isViewingToday
          ? "\(totalTitle)  No captured activity yet."
          : "\(totalTitle)  No captured activity during 9am-9pm"
        Text(emptyDescription)
          .font(.custom("Nunito-Regular", size: 12 * scale))
          .foregroundStyle(Color(hex: "7F7062"))
      } else {
        HStack(spacing: 8 * scale) {
          Text(totalTitle)
            .font(.custom("InstrumentSerif-Regular", size: 14 * scale))
            .foregroundStyle(Color(hex: "777777"))

          ForEach(workflowTotals) { total in
            HStack(spacing: 2 * scale) {
              Text(total.name)
                .font(.custom("Nunito-Regular", size: 12 * scale))
                .foregroundStyle(Color(hex: "1F1B18"))
              Text(formatDuration(minutes: total.minutes))
                .font(.custom("Nunito-SemiBold", size: 12 * scale))
                .foregroundStyle(Color(hex: total.colorHex))
            }
          }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      }
    }
  }
  func refreshWorkflowData() {
    workflowLoadTask?.cancel()
    workflowLoadTask = nil

    let workflowDay = workflowDayInfo(for: selectedDate)
    let resolvedStandupSourceDay = resolveStandupSourceDay(for: workflowDay)
    standupSourceDay = resolvedStandupSourceDay
    refreshStandupDraftIfNeeded(
      storageDayString: workflowDay.dayString,
      sourceDay: resolvedStandupSourceDay
    )

    let categorySnapshot = categoryStore.categories

    workflowLoadTask = Task.detached(priority: .userInitiated) {
      let cards = StorageManager.shared.fetchTimelineCards(forDay: workflowDay.dayString)
      let computed = computeDailyWorkflow(cards: cards, categories: categorySnapshot)

      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard isStillViewingWorkflowDay(workflowDay.dayString) else { return }

        workflowRows = computed.rows
        workflowTotals = computed.totals
        workflowStats = computed.stats
        workflowWindow = computed.window
        workflowDistractionMarkers = computed.distractionMarkers
        workflowHasDistractionCategory = computed.hasDistractionCategory
      }
    }
  }
  func handleSelectedDateChange(oldDate: Date, newDate: Date) {
    let oldWorkflowDay = workflowDayString(for: oldDate)
    let newWorkflowDay = workflowDayString(for: newDate)

    if oldWorkflowDay != newWorkflowDay {
      cancelStandupRegeneration()
    }

    refreshWorkflowData()
  }
  func cancelStandupRegeneration() {
    standupRegenerateTask?.cancel()
    standupRegenerateTask = nil
    standupRegenerateResetTask?.cancel()
    standupRegenerateResetTask = nil
    standupRegenerateState = .idle
    standupRegeneratingDotsPhase = 1
  }
  func isStillViewingWorkflowDay(_ dayString: String) -> Bool {
    workflowDayString(for: selectedDate) == dayString
  }
  func workflowDayString(for date: Date) -> String {
    workflowDayInfo(for: date).dayString
  }
  func isRelevantTimelineDayUpdate(_ updatedDayString: String, for date: Date) -> Bool {
    let targetDay = workflowDayInfo(for: date)
    guard updatedDayString != targetDay.dayString else { return true }

    let calendar = Calendar.current
    for offset in 1...3 {
      guard
        let candidateDate = calendar.date(byAdding: .day, value: -offset, to: targetDay.startOfDay)
      else {
        continue
      }

      if DateFormatter.yyyyMMdd.string(from: candidateDate) == updatedDayString {
        return true
      }
    }

    return false
  }
  func workflowDayInfo(for date: Date) -> DailyStandupDayInfo {
    let anchorDate = timelineDisplayDate(from: date)
    let dayInfo = anchorDate.getDayInfoFor4AMBoundary()
    return DailyStandupDayInfo(
      dayString: dayInfo.dayString,
      startOfDay: dayInfo.startOfDay,
      endOfDay: dayInfo.endOfDay
    )
  }
  func resolveStandupSourceDay(for targetDay: DailyStandupDayInfo) -> DailyStandupDayInfo? {
    let calendar = Calendar.current
    let minimumMinutes = 120

    for offset in 1...3 {
      guard
        let sourceStart = calendar.date(byAdding: .day, value: -offset, to: targetDay.startOfDay)
      else {
        continue
      }

      let sourceDayString = DateFormatter.yyyyMMdd.string(from: sourceStart)
      let hasEnoughActivity = StorageManager.shared.hasMinimumTimelineActivity(
        forDay: sourceDayString,
        minimumMinutes: minimumMinutes
      )

      guard hasEnoughActivity,
        let sourceEnd = calendar.date(byAdding: .day, value: 1, to: sourceStart)
      else {
        continue
      }

      return DailyStandupDayInfo(
        dayString: sourceDayString,
        startOfDay: sourceStart,
        endOfDay: sourceEnd
      )
    }

    return nil
  }
  func shiftDate(by days: Int) {
    let shifted =
      Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    selectedDate = normalizedTimelineDate(shifted)
  }
  func dailyDateTitle(for date: Date) -> String {
    let displayDate = timelineDisplayDate(from: date)
    let timelineToday = timelineDisplayDate(from: Date())
    if Calendar.current.isDate(displayDate, inSameDayAs: timelineToday) {
      return dailyTodayDisplayFormatter.string(from: displayDate)
    }
    return dailyOtherDayDisplayFormatter.string(from: displayDate)
  }
  func workflowTotalsTitle(for date: Date) -> String {
    if isTodaySelection(date) {
      return "Today's total so far"
    }
    if isYesterdaySelection(date) {
      return "Yesterday's total"
    }

    let displayDate = timelineDisplayDate(from: date)
    return "Total for \(dailyStandupSectionDayFormatter.string(from: displayDate))"
  }
  func formatDuration(minutes: Double) -> String {
    formatDurationValue(minutes)
  }
}
