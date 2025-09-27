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

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var categoryStore: CategoryStore
    @State private var selectedIcon: SidebarIcon = .timeline
    @State private var selectedDate = Date()
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
    
    // Track if we've performed the initial scroll to current time
    @State private var didInitialScroll = false
    @State private var previousDate = Date()
    @State private var lastDateNavMethod: String? = nil
    // Minute tick to handle civil-day rollover (header updates + jump to today)
    @State private var dayChangeTimer: Timer? = nil
    @State private var lastObservedCivilDay: String = {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; return fmt.string(from: Date())
    }()
    @State private var showCategoryEditor = false
    
    var body: some View {
        // Two-column layout: left logo + sidebar; right white panel with header, filters, timeline
        HStack(alignment: .top, spacing: 0) {
            // Left column: Logo on top, sidebar centered
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

            // Right column: Main white panel including header + content
            ZStack {
                switch selectedIcon {
                case .settings:
                    SettingsView()
                        .padding(15)
                case .dashboard:
                    DashboardView()
                        .padding(15)
                case .journal:
                    JournalView()
                        .padding(15)
                case .bug:
                    BugReportView()
                        .padding(15)
                case .timeline:
                    VStack(alignment: .leading, spacing: 20) {
                        // Header: Timeline title + Recording toggle (date controls moved to chips row)
                        HStack(alignment: .top) {
                            Text("Timeline")
                                .font(.custom("InstrumentSerif-Regular", size: 42))
                                .foregroundColor(Color.black)
                                .offset(x: timelineOffset)
                                .opacity(timelineOpacity)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 10) {
                                // Recording toggle (kept alongside header)
                                HStack(spacing: 8) {
                                    Text("Recording")
                                        .font(
                                            Font.custom("Nunito", size: 14)
                                                .weight(.semibold)
                                        )
                                        .foregroundColor(.black)

                                    Toggle("Recording", isOn: $appState.isRecording)
                                        .labelsHidden()
                                        .toggleStyle(SunriseGlassPillToggleStyle())
                                        .accessibilityLabel(Text("Recording"))
                                }

                                DateNavigationControls(
                                    selectedDate: $selectedDate,
                                    showDatePicker: $showDatePicker,
                                    lastDateNavMethod: $lastDateNavMethod,
                                    previousDate: $previousDate
                                )
                            }
                        }
                        .padding(.horizontal, 10)

                        // Content area: Left (chips + timeline) and Right (summary)
                        GeometryReader { geo in
                            HStack(alignment: .top, spacing: 20) {
                                // Left column: chips row at top, timeline below
                                VStack(alignment: .leading, spacing: 12) {
                                    TabFilterBar(
                                        categories: categoryStore.editableCategories,
                                        idleCategory: categoryStore.idleCategory,
                                        onManageCategories: { showCategoryEditor = true }
                                    )
                                        .padding(.leading, 2)
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

                                // Right column: activity detail card — constrained height with internal scrolling for summary
                                ActivityCard(
                                    activity: selectedActivity,
                                    maxHeight: geo.size.height,
                                    scrollSummary: true,
                                    hasAnyActivities: hasAnyActivities
                                )
                                    .frame(minWidth: 260, idealWidth: 380, maxWidth: 420)
                                    .opacity(contentOpacity)
                            }
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        }
                    }
                    .padding(15)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14.72286, style: .continuous)
                    .fill(Color.white.opacity(0.2))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14.72286, style: .continuous))
            // No outline stroke — clean white panel
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(selectedDate: $selectedDate, isPresented: $showDatePicker)
        }
        .onAppear {
            // screen viewed and initial timeline view
            AnalyticsService.shared.screen("timeline")
            AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(selectedDate)])
            // Orchestrated entrance animations following Emil Kowalski principles
            // Fast, under 300ms, natural spring motion
            
            // Logo appears first with scale and fade
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)) {
                logoScale = 1.0
                logoOpacity = 1
            }
            
            // Timeline text slides in from left
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.1)) {
                timelineOffset = 0
                timelineOpacity = 1
            }
            
            // Sidebar slides up
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.15)) {
                sidebarOffset = 0
                sidebarOpacity = 1
            }
            
            // Main content fades in last
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.2)) {
                contentOpacity = 1
            }
            
            // Perform initial scroll to current time on cold start
            if !didInitialScroll {
                performInitialScrollIfNeeded()
            }

            // Start minute-level tick to detect civil-day rollover (midnight)
            startDayChangeTimer()
        }
        // Trigger reset when idle fired and timeline is visible
        .onChange(of: inactivity.pendingReset) { fired in
            if fired, selectedIcon != .settings {
                performIdleResetAndScroll()
                InactivityMonitor.shared.markHandledIfPending()
            }
        }
        .onChange(of: selectedIcon) { newIcon in
            // tab selected + screen viewed
            let tabName: String
            switch newIcon {
            case .timeline: tabName = "timeline"
            case .dashboard: tabName = "dashboard"
            case .journal: tabName = "journal"
            case .bug: tabName = "bug_report"
            case .settings: tabName = "settings"
            }
            AnalyticsService.shared.capture("tab_selected", ["tab": tabName])
            AnalyticsService.shared.screen(tabName)
            if newIcon == .timeline {
                AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(selectedDate)])
            }
        }
        .onChange(of: selectedDate) { newDate in
            // If changed via picker, emit navigation now
            if let method = lastDateNavMethod, method == "picker" {
                AnalyticsService.shared.capture("date_navigation", [
                    "method": method,
                    "from_day": dayString(previousDate),
                    "to_day": dayString(newDate)
                ])
            }
            previousDate = newDate
            AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(newDate)])
        }
        .onChange(of: selectedActivity?.id) { _ in
            guard let a = selectedActivity else { return }
            let dur = a.endTime.timeIntervalSince(a.startTime)
            AnalyticsService.shared.capture("activity_card_opened", [
                "activity_type": a.category,
                "duration_bucket": AnalyticsService.shared.secondsBucket(dur),
                "has_video": a.videoSummaryURL != nil
            ])
        }
        // If user returns from Settings and a reset was pending, perform it once
        .onChange(of: selectedIcon) { newIcon in
            if newIcon != .settings, inactivity.pendingReset {
                performIdleResetAndScroll()
                InactivityMonitor.shared.markHandledIfPending()
            }
        }
        .onDisappear {
            // Safety: stop timer if view disappears
            stopDayChangeTimer()
        }
        .overlay {
            if showCategoryEditor {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            showCategoryEditor = false
                        }

                    ColorOrganizerRoot(
                        backgroundStyle: .color(.clear),
                        onDismiss: { showCategoryEditor = false }
                    )
                    .environmentObject(categoryStore)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Block tap from reaching backdrop
                    }
                }
            }
        }
    }
    
    private func formatDateForDisplay(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today,' MMM d"
        } else {
            formatter.dateFormat = "E, MMM d"
        }

        return formatter.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum SidebarIcon: CaseIterable {
    case timeline
    case dashboard
    case journal
    case bug
    case settings

    var assetName: String? {
        switch self {
        case .timeline: return "TimelineIcon"
        case .dashboard: return "DashboardIcon"
        case .journal: return "JournalIcon"
        case .bug: return nil
        case .settings: return nil
        }
    }

    var systemNameFallback: String? {
        switch self {
        case .bug: return "exclamationmark.bubble"
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
                        .foregroundColor(isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else if let sys = icon.systemNameFallback {
                    Image(systemName: sys)
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
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

    private let chipRowHeight: CGFloat = 44
    private let chipVerticalPadding: CGFloat = 6

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(categories) { category in
                            CategoryChip(category: category, isIdle: false)
                        }

                        if let idleCategory {
                            CategoryChip(category: idleCategory, isIdle: true)
                        }
                    }
                    .padding(.vertical, chipVerticalPadding)
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                }
                .frame(height: chipRowHeight)
                .background(Color.clear)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: chipRowHeight + 18, height: chipRowHeight)
                        .allowsHitTesting(false)
                }

                Button(action: onManageCategories) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.black.opacity(0.75))
                        .frame(
                            width: chipRowHeight - (chipVerticalPadding * 2),
                            height: chipRowHeight - (chipVerticalPadding * 2)
                        )
                        .background(Color.white.opacity(0.95))
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }
            .frame(height: chipRowHeight)
        }
        .padding(.leading, 15)
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
                selectedDate = to
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
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                if tomorrow <= Date() {
                    let from = selectedDate
                    previousDate = selectedDate
                    selectedDate = tomorrow
                    lastDateNavMethod = "next"
                    AnalyticsService.shared.capture("date_navigation", [
                        "method": "next",
                        "from_day": dayString(from),
                        "to_day": dayString(tomorrow)
                    ])
                }
            } content: {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(tomorrow > Date() ? Color.gray.opacity(0.3) : Color(red: 0.3, green: 0.3, blue: 0.3))
            }
        }
    }

    private func formatDateForDisplay(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today,' MMM d"
        } else {
            formatter.dateFormat = "E, MMM d"
        }

        return formatter.string(from: date)
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
}

private extension TabFilterBar {
    struct CategoryChip: View {
        let category: TimelineCategory
        let isIdle: Bool

        var body: some View {
            let baseColor = Color(hex: category.colorHex)
            let textColor = isIdle ? baseColor : adaptiveTextColor(for: category.colorHex)
            let pillCornerRadius: CGFloat = 1000

            return Text(category.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Group {
                        if isIdle {
                            Color.white.opacity(0.8)
                        } else {
                            baseColor.opacity(0.9)
                        }
                    }
                )
                .foregroundColor(textColor)
                .overlay(
                    RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                        .stroke(borderColor(for: baseColor, isIdle: isIdle), style: borderStyle(for: isIdle))
                )
                .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous))
        }

        private func borderColor(for color: Color, isIdle: Bool) -> Color {
            if isIdle {
                return color.opacity(0.6)
            }
            return Color.white.opacity(0.2)
        }

        private func borderStyle(for isIdle: Bool) -> StrokeStyle {
            if isIdle {
                return StrokeStyle(lineWidth: 1.2, dash: [4, 2])
            }
            return StrokeStyle(lineWidth: 1)
        }

        private func adaptiveTextColor(for hex: String) -> Color {
            guard let nsColor = NSColor(hex: hex) else { return .white }
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            nsColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
            let brightness = (0.299 * r) + (0.587 * g) + (0.114 * b)
            return brightness > 0.6 ? Color.black.opacity(0.8) : .white
        }
    }
}

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
            selectedDate = Date()
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
        selectedDate = Date()
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
              Calendar.current.isDateInToday(selectedDate) else {
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
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var categoryStore: CategoryStore

    // Reprocessing state
    @State private var isReprocessing: Bool = false
    @State private var reprocessingProgress: String = ""
    @State private var showProgressModal: Bool = false
    @State private var reprocessingError: String? = nil
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
    
    var body: some View {
        if let activity = activity {
            VStack(alignment: .leading, spacing: 16) {
                // Header (icon removed by request)
                HStack {
                    Text(activity.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.black)
                    Spacer()
                }

                if let badge = categoryBadge(for: activity.category) {
                    HStack {
                        Text(badge.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(badge.textColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(badge.background)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                }

                Text("\(timeFormatter.string(from: activity.startTime)) to \(timeFormatter.string(from: activity.endTime))")
                    .font(.caption)
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                
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
            .padding(20)
            .background(Color.white)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(hex: "E5E5E5"), lineWidth: 1)
            )
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(hex: "E5E5E5"), lineWidth: 1)
            )
            .if(maxHeight != nil) { view in
                view.frame(maxHeight: maxHeight!)
            }
            .overlay {
                if showProgressModal {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()

                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .progressViewStyle(CircularProgressViewStyle())

                            Text(reprocessingProgress)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.black)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)

                            if let error = reprocessingError {
                                Button("Dismiss") {
                                    showProgressModal = false
                                    reprocessingError = nil
                                    reprocessingProgress = ""
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(6)
                            }
                        }
                        .padding(24)
                        .background(Color.white)
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryContent(for activity: TimelineActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUMMARY")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
            
            Text(activity.summary)
                .font(.system(size: 12))
                .foregroundColor(.black)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            
            if !activity.detailedSummary.isEmpty && activity.detailedSummary != activity.summary {
                Text("DETAILED SUMMARY")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
                    .padding(.top, 8)

                Text(activity.detailedSummary)
                    .font(.system(size: 12))
                    .foregroundColor(.black)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // Show reprocessing buttons for failed processing cards
            if activity.title == "Processing failed", let batchId = activity.batchId {
                reprocessingButtons(for: activity, batchId: batchId)
            }
        }
    }

    @ViewBuilder
    private func reprocessingButtons(for activity: TimelineActivity, batchId: Int64) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("REPROCESSING")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
                .padding(.top, 8)

            VStack(spacing: 8) {
                Button(action: {
                    reprocessBatch(batchId: batchId)
                }) {
                    HStack {
                        if isReprocessing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        Text(isReprocessing ? "Processing..." : "Reprocess This Batch")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isReprocessing ? Color.blue.opacity(0.6) : Color.blue)
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isReprocessing)

                Button(action: {
                    reprocessDay(for: activity)
                }) {
                    HStack {
                        if isReprocessing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 12))
                        }
                        Text(isReprocessing ? "Processing..." : "Reprocess Entire Day")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(isReprocessing ? .blue.opacity(0.6) : .blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isReprocessing)
            }
        }
    }

    // MARK: - Reprocessing Functions

    private func reprocessBatch(batchId: Int64) {
        guard !isReprocessing else { return }

        isReprocessing = true
        reprocessingError = nil
        showProgressModal = true
        reprocessingProgress = "Starting batch reprocessing..."

        AnalysisManager.shared.reprocessSpecificBatches([batchId], progressHandler: { progress in
            DispatchQueue.main.async {
                self.reprocessingProgress = progress
            }
        }, completion: { result in
            DispatchQueue.main.async {
                self.isReprocessing = false

                switch result {
                case .success:
                    self.reprocessingProgress = "✅ Batch reprocessing completed successfully!"
                    // Auto-hide modal after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.showProgressModal = false
                        self.reprocessingProgress = ""
                    }
                case .failure(let error):
                    self.reprocessingError = error.localizedDescription
                    self.reprocessingProgress = "❌ Reprocessing failed: \(error.localizedDescription)"
                }
            }
        })
    }

    private func reprocessDay(for activity: TimelineActivity) {
        guard !isReprocessing else { return }

        // Convert activity start time to day string
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dayString = formatter.string(from: activity.startTime)

        isReprocessing = true
        reprocessingError = nil
        showProgressModal = true
        reprocessingProgress = "Starting day reprocessing for \(dayString)..."

        AnalysisManager.shared.reprocessDay(dayString, progressHandler: { progress in
            DispatchQueue.main.async {
                self.reprocessingProgress = progress
            }
        }, completion: { result in
            DispatchQueue.main.async {
                self.isReprocessing = false

                switch result {
                case .success:
                    self.reprocessingProgress = "✅ Day reprocessing completed successfully!"
                    // Auto-hide modal after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.showProgressModal = false
                        self.reprocessingProgress = ""
                    }
                case .failure(let error):
                    self.reprocessingError = error.localizedDescription
                    self.reprocessingProgress = "❌ Reprocessing failed: \(error.localizedDescription)"
                }
            }
        })
    }

    private func categoryBadge(for raw: String) -> (name: String, background: Color, textColor: Color)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        let categories = categoryStore.categories
        let matched = categories.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }
        guard let category = matched ?? categories.first else { return nil }

        let nsColor = NSColor(hex: category.colorHex) ?? NSColor(hex: "#4F80EB") ?? .systemBlue
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let brightness = (0.299 * r) + (0.587 * g) + (0.114 * b)

        let background: Color
        let textColor: Color
        if category.isIdle {
            background = Color.white.opacity(0.8)
            textColor = Color(nsColor: nsColor).opacity(0.9)
        } else {
            background = Color(nsColor: nsColor).opacity(0.85)
            textColor = brightness > 0.6 ? Color.black.opacity(0.8) : .white
        }

        return (name: category.name, background: background, textColor: textColor)
    }
}

struct MetricRow: View {
    let label: String
    let value: Int
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
            
            HStack {
                Text("\(value)%")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .frame(width: geometry.size.width * CGFloat(value) / 100, height: 8)
                    }
                }
                .frame(height: 8)
            }
        }
    }
}

// Background view moved to separate file: MainUIBackgroundView.swift
