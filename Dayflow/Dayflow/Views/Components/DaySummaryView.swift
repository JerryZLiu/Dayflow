//
//  DaySummaryView.swift
//  Dayflow
//
//  "Your day so far" dashboard showing category breakdown and focus stats
//

import SwiftUI

private let dayGoalReviewShownTimelineDayKey = "dayGoalReviewShownTimelineDay"

struct DaySummaryLoadToken: Equatable, Sendable {
  let id: UUID
  let dayString: String

  init(id: UUID = UUID(), dayString: String) {
    self.id = id
    self.dayString = dayString
  }

  /// Token equality is the latest-wins guarantee. The day keeps tokens self-describing and
  /// prevents a request identity from being reused across timeline days.
  func matches(latest: DaySummaryLoadToken?) -> Bool {
    self == latest
  }
}

struct DaySummaryView: View {
  let selectedDate: Date
  let categories: [TimelineCategory]
  let storageManager: StorageManaging
  let cardsToReviewCount: Int
  let reviewRefreshToken: Int
  let recordingControlMode: RecordingControlMode
  var goalPromptDay: String? = nil
  var onGoalPromptHandled: ((String) -> Void)? = nil
  var onReviewTap: (() -> Void)? = nil
  var onShowGoalFlow: ((DayGoalFlowPresentation) -> Void)? = nil

  @State private var timelineCards: [TimelineCard] = []
  @State private var isLoading = true
  @State private var hasCompletedInitialLoad = false
  @State private var focusCategoryIDs: Set<UUID> = []
  @State private var isEditingFocusCategories = false
  @State private var distractionCategoryIDs: Set<UUID> = []
  @State private var isEditingDistractionCategories = false
  @State private var dayGoalPlan: DayGoalPlan?
  @State private var hasExplicitDayGoalPlan = false
  @State private var explicitYesterdayGoalPlan: DayGoalPlan?
  @State private var yesterdayGoalReview: DayGoalReviewSnapshot?
  @State private var goalSetupReferenceStats = DayGoalSetupReferenceStats.empty
  @State private var handledGoalPromptDay: String?

  // MARK: - Pre-computed Stats (to avoid expensive parsing during body evaluation)
  // These are computed on background thread when data loads, avoiding main thread hangs
  @State private var cardsWithDurations: [DaySummaryStats.CardWithDuration] = []
  @State private var cachedCategoryDurations: [CategoryTimeData] = []
  @State private var cachedTotalFocusTime: TimeInterval = 0
  @State private var cachedTotalCapturedTime: TimeInterval = 0
  @State private var cachedFocusBlocks: [FocusBlock] = []
  @State private var cachedTotalDistractedTime: TimeInterval = 0
  @State private var reviewSummary = TimelineReviewSummarySnapshot.placeholder
  @State private var dataLoadTask: Task<Void, Never>?
  @State private var reviewLoadTask: Task<Void, Never>?
  @State private var categoryStatsTask: Task<Void, Never>?
  @State private var dataLoadToken: DaySummaryLoadToken?
  @State private var reviewLoadToken: DaySummaryLoadToken?
  @State private var categoryStatsToken: DaySummaryLoadToken?

  private let showDistractionPattern = false
  private enum Design {
    static let contentWidth: CGFloat = 322
    static let horizontalPadding: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 48
    static let sectionSpacing: CGFloat = 26
    static let targetsHeight: CGFloat = 213
    static let headerSpacing: CGFloat = 6
    static let donutSectionSpacing: CGFloat = 20

    static let dividerColor = Color(hex: "E7E5E3")

    static let titleColor = Color(hex: "333333")
    static let subtitleColor = Color(hex: "707070")

  }

  // MARK: - Computed Stats

  private var timelineDayInfo: (dayString: String, startOfDay: Date, endOfDay: Date) {
    let timelineDate = timelineDisplayDate(from: selectedDate)
    let info = timelineDate.getDayInfoFor4AMBoundary()
    return (info.dayString, info.startOfDay, info.endOfDay)
  }

  private var previousTimelineDayInfo: (dayString: String, startOfDay: Date, endOfDay: Date) {
    let previousDate =
      Calendar.current.date(byAdding: .day, value: -1, to: selectedDate)
      ?? selectedDate
    let timelineDate = timelineDisplayDate(from: previousDate)
    let info = timelineDate.getDayInfoFor4AMBoundary()
    return (info.dayString, info.startOfDay, info.endOfDay)
  }

  private var effectiveGoalPlan: DayGoalPlan {
    if let dayGoalPlan {
      return dayGoalPlan.carriedForward(to: timelineDayInfo.dayString, categories: categories)
    }
    return DayGoalPlan.defaultPlan(day: timelineDayInfo.dayString, categories: categories)
  }

  // MARK: - Cached Stats Accessors
  // These now return pre-computed values instead of computing during body evaluation

  private var categoryDurations: [CategoryTimeData] {
    cachedCategoryDurations
  }

  private var totalFocusTime: TimeInterval {
    cachedTotalFocusTime
  }

  private var totalCapturedTime: TimeInterval {
    cachedTotalCapturedTime
  }

  private var focusBlocks: [FocusBlock] {
    cachedFocusBlocks
  }

  private var totalDistractedTime: TimeInterval {
    cachedTotalDistractedTime
  }

  private var distractionPattern: (title: String, description: String)? {
    let distractions = timelineCards.flatMap { $0.distractions ?? [] }
    guard !distractions.isEmpty else { return nil }

    let grouped = Dictionary(grouping: distractions) { distraction in
      distraction.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let mostFrequent = grouped.max { $0.value.count < $1.value.count }
    guard let title = mostFrequent?.key, let group = mostFrequent?.value else { return nil }

    let description = group.max(by: { ($0.summary.count) < ($1.summary.count) })?.summary ?? ""
    return (title: title, description: description)
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      todayTargetsSection

      ScrollView {
        VStack(alignment: .leading, spacing: Design.sectionSpacing) {
          daySoFarSection

          sectionDivider

          reviewSection

          sectionDivider

          focusSection

          sectionDivider

          distractionsSection
        }
        .frame(width: Design.contentWidth, alignment: .leading)
        .padding(.top, Design.topPadding)
        .padding(.bottom, Design.bottomPadding)
        .padding(.horizontal, Design.horizontalPadding)
        .onScrollStart(panelName: "day_summary") { direction in
          AnalyticsService.shared.capture(
            "right_panel_scrolled",
            [
              "panel": "day_summary",
              "direction": direction,
            ])
        }
      }
      .scrollIndicators(.never)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      loadData()
    }
    .onDisappear {
      cancelLoadTasks()
    }
    .onChange(of: selectedDate) {
      loadData()
    }
    .onChange(of: goalPromptDay) {
      handleGoalPromptIfReady()
    }
    .onChange(of: reviewRefreshToken) {
      loadReviewSummary()
    }
    .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { notification in
      if let dayString = notification.userInfo?["dayString"] as? String {
        guard dayString == timelineDayInfo.dayString else { return }
      }
      loadData()
    }
    .onChange(of: categories) {
      recomputeCachedStatsForCategoryChange()
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if isEditingFocusCategories {
        isEditingFocusCategories = false
      }
      if isEditingDistractionCategories {
        isEditingDistractionCategories = false
      }
    }
  }

  // MARK: - Data Loading

  private func loadData() {
    dataLoadTask?.cancel()
    reviewLoadTask?.cancel()
    categoryStatsTask?.cancel()
    reviewLoadTask = nil
    categoryStatsTask = nil
    reviewLoadToken = nil
    categoryStatsToken = nil

    isLoading = true

    let dayInfo = timelineDayInfo
    let dayString = dayInfo.dayString
    let loadToken = DaySummaryLoadToken(dayString: dayString)
    dataLoadToken = loadToken
    let previousDayInfo = previousTimelineDayInfo
    let storageManager = storageManager
    let currentTimelineDate = timelineDisplayDate(from: selectedDate)

    // Capture current state for background computation
    let currentCategories = categories

    dataLoadTask = Task.detached(priority: .userInitiated) {
      // Use timeline display date to handle 4 AM boundary
      let cards = storageManager.fetchTimelineCards(forDay: dayString)
      let explicitPlanForDay = storageManager.fetchDayGoalPlan(forDay: dayString) != nil
      let plan = DaySummaryStats.carriedForwardGoalPlan(
        day: dayString,
        storageManager: storageManager,
        categories: currentCategories
      )
      let summary = DaySummaryStats.makeReviewSummary(
        segments: storageManager.fetchReviewRatingSegments(
          overlapping: Int(dayInfo.startOfDay.timeIntervalSince1970),
          endTs: Int(dayInfo.endOfDay.timeIntervalSince1970)
        ),
        dayStartTs: Int(dayInfo.startOfDay.timeIntervalSince1970),
        dayEndTs: Int(dayInfo.endOfDay.timeIntervalSince1970)
      )

      // Pre-compute all card durations (expensive parsing done once here, off main thread)
      let precomputed = DaySummaryStats.precomputeCardDurations(cards)

      // Pre-compute all stats using the parsed durations
      let catDurations = DaySummaryStats.computeCategoryDurations(
        from: precomputed, categories: currentCategories)
      let totalCaptured = DaySummaryStats.computeTotalCapturedTime(
        from: precomputed, categories: currentCategories)
      let totalFocus = DaySummaryStats.computeTotalFocusTime(
        from: precomputed, snapshots: plan.focusCategories, categories: currentCategories)
      let blocks = DaySummaryStats.computeFocusBlocks(
        from: precomputed, snapshots: plan.focusCategories, baseDate: dayInfo.startOfDay,
        categories: currentCategories)
      let totalDistracted = DaySummaryStats.computeTotalDistractedTime(
        from: precomputed, snapshots: plan.distractionCategories, categories: currentCategories)
      let yesterdayReview = DaySummaryStats.makeGoalReviewSnapshot(
        dayInfo: previousDayInfo,
        storageManager: storageManager,
        categories: currentCategories
      )
      let explicitYesterdayPlan = storageManager.fetchDayGoalPlan(forDay: previousDayInfo.dayString)
      let setupReferenceStats = DaySummaryStats.makeGoalSetupReferenceStats(
        currentTimelineDate: currentTimelineDate,
        storageManager: storageManager,
        categories: currentCategories
      )

      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard loadToken.matches(latest: self.dataLoadToken) else { return }

        // A targeted refresh may have started while this full load was running. The full load
        // owns the complete snapshot, so it also owns the overlapping review and stats fields.
        self.reviewLoadTask?.cancel()
        self.categoryStatsTask?.cancel()
        self.reviewLoadTask = nil
        self.categoryStatsTask = nil
        self.reviewLoadToken = nil
        self.categoryStatsToken = nil

        self.timelineCards = cards
        self.applyGoalPlan(plan)
        self.hasExplicitDayGoalPlan = explicitPlanForDay
        self.cardsWithDurations = precomputed
        self.cachedCategoryDurations = catDurations
        self.cachedTotalCapturedTime = totalCaptured
        self.cachedTotalFocusTime = totalFocus
        self.cachedFocusBlocks = blocks
        self.cachedTotalDistractedTime = totalDistracted
        self.isLoading = false
        self.hasCompletedInitialLoad = true
        self.reviewSummary = summary
        self.explicitYesterdayGoalPlan = explicitYesterdayPlan
        self.yesterdayGoalReview = yesterdayReview
        self.goalSetupReferenceStats = setupReferenceStats
        self.handleGoalPromptIfReady()
        self.dataLoadTask = nil
      }
    }
  }

  private func loadReviewSummary() {
    reviewLoadTask?.cancel()

    let dayInfo = timelineDayInfo
    let loadToken = DaySummaryLoadToken(dayString: dayInfo.dayString)
    reviewLoadToken = loadToken
    let storageManager = storageManager
    reviewLoadTask = Task.detached(priority: .userInitiated) {
      let summary = DaySummaryStats.makeReviewSummary(
        segments: storageManager.fetchReviewRatingSegments(
          overlapping: Int(dayInfo.startOfDay.timeIntervalSince1970),
          endTs: Int(dayInfo.endOfDay.timeIntervalSince1970)
        ),
        dayStartTs: Int(dayInfo.startOfDay.timeIntervalSince1970),
        dayEndTs: Int(dayInfo.endOfDay.timeIntervalSince1970)
      )

      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard loadToken.matches(latest: self.reviewLoadToken) else { return }

        self.reviewSummary = summary
        self.reviewLoadTask = nil
      }
    }
  }

  private func cancelLoadTasks() {
    dataLoadTask?.cancel()
    reviewLoadTask?.cancel()
    categoryStatsTask?.cancel()
    dataLoadTask = nil
    reviewLoadTask = nil
    categoryStatsTask = nil
    dataLoadToken = nil
    reviewLoadToken = nil
    categoryStatsToken = nil
  }

  // MARK: - Header

  private var todayTargetsSection: some View {
    DayGoalHeader(
      focusTargetDuration: effectiveGoalPlan.focusTargetDuration,
      focusDuration: totalFocusTime,
      focusCategories: targetFocusCategories,
      distractionLimitDuration: effectiveGoalPlan.distractionLimitDuration,
      distractedDuration: totalDistractedTime,
      showsDisabledState: effectiveGoalPlan.isSkipped,
      recordingControlMode: recordingControlMode,
      onSetGoals: {
        presentGoalFlow(source: "right_panel_set_goals")
      }
    )
    .frame(height: Design.targetsHeight)
  }

  private var canShowYesterdayGoalReview: Bool {
    guard explicitYesterdayGoalPlan?.isSkipped == false else { return false }
    return UserDefaults.standard.string(forKey: dayGoalReviewShownTimelineDayKey)
      != timelineDayInfo.dayString
  }

  private func presentGoalFlow(
    initialScreen: DayGoalFlowInitialScreen? = nil,
    source: String
  ) {
    guard let onShowGoalFlow else { return }

    let resolvedInitialScreen = initialScreen ?? (canShowYesterdayGoalReview ? .review : .setup)
    let review =
      yesterdayGoalReview
      ?? DayGoalReviewSnapshot.empty(
        day: previousTimelineDayInfo.dayString,
        plan: DayGoalPlan.defaultPlan(
          day: previousTimelineDayInfo.dayString,
          categories: categories
        )
      )
    let plan = effectiveGoalPlan
    let hadExistingPlan = hasExplicitDayGoalPlan

    onShowGoalFlow(
      DayGoalFlowPresentation(
        review: review,
        plan: plan,
        categories: selectableCategories,
        setupReferenceStats: goalSetupReferenceStats,
        initialScreen: resolvedInitialScreen,
        onSkip: skipGoalPlan,
        onConfirm: confirmGoalPlan,
        onSetupStarted: {
          trackGoalSetupStarted(source: "goal_flow", entryPoint: "review_continue")
        },
        onCategoryToggled: { kind, action, draft in
          trackGoalCategoryToggled(
            kind: kind,
            action: action,
            source: "goal_flow",
            plan: normalizedPlan(draft),
            hadExistingPlan: hadExistingPlan
          )
        }
      )
    )
    trackGoalFlowOpened(
      initialScreen: resolvedInitialScreen,
      source: source,
      plan: plan,
      reviewDay: review.day,
      hadExistingPlan: hadExistingPlan
    )
    if resolvedInitialScreen == .review {
      trackGoalReviewShown(source: source, reviewDay: review.day, hadExistingPlan: hadExistingPlan)
    } else {
      trackGoalSetupStarted(source: source, entryPoint: "initial_screen")
    }
    markYesterdayGoalReviewShownIfNeeded(initialScreen: resolvedInitialScreen)
  }

  private func markYesterdayGoalReviewShownIfNeeded(initialScreen: DayGoalFlowInitialScreen) {
    guard initialScreen == .review else { return }
    UserDefaults.standard.set(timelineDayInfo.dayString, forKey: dayGoalReviewShownTimelineDayKey)
  }

  private func handleGoalPromptIfReady() {
    guard hasCompletedInitialLoad else { return }
    guard let goalPromptDay else { return }
    guard goalPromptDay == timelineDayInfo.dayString else { return }
    guard handledGoalPromptDay != goalPromptDay else { return }
    guard onShowGoalFlow != nil else { return }

    handledGoalPromptDay = goalPromptDay
    let initialScreen: DayGoalFlowInitialScreen =
      canShowYesterdayGoalReview ? .review : .setup
    presentGoalFlow(initialScreen: initialScreen, source: "daily_prompt")
    onGoalPromptHandled?(goalPromptDay)
  }

  private var daySoFarSection: some View {
    daySoFarContent
  }

  private var daySoFarContent: some View {
    VStack(alignment: .leading, spacing: Design.donutSectionSpacing) {
      VStack(alignment: .leading, spacing: Design.headerSpacing) {
        Text("Your day so far")
          .font(.custom("InstrumentSerif-Regular", size: 24))
          .foregroundColor(Design.titleColor)
      }

      if isLoading && hasCompletedInitialLoad == false {
        ProgressView()
          .frame(width: 205, height: 205)
          .frame(maxWidth: .infinity)
      } else if !categoryDurations.isEmpty {
        CategoryDonutChart(data: categoryDurations, size: 205)
          .frame(maxWidth: .infinity)
      } else {
        emptyChartPlaceholder
          .frame(maxWidth: .infinity)
      }
    }
  }

  // MARK: - Empty State

  private var emptyChartPlaceholder: some View {
    VStack(spacing: 12) {
      Circle()
        .stroke(Color.gray.opacity(0.2), lineWidth: 20)
        .frame(width: 140, height: 140)

      Text("No activity data yet")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color.gray.opacity(0.6))
    }
    .padding(.vertical, 20)
  }

  private var reviewSection: some View {
    TimelineReviewSummaryCard(
      summary: reviewSummary,
      cardsToReviewCount: cardsToReviewCount,
      onReviewTap: onReviewTap
    )
  }

  // MARK: - Focus Section

  private var focusSection: some View {
    DayFocusSummarySection(
      totalFocusText: formatDurationTitleCase(totalFocusTime),
      focusBlocks: focusBlocks,
      isSelectionEmpty: isFocusSelectionEmpty,
      categories: selectableCategories,
      selectedCategoryIDs: focusCategoryIDs,
      isEditingCategories: isEditingFocusCategories,
      onEditCategories: {
        isEditingFocusCategories = true
        isEditingDistractionCategories = false
      },
      onToggleCategory: toggleFocusCategory,
      onDoneEditing: {
        isEditingFocusCategories = false
      }
    )
  }

  private var distractionsSection: some View {
    DayDistractionSummarySection(
      totalCapturedText: formatDurationLowercase(totalCapturedTime),
      totalDistractedText: formatDurationLowercase(totalDistractedTime),
      distractedRatio: distractedRatio,
      patternTitle: showDistractionPattern ? (distractionPattern?.title ?? "") : "",
      patternDescription: showDistractionPattern ? (distractionPattern?.description ?? "") : "",
      isSelectionEmpty: isDistractionSelectionEmpty,
      categories: selectableCategories,
      selectedCategoryIDs: distractionCategoryIDs,
      isEditingCategories: isEditingDistractionCategories,
      onEditCategories: {
        isEditingDistractionCategories = true
        isEditingFocusCategories = false
      },
      onToggleCategory: toggleDistractionCategory,
      onDoneEditing: {
        isEditingDistractionCategories = false
      }
    )
  }

  private var sectionDivider: some View {
    Rectangle()
      .fill(Design.dividerColor)
      .frame(height: 1)
      .frame(maxWidth: .infinity)
  }

  private var distractedRatio: Double {
    let captured = totalCapturedTime
    guard captured > 0 else { return 0 }
    let ratio = totalDistractedTime / captured
    return min(max(ratio, 0), 1)
  }

  private var targetFocusCategories: [TargetCategoryProgress] {
    let durationByID = categoryDurations.reduce(into: [String: TimeInterval]()) { result, item in
      result[item.id] = item.duration
    }
    let durationByName = categoryDurations.reduce(into: [String: TimeInterval]()) { result, item in
      result[normalizedCategoryName(item.name)] = item.duration
    }

    return effectiveGoalPlan.focusCategories
      .map(resolveSnapshot)
      .sorted { $0.sortOrder < $1.sortOrder }
      .prefix(4)
      .map { snapshot in
        TargetCategoryProgress(
          id: snapshot.categoryID,
          name: snapshot.name,
          colorHex: snapshot.colorHex,
          duration: durationByID[snapshot.categoryID]
            ?? durationByName[normalizedCategoryName(snapshot.name), default: 0]
        )
      }
  }

  // MARK: - Helpers

  nonisolated private func normalizedCategoryName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var selectableCategories: [TimelineCategory] {
    categories
      .filter {
        $0.isSystem == false && $0.isIdle == false && normalizedCategoryName($0.name) != "system"
      }
      .sorted { $0.order < $1.order }
  }

  private var isFocusSelectionEmpty: Bool {
    focusCategoryIDs.isEmpty
  }

  private var isDistractionSelectionEmpty: Bool {
    distractionCategoryIDs.isEmpty
  }

  private func toggleFocusCategory(_ category: TimelineCategory) {
    var plan = effectiveGoalPlan
    let categoryID = category.id.uuidString
    let action: String
    if plan.focusCategories.contains(where: { $0.categoryID == categoryID }) {
      plan.focusCategories.removeAll { $0.categoryID == categoryID }
      action = "removed"
    } else {
      plan.focusCategories.append(
        DayGoalCategorySnapshot(category: category, sortOrder: plan.focusCategories.count)
      )
      action = "added"
    }
    let result = saveGoalPlan(
      plan,
      updateSource: "right_panel",
      updateKind: "focus_category_\(action)"
    )
    trackGoalCategoryToggled(
      kind: .focus,
      action: action,
      source: "right_panel",
      plan: result.plan,
      hadExistingPlan: result.hadExistingPlan
    )
  }

  private func toggleDistractionCategory(_ category: TimelineCategory) {
    var plan = effectiveGoalPlan
    let categoryID = category.id.uuidString
    let action: String
    if plan.distractionCategories.contains(where: { $0.categoryID == categoryID }) {
      plan.distractionCategories.removeAll { $0.categoryID == categoryID }
      action = "removed"
    } else {
      plan.distractionCategories.append(
        DayGoalCategorySnapshot(category: category, sortOrder: plan.distractionCategories.count)
      )
      action = "added"
    }
    let result = saveGoalPlan(
      plan,
      updateSource: "right_panel",
      updateKind: "distraction_category_\(action)"
    )
    trackGoalCategoryToggled(
      kind: .distraction,
      action: action,
      source: "right_panel",
      plan: result.plan,
      hadExistingPlan: result.hadExistingPlan
    )
  }

  private func applyGoalPlan(_ plan: DayGoalPlan) {
    let resolved = plan.carriedForward(to: timelineDayInfo.dayString, categories: categories)
    dayGoalPlan = resolved
    focusCategoryIDs = Set(resolved.focusCategories.compactMap { UUID(uuidString: $0.categoryID) })
    distractionCategoryIDs = Set(
      resolved.distractionCategories.compactMap { UUID(uuidString: $0.categoryID) }
    )
  }

  private func confirmGoalPlan(_ plan: DayGoalPlan) {
    let result = saveGoalPlan(plan, updateSource: "goal_flow", updateKind: "confirmed")
    trackGoalPlanConfirmed(
      result.plan,
      source: "goal_flow",
      hadExistingPlan: result.hadExistingPlan
    )
  }

  @discardableResult
  private func saveGoalPlan(
    _ plan: DayGoalPlan,
    updateSource: String,
    updateKind: String
  ) -> (plan: DayGoalPlan, hadExistingPlan: Bool) {
    let normalized = normalizedPlan(plan)
    let hadExistingPlan = hasExplicitDayGoalPlan
    applyGoalPlan(normalized)
    hasExplicitDayGoalPlan = true
    recomputeCachedStatsForCategoryChange()
    trackGoalPlanUpdated(
      normalized,
      source: updateSource,
      updateKind: updateKind,
      hadExistingPlan: hadExistingPlan
    )

    let storageManager = storageManager
    Task.detached(priority: .utility) {
      storageManager.saveDayGoalPlan(normalized)
    }

    return (normalized, hadExistingPlan)
  }

  private func skipGoalPlan() {
    var skipped = effectiveGoalPlan
    let now = Int(Date().timeIntervalSince1970)
    if skipped.createdAt <= 0 {
      skipped.createdAt = now
    }
    skipped.updatedAt = now
    skipped.isSkipped = true
    let result = saveGoalPlan(skipped, updateSource: "goal_flow", updateKind: "skipped")
    trackGoalPlanSkipped(
      result.plan,
      source: "goal_flow",
      hadExistingPlan: result.hadExistingPlan
    )
  }

  private func normalizedPlan(_ plan: DayGoalPlan) -> DayGoalPlan {
    var copy = plan.carriedForward(to: timelineDayInfo.dayString, categories: selectableCategories)
    copy.focusCategories = copy.focusCategories.enumerated().map { index, snapshot in
      let resolved = resolveSnapshot(snapshot)
      return DayGoalCategorySnapshot(
        categoryID: resolved.categoryID,
        name: resolved.name,
        colorHex: resolved.colorHex,
        sortOrder: index
      )
    }
    copy.distractionCategories = copy.distractionCategories.enumerated().map { index, snapshot in
      let resolved = resolveSnapshot(snapshot)
      return DayGoalCategorySnapshot(
        categoryID: resolved.categoryID,
        name: resolved.name,
        colorHex: resolved.colorHex,
        sortOrder: index
      )
    }
    return copy
  }

  private func trackGoalFlowOpened(
    initialScreen: DayGoalFlowInitialScreen,
    source: String,
    plan: DayGoalPlan,
    reviewDay: String,
    hadExistingPlan: Bool
  ) {
    var payload = goalAnalyticsPayload(
      for: plan,
      source: source,
      hadExistingPlan: hadExistingPlan
    )
    payload["initial_screen"] = initialScreen.rawValue
    payload["review_day"] = reviewDay
    AnalyticsService.shared.capture("day_goal_flow_opened", payload)
  }

  private func trackGoalReviewShown(
    source: String,
    reviewDay: String,
    hadExistingPlan: Bool
  ) {
    var payload = goalAnalyticsPayload(
      for: effectiveGoalPlan,
      source: source,
      hadExistingPlan: hadExistingPlan
    )
    payload["review_day"] = reviewDay
    AnalyticsService.shared.capture("day_goal_review_shown", payload)
  }

  private func trackGoalSetupStarted(source: String, entryPoint: String) {
    var payload = goalAnalyticsPayload(
      for: effectiveGoalPlan,
      source: source,
      hadExistingPlan: hasExplicitDayGoalPlan
    )
    payload["entry_point"] = entryPoint
    AnalyticsService.shared.capture("day_goal_setup_started", payload)
  }

  private func trackGoalPlanConfirmed(
    _ plan: DayGoalPlan,
    source: String,
    hadExistingPlan: Bool
  ) {
    AnalyticsService.shared.capture(
      "day_goal_plan_confirmed",
      goalAnalyticsPayload(for: plan, source: source, hadExistingPlan: hadExistingPlan)
    )
    AnalyticsService.shared.setPersonProperties([
      "has_used_day_goals": true,
      "has_confirmed_day_goal": true,
      "last_day_goal_action": "confirmed",
      "last_day_goal_target_day": plan.day,
    ])
  }

  private func trackGoalPlanSkipped(
    _ plan: DayGoalPlan,
    source: String,
    hadExistingPlan: Bool
  ) {
    AnalyticsService.shared.capture(
      "day_goal_plan_skipped",
      goalAnalyticsPayload(for: plan, source: source, hadExistingPlan: hadExistingPlan)
    )
    AnalyticsService.shared.setPersonProperties([
      "has_used_day_goals": true,
      "last_day_goal_action": "skipped",
      "last_day_goal_target_day": plan.day,
    ])
  }

  private func trackGoalPlanUpdated(
    _ plan: DayGoalPlan,
    source: String,
    updateKind: String,
    hadExistingPlan: Bool
  ) {
    var payload = goalAnalyticsPayload(
      for: plan,
      source: source,
      hadExistingPlan: hadExistingPlan
    )
    payload["update_kind"] = updateKind
    AnalyticsService.shared.capture("day_goal_plan_updated", payload)
  }

  private func trackGoalCategoryToggled(
    kind: DayGoalCategoryKind,
    action: String,
    source: String,
    plan: DayGoalPlan,
    hadExistingPlan: Bool
  ) {
    var payload = goalAnalyticsPayload(
      for: plan,
      source: source,
      hadExistingPlan: hadExistingPlan
    )
    payload["category_kind"] = kind.rawValue
    payload["action"] = action
    AnalyticsService.shared.capture("day_goal_category_toggled", payload)
  }

  private func goalAnalyticsPayload(
    for plan: DayGoalPlan,
    source: String,
    hadExistingPlan: Bool
  ) -> [String: Any] {
    [
      "target_day": plan.day,
      "source": source,
      "focus_target_minutes": plan.focusTargetMinutes,
      "distraction_limit_minutes": plan.distractionLimitMinutes,
      "focus_category_count": plan.focusCategories.count,
      "distraction_category_count": plan.distractionCategories.count,
      "is_skipped": plan.isSkipped,
      "had_existing_plan": hadExistingPlan,
    ]
  }

  private func resolveSnapshot(_ snapshot: DayGoalCategorySnapshot) -> DayGoalCategorySnapshot {
    let current =
      selectableCategories.first(where: { $0.id.uuidString == snapshot.categoryID })
      ?? selectableCategories.first {
        normalizedCategoryName($0.name) == normalizedCategoryName(snapshot.name)
      }
    guard let current else {
      return snapshot
    }
    return DayGoalCategorySnapshot(
      categoryID: current.id.uuidString,
      name: current.name,
      colorHex: current.colorHex,
      sortOrder: snapshot.sortOrder
    )
  }

  private func formatDurationTitleCase(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int(seconds / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 && minutes > 0 {
      return "\(hours) Hours \(minutes) minutes"
    } else if hours > 0 {
      return "\(hours) Hours"
    } else if minutes > 0 {
      return "\(minutes) minutes"
    } else {
      return "0 minutes"
    }
  }

  private func formatDurationLowercase(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int(seconds / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 && minutes > 0 {
      return "\(hours) hours \(minutes) minutes"
    } else if hours > 0 {
      return "\(hours) hours"
    } else if minutes > 0 {
      return "\(minutes) minutes"
    } else {
      return "0 minutes"
    }
  }

  /// Recomputes cached stats when categories change (rename/color/system/focus/distraction flags)
  private func recomputeCachedStatsForCategoryChange() {
    categoryStatsTask?.cancel()

    let precomputed =
      cardsWithDurations.isEmpty
      ? DaySummaryStats.precomputeCardDurations(timelineCards) : cardsWithDurations
    let currentCategories = categories
    let plan = effectiveGoalPlan
    let dayInfo = timelineDayInfo
    let baseDate = dayInfo.startOfDay
    let loadToken = DaySummaryLoadToken(dayString: dayInfo.dayString)
    categoryStatsToken = loadToken

    categoryStatsTask = Task.detached(priority: .userInitiated) {
      let catDurations = DaySummaryStats.computeCategoryDurations(
        from: precomputed, categories: currentCategories)
      let totalCaptured = DaySummaryStats.computeTotalCapturedTime(
        from: precomputed, categories: currentCategories)
      let totalFocus = DaySummaryStats.computeTotalFocusTime(
        from: precomputed, snapshots: plan.focusCategories, categories: currentCategories)
      let blocks = DaySummaryStats.computeFocusBlocks(
        from: precomputed, snapshots: plan.focusCategories, baseDate: baseDate,
        categories: currentCategories)
      let totalDistracted = DaySummaryStats.computeTotalDistractedTime(
        from: precomputed, snapshots: plan.distractionCategories, categories: currentCategories)

      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard loadToken.matches(latest: self.categoryStatsToken) else { return }

        self.cachedCategoryDurations = catDurations
        self.cachedTotalCapturedTime = totalCaptured
        self.cachedTotalFocusTime = totalFocus
        self.cachedFocusBlocks = blocks
        self.cachedTotalDistractedTime = totalDistracted
        self.categoryStatsTask = nil
      }
    }
  }
}

#Preview("Day Summary") {
  let sampleCategories: [TimelineCategory] = [
    TimelineCategory(name: "Research", colorHex: "#8BAAFF", order: 0),
    TimelineCategory(name: "Coding", colorHex: "#CF8FFF", order: 1),
    TimelineCategory(name: "Code review", colorHex: "#90DDF0", order: 2),
    TimelineCategory(name: "Debugging", colorHex: "#6E66D4", order: 3),
    TimelineCategory(name: "Distraction", colorHex: "#FF5950", order: 4),
    TimelineCategory(name: "Idle", colorHex: "#A0AEC0", order: 5, isSystem: true, isIdle: true),
  ]

  DaySummaryView(
    selectedDate: Date(),
    categories: sampleCategories,
    storageManager: StorageManager.shared,
    cardsToReviewCount: 3,
    reviewRefreshToken: 0,
    recordingControlMode: .active,
    onReviewTap: {}
  )
  .frame(width: 358, height: 700)
  .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
