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

    @State private var timelineCards: [TimelineCard] = []
    @State private var isLoading = true
    @State private var focusCategoryIDs: Set<UUID> = []
    @State private var isEditingFocusCategories = false
    @State private var distractionCategoryIDs: Set<UUID> = []
    @State private var isEditingDistractionCategories = false
    @State private var hasEarlyAccess = UserDefaults.standard.bool(forKey: "daySummaryEarlyAccessGranted")
    
    // MARK: - Animation State
    @State private var gatePhase: GatePhase = UserDefaults.standard.bool(
        forKey: "daySummaryEarlyAccessGranted"
    ) ? .hidden : .locked
    
    @State private var gateOpacity: Double = UserDefaults.standard.bool(
        forKey: "daySummaryEarlyAccessGranted"
    ) ? 0 : 1
    
    // Animation specific state
    @State private var gateScale: CGFloat = 1
    @State private var gateBlur: CGFloat = 0
    @State private var gateRingProgress: CGFloat = 0
    @State private var gateCheckProgress: CGFloat = 0
    @State private var gateGlowOpacity: Double = 0
    @State private var gatePulse: CGFloat = 1
    @State private var successIconScale: CGFloat = 0.5 // Start small for pop effect

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
        static let shareTextColor = Color(hex: "D7A585")
        static let shareBorderColor = Color(hex: "F7E4CE")
        static let shareBackground = Color(hex: "FFF5EA")

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

    // MARK: - Computed Stats

    private var timelineDayInfo: (dayString: String, startOfDay: Date) {
        let timelineDate = timelineDisplayDate(from: selectedDate)
        let info = timelineDate.getDayInfoFor4AMBoundary()
        return (info.dayString, info.startOfDay)
    }

    private var categoryDurations: [CategoryTimeData] {
        // Group cards by category and sum durations
        var durationsByCategory: [String: TimeInterval] = [:]

        for card in timelineCards {
            guard isSystemCategory(card.category) == false else { continue }
            let duration = durationSeconds(start: card.startTimestamp, end: card.endTimestamp)
            durationsByCategory[card.category, default: 0] += duration
        }

        // Map to CategoryTimeData, matching colors from categories
        return durationsByCategory.compactMap { (name, duration) -> CategoryTimeData? in
            guard duration > 0 else { return nil }

            // Find matching category for color
            let colorHex = categories.first(where: { $0.name == name })?.colorHex ?? "#E5E7EB"

            return CategoryTimeData(
                name: name,
                colorHex: colorHex,
                duration: duration
            )
        }
        .sorted { $0.duration > $1.duration } // Sort by duration descending
    }

    private var totalFocusTime: TimeInterval {
        // Focus time = user-selected categories
        timelineCards
            .filter { isFocusCategory($0.category) }
            .reduce(0) { total, card in
                total + durationSeconds(start: card.startTimestamp, end: card.endTimestamp)
            }
    }

    private var totalCapturedTime: TimeInterval {
        timelineCards.reduce(0) { total, card in
            guard isSystemCategory(card.category) == false else { return total }
            return total + durationSeconds(start: card.startTimestamp, end: card.endTimestamp)
        }
    }

    private var focusBlocks: [FocusBlock] {
        let baseDate = timelineDayInfo.startOfDay
        let focusCards = timelineCards.filter { isFocusCategory($0.category) }

        var blocks: [(start: Int, end: Int)] = []
        for card in focusCards {
            guard let start = timelineMinutes(for: card.startTimestamp),
                  let end = timelineMinutes(for: card.endTimestamp) else { continue }
            var adjustedEnd = end
            if adjustedEnd < start {
                adjustedEnd += Design.minutesPerDay
            }
            blocks.append((start: start, end: adjustedEnd))
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

    private var totalDistractedTime: TimeInterval {
        timelineCards.reduce(0) { total, card in
            guard isSystemCategory(card.category) == false else { return total }
            guard isDistractionCategory(card.category) else { return total }
            return total + durationSeconds(start: card.startTimestamp, end: card.endTimestamp)
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: Design.sectionSpacing) {
                daySoFarSection

                sectionDivider

                focusSection

                sectionDivider

                distractionsSection
            }
            .frame(width: Design.contentWidth, alignment: .leading)
            .padding(.top, Design.topPadding)
            .padding(.bottom, Design.bottomPadding)
            .padding(.horizontal, Design.horizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadFocusSelectionIfNeeded()
            loadDistractionSelectionIfNeeded()
            loadData()
        }
        .onChange(of: selectedDate) { _ in
            loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { notification in
            if let dayString = notification.userInfo?["dayString"] as? String {
                guard dayString == timelineDayInfo.dayString else { return }
            }
            loadData()
        }
        .onChange(of: categories) { _ in
            syncFocusSelectionWithCategories()
            syncDistractionSelectionWithCategories()
        }
        .onChange(of: focusCategoryIDs) { _ in
            persistFocusSelection()
        }
        .onChange(of: distractionCategoryIDs) { _ in
            persistDistractionSelection()
        }
        .onChange(of: hasEarlyAccess) { newValue in
            if newValue {
                UserDefaults.standard.set(true, forKey: earlyAccessStorageKey)
            }
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

        let dayString = timelineDayInfo.dayString
        let storageManager = storageManager

        Task.detached(priority: .userInitiated) {
            // Use timeline display date to handle 4 AM boundary
            let cards = await storageManager.fetchTimelineCards(forDay: dayString)

            await MainActor.run {
                self.timelineCards = cards
                self.isLoading = false
            }
        }
    }

    // MARK: - Header

    private var daySoFarSection: some View {
        ZStack(alignment: .center) {
            daySoFarContent
                .blur(radius: gatePhase == .hidden ? 0 : Design.gateBlurRadius)
                .allowsHitTesting(gatePhase == .hidden)

            if gatePhase != .hidden {
                earlyAccessGateOverlay
                    .scaleEffect(gateScale)
                    .blur(radius: gateBlur)
                    .opacity(gateOpacity)
            }
        }
    }

    private var daySoFarContent: some View {
        VStack(alignment: .leading, spacing: Design.donutSectionSpacing) {
            VStack(alignment: .leading, spacing: Design.headerSpacing) {
                HStack(alignment: .center) {
                    Text("Your day so far")
                        .font(.custom("InstrumentSerif-Regular", size: 24))
                        .foregroundColor(Design.titleColor)

                    Spacer()

                    Button(action: {
                        // TODO: Implement share functionality
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 10, weight: .medium))
                            Text("Share")
                                .font(.custom("Nunito", size: 10).weight(.medium))
                        }
                        .foregroundColor(Design.shareTextColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Design.shareBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Design.shareBorderColor, lineWidth: 0.75)
                        )
                        .frame(height: 19)
                    }
                    .buttonStyle(.plain)
                }

                Text("This data will update every 15 minutes. Check back throughout the day to gain new understanding on your workflow.")
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Design.subtitleColor)
                    .lineSpacing(2)
            }

            if isLoading {
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

            VStack(spacing: 12) {
                Text("EARLY ACCESS")
                    .font(.custom("Nunito", size: 11).weight(.semibold))
                    .foregroundColor(Design.gateOverlineColor)
                    .tracking(0.6)

                Text("Your day so far")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundColor(Design.gateTitleColor)

                Text("Request early access to unlock your live breakdown and focus insights.")
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
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
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }

            if gatePhase == .granted {
                VStack(spacing: 6) {
                    ZStack {
                        // Glow
                        Circle()
                            .fill(Design.gateGlow)
                            .frame(width: 50, height: 50)
                            .opacity(gateGlowOpacity)
                            .scaleEffect(gatePulse)

                        // Ring
                        Circle()
                            .trim(from: 0, to: gateRingProgress)
                            .stroke(Design.gateAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(Angle.degrees(-90))
                            .frame(width: 38, height: 38)

                        // Checkmark
                        CheckmarkShape()
                            .trim(from: 0, to: gateCheckProgress)
                            .stroke(
                                Design.gateAccent,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 20, height: 14)
                    }
                    .scaleEffect(successIconScale)

                    Text("Access granted")
                        .font(.custom("Nunito", size: 12).weight(.bold))
                        .foregroundColor(Design.gateTitleColor)
                        .opacity(gateCheckProgress) // Fade text in with check
                        .offset(y: 2)
                }
            }
        }
    }

    // MARK: - Animation Logic
    
    private func requestEarlyAccess() {
        guard gatePhase == .locked else { return }
        
        // 1. Tactile Feedback (The "Responsive" Button)
        // Immediate scale down on press to feel physical
        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.6)) {
            gateScale = 0.96
        }
        
        // 2. State Change & Reset
        // Slight delay to let the scale-down register, then start loading
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            gatePhase = .requesting
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                gateScale = 1.0 // Return to normal size
            }
        }

        // 3. The "Unlock" Sequence
        // Simulate network delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            gatePhase = .granted
            hasEarlyAccess = true
            
            // Pop the icon in (Scale 0 -> 1.1 -> 1.0)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                successIconScale = 1.0
            }

            // Draw Ring
            withAnimation(.easeOut(duration: 0.4)) {
                gateRingProgress = 1
            }
            
            // Draw Checkmark (Staggered slightly after ring starts)
            withAnimation(.easeOut(duration: 0.3).delay(0.2)) {
                gateCheckProgress = 1
            }
            
            // Pulse Glow (The "Delight")
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                gateGlowOpacity = 0.6
                gatePulse = 1.3
            }
            // Fade glow out
            withAnimation(.easeIn(duration: 0.5).delay(0.6)) {
                gateGlowOpacity = 0
            }
        }

        // 4. The Exit (Origin-Aware & The "Blur Trick")
        // Instead of just fading, scale up + blur out to reveal content
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            withAnimation(.easeIn(duration: 0.35)) {
                gateOpacity = 0
                gateScale = 1.05 // Expand slightly as it dissipates
                gateBlur = 8     // Blur trick: masks the fade-out imperfections
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                gatePhase = .hidden
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
            }

            if isFocusSelectionEmpty {
                Text("Edit categories to calculate focus.")
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Design.subtitleColor)
            }

            VStack(spacing: Design.focusCardsSpacing) {
                TotalFocusCard(value: formatDurationTitleCase(totalFocusTime))

                LongestFocusCard(focusBlocks: focusBlocks)
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

    // MARK: - Helpers

    private func isFocusCategory(_ category: String) -> Bool {
        if isSystemCategory(category) { return false }
        guard let categoryID = categoryID(for: category) else { return false }
        return focusCategoryIDs.contains(categoryID)
    }

    private func normalizedCategoryName(_ name: String) -> String {
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

    private func timelineMinutes(for timeString: String) -> Int? {
        guard let minutes = parseTimeHMMA(timeString: timeString) else { return nil }
        if minutes >= Design.timelineDayStartMinutes {
            return minutes - Design.timelineDayStartMinutes
        }
        return minutes + (Design.minutesPerDay - Design.timelineDayStartMinutes)
    }

    private func durationSeconds(start: String, end: String) -> TimeInterval {
        guard let startMinutes = timelineMinutes(for: start),
              let endMinutes = timelineMinutes(for: end) else { return 0 }
        var adjustedEnd = endMinutes
        if adjustedEnd < startMinutes {
            adjustedEnd += Design.minutesPerDay
        }
        return TimeInterval(adjustedEnd - startMinutes) * 60
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
        storageManager: StorageManager.shared
    )
    .frame(width: 358, height: 700)
    .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
