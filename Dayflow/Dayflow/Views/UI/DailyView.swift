import AppKit
import Foundation
import SwiftUI
import UserNotifications

private let dailyTodayDisplayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "'Today,' MMMM d"
  return formatter
}()

private let dailyOtherDayDisplayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "EEEE, MMMM d"
  return formatter
}()

private let dailyStandupSectionDayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "EEE, MMM d"
  return formatter
}()

private let dailyStandupWeekdayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "EEEE"
  return formatter
}()

private enum DailyGridConfig {
  static let visibleStartMinute: Double = 9 * 60
  static let visibleEndMinute: Double = 21 * 60
  static let slotDurationMinutes: Double = 15
  static let fallbackCategoryNames = ["Work", "Personal", "Distraction", "Idle"]
  static let fallbackColorHexes = ["B984FF", "6AADFF", "FF5950", "A0AEC0"]
}

private enum DailyStandupCopyState: Equatable {
  case idle
  case copied
}

private enum DailyStandupRegenerateState: Equatable {
  case idle
  case regenerating
  case regenerated
  case noData
}

private struct DailyStandupSectionTitles {
  let highlights: String
  let tasks: String
  let blockers: String
}

private struct DailyStandupDayInfo: Equatable, Sendable {
  let dayString: String
  let startOfDay: Date
  let endOfDay: Date
}

private enum DailyAccessFlowStep {
  case intro
  case notifications
  case provider
}

struct DailyView: View {
  @AppStorage("isDailyUnlocked") private var isUnlocked: Bool = false
  @Binding var selectedDate: Date
  @EnvironmentObject private var categoryStore: CategoryStore

  @State private var accessFlowStep: DailyAccessFlowStep = .intro
  @State private var lockScreenConfettiTrigger: Int = 0
  @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
  @State private var isCheckingNotificationAuthorization: Bool = false
  @State private var isRequestingNotificationPermission: Bool = false
  @State private var workflowRows: [DailyWorkflowGridRow] = []
  @State private var workflowTotals: [DailyWorkflowTotalItem] = []
  @State private var workflowStats: [DailyWorkflowStatChip] = DailyWorkflowStatChip.placeholder
  @State private var workflowWindow: DailyWorkflowTimelineWindow = .placeholder
  @State private var workflowDistractionMarkers: [DailyWorkflowDistractionMarker] = []
  @State private var workflowHasDistractionCategory: Bool = false
  @State private var workflowHoveredCellKey: String? = nil
  @State private var workflowHoveredDistractionId: String? = nil
  @State private var workflowLoadTask: Task<Void, Never>? = nil
  @State private var standupDraft: DailyStandupDraft = .default
  @State private var standupSourceDay: DailyStandupDayInfo? = nil
  @State private var loadedStandupDraftDay: String? = nil
  @State private var loadedStandupFallbackSourceDay: String? = nil
  @State private var standupDraftSaveTask: Task<Void, Never>? = nil
  @State private var standupCopyState: DailyStandupCopyState = .idle
  @State private var standupCopyResetTask: Task<Void, Never>? = nil
  @State private var standupRegenerateState: DailyStandupRegenerateState = .idle
  @State private var standupRegenerateTask: Task<Void, Never>? = nil
  @State private var standupRegenerateResetTask: Task<Void, Never>? = nil
  @State private var standupRegeneratingDotsPhase: Int = 1
  @State private var hasPersistedStandupEntry: Bool = false
  @State private var dailyRecapProvider: DailyRecapProvider = DailyRecapProvider.load()
  @State private var isShowingProviderPicker: Bool = false
  @State private var isRefreshingProviderAvailability: Bool = false
  @State private var providerAvailabilityTask: Task<Void, Never>? = nil
  @State private var providerAvailability: [DailyRecapProvider: DailyRecapProviderAvailability] =
    [:]

  private let betaNoticeCopy =
    "Daily is a new way to visualize your day and turn it into a standup update fast."
  private let priorStandupHistoryLimit = 3
  private static let maxDateTitleWidth: CGFloat = {
    let referenceText = "Wednesday, September 30"
    let font = NSFont(name: "InstrumentSerif-Regular", size: 26) ?? NSFont.systemFont(ofSize: 26)
    let width = referenceText.size(withAttributes: [.font: font]).width
    return ceil(width) + 6
  }()

  var body: some View {
    ZStack {
      if isUnlocked {
        unlockedContent
          .transition(.opacity)
      } else {
        lockScreen
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .environment(\.colorScheme, .light)
    .onAppear {
      dailyRecapProvider = DailyRecapGenerator.shared.selectedProvider()
      refreshProviderAvailability()
      checkNotificationAuthorizationForUnlock()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      checkNotificationAuthorizationForUnlock()
    }
    .onChange(of: isUnlocked) { _, newValue in
      guard !newValue else { return }
      accessFlowStep = .intro
      checkNotificationAuthorizationForUnlock()
    }
  }

  private var lockScreen: some View {
    ZStack {
      dailyLockScreenBackground

      Group {
        if accessFlowStep == .intro {
          DailyAccessIntroView(
            betaNoticeCopy: betaNoticeCopy,
            onRequestAccess: startDailyAccessFlow,
            onConfettiStart: triggerLockScreenConfetti
          )
          .transition(.opacity.combined(with: .move(edge: .leading)))
        } else if accessFlowStep == .notifications {
          DailyNotificationOnboardingView(
            notificationPermissionMessage: notificationPermissionMessage,
            notificationPermissionButtonTitle: notificationPermissionButtonTitle,
            isNotificationPermissionButtonDisabled: isNotificationPermissionButtonDisabled,
            isNotificationRecheckButtonDisabled: isNotificationRecheckButtonDisabled,
            onNotificationPermissionAction: handleNotificationPermissionAction,
            onRecheckPermissions: checkNotificationAuthorizationForUnlock
          )
          .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
          DailyProviderOnboardingView(
            selectedProvider: dailyRecapProvider,
            providerAvailability: providerAvailability,
            isRefreshingProviderAvailability: isRefreshingProviderAvailability,
            canContinue: canFinishDailyProviderOnboarding,
            onSelectProvider: selectDailyRecapProvider,
            onContinue: finishDailyProviderOnboarding
          )
          .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 28)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

      if lockScreenConfettiTrigger > 0 {
        ConfettiBurstView(trigger: lockScreenConfettiTrigger)
          .zIndex(10)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .animation(.spring(response: 0.42, dampingFraction: 0.88), value: accessFlowStep)
  }

  private var dailyLockScreenBackground: some View {
    GeometryReader { geo in
      Image("JournalPreview")
        .resizable()
        .scaledToFill()
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
        .allowsHitTesting(false)
    }
  }

  private var isNotificationPermissionButtonDisabled: Bool {
    isCheckingNotificationAuthorization || isRequestingNotificationPermission
  }

  private var isNotificationRecheckButtonDisabled: Bool {
    isCheckingNotificationAuthorization || isRequestingNotificationPermission
  }

  private var canFinishDailyProviderOnboarding: Bool {
    guard !(isRefreshingProviderAvailability && providerAvailability.isEmpty) else {
      return false
    }

    return selectedProviderAvailability.isAvailable
  }

  private var selectedProviderAvailability: DailyRecapProviderAvailability {
    providerAvailability[dailyRecapProvider]
      ?? DailyRecapProviderAvailability(
        isAvailable: true,
        detail: dailyRecapProvider.pickerSubtitle
      )
  }

  private var canRegenerateStandup: Bool {
    dailyRecapProvider.canGenerate
      && selectedProviderAvailability.isAvailable
      && standupRegenerateState != .regenerating
  }

  private var regenerateButtonHelpText: String {
    if !dailyRecapProvider.canGenerate {
      return DailyStandupPlaceholder.noProviderSelectedMessage
    }

    if !selectedProviderAvailability.isAvailable {
      return selectedProviderAvailability.detail
    }

    return "Regenerate standup highlights"
  }

  private var unlockedContent: some View {
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
    .onChange(of: selectedDate) { _, _ in
      refreshWorkflowData()
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

  private var notificationPermissionButtonTitle: String {
    if isCheckingNotificationAuthorization || isRequestingNotificationPermission {
      return "Checking..."
    }

    if notificationAuthorizationStatus == .authorized {
      return "Opening Daily..."
    }

    if notificationAuthorizationStatus == .denied {
      return "Open System Settings"
    }

    return "Turn on notifications"
  }

  private var notificationPermissionMessage: String {
    if notificationAuthorizationStatus == .denied {
      return
        "Notifications are currently off for Dayflow. Enable them in System Settings to finish unlocking Daily."
    }

    if notificationAuthorizationStatus == .authorized {
      return "Notifications are already enabled. We'll open Daily automatically."
    }

    return
      "Turn them on to continue. If you come back from System Settings, we'll check automatically."
  }

  private func checkNotificationAuthorizationForUnlock() {
    guard !isCheckingNotificationAuthorization, !isRequestingNotificationPermission else {
      return
    }

    isCheckingNotificationAuthorization = true

    Task {
      let status = await NotificationService.shared.authorizationStatus()

      await MainActor.run {
        isCheckingNotificationAuthorization = false
        notificationAuthorizationStatus = status

        guard !isUnlocked else {
          return
        }

        if canUnlockDaily(for: status) {
          handleAuthorizedDailyAccessStatus()
        }
      }
    }
  }

  private func handleNotificationPermissionAction() {
    if notificationAuthorizationStatus == .authorized {
      advanceToDailyProviderStep()
    } else if notificationAuthorizationStatus == .denied {
      openNotificationSettings()
    } else {
      requestNotificationPermissionForUnlock()
    }
  }

  private func requestNotificationPermissionForUnlock() {
    guard !isRequestingNotificationPermission else { return }
    isRequestingNotificationPermission = true

    Task {
      let granted = await NotificationService.shared.requestPermission()
      let status = await NotificationService.shared.authorizationStatus()

      await MainActor.run {
        isRequestingNotificationPermission = false
        notificationAuthorizationStatus = status

        if granted || canUnlockDaily(for: status) {
          advanceToDailyProviderStep()
        } else {
          openNotificationSettings()
        }
      }
    }
  }

  private func openNotificationSettings() {
    let bundleID = Bundle.main.bundleIdentifier ?? "ai.dayflow.Dayflow"
    let settingsURLString =
      "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)"

    if let settingsURL = URL(string: settingsURLString) {
      _ = NSWorkspace.shared.open(settingsURL)
      return
    }

    if let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
    {
      _ = NSWorkspace.shared.open(fallbackURL)
    }
  }

  private func completeDailyUnlock() {
    AnalyticsService.shared.capture("daily_unlocked")

    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
      isUnlocked = true
    }
  }

  private func canUnlockDaily(for status: UNAuthorizationStatus) -> Bool {
    switch status {
    case .authorized:
      return true
    case .provisional, .notDetermined, .denied:
      return false
    @unknown default:
      return false
    }
  }

  private func handleAuthorizedDailyAccessStatus() {
    guard accessFlowStep == .notifications else {
      return
    }

    advanceToDailyProviderStep()
  }

  private func advanceToDailyProviderStep() {
    dailyRecapProvider = DailyRecapGenerator.shared.selectedProvider()
    refreshProviderAvailability()

    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
      accessFlowStep = .provider
    }
  }

  private func triggerLockScreenConfetti() {
    lockScreenConfettiTrigger += 1
  }

  private func startDailyAccessFlow() {
    AnalyticsService.shared.capture(
      "daily_access_requested",
      ["source": "daily_intro"]
    )

    refreshProviderAvailability()

    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
      accessFlowStep =
        canUnlockDaily(for: notificationAuthorizationStatus) ? .provider : .notifications
    }
  }

  private func finishDailyProviderOnboarding() {
    guard canFinishDailyProviderOnboarding else {
      return
    }

    prepareTodayDailyGenerationAfterUnlock()
    completeDailyUnlock()

    if dailyRecapProvider.canGenerate {
      Task { @MainActor in
        regenerateStandupFromTimeline()
      }
    }
  }

  private func prepareTodayDailyGenerationAfterUnlock() {
    let today = Date()
    selectedDate = today

    standupRegenerateTask?.cancel()
    standupRegenerateTask = nil
    standupRegenerateResetTask?.cancel()
    standupRegenerateResetTask = nil
    standupRegenerateState = .idle
    standupRegeneratingDotsPhase = 1
    loadedStandupDraftDay = nil
    loadedStandupFallbackSourceDay = nil
    standupSourceDay = nil

    refreshWorkflowData()
  }

  private func topControls(scale: CGFloat) -> some View {
    let canMoveToNextDay = canNavigateForward(from: selectedDate)

    return HStack {
      HStack(spacing: 8 * scale) {
        Button(action: { shiftDate(by: -1) }) {
          Image("CalendarLeftButton")
            .resizable()
            .scaledToFit()
            .frame(width: 26 * scale, height: 26 * scale)
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
          Image("CalendarRightButton")
            .resizable()
            .scaledToFit()
            .frame(width: 26 * scale, height: 26 * scale)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canMoveToNextDay)
        .hoverScaleEffect(enabled: canMoveToNextDay, scale: 1.02)
        .pointingHandCursorOnHover(enabled: canMoveToNextDay, reassertOnPressEnd: true)
      }
      .frame(maxWidth: .infinity)
    }
  }

  private func isTodaySelection(_ date: Date) -> Bool {
    let displayDate = timelineDisplayDate(from: date)
    let timelineToday = timelineDisplayDate(from: Date())
    return Calendar.current.isDate(displayDate, inSameDayAs: timelineToday)
  }

  private func isYesterdaySelection(_ date: Date) -> Bool {
    let calendar = Calendar.current
    let displayDate = timelineDisplayDate(from: date)
    let timelineToday = timelineDisplayDate(from: Date())
    guard let timelineYesterday = calendar.date(byAdding: .day, value: -1, to: timelineToday) else {
      return false
    }
    return calendar.isDate(displayDate, inSameDayAs: timelineYesterday)
  }

  private func workflowSection(scale: CGFloat, isViewingToday: Bool) -> some View {
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
      .overlay(alignment: .topLeading) {
        workflowTooltipOverlay(scale: scale)
      }
    }
  }

  @ViewBuilder
  private func workflowTooltipOverlay(scale: CGFloat) -> some View {
    let layoutScale = scale
    let topInset: CGFloat = 25 * layoutScale
    let cellSize: CGFloat = 18 * layoutScale
    let columnSpacing: CGFloat = 2 * layoutScale
    let rowSpacing: CGFloat = 2 * layoutScale
    let leftInset: CGFloat = 36 * layoutScale
    let filteredRows =
      workflowHasDistractionCategory
      ? workflowRows.filter {
        !isDistractionCategoryKey($0.id)
      }
      : workflowRows
    let categoryLabelWidth = gridLabelColumnWidth(for: filteredRows, layoutScale: layoutScale)
    let showDistractions = workflowHasDistractionCategory && !workflowDistractionMarkers.isEmpty
    let distractionLabelWidth =
      showDistractions
      ? gridLabelColumnWidth(
        for: [
          DailyWorkflowGridRow(
            id: "d", name: "Distractions", colorHex: "FF5950",
            slotOccupancies: [], slotCardInfos: [])
        ], layoutScale: layoutScale) : 0
    let effectiveLabelWidth =
      showDistractions
      ? max(categoryLabelWidth, distractionLabelWidth) : categoryLabelWidth
    let labelToGridSpacing: CGFloat = 13 * layoutScale
    let gridLeadingOffset = leftInset + effectiveLabelWidth + labelToGridSpacing
    let slotCount = max(
      1, filteredRows.map { $0.slotOccupancies.count }.max() ?? workflowWindow.slotCount)
    let gridWidth =
      (cellSize * CGFloat(slotCount)) + (columnSpacing * CGFloat(max(0, slotCount - 1)))
    let distractionRowSpacing: CGFloat = 6 * layoutScale
    let gridRowsHeight =
      (cellSize * CGFloat(filteredRows.count))
      + (rowSpacing * CGFloat(max(0, filteredRows.count - 1)))

    ZStack(alignment: .topLeading) {
      Color.clear

      // Cell tooltip — bottom-anchored so variable-height cards sit above the cell
      if let cellKey = workflowHoveredCellKey {
        let parts = cellKey.split(separator: "-")
        if parts.count == 2,
          let rowIndex = Int(parts[0]),
          let slotIndex = Int(parts[1]),
          rowIndex < filteredRows.count,
          slotIndex < filteredRows[rowIndex].slotCardInfos.count,
          let cardInfo = filteredRows[rowIndex].slotCardInfos[slotIndex]
        {
          let tooltipCenterX =
            gridLeadingOffset + CGFloat(slotIndex) * (cellSize + columnSpacing) + cellSize / 2
          let anchorY =
            topInset + CGFloat(rowIndex) * (cellSize + rowSpacing) - (4 * layoutScale)

          // Invisible anchor point at the cell's top edge
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
            .offset(x: tooltipCenterX, y: anchorY)
        }
      }

      // Distraction tooltip — bottom-anchored above the distraction row
      if showDistractions,
        let hoveredId = workflowHoveredDistractionId,
        let marker = workflowDistractionMarkers.first(where: { $0.id == hoveredId })
      {
        let totalMinutes = workflowWindow.endMinute - workflowWindow.startMinute
        let startFraction =
          (marker.startMinute - workflowWindow.startMinute) / totalMinutes
        let endFraction = (marker.endMinute - workflowWindow.startMinute) / totalMinutes
        let xPos = CGFloat(startFraction) * gridWidth
        let markerWidth = max(
          3 * layoutScale, CGFloat(endFraction - startFraction) * gridWidth)
        let tooltipCenterX = gridLeadingOffset + xPos + markerWidth / 2
        let anchorY =
          topInset + gridRowsHeight + distractionRowSpacing - (4 * layoutScale)

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
          .offset(x: tooltipCenterX, y: anchorY)
      }
    }
    .animation(.easeOut(duration: 0.12), value: workflowHoveredCellKey)
    .animation(.easeOut(duration: 0.12), value: workflowHoveredDistractionId)
    .allowsHitTesting(false)
  }

  private func workflowTotalsView(scale: CGFloat, isViewingToday: Bool) -> some View {
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

  @ViewBuilder
  private func actionRow(scale: CGFloat) -> some View {
    let actionButtons = HStack(spacing: 10 * scale) {
      if hasPersistedStandupEntry {
        standupCopyButton(scale: scale)
      }
      standupRegenerateButton(scale: scale)
      dailyProviderButton(scale: scale)
    }

    HStack {
      Spacer(minLength: 0)
      actionButtons
    }
  }

  private func standupCopyButton(scale: CGFloat) -> some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))

    return Button(action: copyStandupUpdateToClipboard) {
      HStack(spacing: 6 * scale) {
        ZStack {
          if standupCopyState == .copied {
            Image(systemName: "checkmark")
              .font(.system(size: 12 * scale, weight: .semibold))
              .transition(transition)
          } else {
            Image("Copy")
              .resizable()
              .interpolation(.high)
              .renderingMode(.template)
              .scaledToFit()
              .frame(width: 16 * scale, height: 16 * scale)
              .transition(transition)
          }
        }
        .frame(width: 16 * scale, height: 16 * scale)

        ZStack(alignment: .leading) {
          Text("Copy standup update")
            .font(.custom("Nunito-Medium", size: 14 * scale))
            .lineLimit(1)
            .opacity(standupCopyState == .copied ? 0 : 1)

          Text("Copied")
            .font(.custom("Nunito-Medium", size: 14 * scale))
            .lineLimit(1)
            .opacity(standupCopyState == .copied ? 1 : 0)
        }
        .frame(minWidth: 136 * scale, alignment: .leading)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 12 * scale)
      .padding(.vertical, 10 * scale)
      .background(
        LinearGradient(
          colors: [
            Color(hex: "FF986F"),
            Color(hex: "BDAAFF"),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .clipShape(Capsule(style: .continuous))
      .overlay(
        Capsule(style: .continuous)
          .stroke(Color(hex: "F2D7C3"), lineWidth: max(1.2, 1.5 * scale))
      )
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(DailyCopyPressButtonStyle())
    .animation(.easeInOut(duration: 0.22), value: standupCopyState)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .accessibilityLabel(
      Text(standupCopyState == .copied ? "Copied standup update" : "Copy standup update"))
  }

  private func standupRegenerateButton(scale: CGFloat) -> some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))

    return Button(action: regenerateStandupFromTimeline) {
      HStack(spacing: 6 * scale) {
        ZStack {
          if standupRegenerateState == .regenerating {
            ProgressView()
              .progressViewStyle(.circular)
              .scaleEffect(0.6 * scale)
              .tint(.white)
          } else if standupRegenerateState == .regenerated {
            Image(systemName: "checkmark")
              .font(.system(size: 12 * scale, weight: .semibold))
              .transition(transition)
          } else if standupRegenerateState == .noData {
            Image(systemName: "exclamationmark.circle")
              .font(.system(size: 12 * scale, weight: .semibold))
              .transition(transition)
          } else {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12 * scale, weight: .semibold))
              .transition(transition)
          }
        }
        .frame(width: 16 * scale, height: 16 * scale)

        ZStack(alignment: .leading) {
          Text(regenerateButtonLabel)
            .font(.custom("Nunito-Medium", size: 14 * scale))
            .lineLimit(1)
            .opacity(transientRegenerateButtonLabel == nil ? 1 : 0)

          Text(transientRegenerateButtonLabel ?? "")
            .font(.custom("Nunito-Medium", size: 14 * scale))
            .lineLimit(1)
            .opacity(transientRegenerateButtonLabel == nil ? 0 : 1)
        }
        .frame(minWidth: 108 * scale, alignment: .leading)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 12 * scale)
      .padding(.vertical, 10 * scale)
      .background(
        LinearGradient(
          colors: [
            Color(hex: "FFB58A"),
            Color(hex: "ED9BC0"),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .clipShape(Capsule(style: .continuous))
      .overlay(
        Capsule(style: .continuous)
          .stroke(Color(hex: "F2D7C3"), lineWidth: max(1.2, 1.5 * scale))
      )
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(DailyCopyPressButtonStyle())
    .animation(.easeInOut(duration: 0.22), value: standupRegenerateState)
    .disabled(!canRegenerateStandup)
    .pointingHandCursorOnHover(
      enabled: canRegenerateStandup, reassertOnPressEnd: true
    )
    .accessibilityLabel(Text("Regenerate standup highlights"))
    .help(regenerateButtonHelpText)
    .background {
      if standupRegenerateState == .regenerating {
        Color.clear
          .onReceive(Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()) { _ in
            standupRegeneratingDotsPhase = (standupRegeneratingDotsPhase % 3) + 1
          }
      }
    }
    .onChange(of: standupRegenerateState) {
      if standupRegenerateState != .regenerating {
        standupRegeneratingDotsPhase = 1
      }
    }
  }

  private func dailyProviderButton(scale: CGFloat) -> some View {
    Button {
      if !isShowingProviderPicker {
        refreshProviderAvailability()
      }
      isShowingProviderPicker.toggle()
    } label: {
      ZStack {
        Circle()
          .fill(Color(hex: "F7F3F1"))

        Circle()
          .stroke(Color(hex: "E4D7D0"), lineWidth: max(1.1, 1.3 * scale))

        Image(systemName: "gearshape.fill")
          .font(.system(size: 13 * scale, weight: .semibold))
          .foregroundStyle(Color(hex: "B46531"))
      }
      .frame(width: 38 * scale, height: 38 * scale)
      .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
      .contentShape(Circle())
    }
    .buttonStyle(DailyCopyPressButtonStyle())
    .disabled(standupRegenerateState == .regenerating)
    .pointingHandCursorOnHover(
      enabled: standupRegenerateState != .regenerating,
      reassertOnPressEnd: true
    )
    .accessibilityLabel(Text("Choose daily recap provider"))
    .help("Daily recap provider: \(dailyRecapProvider.selectionLabel)")
    .popover(isPresented: $isShowingProviderPicker, arrowEdge: .bottom) {
      dailyProviderPicker(scale: scale)
        .padding(16)
        .frame(width: 312)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
    }
  }

  private func dailyProviderPicker(scale: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 12 * scale) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2 * scale) {
          Text("Daily recap provider")
            .font(.custom("InstrumentSerif-Regular", size: 22 * scale))
            .foregroundStyle(Color(hex: "2E221B"))

          Text("Choose how Daily generates this recap, or turn generation off.")
            .font(.custom("Nunito-Regular", size: 12 * scale))
            .foregroundStyle(Color(hex: "8B6B59"))
        }

        Spacer(minLength: 0)

        if isRefreshingProviderAvailability {
          ProgressView()
            .controlSize(.small)
            .tint(Color(hex: "B46531"))
        }
      }

      VStack(spacing: 8 * scale) {
        ForEach(DailyRecapProvider.allCases, id: \.self) { provider in
          let availability =
            providerAvailability[provider]
            ?? DailyRecapProviderAvailability(isAvailable: true, detail: provider.pickerSubtitle)
          let isSelected = dailyRecapProvider == provider

          Button {
            selectDailyRecapProvider(provider)
          } label: {
            HStack(alignment: .top, spacing: 10 * scale) {
              VStack(alignment: .leading, spacing: 2 * scale) {
                Text(provider.displayName)
                  .font(.custom("Nunito-SemiBold", size: 13 * scale))
                  .foregroundStyle(Color(hex: isSelected ? "8F522C" : "2F241D"))

                Text(availability.detail)
                  .font(.custom("Nunito-Regular", size: 12 * scale))
                  .foregroundStyle(Color(hex: availability.isAvailable ? "8B6B59" : "B07A74"))
                  .multilineTextAlignment(.leading)
              }

              Spacer(minLength: 0)

              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(
                  isSelected ? Color(hex: "C96F3A") : Color(hex: "D3C6BE")
                )
            }
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 10 * scale)
            .background(
              RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(
                  isSelected
                    ? Color(hex: "FFF4EC")
                    : Color(hex: "FAF8F7")
                )
            )
            .overlay(
              RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .stroke(
                  isSelected ? Color(hex: "EBC4AB") : Color(hex: "E8E1DC"),
                  lineWidth: max(1, 1.2 * scale)
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(!availability.isAvailable)
          .pointingHandCursorOnHover(enabled: availability.isAvailable, reassertOnPressEnd: true)
        }
      }
    }
  }

  private func selectDailyRecapProvider(_ provider: DailyRecapProvider) {
    let previousProvider = dailyRecapProvider
    guard previousProvider != provider else {
      isShowingProviderPicker = false
      return
    }

    dailyRecapProvider = provider
    DailyRecapGenerator.shared.persistSelectedProvider(provider)
    isShowingProviderPicker = false
    standupRegenerateResetTask?.cancel()
    standupRegenerateResetTask = nil
    standupRegenerateState = .idle
    loadedStandupDraftDay = nil
    loadedStandupFallbackSourceDay = nil

    AnalyticsService.shared.capture(
      "daily_provider_selected",
      [
        "previous_daily_provider": previousProvider.analyticsName,
        "previous_daily_provider_label": previousProvider.displayName,
        "daily_provider": provider.analyticsName,
        "daily_provider_label": provider.displayName,
        "daily_runtime": provider.runtimeLabel,
        "daily_model_or_tool": provider.modelOrTool as Any,
      ]
    )

    refreshWorkflowData()
  }

  private func refreshProviderAvailability() {
    providerAvailabilityTask?.cancel()
    isRefreshingProviderAvailability = true

    providerAvailabilityTask = Task.detached(priority: .utility) {
      let snapshot = DailyRecapGenerator.shared.availabilitySnapshot()
      guard !Task.isCancelled else { return }

      await MainActor.run {
        providerAvailability = snapshot
        isRefreshingProviderAvailability = false
        providerAvailabilityTask = nil
      }
    }
  }

  @ViewBuilder
  private func highlightsAndTasksSection(
    useSingleColumn: Bool,
    contentWidth: CGFloat,
    scale: CGFloat,
    heading: String,
    titles: DailyStandupSectionTitles
  ) -> some View {
    VStack(alignment: .leading, spacing: 8 * scale) {
      Text(heading)
        .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
        .foregroundStyle(Color(hex: "B46531"))

      if useSingleColumn {
        VStack(alignment: .leading, spacing: 12 * scale) {
          DailyBulletCard(
            style: .highlights,
            seamMode: .standalone,
            title: titles.highlights,
            items: $standupDraft.highlights,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          DailyBulletCard(
            style: .tasks,
            seamMode: .standalone,
            title: titles.tasks,
            items: $standupDraft.tasks,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
        }
      } else {
        // Figma overlaps borders by ~1px to avoid a visible gutter.
        let cardSpacing = -1 * scale
        let cardWidth = (contentWidth - cardSpacing) / 2
        HStack(alignment: .top, spacing: cardSpacing) {
          DailyBulletCard(
            style: .highlights,
            seamMode: .joinedLeading,
            title: titles.highlights,
            items: $standupDraft.highlights,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          .frame(width: cardWidth)

          DailyBulletCard(
            style: .tasks,
            seamMode: .joinedTrailing,
            title: titles.tasks,
            items: $standupDraft.tasks,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          .frame(width: cardWidth)
        }
      }
    }
  }

  private func refreshWorkflowData() {
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
        workflowRows = computed.rows
        workflowTotals = computed.totals
        workflowStats = computed.stats
        workflowWindow = computed.window
        workflowDistractionMarkers = computed.distractionMarkers
        workflowHasDistractionCategory = computed.hasDistractionCategory
      }
    }
  }

  private func copyStandupUpdateToClipboard() {
    let clipboardText = standupClipboardText(for: selectedDate)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(clipboardText, forType: .string)

    standupCopyResetTask?.cancel()

    withAnimation(.easeInOut(duration: 0.22)) {
      standupCopyState = .copied
    }

    AnalyticsService.shared.capture(
      "daily_standup_copied",
      [
        "timeline_day": workflowDayString(for: selectedDate),
        "highlights_count": standupDraft.highlights.count,
        "tasks_count": standupDraft.tasks.count,
      ])

    standupCopyResetTask = Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        withAnimation(.easeInOut(duration: 0.22)) {
          standupCopyState = .idle
        }
        standupCopyResetTask = nil
      }
    }
  }

  private func regenerateStandupFromTimeline() {
    guard standupRegenerateState != .regenerating else { return }
    let regenerateRunId = UUID().uuidString

    let targetDay = workflowDayInfo(for: selectedDate)
    let storageDayString = targetDay.dayString
    let selectedProvider = dailyRecapProvider
    let usesDayflowInputs = selectedProvider.usesDayflowInputs

    guard selectedProvider.canGenerate else {
      standupDraft = .noProviderSelected
      standupRegenerateState = .idle
      return
    }
    let providerProps: [String: Any] = [
      "daily_provider": selectedProvider.analyticsName,
      "daily_provider_label": selectedProvider.displayName,
      "daily_runtime": selectedProvider.runtimeLabel,
      "daily_model_or_tool": selectedProvider.modelOrTool as Any,
    ]
    guard let sourceDayInfo = standupSourceDay ?? resolveStandupSourceDay(for: targetDay) else {
      standupRegenerateState = .noData
      AnalyticsService.shared.capture(
        "daily_generation_failed",
        providerProps.merging(
          [
            "timeline_day": storageDayString,
            "source": "regenerate_button",
            "reason": "not_enough_recent_activity",
          ],
          uniquingKeysWith: { _, new in new }
        ))
      scheduleStandupRegenerateReset()
      return
    }

    let dayString = sourceDayInfo.dayString
    let dayStartTs = Int(sourceDayInfo.startOfDay.timeIntervalSince1970)
    let dayEndTs = Int(sourceDayInfo.endOfDay.timeIntervalSince1970)
    let standupTitles = standupSectionTitles(for: selectedDate, sourceDay: sourceDayInfo)
    let currentHighlightsTitle = standupTitles.highlights
    let currentTasksTitle = standupTitles.tasks
    let currentBlockersTitle = standupTitles.blockers

    standupRegenerateTask?.cancel()
    standupRegenerateResetTask?.cancel()

    AnalyticsService.shared.capture(
      "daily_standup_regenerate_clicked",
      providerProps.merging(
        [
          "timeline_day": storageDayString,
          "source": "regenerate_button",
        ],
        uniquingKeysWith: { _, new in new }
      ))
    print(
      "[Daily] Regenerate started run_id=\(regenerateRunId) day=\(dayString) provider=\(selectedProvider.analyticsName) model=\(selectedProvider.modelOrTool ?? "default")"
    )

    standupRegenerateState = .regenerating

    standupRegenerateTask = Task.detached(priority: .userInitiated) {
      let startedAt = Date()
      let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
      guard !cards.isEmpty else {
        guard !Task.isCancelled else { return }
        print(
          "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) reason=no_cards")
        await MainActor.run {
          standupRegenerateState = .noData
          standupRegenerateTask = nil
          AnalyticsService.shared.capture(
            "daily_generation_failed",
            providerProps.merging(
              [
                "timeline_day": storageDayString,
                "source": "regenerate_button",
                "reason": "no_cards",
              ],
              uniquingKeysWith: { _, new in new }
            ))
          scheduleStandupRegenerateReset()
        }
        return
      }

      let observations =
        usesDayflowInputs
        ? StorageManager.shared.fetchObservations(startTs: dayStartTs, endTs: dayEndTs) : []
      let priorEntries =
        usesDayflowInputs
        ? StorageManager.shared.fetchRecentDailyStandups(
          limit: priorStandupHistoryLimit,
          excludingDay: dayString
        ) : []
      let cardsText = DailyRecapGenerator.makeCardsText(day: dayString, cards: cards)
      let observationsText =
        usesDayflowInputs
        ? DailyRecapGenerator.makeObservationsText(day: dayString, observations: observations)
        : ""
      let priorDailyText =
        usesDayflowInputs ? DailyRecapGenerator.makePriorDailyText(entries: priorEntries) : ""
      let preferencesText =
        usesDayflowInputs
        ? DailyRecapGenerator.makePreferencesText(
          highlightsTitle: currentHighlightsTitle,
          tasksTitle: currentTasksTitle,
          blockersTitle: currentBlockersTitle
        ) : ""

      AnalyticsService.shared.capture(
        "daily_generation_payload_built",
        providerProps.merging(
          [
            "timeline_day": dayString,
            "source": "regenerate_button",
            "input_mode": usesDayflowInputs ? "cards_observations_prior" : "cards_only",
            "cards_count": cards.count,
            "observations_count": observations.count,
            "prior_daily_count": priorEntries.count,
            "cards_text_chars": cardsText.count,
            "observations_text_chars": observationsText.count,
            "prior_daily_text_chars": priorDailyText.count,
            "preferences_text_chars": preferencesText.count,
          ],
          uniquingKeysWith: { _, new in new }
        ))
      print(
        "[Daily] Regenerate payload run_id=\(regenerateRunId) day=\(dayString) "
          + "cards=\(cards.count) observations=\(observations.count) prior_daily=\(priorEntries.count) input_mode=\(usesDayflowInputs ? "cards_observations_prior" : "cards_only")"
      )

      do {
        let context = DailyRecapGenerationContext(
          targetDayString: storageDayString,
          sourceDayString: dayString,
          cards: cards,
          observations: observations,
          priorEntries: priorEntries,
          highlightsTitle: currentHighlightsTitle,
          tasksTitle: currentTasksTitle,
          blockersTitle: currentBlockersTitle
        )
        let regeneratedDraft = try await DailyRecapGenerator.shared.generate(context: context)

        guard let payloadJSON = regeneratedDraft.encodedJSONString() else {
          guard !Task.isCancelled else { return }
          print(
            "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) "
              + "reason=encode_failed"
          )
          await MainActor.run {
            standupRegenerateState = .idle
            standupRegenerateTask = nil
            AnalyticsService.shared.capture(
              "daily_generation_failed",
              providerProps.merging(
                [
                  "timeline_day": storageDayString,
                  "source": "regenerate_button",
                  "reason": "encode_failed",
                ],
                uniquingKeysWith: { _, new in new }
              ))
          }
          return
        }

        StorageManager.shared.saveDailyStandup(forDay: storageDayString, payloadJSON: payloadJSON)

        guard !Task.isCancelled else { return }
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let blockersCount = regeneratedDraft.blockersBody
          .split(whereSeparator: \.isNewline)
          .count
        print(
          "[Daily] Regenerate succeeded run_id=\(regenerateRunId) day=\(dayString) cards=\(cards.count) observations=\(observations.count) highlights=\(regeneratedDraft.highlights.count) tasks=\(regeneratedDraft.tasks.count) blockers=\(blockersCount) latency_ms=\(latencyMs)"
        )

        await MainActor.run {
          standupDraft = regeneratedDraft
          loadedStandupDraftDay = storageDayString
          loadedStandupFallbackSourceDay = sourceDayInfo.dayString
          standupSourceDay = sourceDayInfo
          hasPersistedStandupEntry = true
          standupRegenerateTask = nil
          standupRegenerateState = .regenerated

          AnalyticsService.shared.capture(
            "daily_standup_regenerated",
            providerProps.merging(
              [
                "timeline_day": storageDayString,
                "highlights_count": regeneratedDraft.highlights.count,
                "tasks_count": regeneratedDraft.tasks.count,
                "blockers_count": blockersCount,
              ],
              uniquingKeysWith: { _, new in new }
            ))
          AnalyticsService.shared.capture(
            "daily_generation_succeeded",
            providerProps.merging(
              [
                "timeline_day": storageDayString,
                "source": "regenerate_button",
                "highlights_count": regeneratedDraft.highlights.count,
                "tasks_count": regeneratedDraft.tasks.count,
                "blockers_count": blockersCount,
                "latency_ms": latencyMs,
              ],
              uniquingKeysWith: { _, new in new }
            ))
          print(
            "[Daily] Regenerate notification enqueue run_id=\(regenerateRunId) "
              + "day=\(storageDayString)"
          )
          NotificationService.shared.scheduleDailyRecapReadyNotification(forDay: storageDayString)

          scheduleStandupRegenerateReset()
        }
      } catch {
        let nsError = error as NSError
        guard !Task.isCancelled else { return }
        print(
          "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) reason=api_error error_domain=\(nsError.domain) error_code=\(nsError.code) error_message=\(nsError.localizedDescription)"
        )
        await MainActor.run {
          standupRegenerateState = .idle
          standupRegenerateTask = nil
          AnalyticsService.shared.capture(
            "daily_generation_failed",
            providerProps.merging(
              [
                "timeline_day": storageDayString,
                "source": "regenerate_button",
                "reason": "api_error",
                "error_domain": nsError.domain,
                "error_code": nsError.code,
                "error_message": String(nsError.localizedDescription.prefix(500)),
              ],
              uniquingKeysWith: { _, new in new }
            ))
        }
      }
    }
  }

  private func standupClipboardText(for date: Date) -> String {
    let targetDay = workflowDayInfo(for: date)
    let sourceDay = resolveStandupSourceDay(for: targetDay)
    let titles = standupSectionTitles(for: date, sourceDay: sourceDay)
    let yesterdayItems = sanitizedStandupItems(standupDraft.highlights)
    let todayItems = sanitizedStandupItems(standupDraft.tasks)
    let blockersItems = sanitizedBlockers(standupDraft.blockersBody)

    var lines: [String] = []
    lines.append(titles.highlights)
    if yesterdayItems.isEmpty {
      lines.append("- None right now")
    } else {
      yesterdayItems.forEach { lines.append("- \($0)") }
    }
    lines.append("")

    lines.append(titles.tasks)
    if todayItems.isEmpty {
      lines.append("- None right now")
    } else {
      todayItems.forEach { lines.append("- \($0)") }
    }
    lines.append("")

    lines.append(titles.blockers)
    if blockersItems.isEmpty {
      lines.append("- None right now")
    } else {
      blockersItems.forEach { lines.append("- \($0)") }
    }

    return lines.joined(separator: "\n")
  }

  private func sanitizedStandupItems(_ items: [DailyBulletItem]) -> [String] {
    items.compactMap { sanitizedBulletText($0.text) }
  }

  private func sanitizedBlockers(_ text: String) -> [String] {
    let segments = text.split(whereSeparator: \.isNewline).map(String.init)
    if segments.isEmpty {
      return sanitizedBulletText(text).map { [$0] } ?? []
    }
    return segments.compactMap(sanitizedBulletText)
  }

  private func sanitizedBulletText(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.notGeneratedMessage) != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.todayNotGeneratedMessage)
        != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.insufficientHistoryMessage)
        != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.noProviderSelectedMessage)
        != .orderedSame
    else {
      return nil
    }
    return trimmed
  }

  private func refreshStandupDraftIfNeeded(
    storageDayString: String,
    sourceDay: DailyStandupDayInfo?
  ) {
    let fallbackSourceDayString = sourceDay?.dayString
    let isSameDraftDay = loadedStandupDraftDay == storageDayString
    let isSameFallbackSourceDay = loadedStandupFallbackSourceDay == fallbackSourceDayString
    let entry = StorageManager.shared.fetchDailyStandup(forDay: storageDayString)
    hasPersistedStandupEntry = entry != nil

    if dailyRecapProvider == .none, entry == nil {
      guard !isSameDraftDay || !isSameFallbackSourceDay || standupDraft != .noProviderSelected
      else {
        return
      }

      loadedStandupDraftDay = storageDayString
      loadedStandupFallbackSourceDay = fallbackSourceDayString
      standupDraft = .noProviderSelected
      return
    }

    if entry != nil {
      guard !isSameDraftDay else { return }
    } else {
      guard !isSameDraftDay || !isSameFallbackSourceDay else { return }
    }

    loadedStandupDraftDay = storageDayString
    loadedStandupFallbackSourceDay = fallbackSourceDayString

    guard let entry,
      let data = entry.payloadJSON.data(using: .utf8),
      var decoded = try? JSONDecoder().decode(DailyStandupDraft.self, from: data)
    else {
      standupDraft = placeholderStandupDraft(sourceDay: sourceDay)
      return
    }

    if decoded.generation == nil {
      decoded.generation = .legacyDayflow
    }
    standupDraft = decoded
  }

  private func scheduleStandupDraftSave() {
    guard let dayString = loadedStandupDraftDay else { return }
    let draftToSave = standupDraft

    standupDraftSaveTask?.cancel()
    standupDraftSaveTask = Task.detached(priority: .utility) {
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }

      let existing = StorageManager.shared.fetchDailyStandup(forDay: dayString)
      let placeholderDrafts: [DailyStandupDraft] = [
        .default,
        .insufficientHistory,
      ]
      if draftToSave == .noProviderSelected {
        return
      }
      if existing == nil && placeholderDrafts.contains(draftToSave) {
        return
      }

      guard let data = try? JSONEncoder().encode(draftToSave),
        let json = String(data: data, encoding: .utf8)
      else {
        return
      }

      StorageManager.shared.saveDailyStandup(forDay: dayString, payloadJSON: json)
      await MainActor.run {
        if loadedStandupDraftDay == dayString {
          hasPersistedStandupEntry = true
        }
      }
    }
  }

  private func workflowDayString(for date: Date) -> String {
    workflowDayInfo(for: date).dayString
  }

  private func isRelevantTimelineDayUpdate(_ updatedDayString: String, for date: Date) -> Bool {
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

  private func workflowDayInfo(for date: Date) -> DailyStandupDayInfo {
    let anchorDate = timelineDisplayDate(from: date)
    let dayInfo = anchorDate.getDayInfoFor4AMBoundary()
    return DailyStandupDayInfo(
      dayString: dayInfo.dayString,
      startOfDay: dayInfo.startOfDay,
      endOfDay: dayInfo.endOfDay
    )
  }

  private func resolveStandupSourceDay(for targetDay: DailyStandupDayInfo) -> DailyStandupDayInfo? {
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

  private func placeholderStandupDraft(sourceDay: DailyStandupDayInfo?) -> DailyStandupDraft {
    if dailyRecapProvider == .none {
      return .noProviderSelected
    }

    if sourceDay == nil {
      return .insufficientHistory
    }

    return .default
  }

  private var regenerateButtonLabel: String {
    switch standupRegenerateState {
    case .regenerating:
      return "Regenerating" + String(repeating: ".", count: standupRegeneratingDotsPhase)
    case .idle, .regenerated, .noData:
      return "Regenerate"
    }
  }

  private var transientRegenerateButtonLabel: String? {
    switch standupRegenerateState {
    case .regenerated:
      return "Regenerated"
    case .noData:
      return "No data"
    case .idle, .regenerating:
      return nil
    }
  }

  private func scheduleStandupRegenerateReset() {
    standupRegenerateResetTask?.cancel()
    standupRegenerateResetTask = Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        standupRegenerateState = .idle
        standupRegenerateResetTask = nil
      }
    }
  }

  private func shiftDate(by days: Int) {
    let shifted =
      Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    selectedDate = normalizedTimelineDate(shifted)
  }

  private func dailyDateTitle(for date: Date) -> String {
    let displayDate = timelineDisplayDate(from: date)
    let timelineToday = timelineDisplayDate(from: Date())
    if Calendar.current.isDate(displayDate, inSameDayAs: timelineToday) {
      return dailyTodayDisplayFormatter.string(from: displayDate)
    }
    return dailyOtherDayDisplayFormatter.string(from: displayDate)
  }

  private func standupSectionTitles(for date: Date, sourceDay: DailyStandupDayInfo?)
    -> DailyStandupSectionTitles
  {
    let targetDay = workflowDayInfo(for: date)
    return DailyStandupSectionTitles(
      highlights: standupHighlightsTitle(for: sourceDay),
      tasks: standupTasksTitle(for: targetDay),
      blockers: "Blockers"
    )
  }

  private func standupSectionHeading(for date: Date) -> String {
    "Standup for \(dailyDateTitle(for: date))"
  }

  private func standupHighlightsTitle(for sourceDay: DailyStandupDayInfo?) -> String {
    guard let sourceDay else { return "Recent highlights" }

    let label = standupDayLabelText(for: sourceDay.startOfDay)
    if label == "Today" || label == "Yesterday" || label.hasPrefix("Last ") {
      return "\(label)'s highlights"
    }
    return "Highlights from \(label)"
  }

  private func standupTasksTitle(for targetDay: DailyStandupDayInfo) -> String {
    let label = standupDayLabelText(for: targetDay.startOfDay)
    if label == "Today" || label == "Yesterday" {
      return "\(label)'s tasks"
    }
    return "Tasks for \(label)"
  }

  private func standupDayLabelText(for date: Date) -> String {
    let calendar = Calendar.current
    let displayDate = normalizedTimelineDate(date)
    let timelineToday = timelineDisplayDate(from: Date())

    if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
      return "Today"
    }

    guard let timelineYesterday = calendar.date(byAdding: .day, value: -1, to: timelineToday)
    else {
      return dailyOtherDayDisplayFormatter.string(from: displayDate)
    }

    if calendar.isDate(displayDate, inSameDayAs: timelineYesterday) {
      return "Yesterday"
    }

    let daysAgo = calendar.dateComponents([.day], from: displayDate, to: timelineToday).day ?? 99
    if (2...6).contains(daysAgo) {
      return "Last \(dailyStandupWeekdayFormatter.string(from: displayDate))"
    }

    return dailyOtherDayDisplayFormatter.string(from: displayDate)
  }

  private func workflowTotalsTitle(for date: Date) -> String {
    if isTodaySelection(date) {
      return "Today's total so far"
    }
    if isYesterdaySelection(date) {
      return "Yesterday's total"
    }

    let displayDate = timelineDisplayDate(from: date)
    return "Total for \(dailyStandupSectionDayFormatter.string(from: displayDate))"
  }

  private func formatDuration(minutes: Double) -> String {
    formatDurationValue(minutes)
  }
}

private struct DailyCopyPressButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }
}

private struct DailyWorkflowGrid: View {
  let rows: [DailyWorkflowGridRow]
  let timelineWindow: DailyWorkflowTimelineWindow
  let distractionMarkers: [DailyWorkflowDistractionMarker]
  let showDistractionRow: Bool
  let scale: CGFloat

  @Binding var hoveredDistractionId: String?
  @Binding var hoveredCellKey: String?

  private var renderRows: [DailyWorkflowGridRow] {
    if rows.isEmpty {
      return DailyWorkflowGridRow.placeholderRows(slotCount: timelineWindow.slotCount)
    }
    // Hide the Distraction/Distractions category row when we have a dedicated distractions row
    if showDistractionRow {
      return rows.filter {
        !isDistractionCategoryKey($0.id)
      }
    }
    return rows
  }

  var body: some View {
    GeometryReader { geo in
      let hourTicks = timelineWindow.hourTickHours
      let slotCount = max(
        1, renderRows.map { $0.slotOccupancies.count }.max() ?? timelineWindow.slotCount)
      let layoutScale = scale

      let leftInset: CGFloat = 36 * layoutScale
      let categoryLabelWidth = labelColumnWidth(for: renderRows, layoutScale: layoutScale)
      let labelToGridSpacing: CGFloat = 13 * layoutScale
      let rightInset: CGFloat = 52 * layoutScale
      let topInset: CGFloat = 25 * layoutScale
      let axisTopSpacing: CGFloat = 10 * layoutScale
      let axisLabelSpacing: CGFloat = 5 * layoutScale

      let distractionRowHeight: CGFloat = 10 * layoutScale
      let distractionRowSpacing: CGFloat = 6 * layoutScale
      let distractionCornerRadius: CGFloat = max(1, 2 * layoutScale)
      let showDistractions = showDistractionRow && !distractionMarkers.isEmpty
      let distractionLabelWidth =
        showDistractions
        ? labelColumnWidth(
          for: [
            DailyWorkflowGridRow(
              id: "d", name: "Distractions", colorHex: "FF5950",
              slotOccupancies: [], slotCardInfos: [])
          ], layoutScale: layoutScale) : 0
      let effectiveLabelWidth =
        showDistractions
        ? max(categoryLabelWidth, distractionLabelWidth) : categoryLabelWidth

      let gridViewportWidth = max(
        80, geo.size.width - leftInset - effectiveLabelWidth - labelToGridSpacing - rightInset)
      let baselineCellSize: CGFloat = 18 * layoutScale
      let baselineGap: CGFloat = 2 * layoutScale
      let cellSize = baselineCellSize
      let columnSpacing = baselineGap
      let rowSpacing = baselineGap
      let cellCornerRadius = max(1.2, 2.5 * layoutScale)
      let categoryLabelFontSize: CGFloat = 12 * layoutScale
      let axisLabelFontSize: CGFloat = 10 * layoutScale
      let totalGap = columnSpacing * CGFloat(slotCount - 1)
      let gridWidth = (cellSize * CGFloat(slotCount)) + totalGap
      let axisWidth = gridWidth

      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: labelToGridSpacing) {
          VStack(alignment: .trailing, spacing: rowSpacing) {
            ForEach(renderRows) { row in
              Text(row.name)
                .font(.custom("Nunito-Regular", size: categoryLabelFontSize))
                .foregroundStyle(Color.black.opacity(0.9))
                .frame(width: effectiveLabelWidth, height: cellSize, alignment: .trailing)
            }
            if showDistractions {
              Text("Distractions")
                .font(.custom("Nunito-Regular", size: categoryLabelFontSize))
                .foregroundStyle(Color.black.opacity(0.9))
                .frame(
                  width: effectiveLabelWidth, height: distractionRowHeight, alignment: .trailing
                )
                .padding(.top, distractionRowSpacing - rowSpacing)
            }
          }
          .padding(.top, topInset)

          ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
              // Grid rows
              VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(Array(renderRows.enumerated()), id: \.element.id) { rowIndex, row in
                  HStack(spacing: columnSpacing) {
                    ForEach(0..<slotCount, id: \.self) { slotIndex in
                      let cellKey = "\(rowIndex)-\(slotIndex)"
                      Rectangle()
                        .foregroundStyle(.clear)
                        .background(fillColor(for: row, slotIndex: slotIndex))
                        .cornerRadius(cellCornerRadius)
                        .frame(width: cellSize, height: cellSize)
                        .onHover { hovering in
                          if hovering {
                            hoveredCellKey = cellKey
                            hoveredDistractionId = nil
                          } else if hoveredCellKey == cellKey {
                            hoveredCellKey = nil
                          }
                        }
                    }
                  }
                  .frame(width: gridWidth, alignment: .leading)
                }
              }
              .padding(.top, topInset)

              // Distractions row — continuous markers with proper hit areas
              if showDistractions {
                let totalMinutes = timelineWindow.endMinute - timelineWindow.startMinute

                ZStack(alignment: .topLeading) {
                  // Background track
                  Rectangle()
                    .fill(Color(red: 0.95, green: 0.93, blue: 0.92))
                    .cornerRadius(distractionCornerRadius)
                    .frame(width: gridWidth, height: distractionRowHeight)

                  // Markers — each in its own HStack for correct hit-testing
                  ForEach(distractionMarkers) { marker in
                    let startFraction =
                      (marker.startMinute - timelineWindow.startMinute) / totalMinutes
                    let endFraction = (marker.endMinute - timelineWindow.startMinute) / totalMinutes
                    let leadingPad = CGFloat(startFraction) * gridWidth
                    let markerWidth = max(
                      3 * layoutScale, CGFloat(endFraction - startFraction) * gridWidth)

                    HStack(spacing: 0) {
                      Color.clear.frame(width: leadingPad, height: distractionRowHeight)
                      Rectangle()
                        .fill(Color(hex: "FF5950"))
                        .opacity(hoveredDistractionId == marker.id ? 1.0 : 0.85)
                        .cornerRadius(distractionCornerRadius)
                        .frame(width: markerWidth, height: distractionRowHeight)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                          if hovering {
                            hoveredDistractionId = marker.id
                            hoveredCellKey = nil
                          } else if hoveredDistractionId == marker.id {
                            hoveredDistractionId = nil
                          }
                        }
                      Spacer(minLength: 0)
                    }
                    .frame(width: gridWidth, height: distractionRowHeight)
                  }
                }
                .frame(width: gridWidth, height: distractionRowHeight)
                .padding(.top, distractionRowSpacing)
              }

              VStack(alignment: .leading, spacing: axisLabelSpacing) {
                Rectangle()
                  .fill(Color(hex: "E0D9D5"))
                  .frame(width: axisWidth, height: max(0.7, 0.9 * layoutScale))

                if hourTicks.count > 1 {
                  let intervalCount = hourTicks.count - 1
                  let intervalWidth = axisWidth / CGFloat(intervalCount)
                  let labelWidth = max(22 * layoutScale, min(34 * layoutScale, intervalWidth * 1.4))

                  ZStack(alignment: .leading) {
                    ForEach(Array(hourTicks.enumerated()), id: \.offset) { index, hour in
                      let tickX = CGFloat(index) * intervalWidth
                      Text(formatAxisHourLabel(fromAbsoluteHour: hour))
                        .font(.custom("Nunito-Regular", size: axisLabelFontSize))
                        .kerning(-0.08 * layoutScale)
                        .foregroundStyle(Color.black.opacity(0.78))
                        .frame(
                          width: labelWidth,
                          alignment: axisLabelAlignment(
                            tickIndex: index,
                            tickCount: hourTicks.count
                          )
                        )
                        .offset(
                          x: axisLabelOffset(
                            tickIndex: index,
                            tickCount: hourTicks.count,
                            tickX: tickX,
                            axisWidth: axisWidth,
                            labelWidth: labelWidth
                          )
                        )
                    }
                  }
                  .frame(width: axisWidth, alignment: .leading)
                } else if let onlyTick = hourTicks.first {
                  Text(formatAxisHourLabel(fromAbsoluteHour: onlyTick))
                    .font(.custom("Nunito-Regular", size: axisLabelFontSize))
                    .kerning(-0.08 * layoutScale)
                    .foregroundStyle(Color.black.opacity(0.78))
                    .frame(width: axisWidth, alignment: .leading)
                }
              }
              .padding(.top, axisTopSpacing)
            }
            .frame(width: gridWidth, alignment: .leading)
          }
          .frame(width: gridViewportWidth, alignment: .leading)
        }
      }
      .padding(.leading, leftInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(
      height: contentHeight(
        for: renderRows.count, layoutScale: scale,
        includeDistractionRow: showDistractionRow && !distractionMarkers.isEmpty)
    )
  }

  private func contentHeight(
    for rowCount: Int, layoutScale: CGFloat, includeDistractionRow: Bool = false
  ) -> CGFloat {
    let rows = max(1, rowCount)
    let topInset: CGFloat = 25 * layoutScale
    let cell: CGFloat = 18 * layoutScale
    let gap: CGFloat = 2 * layoutScale
    let rowsHeight = (cell * CGFloat(rows)) + (gap * CGFloat(max(0, rows - 1)))
    let distractionHeight: CGFloat =
      includeDistractionRow ? (6 * layoutScale) + (10 * layoutScale) : 0
    let axisTopSpacing: CGFloat = 10 * layoutScale
    let axisLineHeight: CGFloat = max(0.7, 0.9 * layoutScale)
    let axisLabelSpacing: CGFloat = 5 * layoutScale
    let axisLabelHeight: CGFloat = 14 * layoutScale
    let bottomBuffer: CGFloat = 6 * layoutScale
    return topInset + rowsHeight + distractionHeight + axisTopSpacing + axisLineHeight
      + axisLabelSpacing + axisLabelHeight + bottomBuffer
  }

  private func fillColor(for row: DailyWorkflowGridRow, slotIndex: Int) -> Color {
    guard slotIndex < row.slotOccupancies.count else {
      return Color(red: 0.95, green: 0.93, blue: 0.92)
    }
    let occupancy = min(max(row.slotOccupancies[slotIndex], 0), 1)
    guard occupancy > 0 else { return Color(red: 0.95, green: 0.93, blue: 0.92) }

    // Partial occupancy stays dimmer; full occupancy reaches full intensity.
    let alpha = 0.3 + (occupancy * 0.7)
    return Color(hex: row.colorHex).opacity(alpha)
  }

  private func axisLabelAlignment(tickIndex: Int, tickCount: Int) -> Alignment {
    if tickIndex == tickCount - 1 { return .trailing }
    return .leading
  }

  private func axisLabelOffset(
    tickIndex: Int,
    tickCount: Int,
    tickX: CGFloat,
    axisWidth: CGFloat,
    labelWidth: CGFloat
  ) -> CGFloat {
    if tickIndex == tickCount - 1 { return max(0, axisWidth - labelWidth) }
    return min(max(0, tickX), max(0, axisWidth - labelWidth))
  }

  private func labelColumnWidth(for rows: [DailyWorkflowGridRow], layoutScale: CGFloat) -> CGFloat {
    gridLabelColumnWidth(for: rows, layoutScale: layoutScale)
  }

}

// MARK: - Shared tooltip builders and grid helpers

private func gridLabelColumnWidth(
  for rows: [DailyWorkflowGridRow], layoutScale: CGFloat
) -> CGFloat {
  let fontSize = 12 * layoutScale
  let font =
    NSFont(name: "Nunito-Regular", size: fontSize)
    ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
  let measuredMax = rows.reduce(CGFloat.zero) { currentMax, row in
    let width = (row.name as NSString).size(withAttributes: [.font: font]).width
    return max(currentMax, width)
  }
  return ceil(measuredMax + 1)
}

@ViewBuilder
private func workflowTooltip(
  durationMinutes: Double,
  title: String,
  accentColor: Color,
  layoutScale: CGFloat
) -> some View {
  VStack(alignment: .leading, spacing: 4 * layoutScale) {
    Text(formatDurationValue(durationMinutes))
      .font(.custom("Nunito-SemiBold", size: 12 * layoutScale))
      .foregroundStyle(accentColor)
    Text(title)
      .font(.custom("Nunito-Regular", size: 12 * layoutScale))
      .foregroundStyle(Color.black)
      .fixedSize(horizontal: false, vertical: true)
  }
  .padding(8 * layoutScale)
  .frame(width: 200 * layoutScale, alignment: .leading)
  .background(tooltipBackground(layoutScale: layoutScale))
  .allowsHitTesting(false)
}

@ViewBuilder
private func tooltipBackground(layoutScale: CGFloat) -> some View {
  RoundedRectangle(cornerRadius: 4, style: .continuous)
    .fill(Color.white)
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(Color(hex: "EDE0CE"), lineWidth: 1)
    )
    .shadow(
      color: Color(red: 1, green: 0.63, blue: 0.54).opacity(0.25), radius: 2, x: 0, y: 2)
}

private struct DailyStatChip: View {
  let title: String
  let value: String
  let scale: CGFloat

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.custom("Nunito-Regular", size: 10 * scale))
        .foregroundStyle(Color(hex: "5D5651"))
      Text(value)
        .font(.custom("Nunito-SemiBold", size: 10 * scale))
        .foregroundStyle(Color(hex: "D77A43"))
    }
    .padding(.horizontal, 12 * scale)
    .padding(.vertical, 6 * scale)
    .background(
      Capsule(style: .continuous)
        .fill(Color(hex: "F7F3F0"))
    )
    .overlay(
      Capsule(style: .continuous)
        .stroke(Color(hex: "DDD6CF"), lineWidth: max(0.6, 0.8 * scale))
    )
  }
}

private struct DailyModeToggle: View {
  enum ActiveMode {
    case highlights
    case details
  }

  let activeMode: ActiveMode
  let scale: CGFloat

  private var cornerRadius: CGFloat { 8 * scale }
  private var borderWidth: CGFloat { max(0.7, 1 * scale) }
  private var borderColor: Color { Color(hex: "C7C2C0") }

  var body: some View {
    HStack(spacing: 0) {
      segment(
        text: "Highlights",
        isActive: activeMode == .highlights,
        isLeading: true
      )
      segment(
        text: "Details",
        isActive: activeMode == .details,
        isLeading: false
      )
    }
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(borderColor, lineWidth: borderWidth)
    )
  }

  @ViewBuilder
  private func segment(text: String, isActive: Bool, isLeading: Bool) -> some View {
    let fill = isActive ? Color(hex: "FFA767") : Color(hex: "FFFAF7").opacity(0.6)

    Text(text)
      .font(.custom("Nunito-Regular", size: 14 * scale))
      .lineLimit(1)
      .foregroundStyle(isActive ? Color.white : Color(hex: "837870"))
      .padding(.horizontal, 12 * scale)
      .padding(.vertical, 8 * scale)
      .frame(minHeight: 33 * scale)
      .background(
        UnevenRoundedRectangle(
          cornerRadii: .init(
            topLeading: isLeading ? cornerRadius : 0,
            bottomLeading: isLeading ? cornerRadius : 0,
            bottomTrailing: isLeading ? 0 : cornerRadius,
            topTrailing: isLeading ? 0 : cornerRadius
          ),
          style: .continuous
        )
        .fill(fill)
      )
      .overlay(alignment: .trailing) {
        if isLeading {
          Rectangle()
            .fill(borderColor)
            .frame(width: borderWidth)
        }
      }
  }
}

private struct DailyBulletCard: View {
  enum SeamMode {
    case standalone
    case joinedLeading
    case joinedTrailing
  }

  enum Style {
    case highlights
    case tasks
  }

  let style: Style
  let seamMode: SeamMode
  let title: String
  @Binding var items: [DailyBulletItem]
  @Binding var blockersTitle: String
  @Binding var blockersBody: String
  let scale: CGFloat
  @State private var draggedItemID: UUID? = nil
  @State private var pendingScrollTargetID: UUID? = nil
  @FocusState private var focusedItemID: UUID?
  @State private var keyMonitor: Any? = nil

  private var listViewportHeight: CGFloat {
    style == .tasks ? 142 * scale : 230 * scale
  }

  private var listMinHeight: CGFloat {
    style == .tasks ? 92 * scale : 154 * scale
  }

  private var cardShape: UnevenRoundedRectangle {
    let cornerRadius = 12 * scale
    let cornerRadii: RectangleCornerRadii

    switch seamMode {
    case .standalone:
      cornerRadii = .init(
        topLeading: cornerRadius,
        bottomLeading: cornerRadius,
        bottomTrailing: cornerRadius,
        topTrailing: cornerRadius
      )
    case .joinedLeading:
      cornerRadii = .init(
        topLeading: cornerRadius,
        bottomLeading: cornerRadius,
        bottomTrailing: 0,
        topTrailing: 0
      )
    case .joinedTrailing:
      cornerRadii = .init(
        topLeading: 0,
        bottomLeading: 0,
        bottomTrailing: cornerRadius,
        topTrailing: cornerRadius
      )
    }

    return UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 18 * scale) {
        Text(title)
          .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
          .foregroundStyle(Color(hex: "B46531"))
          .frame(maxWidth: .infinity, alignment: .leading)

        itemListEditor
      }
      .padding(.leading, 26 * scale)
      .padding(.trailing, 26 * scale)
      .padding(.top, 26 * scale)

      addItemButton
        .padding(.leading, style == .highlights ? 16 * scale : 26 * scale)
        .padding(.bottom, style == .tasks ? 24 * scale : 20 * scale)

      if style == .tasks {
        DailyBlockersSection(
          scale: scale,
          title: $blockersTitle,
          prompt: $blockersBody
        )
      }
    }
    .frame(maxWidth: .infinity, minHeight: max(180, 394 * scale), alignment: .topLeading)
    .background(
      cardShape
        .fill(
          LinearGradient(
            gradient: Gradient(stops: [
              .init(color: Color.white.opacity(0.6), location: 0.011932),
              .init(color: Color.white, location: 0.5104),
              .init(color: Color.white.opacity(0.6), location: 0.98092),
            ]),
            startPoint: UnitPoint(x: 1, y: 0.45),
            endPoint: UnitPoint(x: 0, y: 0.55)
          )
        )
    )
    .clipShape(cardShape)
    .overlay(
      cardShape
        .stroke(Color(hex: "EBE6E3"), lineWidth: max(0.7, 1 * scale))
    )
    .shadow(color: Color.black.opacity(0.1), radius: 12 * scale, x: 0, y: 0)
    .onAppear {
      setupKeyMonitor()
    }
    .onDisappear {
      removeKeyMonitor()
    }
  }

  private var itemListEditor: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: items.count > 5) {
        LazyVStack(alignment: .leading, spacing: 10 * scale) {
          ForEach(items) { item in
            let itemID = item.id
            HStack(alignment: .top, spacing: 8 * scale) {
              DailyDragHandleIcon(scale: scale)
                .frame(width: 18 * scale, height: 18 * scale)
                .padding(.top, 2 * scale)
                .contentShape(Rectangle())
                .onDrag {
                  draggedItemID = itemID
                  return NSItemProvider(object: itemID.uuidString as NSString)
                }
                .pointingHandCursorOnHover(reassertOnPressEnd: true)

              TextField("", text: bindingForItemText(id: itemID), axis: .vertical)
                .font(.custom("Nunito-Regular", size: 14 * scale))
                .foregroundStyle(Color.black)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focusedItemID, equals: itemID)
                .onSubmit {
                  addItem(after: itemID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(itemID)
            .frame(minHeight: 22 * scale, alignment: .top)
            .onDrop(
              of: ["public.text"],
              delegate: DailyListItemDropDelegate(
                targetItemID: itemID,
                items: $items,
                draggedItemID: $draggedItemID
              )
            )
          }
        }
        .padding(.vertical, 2 * scale)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: listMinHeight, maxHeight: listViewportHeight, alignment: .topLeading)
      .onDrop(
        of: ["public.text"],
        delegate: DailyListDropToEndDelegate(
          items: $items,
          draggedItemID: $draggedItemID
        )
      )
      .onChange(of: pendingScrollTargetID) { _, newValue in
        guard let newValue else { return }
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo(newValue, anchor: .bottom)
        }
        pendingScrollTargetID = nil
      }
    }
  }

  private func bindingForItemText(id itemID: UUID) -> Binding<String> {
    Binding(
      get: {
        items.first(where: { $0.id == itemID })?.text ?? ""
      },
      set: { newValue in
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].text = newValue
      }
    )
  }

  private var addItemButton: some View {
    Button(action: { addItem(after: nil) }) {
      HStack(spacing: 6 * scale) {
        Image(systemName: "plus")
          .font(.system(size: 18 * scale, weight: .regular))
          .foregroundStyle(Color(hex: "999999"))
          .frame(width: 18 * scale, height: 18 * scale)

        Text("Add item")
          .font(.custom("Nunito-Regular", size: 13 * scale))
          .foregroundStyle(Color(hex: "999999"))
          .lineLimit(1)
      }
      .padding(.vertical, 6 * scale)
    }
    .buttonStyle(.plain)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }

  private func addItem(after itemID: UUID?) {
    let newItem = DailyBulletItem(text: "")
    if let itemID, let index = items.firstIndex(where: { $0.id == itemID }) {
      items.insert(newItem, at: index + 1)
    } else {
      items.append(newItem)
    }

    pendingScrollTargetID = newItem.id
    focusedItemID = newItem.id
  }

  private func setupKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 51 else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags.isEmpty else { return event }
      return scheduleFocusedItemRemovalIfEmpty() ? nil : event
    }
  }

  private func removeKeyMonitor() {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
  }

  private func scheduleFocusedItemRemovalIfEmpty() -> Bool {
    guard let activeFocusedItemID = focusedItemID,
      let index = items.firstIndex(where: { $0.id == activeFocusedItemID })
    else {
      return false
    }

    guard items.indices.contains(index) else {
      return false
    }

    guard items[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }

    DispatchQueue.main.async {
      removeItemIfStillEmpty(withID: activeFocusedItemID)
    }
    return true
  }

  private func removeItemIfStillEmpty(withID itemID: UUID) {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else {
      return
    }

    guard items.indices.contains(index) else {
      return
    }

    guard items[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    focusedItemID = nil
    items.remove(at: index)
  }
}

private struct DailyDragHandleIcon: View {
  let scale: CGFloat

  var body: some View {
    VStack(spacing: 2 * scale) {
      ForEach(0..<3, id: \.self) { _ in
        HStack(spacing: 2 * scale) {
          Circle()
            .fill(Color(hex: "A5A5A5"))
            .frame(width: 2.5 * scale, height: 2.5 * scale)
          Circle()
            .fill(Color(hex: "A5A5A5"))
            .frame(width: 2.5 * scale, height: 2.5 * scale)
        }
      }
    }
    .frame(width: 12 * scale, height: 12 * scale, alignment: .center)
  }
}

private struct DailyBlockersSection: View {
  let scale: CGFloat
  @Binding var title: String
  @Binding var prompt: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8 * scale) {
      TextField("Blockers", text: $title)
        .font(.custom("Nunito-Medium", size: 14 * scale))
        .foregroundStyle(Color(hex: "BD9479"))
        .textFieldStyle(.plain)

      HStack(alignment: .center, spacing: 8 * scale) {
        DailyDragHandleIcon(scale: scale)
          .frame(width: 18 * scale, height: 18 * scale)

        TextField("Fill in any blockers you may have", text: $prompt, axis: .vertical)
          .font(.custom("Nunito-Regular", size: 14 * scale))
          .foregroundStyle(Color(hex: "929292"))
          .textFieldStyle(.plain)
          .lineLimit(1...4)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.leading, 26 * scale)
    .padding(.trailing, 26 * scale)
    .padding(.top, 14 * scale)
    .frame(maxWidth: .infinity, minHeight: 94 * scale, alignment: .topLeading)
    .background(Color(hex: "F7F6F5"))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color(hex: "EBE6E3"))
        .frame(height: max(0.7, 1 * scale))
    }
  }
}

private struct DailyListItemDropDelegate: DropDelegate {
  let targetItemID: UUID
  @Binding var items: [DailyBulletItem]
  @Binding var draggedItemID: UUID?

  func dropEntered(info: DropInfo) {
    guard let draggedID = draggedItemID,
      draggedID != targetItemID,
      let fromIndex = items.firstIndex(where: { $0.id == draggedID }),
      let toIndex = items.firstIndex(where: { $0.id == targetItemID })
    else {
      return
    }

    withAnimation(.easeInOut(duration: 0.14)) {
      items.move(
        fromOffsets: IndexSet(integer: fromIndex),
        toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
      )
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedItemID = nil
    return true
  }
}

private struct DailyListDropToEndDelegate: DropDelegate {
  @Binding var items: [DailyBulletItem]
  @Binding var draggedItemID: UUID?

  func dropEntered(info: DropInfo) {
    guard let draggedID = draggedItemID,
      let fromIndex = items.firstIndex(where: { $0.id == draggedID })
    else {
      return
    }

    let endIndex = items.count
    guard fromIndex != endIndex - 1 else { return }

    withAnimation(.easeInOut(duration: 0.14)) {
      items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: endIndex)
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedItemID = nil
    return true
  }
}

private struct DailyWorkflowSlotCardInfo: Sendable {
  let title: String
  let durationMinutes: Double
}

private struct DailyWorkflowGridRow: Identifiable, Sendable {
  let id: String
  let name: String
  let colorHex: String
  let slotOccupancies: [Double]
  let slotCardInfos: [DailyWorkflowSlotCardInfo?]

  static func placeholderRows(slotCount: Int) -> [DailyWorkflowGridRow] {
    DailyGridConfig.fallbackCategoryNames.enumerated().map { index, name in
      DailyWorkflowGridRow(
        id: "placeholder-\(index)",
        name: name,
        colorHex: DailyGridConfig.fallbackColorHexes[
          index % DailyGridConfig.fallbackColorHexes.count],
        slotOccupancies: Array(repeating: 0, count: max(1, slotCount)),
        slotCardInfos: Array(repeating: nil, count: max(1, slotCount))
      )
    }
  }
}

private struct DailyWorkflowTotalItem: Identifiable, Sendable {
  let id: String
  let name: String
  let minutes: Double
  let colorHex: String
}

private struct DailyWorkflowDistractionMarker: Identifiable, Sendable {
  let id: String
  let title: String
  let startMinute: Double
  let endMinute: Double
}

private struct DailyWorkflowComputationResult: Sendable {
  let rows: [DailyWorkflowGridRow]
  let totals: [DailyWorkflowTotalItem]
  let stats: [DailyWorkflowStatChip]
  let window: DailyWorkflowTimelineWindow
  let distractionMarkers: [DailyWorkflowDistractionMarker]
  let hasDistractionCategory: Bool
}

private struct DailyWorkflowSegment: Sendable {
  let categoryKey: String
  let displayName: String
  let colorHex: String
  let startMinute: Double
  let endMinute: Double
  let hasDistraction: Bool
  let cardTitle: String
  let cardDurationMinutes: Double
}

private struct DailyWorkflowStatChip: Identifiable, Sendable {
  let id: String
  let title: String
  let value: String

  static let placeholder: [DailyWorkflowStatChip] = [
    DailyWorkflowStatChip(id: "context-switched", title: "Context switched", value: "0 times"),
    DailyWorkflowStatChip(id: "interrupted", title: "Interrupted", value: "0 times"),
    DailyWorkflowStatChip(id: "focused-for", title: "Focused for", value: "0m"),
    DailyWorkflowStatChip(id: "distracted-for", title: "Distracted for", value: "0m"),
    DailyWorkflowStatChip(id: "transitioning-time", title: "Transitioning time", value: "0m"),
  ]
}

private struct DailyWorkflowTimelineWindow: Sendable {
  let startMinute: Double
  let endMinute: Double

  static let placeholder = DailyWorkflowTimelineWindow(
    startMinute: DailyGridConfig.visibleStartMinute,
    endMinute: DailyGridConfig.visibleEndMinute
  )

  var hourTickHours: [Int] {
    guard endMinute > startMinute else { return [9, 17] }

    let startHour = Int(floor(startMinute / 60))
    let endHour = Int(ceil(endMinute / 60))
    let adjustedEndHour = max(startHour + 1, endHour)
    return Array(startHour...adjustedEndHour)
  }

  var slotCount: Int {
    guard endMinute > startMinute else {
      let fallbackDuration = DailyGridConfig.visibleEndMinute - DailyGridConfig.visibleStartMinute
      return max(1, Int((fallbackDuration / DailyGridConfig.slotDurationMinutes).rounded()))
    }

    let durationMinutes = endMinute - startMinute
    return max(1, Int((durationMinutes / DailyGridConfig.slotDurationMinutes).rounded()))
  }

  var hourLabels: [String] {
    hourTickHours.map(formatAxisHourLabel(fromAbsoluteHour:))
  }
}

private func computeDailyWorkflow(cards: [TimelineCard], categories: [TimelineCategory])
  -> DailyWorkflowComputationResult
{
  let systemCategoryKey = normalizedCategoryKey("System")
  let orderedCategories =
    categories
    .sorted { $0.order < $1.order }
    .filter { normalizedCategoryKey($0.name) != systemCategoryKey }

  let categoryLookup = firstCategoryLookup(
    from: orderedCategories,
    normalizedKey: normalizedCategoryKey
  )
  let colorMap = categoryLookup.mapValues { normalizedHex($0.colorHex) }
  let nameMap = categoryLookup.mapValues {
    $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  struct RawDailyWorkflowSegment {
    let categoryKey: String
    let displayName: String
    let colorHex: String
    let startMinute: Double
    let endMinute: Double
    let hasDistraction: Bool
    let cardTitle: String
    let cardDurationMinutes: Double
  }

  var rawSegments: [RawDailyWorkflowSegment] = []
  rawSegments.reserveCapacity(cards.count)

  for card in cards {
    guard var startMinute = parseCardMinute(card.startTimestamp),
      var endMinute = parseCardMinute(card.endTimestamp)
    else {
      continue
    }

    let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
    startMinute = normalized.start
    endMinute = normalized.end

    let trimmed = card.category.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = trimmed.isEmpty ? "Uncategorized" : trimmed
    let key = normalizedCategoryKey(displayName)
    guard key != systemCategoryKey else { continue }
    let colorHex = colorMap[key] ?? fallbackColorHex(for: key)

    rawSegments.append(
      RawDailyWorkflowSegment(
        categoryKey: key,
        displayName: displayName,
        colorHex: colorHex,
        startMinute: startMinute,
        endMinute: endMinute,
        hasDistraction: !(card.distractions?.isEmpty ?? true),
        cardTitle: card.title,
        cardDurationMinutes: endMinute - startMinute
      )
    )
  }

  let workflowWindow: DailyWorkflowTimelineWindow = {
    guard !rawSegments.isEmpty else { return .placeholder }

    let firstUsedMinute = rawSegments.map(\.startMinute).min() ?? DailyGridConfig.visibleStartMinute
    let lastUsedMinute = rawSegments.map(\.endMinute).max() ?? DailyGridConfig.visibleEndMinute

    let alignedStart = floor(firstUsedMinute / 60) * 60
    let alignedDataEnd = ceil(lastUsedMinute / 60) * 60
    let minWindowDuration = DailyGridConfig.visibleEndMinute - DailyGridConfig.visibleStartMinute
    let computedEnd = max(alignedStart + minWindowDuration, alignedDataEnd)

    return DailyWorkflowTimelineWindow(startMinute: alignedStart, endMinute: computedEnd)
  }()

  let visibleStart = workflowWindow.startMinute
  let visibleEnd = workflowWindow.endMinute
  let slotCount = workflowWindow.slotCount
  let slotDuration = DailyGridConfig.slotDurationMinutes

  let segments: [DailyWorkflowSegment] = rawSegments.compactMap { raw in
    let clippedStart = max(raw.startMinute, visibleStart)
    let clippedEnd = min(raw.endMinute, visibleEnd)
    guard clippedEnd > clippedStart else { return nil }
    return DailyWorkflowSegment(
      categoryKey: raw.categoryKey,
      displayName: raw.displayName,
      colorHex: raw.colorHex,
      startMinute: clippedStart,
      endMinute: clippedEnd,
      hasDistraction: raw.hasDistraction,
      cardTitle: raw.cardTitle,
      cardDurationMinutes: raw.cardDurationMinutes
    )
  }

  var durationByCategory: [String: Double] = [:]
  var resolvedNameByCategory: [String: String] = [:]
  var resolvedColorByCategory: [String: String] = [:]

  for segment in segments {
    let overlap = max(0, segment.endMinute - segment.startMinute)
    guard overlap > 0 else { continue }
    durationByCategory[segment.categoryKey, default: 0] += overlap
    resolvedNameByCategory[segment.categoryKey] = segment.displayName
    resolvedColorByCategory[segment.categoryKey] = segment.colorHex
  }

  let sortedSegments = segments.sorted { lhs, rhs in
    if lhs.startMinute == rhs.startMinute {
      return lhs.endMinute < rhs.endMinute
    }
    return lhs.startMinute < rhs.startMinute
  }

  let idleCategoryKeys = Set(
    orderedCategories.filter(\.isIdle).map { normalizedCategoryKey($0.name) })
  var contextSwitches = 0
  var interruptions = 0
  var focusedMinutes = 0.0
  var distractedMinutes = 0.0
  var transitionMinutes = 0.0
  var previousCategory: String? = nil
  var previousEndMinute: Double? = nil

  for segment in sortedSegments {
    let duration = max(0, segment.endMinute - segment.startMinute)
    guard duration > 0 else { continue }

    if idleCategoryKeys.contains(segment.categoryKey) {
      distractedMinutes += duration
    } else {
      focusedMinutes += duration
    }

    if segment.hasDistraction {
      interruptions += 1
    }

    if let previousCategory, previousCategory != segment.categoryKey {
      contextSwitches += 1
    }
    previousCategory = segment.categoryKey

    if let priorEndMinute = previousEndMinute {
      let gap = segment.startMinute - priorEndMinute
      if gap > 0 {
        transitionMinutes += gap
      }
      previousEndMinute = max(priorEndMinute, segment.endMinute)
    } else {
      previousEndMinute = segment.endMinute
    }
  }

  var selectedKeys: [String] = []
  var seenKeys = Set<String>()

  for category in orderedCategories {
    let key = normalizedCategoryKey(category.name)
    guard !key.isEmpty else { continue }
    guard seenKeys.insert(key).inserted else { continue }
    selectedKeys.append(key)
  }

  let unknownUsedKeys = durationByCategory.keys
    .filter { !seenKeys.contains($0) && $0 != systemCategoryKey }
    .sorted()

  for key in unknownUsedKeys {
    selectedKeys.append(key)
    seenKeys.insert(key)
  }

  let segmentsByCategory = Dictionary(grouping: segments, by: { $0.categoryKey })

  let rows: [DailyWorkflowGridRow] = selectedKeys.map { key in
    let rowSegments = segmentsByCategory[key] ?? []

    var occupancies: [Double] = []
    var cardInfos: [DailyWorkflowSlotCardInfo?] = []
    occupancies.reserveCapacity(slotCount)
    cardInfos.reserveCapacity(slotCount)

    for slotIndex in 0..<slotCount {
      let slotStart = visibleStart + (Double(slotIndex) * slotDuration)
      let slotEnd = min(visibleEnd, slotStart + slotDuration)
      let slotMinutes = max(1, slotEnd - slotStart)

      var totalOccupied = 0.0
      var bestOverlap = 0.0
      var bestSegment: DailyWorkflowSegment?

      for segment in rowSegments {
        let overlap = max(
          0, min(segment.endMinute, slotEnd) - max(segment.startMinute, slotStart))
        totalOccupied += overlap
        if overlap > bestOverlap {
          bestOverlap = overlap
          bestSegment = segment
        }
      }

      occupancies.append(min(1, totalOccupied / slotMinutes))
      if let best = bestSegment, bestOverlap > 0 {
        cardInfos.append(
          DailyWorkflowSlotCardInfo(
            title: best.cardTitle,
            durationMinutes: best.cardDurationMinutes
          ))
      } else {
        cardInfos.append(nil)
      }
    }

    let displayName =
      resolvedNameByCategory[key] ?? nameMap[key]
      ?? (key.isEmpty ? "Uncategorized" : key.capitalized)
    let colorHex = resolvedColorByCategory[key] ?? colorMap[key] ?? fallbackColorHex(for: key)

    return DailyWorkflowGridRow(
      id: key,
      name: displayName,
      colorHex: colorHex,
      slotOccupancies: occupancies,
      slotCardInfos: cardInfos
    )
  }

  let totals = selectedKeys.compactMap { key -> DailyWorkflowTotalItem? in
    guard let minutes = durationByCategory[key], minutes > 0 else { return nil }
    let name = resolvedNameByCategory[key] ?? nameMap[key] ?? "Uncategorized"
    let colorHex = resolvedColorByCategory[key] ?? colorMap[key] ?? fallbackColorHex(for: key)
    return DailyWorkflowTotalItem(id: key, name: name, minutes: minutes, colorHex: colorHex)
  }

  let stats = [
    DailyWorkflowStatChip(
      id: "context-switched",
      title: "Context switched",
      value: formatCount(contextSwitches)
    ),
    DailyWorkflowStatChip(
      id: "interrupted",
      title: "Interrupted",
      value: formatCount(interruptions)
    ),
    DailyWorkflowStatChip(
      id: "focused-for",
      title: "Focused for",
      value: formatDurationValue(focusedMinutes)
    ),
    DailyWorkflowStatChip(
      id: "distracted-for",
      title: "Distracted for",
      value: formatDurationValue(distractedMinutes)
    ),
    DailyWorkflowStatChip(
      id: "transitioning-time",
      title: "Transitioning time",
      value: formatDurationValue(transitionMinutes)
    ),
  ]

  // Check if user has a Distraction category
  let distractionCategoryKey = normalizedCategoryKey("Distraction")
  let hasDistractionCategory = orderedCategories.contains {
    normalizedCategoryKey($0.name) == distractionCategoryKey
  }

  // Collect distraction markers from both sources
  var distractionMarkers: [DailyWorkflowDistractionMarker] = []

  if hasDistractionCategory {
    var markerIndex = 0

    for card in cards {
      // Source 1: Full cards categorized as "Distraction"
      let cardCategoryKey = normalizedCategoryKey(
        card.category.trimmingCharacters(in: .whitespacesAndNewlines))
      if cardCategoryKey == distractionCategoryKey {
        if let rawStart = parseCardMinute(card.startTimestamp),
          let rawEnd = parseCardMinute(card.endTimestamp)
        {
          let (startMin, endMin) = normalizedMinuteRange(start: rawStart, end: rawEnd)
          let clippedStart = max(startMin, visibleStart)
          let clippedEnd = min(endMin, visibleEnd)
          if clippedEnd > clippedStart {
            distractionMarkers.append(
              DailyWorkflowDistractionMarker(
                id: "distraction-macro-\(markerIndex)",
                title: card.title,
                startMinute: clippedStart,
                endMinute: clippedEnd
              ))
            markerIndex += 1
          }
        }
      }

      // Source 2: Mini distractions embedded within any card
      if let distractions = card.distractions {
        for distraction in distractions {
          if let rawStart = parseCardMinute(distraction.startTime),
            let rawEnd = parseCardMinute(distraction.endTime)
          {
            var (startMin, endMin) = normalizedMinuteRange(start: rawStart, end: rawEnd)
            // Ensure mini distractions have at least 1 minute of visual width
            if endMin - startMin < 1 { endMin = startMin + 1 }

            let clippedStart = max(startMin, visibleStart)
            let clippedEnd = min(endMin, visibleEnd)
            if clippedEnd > clippedStart {
              distractionMarkers.append(
                DailyWorkflowDistractionMarker(
                  id: "distraction-mini-\(markerIndex)",
                  title: distraction.title,
                  startMinute: clippedStart,
                  endMinute: clippedEnd
                ))
              markerIndex += 1
            }
          }
        }
      }
    }

    // Merge overlapping/adjacent markers into single continuous blocks
    if distractionMarkers.count > 1 {
      distractionMarkers.sort { $0.startMinute < $1.startMinute }
      var merged: [DailyWorkflowDistractionMarker] = []
      var currentStart = distractionMarkers[0].startMinute
      var currentEnd = distractionMarkers[0].endMinute
      var currentTitles = [distractionMarkers[0].title]

      for i in 1..<distractionMarkers.count {
        let marker = distractionMarkers[i]
        // Merge if overlapping or within 2 minutes of each other
        if marker.startMinute <= currentEnd + 2 {
          // Overlapping or touching — extend and collect title
          currentEnd = max(currentEnd, marker.endMinute)
          if !currentTitles.contains(marker.title) {
            currentTitles.append(marker.title)
          }
        } else {
          // Gap — flush current merged marker
          merged.append(
            DailyWorkflowDistractionMarker(
              id: "distraction-merged-\(merged.count)",
              title: currentTitles.joined(separator: ", "),
              startMinute: currentStart,
              endMinute: currentEnd
            ))
          currentStart = marker.startMinute
          currentEnd = marker.endMinute
          currentTitles = [marker.title]
        }
      }
      // Flush last
      merged.append(
        DailyWorkflowDistractionMarker(
          id: "distraction-merged-\(merged.count)",
          title: currentTitles.joined(separator: ", "),
          startMinute: currentStart,
          endMinute: currentEnd
        ))
      distractionMarkers = merged
    }
  }

  return DailyWorkflowComputationResult(
    rows: rows, totals: totals, stats: stats, window: workflowWindow,
    distractionMarkers: distractionMarkers, hasDistractionCategory: hasDistractionCategory)
}

private func isDistractionCategoryKey(_ key: String) -> Bool {
  let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  return normalized == "distraction" || normalized == "distractions"
}

private func normalizedMinuteRange(start: Double, end: Double) -> (start: Double, end: Double) {
  let s = start < 240 ? start + 1440 : start
  var e = end < 240 ? end + 1440 : end
  if e <= s { e += 1440 }
  return (s, e)
}

private func parseCardMinute(_ value: String) -> Double? {
  guard let parsed = parseTimeHMMA(timeString: value) else { return nil }
  return Double(parsed)
}

private func normalizedCategoryKey(_ value: String) -> String {
  value
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
}

private func normalizedHex(_ value: String) -> String {
  value.replacingOccurrences(of: "#", with: "")
}

private func fallbackColorHex(for key: String) -> String {
  let hash = key.utf8.reduce(5381) { current, byte in
    ((current << 5) &+ current) &+ Int(byte)
  }
  let palette = DailyGridConfig.fallbackColorHexes
  let index = abs(hash) % palette.count
  return palette[index]
}

private func formatAxisHourLabel(fromAbsoluteHour hour: Int) -> String {
  let normalized = ((hour % 24) + 24) % 24
  let period = normalized >= 12 ? "pm" : "am"
  let display = normalized % 12 == 0 ? 12 : normalized % 12
  return "\(display)\(period)"
}

private func formatCount(_ count: Int) -> String {
  "\(count) \(count == 1 ? "time" : "times")"
}

private func formatDurationValue(_ minutes: Double) -> String {
  let rounded = max(0, Int(minutes.rounded()))
  let hours = rounded / 60
  let mins = rounded % 60

  if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
  if hours > 0 { return "\(hours)h" }
  return "\(mins)m"
}

struct DailyView_Previews: PreviewProvider {
  static var previews: some View {
    DailyView(selectedDate: .constant(Date()))
      .environmentObject(CategoryStore.shared)
      .frame(width: 1180, height: 760)
  }
}
