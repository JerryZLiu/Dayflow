//
//  DaySummaryView.swift
//  Dayflow
//
//  "Your day so far" dashboard showing category breakdown and focus stats
//

import SwiftUI

struct DaySummaryView: View {
    let selectedDate: Date
    let categories: [TimelineCategory]
    let storageManager: StorageManaging
    let cardsToReviewCount: Int
    let reviewRefreshToken: Int
    var onReviewTap: (() -> Void)? = nil

    @State private var timelineCards: [TimelineCard] = []
    @State private var isLoading = true
    @State private var hasCompletedInitialLoad = false
    @State private var focusCategoryIDs: Set<UUID> = []
    @State private var isEditingFocusCategories = false
    @State private var distractionCategoryIDs: Set<UUID> = []
    @State private var isEditingDistractionCategories = false
    @State private var hasEarlyAccess = UserDefaults.standard.bool(forKey: "daySummaryEarlyAccessGranted")

    // MARK: - Pre-computed Stats (to avoid expensive parsing during body evaluation)
    // These are computed on background thread when data loads, avoiding main thread hangs
    @State private var cardsWithDurations: [CardWithDuration] = []
    @State private var cachedCategoryDurations: [CategoryTimeData] = []
    @State private var cachedTotalFocusTime: TimeInterval = 0
    @State private var cachedTotalCapturedTime: TimeInterval = 0
    @State private var cachedFocusBlocks: [FocusBlock] = []
    @State private var cachedTotalDistractedTime: TimeInterval = 0
    
    // MARK: - Animation State
    @State private var gatePhase: GatePhase = UserDefaults.standard.bool(forKey: "daySummaryEarlyAccessGranted") ? .hidden : .locked
    @State private var gateOpacity: Double = UserDefaults.standard.bool(forKey: "daySummaryEarlyAccessGranted") ? 0 : 1
    @State private var gateScale: CGFloat = 1
    @State private var contentBlur: CGFloat = UserDefaults.standard.bool(forKey: "daySummaryEarlyAccessGranted") ? 0 : 20
    @State private var contentScale: CGFloat = UserDefaults.standard.bool(forKey: "daySummaryEarlyAccessGranted") ? 1.0 : 0.95
    @State private var maskSize: CGFloat = 0
    @State private var shockwaveScale: CGFloat = 0.1
    @State private var shockwaveOpacity: Double = 0
    @State private var successIconScale: CGFloat = 0.001
    @State private var checkmarkStroke: CGFloat = 0
    @State private var particleTrigger: Int = 0
    @State private var reviewSummary = TimelineReviewSummarySnapshot.placeholder

    private let showDistractionPattern = false
    private let focusSelectionStorageKey = "focusCategorySelection"
    private let distractionSelectionStorageKey = "distractionCategorySelection"
    private let earlyAccessStorageKey = "daySummaryEarlyAccessGranted"

    private enum GatePhase {
        case locked
        case requesting
        case granted
        case hidden
    }

    private enum Design {
        static let contentWidth: CGFloat = 322
        static let horizontalPadding: CGFloat = 18
        static let topPadding: CGFloat = 24
        static let bottomPadding: CGFloat = 48
        static let sectionSpacing: CGFloat = 26

        static let headerSpacing: CGFloat = 6
        static let donutSectionSpacing: CGFloat = 20
        static let focusSectionSpacing: CGFloat = 12
        static let focusCardsSpacing: CGFloat = 8
        static let distractionsSpacing: CGFloat = 16

        static let dividerColor = Color(hex: "E7E5E3")

        static let titleColor = Color(hex: "333333")
        static let subtitleColor = Color(hex: "707070")

        static let focusTitleColor = Color(hex: "333333")
        static let focusValueColor = Color(hex: "F3854B")
        static let focusCardBackground = Color(hex: "F7F7F7")
        static let focusCardBorder = Color.white
        static let focusIconColor = Color(hex: "CFC7BE")
        static let focusEditButtonSize: CGFloat = 20
        static let focusEditorWidth: CGFloat = contentWidth + (horizontalPadding * 2)
        static let focusEditorOffsetY: CGFloat = 28

        static let focusGapMinutes: Int = 5
        static let timelineDayStartMinutes: Int = 4 * 60
        static let minutesPerDay: Int = 24 * 60

        static let gateCornerRadius: CGFloat = 16
        static let gateBlurRadius: CGFloat = 3
        static let gateTitleColor = Color(hex: "3A2F28")
        static let gateSubtitleColor = Color(hex: "8A7B6C")
        static let gateOverlineColor = Color(hex: "C9875E")
        static let gateBorderColor = Color(hex: "F0D9C5")
        static let gateAccent = Color(hex: "F3854B")
        static let gateButtonText = Color(hex: "5A3C2C")
        static let gateButtonShadow = Color.black.opacity(0.08)
        static let gateGlow = Color(hex: "FAD2B3")
        static let gateBackgroundStart = Color(hex: "FFF7EE")
        static let gateBackgroundEnd = Color(hex: "FFF1E3")
    }

    /// Pre-computed card data with parsed timestamps to avoid expensive parsing during body evaluation
    private struct CardWithDuration {
        let card: TimelineCard
        let duration: TimeInterval
        let startMinutes: Int  // For focus blocks calculation
        let endMinutes: Int    // For focus blocks calculation
    }

    // MARK: - Computed Stats

    private var timelineDayInfo: (dayString: String, startOfDay: Date, endOfDay: Date) {
        let timelineDate = timelineDisplayDate(from: selectedDate)
        let info = timelineDate.getDayInfoFor4AMBoundary()
        return (info.dayString, info.startOfDay, info.endOfDay)
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
        ZStack {
            ZStack {
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
                        AnalyticsService.shared.capture("right_panel_scrolled", [
                            "panel": "day_summary",
                            "direction": direction
                        ])
                    }
                }
                .scrollIndicators(.never)
                .scaleEffect(contentScale)
                .blur(radius: contentBlur)
            }
            .mask(
                ZStack {
                    if gatePhase == .hidden {
                        Rectangle()
                    } else {
                        Circle().frame(width: maskSize, height: maskSize)
                    }
                }
            )

            if gatePhase != .hidden {
                earlyAccessGateOverlay
                    .scaleEffect(gateScale)
                    .opacity(gateOpacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadFocusSelectionIfNeeded()
            loadDistractionSelectionIfNeeded()
            loadData()
        }
        .onChange(of: selectedDate) {
            loadData()
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
            syncFocusSelectionWithCategories()
            syncDistractionSelectionWithCategories()
            recomputeCachedStatsForCategoryChange()
        }
        .onChange(of: focusCategoryIDs) {
            persistFocusSelection()
            recomputeFocusStats()
        }
        .onChange(of: distractionCategoryIDs) {
            persistDistractionSelection()
            recomputeDistractionStats()
        }
        .onChange(of: hasEarlyAccess) { _, newValue in
            if newValue {
                UserDefaults.standard.set(true, forKey: earlyAccessStorageKey)
            }
        }
        .onChange(of: productivityScore) { _, newScore in
            AppState.shared.productivityScore = newScore
        }
        .onChange(of: productivityScoreHasData) { _, hasData in
            AppState.shared.hasProductivityData = hasData
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
        isLoading = true

        let dayInfo = timelineDayInfo
        let dayString = dayInfo.dayString
        let storageManager = storageManager

        // Capture current state for background computation
        let currentFocusIDs = focusCategoryIDs
        let currentDistractionIDs = distractionCategoryIDs
        let currentCategories = categories

        Task.detached(priority: .userInitiated) {
            // Use timeline display date to handle 4 AM boundary
            let cards = storageManager.fetchTimelineCards(forDay: dayString)
            let summary = Self.makeReviewSummary(
                segments: storageManager.fetchReviewRatingSegments(
                    overlapping: Int(dayInfo.startOfDay.timeIntervalSince1970),
                    endTs: Int(dayInfo.endOfDay.timeIntervalSince1970)
                ),
                dayStartTs: Int(dayInfo.startOfDay.timeIntervalSince1970),
                dayEndTs: Int(dayInfo.endOfDay.timeIntervalSince1970)
            )

            // Pre-compute all card durations (expensive parsing done once here, off main thread)
            let precomputed = self.precomputeCardDurations(cards)

            // Pre-compute all stats using the parsed durations
            let catDurations = self.computeCategoryDurations(from: precomputed, categories: currentCategories)
            let totalCaptured = self.computeTotalCapturedTime(from: precomputed, categories: currentCategories)
            let totalFocus = self.computeTotalFocusTime(from: precomputed, focusIDs: currentFocusIDs, categories: currentCategories)
            let blocks = self.computeFocusBlocks(from: precomputed, focusIDs: currentFocusIDs, baseDate: dayInfo.startOfDay, categories: currentCategories)
            let totalDistracted = self.computeTotalDistractedTime(from: precomputed, distractionIDs: currentDistractionIDs, categories: currentCategories)

            await MainActor.run {
                self.timelineCards = cards
                self.cardsWithDurations = precomputed
                self.cachedCategoryDurations = catDurations
                self.cachedTotalCapturedTime = totalCaptured
                self.cachedTotalFocusTime = totalFocus
                self.cachedFocusBlocks = blocks
                self.cachedTotalDistractedTime = totalDistracted
                self.isLoading = false
                self.hasCompletedInitialLoad = true
                self.reviewSummary = summary
            }
        }
    }

    private func loadReviewSummary() {
        let dayInfo = timelineDayInfo
        let storageManager = storageManager
        Task.detached(priority: .userInitiated) {
            let summary = Self.makeReviewSummary(
                segments: storageManager.fetchReviewRatingSegments(
                    overlapping: Int(dayInfo.startOfDay.timeIntervalSince1970),
                    endTs: Int(dayInfo.endOfDay.timeIntervalSince1970)
                ),
                dayStartTs: Int(dayInfo.startOfDay.timeIntervalSince1970),
                dayEndTs: Int(dayInfo.endOfDay.timeIntervalSince1970)
            )
            await MainActor.run {
                reviewSummary = summary
            }
        }
    }

    // MARK: - Header

    private var daySoFarSection: some View {
        daySoFarContent
    }

    private var daySoFarContent: some View {
        VStack(alignment: .leading, spacing: Design.donutSectionSpacing) {
            VStack(alignment: .leading, spacing: Design.headerSpacing) {
                Text("Your day so far")
                    .font(.custom("InstrumentSerif-Regular", size: 24))
                    .foregroundColor(Design.titleColor)

                Text("This data will update every 15 minutes. Check back throughout the day to gain new understanding on your workflow.")
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Design.subtitleColor)
                    .lineSpacing(2)
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
                .font(.custom("Nunito", size: 12))
                .foregroundColor(Color.gray.opacity(0.6))
        }
        .padding(.vertical, 20)
    }

    // MARK: - Early Access Gate

    private var earlyAccessGateOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Design.gateCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Design.gateBackgroundStart, Design.gateBackgroundEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.gateCornerRadius, style: .continuous)
                        .stroke(Design.gateBorderColor, lineWidth: 1)
                )
                .shadow(color: Design.gateButtonShadow, radius: 12, x: 0, y: 6)

            ShockwaveView(scale: shockwaveScale, opacity: shockwaveOpacity)
            SuccessParticlesView(trigger: particleTrigger)
            ConfettiBurstView(trigger: particleTrigger)

            VStack(spacing: 12) {
                Text("EARLY ACCESS")
                    .font(.custom("Nunito", size: 11).weight(.semibold))
                    .foregroundColor(Design.gateOverlineColor)
                    .tracking(0.6)

                Text("Your day so far")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundColor(Design.gateTitleColor)

                Text("Your day so far is a preview of what's to come in Dashboard. This feature is still in beta and may change rapidly.")
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Design.gateSubtitleColor)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)

                gateActionArea
                    .frame(height: 44) // Fixed height to prevent layout jumps
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
    }

    private var productivityScoreSection: some View {
        ProductivityScoreCard(
            score: productivityScore,
            hasData: productivityScoreHasData,
            isUsingReviewData: reviewSummary.hasData
        )
    }

    private var reviewSection: some View {
        TimelineReviewSummaryCard(
            summary: reviewSummary,
            cardsToReviewCount: cardsToReviewCount,
            onReviewTap: onReviewTap
        )
    }

    @ViewBuilder
    private var gateActionArea: some View {
        ZStack {
            if gatePhase == .locked || gatePhase == .requesting {
                Button(action: requestEarlyAccess) {
                    HStack(spacing: 8) {
                        if gatePhase == .requesting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                        }

                        Text(gatePhase == .requesting ? "Requesting..." : "Request early access")
                            .font(.custom("Nunito", size: 12).weight(.semibold))
                    }
                    .foregroundColor(Design.gateButtonText)
                    .frame(height: 44)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "FFE3CB"), Color(hex: "FFD1AE")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(hex: "F2C7A3"), lineWidth: 1)
                    )
                    .shadow(color: Design.gateButtonShadow, radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(gatePhase == .requesting)
                .buttonStyle(SquishButtonStyle())
                .hoverScaleEffect(
                    enabled: gatePhase != .requesting,
                    scale: 1.02
                )
                .pointingHandCursorOnHover(
                    enabled: gatePhase != .requesting,
                    reassertOnPressEnd: true
                )
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }

            if gatePhase == .granted {
                VStack(spacing: 6) {
                    ZStack {
                        CheckmarkShape()
                            .trim(from: 0, to: checkmarkStroke)
                            .stroke(
                                Design.gateAccent,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 24, height: 18)
                    }
                    .scaleEffect(successIconScale)

                    Text("Access granted!")
                        .font(.custom("Nunito", size: 12).weight(.bold))
                        .foregroundColor(Design.gateTitleColor)
                        .opacity(checkmarkStroke)
                        .offset(y: 2)
                }
            }
        }
    }

    // MARK: - Animation Logic
    
    private func requestEarlyAccess() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { gatePhase = .requesting }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.interpolatingSpring(stiffness: 400, damping: 12)) {
                gatePhase = .granted
                successIconScale = 1.0
                particleTrigger += 1
                hasEarlyAccess = true
            }
            withAnimation(.easeOut(duration: 0.5)) { checkmarkStroke = 1.0 }
            shockwaveOpacity = 1.0
            withAnimation(.easeOut(duration: 0.7)) { shockwaveScale = 6.0; shockwaveOpacity = 0 }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                    maskSize = 2500
                    contentScale = 1.0
                    contentBlur = 0
                }
                withAnimation(.easeIn(duration: 0.3)) { gateOpacity = 0; gateScale = 1.1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    gatePhase = .hidden
                    AnalyticsService.shared.capture("day_summary_unlock_completed", [
                        "source": "button"
                    ])
                }
            }
        }
    }

    // MARK: - Focus Section

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: Design.focusSectionSpacing) {
            HStack(alignment: .center, spacing: 6) {
                Text("Your focus")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundColor(Design.focusTitleColor)

                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(Design.focusIconColor)

                Spacer()

                Button(action: {
                    isEditingFocusCategories = true
                    isEditingDistractionCategories = false
                }) {
                    Image("CategoryEditButton")
                        .resizable()
                        .scaledToFit()
                        .frame(width: Design.focusEditButtonSize, height: Design.focusEditButtonSize)
                }
                .buttonStyle(.plain)
                .hoverScaleEffect(scale: 1.02)
                .pointingHandCursorOnHover(reassertOnPressEnd: true)
            }

            if isFocusSelectionEmpty {
                Text("Edit categories to calculate focus.")
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Design.subtitleColor)
            }

            VStack(spacing: Design.focusCardsSpacing) {
                TotalFocusCard(value: formatDurationTitleCase(totalFocusTime))

                LongestFocusCard(focusBlocks: focusBlocks)

                ProductivityScoreCard(
                    score: productivityScore,
                    hasData: productivityScoreHasData,
                    isUsingReviewData: reviewSummary.hasData
                )
            }
            .opacity(isFocusSelectionEmpty ? 0.45 : 1)
        }
        .overlay(alignment: .topLeading) {
            if isEditingFocusCategories {
                CategorySelectionEditor(
                    categories: selectableCategories,
                    selectedCategoryIDs: focusCategoryIDs,
                    helperText: "Pick the categories that count towards Focus",
                    onToggle: toggleFocusCategory,
                    onDone: { isEditingFocusCategories = false }
                )
                .frame(width: Design.focusEditorWidth, alignment: .leading)
                .offset(y: Design.focusEditorOffsetY)
                .offset(x: -Design.horizontalPadding)
                .onTapGesture { }
            }
        }
    }

    private var distractionsSection: some View {
        VStack(alignment: .leading, spacing: Design.distractionsSpacing) {
            HStack(alignment: .center, spacing: 6) {
                Text("Distractions so far")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundColor(Design.titleColor)

                Spacer()

                Button(action: {
                    isEditingDistractionCategories = true
                    isEditingFocusCategories = false
                }) {
                    Image("CategoryEditButton")
                        .resizable()
                        .scaledToFit()
                        .frame(width: Design.focusEditButtonSize, height: Design.focusEditButtonSize)
                }
                .buttonStyle(.plain)
                .hoverScaleEffect(scale: 1.02)
                .pointingHandCursorOnHover(reassertOnPressEnd: true)
            }

            if isDistractionSelectionEmpty {
                Text("Edit categories to calculate distractions.")
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Design.subtitleColor)
            }

            DistractionSummaryCard(
                totalCaptured: formatDurationLowercase(totalCapturedTime),
                totalDistracted: formatDurationLowercase(totalDistractedTime),
                distractedRatio: distractedRatio,
                patternTitle: showDistractionPattern ? (distractionPattern?.title ?? "") : "",
                patternDescription: showDistractionPattern ? (distractionPattern?.description ?? "") : ""
            )
            .frame(maxWidth: .infinity)
            .opacity(isDistractionSelectionEmpty ? 0.45 : 1)
        }
        .overlay(alignment: .topLeading) {
            if isEditingDistractionCategories {
                CategorySelectionEditor(
                    categories: selectableCategories,
                    selectedCategoryIDs: distractionCategoryIDs,
                    helperText: "Pick the categories that count towards Distractions",
                    onToggle: toggleDistractionCategory,
                    onDone: { isEditingDistractionCategories = false }
                )
                .frame(width: Design.focusEditorWidth, alignment: .leading)
                .offset(y: Design.focusEditorOffsetY)
                .offset(x: -Design.horizontalPadding)
                .onTapGesture { }
            }
        }
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

    private var productivityScore: Int {
        // Prefer manual review data if available
        if reviewSummary.hasData {
            let score = (reviewSummary.productiveRatio * 100) + (reviewSummary.neutralRatio * 50)
            return Int(score.rounded())
        }

        // Fall back to category-based calculation
        let captured = totalCapturedTime
        guard captured > 0 else { return 0 }

        let focusRatio = totalFocusTime / captured
        let distractedRatio = totalDistractedTime / captured
        let neutralRatio = max(0, 1 - focusRatio - distractedRatio)

        let score = (focusRatio * 100) + (neutralRatio * 50)
        return Int(score.rounded())
    }

    private var productivityScoreHasData: Bool {
        reviewSummary.hasData || totalCapturedTime > 0
    }

    // MARK: - Helpers

    private func isFocusCategory(_ category: String) -> Bool {
        if isSystemCategory(category) { return false }
        guard let categoryID = categoryID(for: category) else { return false }
        return focusCategoryIDs.contains(categoryID)
    }

    nonisolated private func normalizedCategoryName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isDistractionCategory(_ name: String) -> Bool {
        if isSystemCategory(name) { return false }
        guard let categoryID = categoryID(for: name) else { return false }
        return distractionCategoryIDs.contains(categoryID)
    }

    private func isSystemCategory(_ name: String) -> Bool {
        let normalized = normalizedCategoryName(name)
        if normalized == "system" {
            return true
        }
        guard let category = categories.first(where: { normalizedCategoryName($0.name) == normalized }) else {
            return false
        }
        return category.isSystem
    }

    private var selectableCategories: [TimelineCategory] {
        categories
            .filter { $0.isSystem == false && normalizedCategoryName($0.name) != "system" }
            .sorted { $0.order < $1.order }
    }

    private var isFocusSelectionEmpty: Bool {
        focusCategoryIDs.isEmpty
    }

    private var isDistractionSelectionEmpty: Bool {
        distractionCategoryIDs.isEmpty
    }

    private func categoryID(for name: String) -> UUID? {
        let normalized = normalizedCategoryName(name)
        return categories.first(where: { normalizedCategoryName($0.name) == normalized })?.id
    }

    private func toggleFocusCategory(_ category: TimelineCategory) {
        if focusCategoryIDs.contains(category.id) {
            focusCategoryIDs.remove(category.id)
        } else {
            focusCategoryIDs.insert(category.id)
        }
    }

    private func toggleDistractionCategory(_ category: TimelineCategory) {
        if distractionCategoryIDs.contains(category.id) {
            distractionCategoryIDs.remove(category.id)
        } else {
            distractionCategoryIDs.insert(category.id)
        }
    }

    private func loadFocusSelectionIfNeeded() {
        let defaults = UserDefaults.standard
        let hasStoredSelection = defaults.object(forKey: focusSelectionStorageKey) != nil
        let validIDs = Set(selectableCategories.map(\.id))

        if hasStoredSelection {
            let stored = defaults.stringArray(forKey: focusSelectionStorageKey) ?? []
            let parsed = Set(stored.compactMap { UUID(uuidString: $0) })
            let sanitized = parsed.intersection(validIDs)
            focusCategoryIDs = sanitized

            if sanitized.count != parsed.count {
                persistFocusSelection()
            }
            return
        }

        if let workCategory = selectableCategories.first(where: { normalizedCategoryName($0.name) == "work" }) {
            focusCategoryIDs = [workCategory.id]
        } else {
            focusCategoryIDs = []
        }
        persistFocusSelection()
    }

    private func syncFocusSelectionWithCategories() {
        let validIDs = Set(selectableCategories.map(\.id))
        let updated = focusCategoryIDs.intersection(validIDs)
        if updated != focusCategoryIDs {
            focusCategoryIDs = updated
        }
    }

    private func persistFocusSelection() {
        let stored = focusCategoryIDs.map { $0.uuidString }
        UserDefaults.standard.set(stored, forKey: focusSelectionStorageKey)
    }

    private func loadDistractionSelectionIfNeeded() {
        let defaults = UserDefaults.standard
        let hasStoredSelection = defaults.object(forKey: distractionSelectionStorageKey) != nil
        let validIDs = Set(selectableCategories.map(\.id))

        if hasStoredSelection {
            let stored = defaults.stringArray(forKey: distractionSelectionStorageKey) ?? []
            let parsed = Set(stored.compactMap { UUID(uuidString: $0) })
            let sanitized = parsed.intersection(validIDs)
            distractionCategoryIDs = sanitized

            if sanitized.count != parsed.count {
                persistDistractionSelection()
            }
            return
        }

        if let distractionCategory = selectableCategories.first(where: {
            let normalized = normalizedCategoryName($0.name)
            return normalized == "distraction" || normalized == "distractions"
        }) {
            distractionCategoryIDs = [distractionCategory.id]
        } else {
            distractionCategoryIDs = []
        }
        persistDistractionSelection()
    }

    private func syncDistractionSelectionWithCategories() {
        let validIDs = Set(selectableCategories.map(\.id))
        let updated = distractionCategoryIDs.intersection(validIDs)
        if updated != distractionCategoryIDs {
            distractionCategoryIDs = updated
        }
    }

    private func persistDistractionSelection() {
        let stored = distractionCategoryIDs.map { $0.uuidString }
        UserDefaults.standard.set(stored, forKey: distractionSelectionStorageKey)
    }

    nonisolated private func timelineMinutes(for timeString: String) -> Int? {
        guard let minutes = parseTimeHMMA(timeString: timeString) else { return nil }
        if minutes >= Design.timelineDayStartMinutes {
            return minutes - Design.timelineDayStartMinutes
        }
        return minutes + (Design.minutesPerDay - Design.timelineDayStartMinutes)
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

    // MARK: - Pre-computation Helpers (run on background thread to avoid main thread hangs)

    /// Pre-computes durations for all cards (expensive parsing done once)
    nonisolated private func precomputeCardDurations(_ cards: [TimelineCard]) -> [CardWithDuration] {
        cards.compactMap { card in
            guard let startMinutes = timelineMinutes(for: card.startTimestamp),
                  let endMinutes = timelineMinutes(for: card.endTimestamp) else {
                return nil
            }
            var adjustedEnd = endMinutes
            if adjustedEnd < startMinutes {
                adjustedEnd += Design.minutesPerDay
            }
            let duration = TimeInterval(adjustedEnd - startMinutes) * 60
            return CardWithDuration(
                card: card,
                duration: duration,
                startMinutes: startMinutes,
                endMinutes: adjustedEnd
            )
        }
    }

    /// Computes category durations from pre-computed data
    nonisolated private func computeCategoryDurations(from precomputed: [CardWithDuration], categories: [TimelineCategory]) -> [CategoryTimeData] {
        var durationsByCategory: [String: TimeInterval] = [:]

        for item in precomputed {
            guard !isSystemCategoryStatic(item.card.category, categories: categories) else { continue }
            durationsByCategory[item.card.category, default: 0] += item.duration
        }

        return durationsByCategory.compactMap { (name, duration) -> CategoryTimeData? in
            guard duration > 0 else { return nil }
            let colorHex = categories.first(where: { $0.name == name })?.colorHex ?? "#E5E7EB"
            return CategoryTimeData(name: name, colorHex: colorHex, duration: duration)
        }
        .sorted { $0.duration > $1.duration }
    }

    /// Computes total captured time from pre-computed data
    nonisolated private func computeTotalCapturedTime(from precomputed: [CardWithDuration], categories: [TimelineCategory]) -> TimeInterval {
        precomputed.reduce(0) { total, item in
            guard !isSystemCategoryStatic(item.card.category, categories: categories) else { return total }
            return total + item.duration
        }
    }

    /// Computes total focus time from pre-computed data
    nonisolated private func computeTotalFocusTime(from precomputed: [CardWithDuration], focusIDs: Set<UUID>, categories: [TimelineCategory]) -> TimeInterval {
        precomputed
            .filter { isFocusCategoryStatic($0.card.category, focusIDs: focusIDs, categories: categories) }
            .reduce(0) { $0 + $1.duration }
    }

    /// Computes focus blocks from pre-computed data
    nonisolated private func computeFocusBlocks(from precomputed: [CardWithDuration], focusIDs: Set<UUID>, baseDate: Date, categories: [TimelineCategory]) -> [FocusBlock] {
        let focusCards = precomputed.filter { isFocusCategoryStatic($0.card.category, focusIDs: focusIDs, categories: categories) }

        var blocks: [(start: Int, end: Int)] = []
        for item in focusCards {
            blocks.append((start: item.startMinutes, end: item.endMinutes))
        }

        let sorted = blocks.sorted { $0.start < $1.start }
        var merged: [(start: Int, end: Int)] = []
        for block in sorted {
            if let last = merged.last {
                let gap = block.start - last.end
                if gap < Design.focusGapMinutes {
                    merged[merged.count - 1].end = max(last.end, block.end)
                    continue
                }
            }
            merged.append(block)
        }

        return merged.map { block in
            let startDate = baseDate.addingTimeInterval(TimeInterval(block.start * 60))
            let endDate = baseDate.addingTimeInterval(TimeInterval(block.end * 60))
            return FocusBlock(startTime: startDate, endTime: endDate)
        }
    }

    /// Computes total distracted time from pre-computed data
    nonisolated private func computeTotalDistractedTime(from precomputed: [CardWithDuration], distractionIDs: Set<UUID>, categories: [TimelineCategory]) -> TimeInterval {
        precomputed.reduce(0) { total, item in
            guard !isSystemCategoryStatic(item.card.category, categories: categories) else { return total }
            guard isDistractionCategoryStatic(item.card.category, distractionIDs: distractionIDs, categories: categories) else { return total }
            return total + item.duration
        }
    }

    /// Static version of isSystemCategory that takes categories as parameter (for use in background thread)
    nonisolated private func isSystemCategoryStatic(_ name: String, categories: [TimelineCategory]) -> Bool {
        let normalized = normalizedCategoryName(name)
        if normalized == "system" { return true }
        guard let category = categories.first(where: { normalizedCategoryName($0.name) == normalized }) else {
            return false
        }
        return category.isSystem
    }

    /// Static version of isFocusCategory (for use in background thread)
    nonisolated private func isFocusCategoryStatic(_ category: String, focusIDs: Set<UUID>, categories: [TimelineCategory]) -> Bool {
        if isSystemCategoryStatic(category, categories: categories) { return false }
        let normalized = normalizedCategoryName(category)
        guard let cat = categories.first(where: { normalizedCategoryName($0.name) == normalized }) else { return false }
        return focusIDs.contains(cat.id)
    }

    /// Static version of isDistractionCategory (for use in background thread)
    nonisolated private func isDistractionCategoryStatic(_ name: String, distractionIDs: Set<UUID>, categories: [TimelineCategory]) -> Bool {
        if isSystemCategoryStatic(name, categories: categories) { return false }
        let normalized = normalizedCategoryName(name)
        guard let cat = categories.first(where: { normalizedCategoryName($0.name) == normalized }) else { return false }
        return distractionIDs.contains(cat.id)
    }

    /// Recomputes focus-related stats when focusCategoryIDs changes
    private func recomputeFocusStats() {
        let precomputed = cardsWithDurations
        let focusIDs = focusCategoryIDs
        let currentCategories = categories
        let baseDate = timelineDayInfo.startOfDay

        Task.detached(priority: .userInitiated) {
            let totalFocus = self.computeTotalFocusTime(from: precomputed, focusIDs: focusIDs, categories: currentCategories)
            let blocks = self.computeFocusBlocks(from: precomputed, focusIDs: focusIDs, baseDate: baseDate, categories: currentCategories)

            await MainActor.run {
                self.cachedTotalFocusTime = totalFocus
                self.cachedFocusBlocks = blocks
            }
        }
    }

    /// Recomputes cached stats when categories change (rename/color/system/focus/distraction flags)
    private func recomputeCachedStatsForCategoryChange() {
        let precomputed = cardsWithDurations.isEmpty ? precomputeCardDurations(timelineCards) : cardsWithDurations
        let currentCategories = categories
        let focusIDs = focusCategoryIDs
        let distractionIDs = distractionCategoryIDs
        let baseDate = timelineDayInfo.startOfDay

        Task.detached(priority: .userInitiated) {
            let catDurations = self.computeCategoryDurations(from: precomputed, categories: currentCategories)
            let totalCaptured = self.computeTotalCapturedTime(from: precomputed, categories: currentCategories)
            let totalFocus = self.computeTotalFocusTime(from: precomputed, focusIDs: focusIDs, categories: currentCategories)
            let blocks = self.computeFocusBlocks(from: precomputed, focusIDs: focusIDs, baseDate: baseDate, categories: currentCategories)
            let totalDistracted = self.computeTotalDistractedTime(from: precomputed, distractionIDs: distractionIDs, categories: currentCategories)

            await MainActor.run {
                self.cachedCategoryDurations = catDurations
                self.cachedTotalCapturedTime = totalCaptured
                self.cachedTotalFocusTime = totalFocus
                self.cachedFocusBlocks = blocks
                self.cachedTotalDistractedTime = totalDistracted
            }
        }
    }

    /// Recomputes distraction-related stats when distractionCategoryIDs changes
    private func recomputeDistractionStats() {
        let precomputed = cardsWithDurations
        let distractionIDs = distractionCategoryIDs
        let currentCategories = categories

        Task.detached(priority: .userInitiated) {
            let totalDistracted = self.computeTotalDistractedTime(from: precomputed, distractionIDs: distractionIDs, categories: currentCategories)

            await MainActor.run {
                self.cachedTotalDistractedTime = totalDistracted
            }
        }
    }

    private enum ReviewRatingKey: String {
        case distracted
        case neutral
        case focused
    }

    nonisolated private static func makeReviewSummary(
        segments: [TimelineReviewRatingSegment],
        dayStartTs: Int,
        dayEndTs: Int
    ) -> TimelineReviewSummarySnapshot {
        var durationByRating: [ReviewRatingKey: TimeInterval] = [
            .distracted: 0,
            .neutral: 0,
            .focused: 0
        ]
        var latestEnd: Int? = nil

        for segment in segments {
            let start = max(segment.startTs, dayStartTs)
            let end = min(segment.endTs, dayEndTs)
            guard end > start else { continue }

            let normalized = segment.rating
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard let rating = ReviewRatingKey(rawValue: normalized) else { continue }

            durationByRating[rating, default: 0] += TimeInterval(end - start)
            latestEnd = max(latestEnd ?? end, end)
        }

        let total = durationByRating.values.reduce(0, +)
        guard total > 0 else {
            return .placeholder
        }

        let distractedRatio = durationByRating[.distracted, default: 0] / total
        let neutralRatio = durationByRating[.neutral, default: 0] / total
        let productiveRatio = durationByRating[.focused, default: 0] / total

        return TimelineReviewSummarySnapshot(
            hasData: true,
            lastReviewedAt: latestEnd.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            distractedRatio: distractedRatio,
            neutralRatio: neutralRatio,
            productiveRatio: productiveRatio,
            distractedDuration: durationByRating[.distracted, default: 0],
            neutralDuration: durationByRating[.neutral, default: 0],
            productiveDuration: durationByRating[.focused, default: 0]
        )
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX, y: rect.midY)
        let mid = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.minY)
        path.move(to: start)
        path.addLine(to: mid)
        path.addLine(to: end)
        return path
    }
}

private struct ProductivityScoreCard: View {
    let score: Int
    let hasData: Bool
    let isUsingReviewData: Bool

    private var scoreColor: Color {
        if score >= 70 {
            return Color(hex: "4CAF50") // Green
        } else if score >= 60 {
            return Color(hex: "F3854B") // Orange
        } else {
            return Color(hex: "F44336") // Red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Productivity score")
                    .font(.custom("InstrumentSerif-Regular", size: 16))
                    .foregroundColor(Color(hex: "333333"))

                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "CFC7BE"))
                    .help(isUsingReviewData
                        ? "Based on your manual reviews (focused/neutral/distracted). Focused = 100pts, Neutral = 50pts, Distracted = 0pts"
                        : "Based on your focus/distraction categories. Review timeline cards for more accurate scoring.")

                Spacer()
            }

            if hasData {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(score)")
                        .font(.custom("InstrumentSerif-Regular", size: 44))
                        .foregroundColor(scoreColor)

                    Text("out of 100")
                        .font(.custom("Nunito", size: 11))
                        .foregroundColor(Color(hex: "707070"))
                        .offset(y: -2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No activity captured yet")
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Color(hex: "707070"))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "F7F7F7"))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TotalFocusCard: View {
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Total focus time")
                    .font(.custom("InstrumentSerif-Regular", size: 16))
                    .foregroundColor(Color(hex: "333333"))

                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "CFC7BE"))

                Spacer()
            }

            Text(value)
                .font(.custom("InstrumentSerif-Regular", size: 34))
                .foregroundColor(Color(hex: "F3854B"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "F7F7F7"))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ShockwaveView: View {
    let scale: CGFloat
    let opacity: Double

    var body: some View {
        Circle()
            .stroke(Color(hex: "F3854B"), lineWidth: 3)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

struct SuccessParticlesView: View {
    let trigger: Int

    var body: some View {
        ZStack {
            ForEach(0..<15, id: \.self) { index in
                Rectangle()
                    .fill(index.isMultiple(of: 2) ? Color(hex: "F3854B") : Color(hex: "3A2F28"))
                    .frame(width: 8, height: 8)
                    .modifier(ParticleModifier(trigger: trigger))
            }
        }
    }
}

struct ParticleModifier: ViewModifier {
    let trigger: Int
    @State private var position: CGPoint = .zero
    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .offset(x: position.x, y: position.y)
            .opacity(opacity)
            .onChange(of: trigger) {
                opacity = 1
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    position = CGPoint(x: .random(in: -200...200), y: .random(in: -200...200))
                }
                withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                    opacity = 0
                }
            }
    }
}

struct SquishButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ConfettiBurstView: View {
    let trigger: Int

    private let colors: [Color] = [
        Color(hex: "FF6B6B"),
        Color(hex: "FFD93D"),
        Color(hex: "6BCB77"),
        Color(hex: "4D96FF"),
        Color(hex: "9B5DE5"),
        Color(hex: "FF8FAB"),
        Color(hex: "00C2FF"),
        Color(hex: "FFA41B"),
        Color(hex: "F72585"),
        Color(hex: "7AE582")
    ]
    private let confettiCount = 40

    var body: some View {
        ZStack {
            ForEach(0..<confettiCount, id: \.self) { index in
                ConfettiPiece(
                    color: colors[index % colors.count],
                    trigger: trigger
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConfettiPiece: View {
    let color: Color
    let trigger: Int
    @State private var offset: CGSize = .zero
    @State private var rotation: Double = 0
    @State private var opacity: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 6, height: 10)
            .rotationEffect(.degrees(rotation))
            .offset(offset)
            .opacity(opacity)
            .onChange(of: trigger) {
                let xStart = Double.random(in: -40...40)
                let xBurst = Double.random(in: -140...140)
                let xFall = Double.random(in: -220...220)
                let yBurst = Double.random(in: -20...40)
                let yFall = Double.random(in: 260...420)
                let spinBurst = Double.random(in: -90...90)
                let spinFall = spinBurst + Double.random(in: -180...180)

                offset = CGSize(width: xStart, height: -6)
                rotation = 0
                opacity = 1

                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    offset = CGSize(width: xBurst, height: yBurst)
                    rotation = spinBurst
                }

                withAnimation(.easeInOut(duration: 2.6).delay(0.35)) {
                    offset = CGSize(width: xFall, height: yFall)
                    rotation = spinFall
                }

                withAnimation(.easeOut(duration: 0.6).delay(2.4)) {
                    opacity = 0
                }
            }
    }
}

private struct CategorySelectionEditor: View {
    let categories: [TimelineCategory]
    let selectedCategoryIDs: Set<UUID>
    let helperText: String
    var onToggle: (TimelineCategory) -> Void
    var onDone: () -> Void

    private enum Design {
        static let pillSpacing: CGFloat = 4
        static let rowSpacing: CGFloat = 4
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 10
        static let dividerColor = Color(red: 0.91, green: 0.89, blue: 0.86)
        static let helperTextColor = Color(hex: "6C6761")
        static let helperTextSize: CGFloat = 11
        static let backgroundColor = Color(red: 0.98, green: 0.96, blue: 0.95).opacity(0.86)
        static let borderColor = Color(red: 0.91, green: 0.88, blue: 0.87)
        static let cornerRadius: CGFloat = 6
    }

    var body: some View {
        VStack(spacing: 12) {
            FocusCategoryFlowLayout(spacing: Design.pillSpacing, rowSpacing: Design.rowSpacing) {
                ForEach(categories) { category in
                    CategoryPill(
                        category: category,
                        isSelected: selectedCategoryIDs.contains(category.id)
                    ) {
                        onToggle(category)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Design.dividerColor)
                .frame(height: 1)

            helperRow
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Design.horizontalPadding)
        .padding(.vertical, Design.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .stroke(Design.borderColor, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .frame(width: 8, height: 8)
            }
            .buttonStyle(.plain)
            .hoverScaleEffect(scale: 1.02)
            .pointingHandCursorOnHover(reassertOnPressEnd: true)
            .padding(6)
            .background(
                Color(red: 0.98, green: 0.98, blue: 0.98).opacity(0.8)
                    .background(.ultraThinMaterial)
            )
            .clipShape(
                RoundedRectangle(cornerRadius: Design.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.cornerRadius)
                .stroke(Color(red: 0.89, green: 0.89, blue: 0.89), lineWidth: 1)
            )
            .offset(x: -8, y: 8)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    private var helperRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.system(size: 11))
                .foregroundColor(Design.helperTextColor.opacity(0.7))

            Text(helperText)
                .font(.custom("Nunito", size: Design.helperTextSize))
                .foregroundColor(Design.helperTextColor)
        }
    }

    private var backgroundView: some View {
        Design.backgroundColor
            .background(.ultraThinMaterial)
    }
}

private struct FocusCategoryFlowLayout: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4

    func makeCache(subviews: Subviews) -> () {
        ()
    }

    func updateCache(_ cache: inout (), subviews: Subviews) { }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = size.width

            if rowWidth > 0 && rowWidth + spacing + proposedWidth > maxWidth {
                totalHeight += rowHeight + rowSpacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = proposedWidth
                rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? proposedWidth : rowWidth + spacing + proposedWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        maxRowWidth = max(maxRowWidth, rowWidth)
        totalHeight += rowHeight

        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += currentRowHeight + rowSpacing
                currentRowHeight = 0
            }

            subview.place(
                at: CGPoint(x: origin.x, y: origin.y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            origin.x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview("Day Summary") {
    let sampleCategories: [TimelineCategory] = [
        TimelineCategory(name: "Work", colorHex: "#B984FF", order: 0),
        TimelineCategory(name: "Personal", colorHex: "#6AADFF", order: 1),
        TimelineCategory(name: "Distraction", colorHex: "#FF5950", order: 2),
        TimelineCategory(name: "Idle", colorHex: "#A0AEC0", order: 3, isSystem: true, isIdle: true)
    ]

    DaySummaryView(
        selectedDate: Date(),
        categories: sampleCategories,
        storageManager: StorageManager.shared,
        cardsToReviewCount: 3,
        reviewRefreshToken: 0,
        onReviewTap: { }
    )
    .frame(width: 358, height: 700)
    .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
