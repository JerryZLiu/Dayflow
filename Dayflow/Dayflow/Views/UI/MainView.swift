//
//  MainView.swift
//  Dayflow
//
//  Timeline UI with transparent design
//

import SwiftUI
import AVKit
import AVFoundation
import AppKit
import Sentry

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var categoryStore: CategoryStore
    @StateObject private var featureFlagManager = FeatureFlagManager.shared
    @StateObject private var migrationManager = DataMigrationManager.shared
    @State private var selectedIcon: SidebarIcon = .timeline
    @State private var selectedDate = timelineDisplayDate(from: Date())
    @State private var showDatePicker = false
    @State private var selectedActivity: TimelineActivity? = nil
    @State private var scrollToNowTick: Int = 0
    @State private var hasAnyActivities: Bool = true
    @ObservedObject private var inactivity = InactivityMonitor.shared
    
    // Animation states for orchestrated entrance - Emil Kowalski principles
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0
    @State private var timelineOffset: CGFloat = -20
    @State private var timelineOpacity: Double = 0
    @State private var sidebarOffset: CGFloat = -30
    @State private var sidebarOpacity: Double = 0
    @State private var contentOpacity: Double = 0
    @State private var dashboardOffset: CGFloat = -20
    @State private var dashboardOpacity: Double = 0
    @State private var journalOffset: CGFloat = -20
    @State private var journalOpacity: Double = 0
    
    // Track if we've performed the initial scroll to current time
    @State private var didInitialScroll = false
    @State private var previousDate = timelineDisplayDate(from: Date())
    @State private var lastDateNavMethod: String? = nil
    // Minute tick to handle civil-day rollover (header updates + jump to today)
    @State private var dayChangeTimer: Timer? = nil
    @State private var lastObservedCivilDay: String = {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; return fmt.string(from: Date())
    }()
    @State private var showCategoryEditor = false

    // FocusLock specific state
    @State private var showMigration = false
    @State private var showFeatureOnboarding = false
    @State private var onboardingFeature: FeatureFlag?
    @State private var showFocusLockOnboarding = false
    @AppStorage("focusLockOnboardingCompleted") private var focusLockOnboardingCompleted = false

    private static let maxDateTitleWidth: CGFloat = {
        let referenceText = "Today, Sep 30"
        let font = NSFont(name: "InstrumentSerif-Regular", size: 36) ?? NSFont.systemFont(ofSize: 36)
        let width = referenceText.size(withAttributes: [.font: font]).width
        return ceil(width) + 4 // small buffer so arrows never nudge
    }()

    var body: some View {
        // Check for migration first
        Group {
            if migrationManager.needsMigration() {
                DataMigrationView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mainAppContent
            }
        }
        .onAppear {
            checkForFeatureOnboarding()
        }
        .sheet(isPresented: $showFeatureOnboarding) {
            if let feature = onboardingFeature {
                FeatureOnboardingView(feature: feature) {
                    showFeatureOnboarding = false
                    featureFlagManager.setOnboardingStatus(for: feature, status: .completed)
                }
                .frame(minWidth: 600, minHeight: 500)
            }
        }
        .sheet(isPresented: $showFocusLockOnboarding) {
            FocusLockOnboardingFlow()
                .environmentObject(featureFlagManager)
                .frame(minWidth: 800, minHeight: 600)
        }
        .onChange(of: focusLockOnboardingCompleted) { oldValue, newValue in
            if newValue {
                showFocusLockOnboarding = false
            }
        }
    }

    @ViewBuilder
    private var mainAppContent: some View {
        // Two-column layout: left logo + sidebar; right white panel including header + content
        HStack(alignment: .top, spacing: 0) {
            // Left column: Logo on top, sidebar centered
            leftSidebarColumn
            
            // Right column: Main white panel including header + content
            rightContentColumn
        }
        .background(
            FlowingGradientBackground()
                .ignoresSafeArea()
        )
    }
    
    private var leftSidebarColumn: some View {
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
    private var rightContentColumn: some View {
        // Right column: Main white panel including header + content
        ZStack {
                switch selectedIcon {
                case .settings:
                    enhancedSettingsView
                        .padding(15)
                case .dashboard:
                    enhancedDashboardView
                        .offset(y: dashboardOffset)
                        .opacity(dashboardOpacity)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                dashboardOffset = 0
                                dashboardOpacity = 1
                            }
                        }
                        .onChange(of: selectedIcon) { oldValue, newValue in
                            if newValue != .dashboard {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    dashboardOffset = -20
                                    dashboardOpacity = 0
                                }
                            }
                        }
                case .journal:
                    enhancedJournalView
                        .offset(y: journalOffset)
                        .opacity(journalOpacity)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                journalOffset = 0
                                journalOpacity = 1
                            }
                        }
                        .onChange(of: selectedIcon) { oldValue, newValue in
                            if newValue != .journal {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    journalOffset = -20
                                    journalOpacity = 0
                                }
                            }
                        }
                case .jarvisChat:
                    JarvisChatView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .focuslock:
                    enhancedFocusLockView
                case .smartTodos:
                    SmartTodoView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .timeline:
                    GeometryReader { geo in
                        HStack(alignment: .top, spacing: 0) {
                            // Left column: header + chips + timeline
                            VStack(alignment: .leading, spacing: 18) {
                                // Header: Date navigation + Recording toggle
                                HStack(alignment: .center) {
                                    HStack(spacing: 16) {
                                        Text(formatDateForDisplay(selectedDate))
                                            .font(.custom(DesignTypography.displayFont, size: DesignTypography.display))
                                            .foregroundColor(DesignColors.primaryText)
                                            .frame(width: Self.maxDateTitleWidth, alignment: .leading)

                                        HStack(spacing: 3) {
                                            Button(action: {
                                                let from = selectedDate
                                                let to = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                                                previousDate = selectedDate
                                                setSelectedDate(to)
                                                lastDateNavMethod = "prev"
                                                AnalyticsService.shared.capture("date_navigation", [
                                                    "method": "prev",
                                                    "from_day": dayString(from),
                                                    "to_day": dayString(to)
                                                ])
                                            }) {
                                                Image("CalendarLeftButton")
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 26, height: 26)
                                            }
                                            .buttonStyle(PlainButtonStyle())

                                            Button(action: {
                                                guard canNavigateForward(from: selectedDate) else { return }
                                                let from = selectedDate
                                                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                                                previousDate = selectedDate
                                                setSelectedDate(tomorrow)
                                                lastDateNavMethod = "next"
                                                AnalyticsService.shared.capture("date_navigation", [
                                                    "method": "next",
                                                    "from_day": dayString(from),
                                                    "to_day": dayString(tomorrow)
                                                ])
                                            }) {
                                                Image("CalendarRightButton")
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 26, height: 26)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            .disabled(!canNavigateForward(from: selectedDate))
                                        }
                                    }
                                    .offset(x: timelineOffset)
                                    .opacity(timelineOpacity)

                                    Spacer()

                                    // Recording toggle (now inline with header)
                                    HStack(spacing: 4) {
                                        Text("Record")
                                            .font(.custom(DesignTypography.bodyFont, size: DesignTypography.caption))
                                            .fontWeight(.medium)
                                            .foregroundColor(DesignColors.primaryOrange)

                                        Toggle("Record", isOn: $appState.isRecording)
                                            .labelsHidden()
                                            .toggleStyle(SunriseGlassPillToggleStyle())
                                            .scaleEffect(0.7)
                                            .accessibilityLabel(Text("Recording"))
                                    }
                                }
                                .padding(.horizontal, 10)

                                // Content area: chips + timeline
                                VStack(alignment: .leading, spacing: 12) {
                                    TabFilterBar(
                                        categories: categoryStore.editableCategories,
                                        idleCategory: categoryStore.idleCategory,
                                        onManageCategories: { showCategoryEditor = true }
                                    )
                                    .padding(.leading, 10)
                                    .opacity(contentOpacity)

                                    CanvasTimelineDataView(
                                        selectedDate: $selectedDate,
                                        selectedActivity: $selectedActivity,
                                        scrollToNowTick: $scrollToNowTick,
                                        hasAnyActivities: $hasAnyActivities
                                    )
                                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                                    .environmentObject(categoryStore)
                                    .opacity(contentOpacity)
                                }
                                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.top, 15)
                            .padding(.bottom, 15)
                            .padding(.leading, 15)
                            .padding(.trailing, 5)

                            // Divider
                            Rectangle()
                                .fill(Color(hex: "ECECEC"))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)

                            // Right column: activity detail card — spans full height
                            UnifiedCard(style: .standard, size: .medium, padding: DesignSpacing.md) {
                                ActivityCard(
                                    activity: selectedActivity,
                                    maxHeight: geo.size.height,
                                    scrollSummary: true,
                                    hasAnyActivities: hasAnyActivities
                                )
                                .opacity(contentOpacity)
                            }
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
                            .frame(minWidth: 195, idealWidth: 285, maxWidth: 315, maxHeight: .infinity)
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
            }
            .padding(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mainContentContainer()
            .padding([.top, .trailing, .bottom], DesignSpacing.lg)
        .onAppear {
            // Orchestrated entrance animations
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
            startDayChangeTimer()
        }
        .onChange(of: inactivity.pendingReset) { oldValue, fired in
            if fired, selectedIcon != .settings {
                performIdleResetAndScroll()
                InactivityMonitor.shared.markHandledIfPending()
            }
        }
        .onChange(of: selectedIcon) { oldValue, newIcon in
            // tab selected + screen viewed
            let tabName: String
            switch newIcon {
            case .timeline: tabName = "timeline"
            case .dashboard: tabName = "dashboard"
            case .journal: tabName = "journal"
            case .jarvisChat: tabName = "jarvis_chat"
            case .focuslock: tabName = "focuslock"
            case .smartTodos: tabName = "smart_todos"
            case .settings: tabName = "settings"
            }

            // Add Sentry context for app state tracking
            SentryHelper.configureScope { scope in
                scope.setContext(value: [
                    "active_view": tabName,
                    "selected_date": dayString(selectedDate),
                    "is_recording": appState.isRecording
                ], key: "app_state")
            }

            // Add breadcrumb for view navigation
            let navBreadcrumb = Breadcrumb(level: .info, category: "navigation")
            navBreadcrumb.message = "Navigated to \(tabName)"
            navBreadcrumb.data = ["view": tabName]
            SentryHelper.addBreadcrumb(navBreadcrumb)

            AnalyticsService.shared.capture("tab_selected", ["tab": tabName])
            AnalyticsService.shared.screen(tabName)
            if newIcon == .timeline {
                AnalyticsService.shared.withSampling(probability: 0.01) {
                    AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(selectedDate)])
                }
            }
        }
        .onChange(of: selectedDate) { oldValue, newDate in
            // If changed via picker, emit navigation now
            if let method = lastDateNavMethod, method == "picker" {
                AnalyticsService.shared.capture("date_navigation", [
                    "method": method,
                    "from_day": dayString(previousDate),
                    "to_day": dayString(newDate)
                ])
            }
            previousDate = newDate
            AnalyticsService.shared.withSampling(probability: 0.01) {
                AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(newDate)])
            }
        }
        .onChange(of: selectedActivity?.id) { oldValue, newValue in
            guard let a = selectedActivity else { return }
            let dur = a.endTime.timeIntervalSince(a.startTime)
            AnalyticsService.shared.capture("activity_card_opened", [
                "activity_type": a.category,
                "duration_bucket": AnalyticsService.shared.secondsBucket(dur),
                "has_video": a.videoSummaryURL != nil
            ])
        }
        .overlay {
            if showCategoryEditor {
                ColorOrganizerRoot(
                    presentationStyle: .sheet,
                    onDismiss: { showCategoryEditor = false }, completionButtonTitle: "Save", showsTitles: true
                )
                .environmentObject(categoryStore)
                // Removed .contentShape(Rectangle()) and .onTapGesture to allow keyboard input
            }
        }
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
        .sheet(isPresented: $showCategoryEditor) {
            CategoryEditorView(categoryStore: categoryStore)
                .frame(minWidth: 800, minHeight: 600)
        }
    }
    
    private func formatDateForDisplay(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let formatter = DateFormatter()

        let displayDate = timelineDisplayDate(from: date, now: now)
        let timelineToday = timelineDisplayDate(from: now, now: now)

        if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
            formatter.dateFormat = "'Today,' MMM d"
        } else {
            formatter.dateFormat = "E, MMM d"
        }

        return formatter.string(from: displayDate)
    }

    private func setSelectedDate(_ date: Date) {
        selectedDate = normalizedTimelineDate(date)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Enhanced Views with Feature Flag Integration

    @ViewBuilder
    private var enhancedSettingsView: some View {
        VStack {
            SettingsView()

            if featureFlagManager.isEnabled(.suggestedTodos) ||
               featureFlagManager.isEnabled(.planner) ||
               featureFlagManager.isEnabled(.dailyJournal) ||
               featureFlagManager.isEnabled(.enhancedDashboard) ||
               featureFlagManager.isEnabled(.jarvisChat) {
                Divider()
                    .padding(.horizontal, 20)

                FeatureFlagsSettingsView()
                    .environmentObject(featureFlagManager)
            }
        }
    }

    @ViewBuilder
    private var enhancedDashboardView: some View {
        // Show only EnhancedDashboardView if feature flag is enabled, otherwise show DashboardView
        if featureFlagManager.isEnabled(.enhancedDashboard) {
            EnhancedDashboardView(featureFlagManager: featureFlagManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DashboardView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var enhancedJournalView: some View {
        // Show EnhancedJournalView (Second Brain) if feature flag is enabled, otherwise show legacy JournalView
        if featureFlagManager.isEnabled(.dailyJournal) {
            EnhancedJournalView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            JournalView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var enhancedFocusLockView: some View {
        // Show enhanced FocusLock view if any features are enabled
        if featureFlagManager.isEnabled(.focusSessions) ||
           featureFlagManager.isEnabled(.emergencyBreaks) ||
           featureFlagManager.isEnabled(.suggestedTodos) ||
           featureFlagManager.isEnabled(.planner) {
            EnhancedFocusLockView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
            FocusLockView()

            // Suggested Todos Section
            if featureFlagManager.isEnabled(.suggestedTodos) {
                Divider()
                    .padding(.vertical, 0)
                SuggestedTodosView()
                    .environmentObject(featureFlagManager)
            }

            // Planner Section
            if featureFlagManager.isEnabled(.planner) {
                Divider()
                    .padding(.vertical, 0)
                PlannerView()
                    .environmentObject(featureFlagManager)
            }
            }
        }
    }

    // MARK: - Feature Onboarding Helpers

    private func checkForFeatureOnboarding() {
        // Check if FocusLock onboarding is needed
        if !focusLockOnboardingCompleted && hasAnyFocusLockFeaturesEnabled() {
            showFocusLockOnboarding = true
            return
        }

        // Check if any enabled features need onboarding
        let enabledFeatures = featureFlagManager.getAllEnabledFeatures()

        for feature in enabledFeatures {
            if featureFlagManager.needsOnboarding(for: feature) {
                onboardingFeature = feature
                showFeatureOnboarding = true
                break
            }
        }
    }

    private func hasAnyFocusLockFeaturesEnabled() -> Bool {
        return featureFlagManager.isEnabled(.focusSessions) ||
               featureFlagManager.isEnabled(.emergencyBreaks) ||
               featureFlagManager.isEnabled(.suggestedTodos) ||
               featureFlagManager.isEnabled(.planner)
    }

    private func shouldShowFeatureBadge(for icon: SidebarIcon) -> Bool {
        switch icon {
        case .dashboard:
            return featureFlagManager.isEnabled(.enhancedDashboard) && featureFlagManager.getOnboardingStatus(for: .enhancedDashboard) == .completed
        case .journal:
            return featureFlagManager.isEnabled(.dailyJournal) && featureFlagManager.getOnboardingStatus(for: .dailyJournal) == .completed
        case .jarvisChat:
            return featureFlagManager.isEnabled(.jarvisChat) && featureFlagManager.getOnboardingStatus(for: .jarvisChat) == .completed
        case .focuslock:
            let hasAnyFocusFeature = featureFlagManager.isEnabled(.focusSessions) ||
                                   featureFlagManager.isEnabled(.emergencyBreaks) ||
                                   featureFlagManager.isEnabled(.suggestedTodos) ||
                                   featureFlagManager.isEnabled(.planner)
            return hasAnyFocusFeature
        default:
            return false
        }
    }

    private func getSidebarIconName(for icon: SidebarIcon) -> String? {
        switch icon {
        case .timeline: return "TimelineIcon"
        case .dashboard:
            return featureFlagManager.isEnabled(.enhancedDashboard) ? "EnhancedDashboardIcon" : "DashboardIcon"
        case .journal:
            return featureFlagManager.isEnabled(.dailyJournal) ? "DailyJournalIcon" : "JournalIcon"
        case .jarvisChat: return nil
        case .focuslock:
            // Show enhanced icon when any FocusLock features are enabled
            let hasAnyFocusFeature = featureFlagManager.isEnabled(.focusSessions) ||
                                   featureFlagManager.isEnabled(.emergencyBreaks) ||
                                   featureFlagManager.isEnabled(.suggestedTodos) ||
                                   featureFlagManager.isEnabled(.planner)
            return hasAnyFocusFeature ? "EnhancedFocusLockIcon" : "FocusLockIcon"
        case .smartTodos: return nil
        case .settings: return nil
        }
    }
}

enum SidebarIcon: CaseIterable {
    case timeline
    case dashboard
    case journal
    case jarvisChat
    case focuslock
    case smartTodos
    case settings

    var assetName: String? {
        switch self {
        case .timeline: return "TimelineIcon"
        case .dashboard: return "DashboardIcon"
        case .journal: return "JournalIcon"
        case .jarvisChat: return nil
        case .focuslock: return nil
        case .smartTodos: return nil
        case .settings: return nil
        }
    }

    var systemNameFallback: String? {
        switch self {
        case .jarvisChat: return "brain.head.profile"
        case .focuslock: return "lock.shield"
        case .smartTodos: return "checklist"
        case .settings: return "gearshape"
        default: return nil
        }
    }
}

struct SidebarView: View {
    @Binding var selectedIcon: SidebarIcon
    
    var body: some View {
        VStack(alignment: .center, spacing: 10.501) {
            ForEach(SidebarIcon.allCases, id: \.self) { icon in
                SidebarIconButton(
                    icon: icon,
                    isSelected: selectedIcon == icon,
                    action: { selectedIcon = icon }
                )
                .frame(width: 40, height: 40)
            }
        }
        // Outer rounded container removed per design
    }
}

struct SidebarIconButton: View {
    let icon: SidebarIcon
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var featureFlagManager = FeatureFlagManager.shared

    private var iconName: String? {
        return icon.systemNameFallback // This will be handled by the parent component
    }

    private var shouldShowBadge: Bool {
        switch icon {
        case .dashboard:
            return featureFlagManager.isEnabled(.enhancedDashboard) &&
                   featureFlagManager.getOnboardingStatus(for: .enhancedDashboard) == .completed
        case .journal:
            return featureFlagManager.isEnabled(.dailyJournal) &&
                   featureFlagManager.getOnboardingStatus(for: .dailyJournal) == .completed
        case .jarvisChat:
            return featureFlagManager.isEnabled(.jarvisChat) &&
                   featureFlagManager.getOnboardingStatus(for: .jarvisChat) == .completed
        case .focuslock:
            let hasAnyFocusFeature = featureFlagManager.isEnabled(.focusSessions) ||
                                   featureFlagManager.isEnabled(.emergencyBreaks) ||
                                   featureFlagManager.isEnabled(.suggestedTodos) ||
                                   featureFlagManager.isEnabled(.planner)
            return hasAnyFocusFeature
        case .smartTodos:
            return featureFlagManager.isEnabled(.suggestedTodos) || featureFlagManager.isEnabled(.planner)
        default:
            return false
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Image("IconBackground")
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.original)
                }

                if let asset = icon.assetName {
                    Image(asset)
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.template)
                        .foregroundColor(isSelected ? DesignColors.primaryOrange : DesignColors.secondaryText)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else if let sys = icon.systemNameFallback {
                    Image(systemName: sys)
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? DesignColors.primaryOrange : DesignColors.secondaryText)
                }

                // Feature badge indicator
                if shouldShowBadge {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Circle()
                                .fill(DesignColors.primaryOrange)
                                .frame(width: DesignSpacing.xs, height: DesignSpacing.xs)
                        }
                    }
                    .frame(width: 40, height: 40)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
    }
}

struct TabFilterBar: View {
    let categories: [TimelineCategory]
    let idleCategory: TimelineCategory?
    let onManageCategories: () -> Void

    @State private var chipRowWidth: CGFloat = 0

    private let editButtonSize: CGFloat = 26
    private let chipButtonSpacing: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let inlineWidth = chipRowWidth + chipButtonSpacing + editButtonSize
            let fitsInline = chipRowWidth == 0 ? true : inlineWidth <= availableWidth

            Group {
                if fitsInline {
                    HStack(spacing: chipButtonSpacing) {
                        measuredChipRow
                        editButton
                    }
                } else {
                    ZStack(alignment: .trailing) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            measuredChipRow
                                .padding(.trailing, editButtonSize + chipButtonSpacing)
                        }
                        .frame(height: 26)

                        overflowGradient
                        editButton
                    }
                }
                .padding(.leading, 1)
                .padding(.trailing, 34) // 26 (button width) + 8 (spacing)
            }
            .frame(height: 26)

            // Gradient fade for overflow
            HStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    gradient: Gradient(colors: [Color.clear, Color(hex: "FFF8F1")]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 40)
                .allowsHitTesting(false)

                Color(hex: "FFF8F1")
                    .frame(width: 26)
                    .allowsHitTesting(false)
            }

            // Edit button always visible on right
            Button(action: onManageCategories) {
                Image("CategoryEditButton")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
            }
            .frame(width: geometry.size.width, height: 26, alignment: .leading)
        }
        .frame(height: 26)
        .onPreferenceChange(ChipRowWidthPreferenceKey.self) { chipRowWidth = $0 }
    }

    struct CategoryChip: View {
        let category: TimelineCategory
        let isIdle: Bool

        var body: some View {
            HStack(spacing: DesignSpacing.xs) {
                Circle()
                    .fill(Color(hex: category.colorHex))
                    .frame(width: DesignSpacing.xs, height: DesignSpacing.xs)

                Text(category.name)
                    .font(.custom(DesignTypography.bodyFont, size: DesignTypography.caption))
                    .fontWeight(.medium)
                    .foregroundColor(DesignColors.primaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, DesignSpacing.sm)
            .padding(.vertical, DesignSpacing.xs)
            .background(DesignColors.cardBackground.opacity(0.8))
            .cornerRadius(DesignRadius.small)
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.small)
                    .inset(by: 0.25)
                    .stroke(DesignColors.tertiaryText.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    private var measuredChipRow: some View {
        HStack(spacing: 5) {
            ForEach(categories) { category in
                CategoryChip(category: category, isIdle: false)
            }

            if let idleCategory {
                CategoryChip(category: idleCategory, isIdle: true)
            }
        }
        .padding(.leading, 1)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ChipRowWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
    }

    private var editButton: some View {
        Button(action: onManageCategories) {
            Image("CategoryEditButton")
                .resizable()
                .scaledToFit()
                .frame(width: editButtonSize, height: editButtonSize)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var overflowGradient: some View {
        HStack(spacing: 0) {
            Spacer()
            LinearGradient(
                gradient: Gradient(colors: [Color.clear, Color(hex: "FFF8F1") ?? Color.white]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 40)
            .allowsHitTesting(false)

            (Color(hex: "FFF8F1") ?? Color.white)
                .frame(width: editButtonSize)
                .allowsHitTesting(false)
        }
    }

    private struct ChipRowWidthPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }
}

struct DateNavigationControls: View {
    @Binding var selectedDate: Date
    @Binding var showDatePicker: Bool
    @Binding var lastDateNavMethod: String?
    @Binding var previousDate: Date

    var body: some View {
        HStack(spacing: 12) {
            DayflowCircleButton {
                let from = selectedDate
                let to = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                previousDate = selectedDate
                selectedDate = normalizedTimelineDate(to)
                lastDateNavMethod = "prev"
                AnalyticsService.shared.capture("date_navigation", [
                    "method": "prev",
                    "from_day": dayString(from),
                    "to_day": dayString(to)
                ])
            } content: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.3))
            }

            Button(action: { showDatePicker = true; lastDateNavMethod = "picker" }) {
                DayflowPillButton(
                    text: formatDateForDisplay(selectedDate),
                    fixedWidth: calculateOptimalPillWidth()
                )
            }
            .buttonStyle(PlainButtonStyle())

            DayflowCircleButton {
                guard canNavigateForward(from: selectedDate) else { return }
                let from = selectedDate
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                previousDate = selectedDate
                selectedDate = normalizedTimelineDate(tomorrow)
                lastDateNavMethod = "next"
                AnalyticsService.shared.capture("date_navigation", [
                    "method": "next",
                    "from_day": dayString(from),
                    "to_day": dayString(tomorrow)
                ])
            } content: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(
                        canNavigateForward(from: selectedDate)
                        ? Color(red: 0.3, green: 0.3, blue: 0.3)
                        : Color.gray.opacity(0.3)
                    )
            }
        }
    }

    private func formatDateForDisplay(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let formatter = DateFormatter()

        let displayDate = timelineDisplayDate(from: date, now: now)
        let timelineToday = timelineDisplayDate(from: now, now: now)

        if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
            formatter.dateFormat = "'Today,' MMM d"
        } else {
            formatter.dateFormat = "E, MMM d"
        }

        return formatter.string(from: displayDate)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func calculateOptimalPillWidth() -> CGFloat {
        let sampleText = "Today, Sep 30"
        let nsFont = NSFont(name: "InstrumentSerif-Regular", size: 18) ?? NSFont.systemFont(ofSize: 18)
        let textSize = sampleText.size(withAttributes: [.font: nsFont])
        let horizontalPadding: CGFloat = 11.77829 * 2
        return textSize.width + horizontalPadding + 8
    }
} // End of MainView struct

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

extension MainView {
    private func startDayChangeTimer() {
        stopDayChangeTimer()
        dayChangeTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            handleMinuteTickForDayChange()
        }
    }

    private func stopDayChangeTimer() {
        dayChangeTimer?.invalidate()
        dayChangeTimer = nil
    }

    private func handleMinuteTickForDayChange() {
        // Detect civil day rollover regardless of what day user is viewing
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let currentCivilDay = fmt.string(from: Date())
        if currentCivilDay != lastObservedCivilDay {
            lastObservedCivilDay = currentCivilDay

            // Jump to current civil day and re-scroll near now
            setSelectedDate(timelineDisplayDate(from: Date()))
            selectedActivity = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    scrollToNowTick &+= 1
                }
            }
        }
    }

    private func performIdleResetAndScroll() {
        // Switch to today
        setSelectedDate(timelineDisplayDate(from: Date()))
        // Clear selection
        selectedActivity = nil
        // Nudge timeline to scroll to now after it reloads
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            #if DEBUG
            print("[MainView] performIdleResetAndScroll -> nudging scrollToNowTick")
            #endif
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollToNowTick &+= 1
            }
        }
    }
    
    private func performInitialScrollIfNeeded() {
        // Check all conditions for initial scroll:
        // 1. Timeline is visible (not in settings)
        // 2. No modal is open
        // 3. Selected date is today
        guard selectedIcon != .settings,
              !showDatePicker,
              timelineIsToday(selectedDate) else {
            return
        }
        
        // Mark that we've attempted initial scroll
        didInitialScroll = true
        
        // Wait for layout to settle after animations complete
        // Increased delay to ensure ScrollView is fully ready on cold start
        #if DEBUG
        print("[MainView] performInitialScrollIfNeeded scheduled with 1.5s delay")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            #if DEBUG
            print("[MainView] performInitialScrollIfNeeded firing -> nudging scrollToNowTick")
            #endif
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollToNowTick &+= 1
            }
        }
    }
}

struct ActivityCard: View {
    let activity: TimelineActivity?
    var maxHeight: CGFloat? = nil
    var scrollSummary: Bool = false
    var hasAnyActivities: Bool = true
    var onCategorySwap: (() -> Void)? = nil
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var categoryStore: CategoryStore

    @State private var isRetrying = false
    @State private var retryProgress: String = ""
    @State private var retryError: String? = nil

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
    
    var body: some View {
        if let activity = activity {
            VStack(alignment: .leading, spacing: DesignSpacing.md) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                        Text(activity.title)
                            .font(.custom(DesignTypography.bodyFont, size: DesignTypography.headline))
                            .fontWeight(.semibold)
                            .foregroundColor(DesignColors.primaryText)

                        Text("\(timeFormatter.string(from: activity.startTime)) to \(timeFormatter.string(from: activity.endTime))")
                            .font(.custom(DesignTypography.bodyFont, size: DesignTypography.caption))
                            .foregroundColor(DesignColors.secondaryText)
                    }

                    Spacer()

                    // Retry button centered between title and time (only for failed cards)
                    if isFailedCard(activity) {
                        retryButtonInline(for: activity)
                    }
                }

                // Error message (if retry failed)
                if isFailedCard(activity), let error = retryError {
                    UnifiedCard(style: .minimal, padding: DesignSpacing.sm) {
                        HStack(alignment: .top, spacing: DesignSpacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(DesignColors.errorRed)
                                .font(.system(size: 12))

                            Text(error)
                                .font(.custom(DesignTypography.bodyFont, size: DesignTypography.caption))
                                .foregroundColor(DesignColors.secondaryText)
                                .lineLimit(2)
                        }
                    }
                }

                // Video thumbnail placeholder
                if let videoURL = activity.videoSummaryURL {
                    VideoThumbnailView(
                        videoURL: videoURL,
                        title: activity.title,
                        startTime: activity.startTime,
                        endTime: activity.endTime
                    )
                        .id(videoURL)
                        .frame(height: 200)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.1))
                        .frame(height: 200)
                        .overlay(
                            VStack {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray.opacity(0.5))
                                Text("No video available")
                                    .font(.caption)
                                    .foregroundColor(.gray.opacity(0.5))
                            }
                        )
                }
                
                // Summary section (scrolls internally when constrained)
                Group {
                    if scrollSummary {
                        ScrollView(.vertical, showsIndicators: false) {
                            summaryContent(for: activity)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .id(activity.id) // Reset scroll position whenever the selected activity changes
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        summaryContent(for: activity)
                    }
                }
            }
            .padding(16)
            .if(maxHeight != nil) { view in
                view.frame(maxHeight: maxHeight!)
            }
        } else {
            // Empty state
            VStack(spacing: 10) {
                Spacer()
                if hasAnyActivities {
                    Text("Select an activity to view details")
                        .font(.custom("Nunito", size: 15))
                        .fontWeight(.regular)
                        .foregroundColor(.gray.opacity(0.5))
                } else {
                    if appState.isRecording {
                        VStack(spacing: 6) {
                            Text("No cards yet")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.7))
                            Text("Cards are generated about every 15 minutes. If Dayflow is on and no cards show up within 30 minutes, please report a bug.")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.gray.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Text("Recording is off")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.7))
                            Text("Dayflow recording is currently turned off, so cards aren’t being produced.")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.gray.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .if(maxHeight != nil) { view in
                view.frame(maxHeight: maxHeight!)
            }
        }
    }

    @ViewBuilder
    private func summaryContent(for activity: TimelineActivity) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.sm) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                Text("SUMMARY")
                    .font(.custom(DesignTypography.bodyFont, size: DesignTypography.caption))
                    .fontWeight(.semibold)
                    .foregroundColor(DesignColors.tertiaryText)

                renderMarkdownText(activity.summary)
                    .font(.custom(DesignTypography.bodyFont, size: DesignTypography.body))
                    .foregroundColor(DesignColors.primaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !activity.detailedSummary.isEmpty && activity.detailedSummary != activity.summary {
                VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                    Text("DETAILED SUMMARY")
                        .font(.custom(DesignTypography.bodyFont, size: DesignTypography.caption))
                        .fontWeight(.semibold)
                        .foregroundColor(DesignColors.tertiaryText)

                    renderMarkdownText(activity.detailedSummary)
                        .font(.custom(DesignTypography.bodyFont, size: DesignTypography.body))
                        .foregroundColor(DesignColors.primaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func renderMarkdownText(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: content, options: options) {
            return Text(parsed)
        }
        return Text(content)
    }

    private func categoryBadge(for raw: String) -> (name: String, indicator: Color)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        let categories = categoryStore.categories
        let matched = categories.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }
        guard let category = matched ?? categories.first else { return nil }

        let nsColor = NSColor(hex: category.colorHex) ?? NSColor(hex: "#4F80EB") ?? .systemBlue
        return (name: category.name, indicator: Color(nsColor: nsColor))
    }

    // MARK: - Retry Functionality

    private func isFailedCard(_ activity: TimelineActivity) -> Bool {
        return activity.title == "Processing failed"
    }

    @ViewBuilder
    private func retryButtonInline(for activity: TimelineActivity) -> some View {
        if isRetrying {
            // Processing state - secondary button with spinner
            Button(action: {}) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Processing")
                }
                .font(.custom("Nunito", size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .disabled(true)
            .opacity(0.7)
        } else {
            // Retry button - primary button
            DayflowButton(title: "Retry") {
                handleRetry(for: activity)
            }
        }
    }

    private func handleRetry(for activity: TimelineActivity) {
        guard let batchId = activity.batchId else {
            retryError = "Cannot retry: batch information missing"
            return
        }

        isRetrying = true
        retryProgress = "Preparing to retry..."
        retryError = nil

        AnalysisManager.shared.reprocessSpecificBatches(
            [batchId],
            progressHandler: { progress in
                DispatchQueue.main.async {
                    self.retryProgress = progress
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    self.isRetrying = false

                    switch result {
                    case .success:
                        self.retryProgress = ""
                        self.retryError = nil
                        // Timeline will auto-refresh when batch completes

                    case .failure(let error):
                        self.retryProgress = ""
                        self.retryError = "Retry failed: \(error.localizedDescription)"

                        // Clear error after 10 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            self.retryError = nil
                        }
                    }
                }
            }
        )
    }
}

struct MetricRow: View {
    let label: String
    let value: Int
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(label)
                .font(.custom(DesignTypography.bodyFont, size: DesignTypography.caption2))
                .fontWeight(.medium)
                .foregroundColor(DesignColors.tertiaryText)

            HStack {
                Text("\(value)%")
                    .font(.custom(DesignTypography.bodyFont, size: DesignTypography.headline))
                    .fontWeight(.semibold)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: DesignRadius.small)
                            .fill(DesignColors.tertiaryText.opacity(0.2))
                            .frame(height: DesignSpacing.xs)

                        RoundedRectangle(cornerRadius: DesignRadius.small)
                            .fill(color)
                            .frame(width: geometry.size.width * CGFloat(value) / 100, height: DesignSpacing.xs)
                    }
                }
                .frame(height: DesignSpacing.xs)
            }
        }
    }
}

// Background view moved to separate file: MainUIBackgroundView.swift

func canNavigateForward(from date: Date, now: Date = Date()) -> Bool {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
    let timelineToday = timelineDisplayDate(from: now, now: now)
    return calendar.compare(tomorrow, to: timelineToday, toGranularity: .day) != .orderedDescending
}

func normalizedTimelineDate(_ date: Date) -> Date {
    let calendar = Calendar.current
    if let normalized = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) {
        return normalized
    }
    let startOfDay = calendar.startOfDay(for: date)
    return calendar.date(byAdding: DateComponents(hour: 12), to: startOfDay) ?? date
}

func timelineDisplayDate(from date: Date, now: Date = Date()) -> Date {
    let calendar = Calendar.current
    var normalizedDate = normalizedTimelineDate(date)
    let normalizedNow = normalizedTimelineDate(now)
    let nowHour = calendar.component(.hour, from: now)

    if nowHour < 4 && calendar.isDate(normalizedDate, inSameDayAs: normalizedNow) {
        normalizedDate = calendar.date(byAdding: .day, value: -1, to: normalizedDate) ?? normalizedDate
    }

    return normalizedDate
}

func timelineIsToday(_ date: Date, now: Date = Date()) -> Bool {
    let calendar = Calendar.current
    let timelineDate = timelineDisplayDate(from: date, now: now)
    let timelineToday = timelineDisplayDate(from: now, now: now)
    return calendar.isDate(timelineDate, inSameDayAs: timelineToday)
}
