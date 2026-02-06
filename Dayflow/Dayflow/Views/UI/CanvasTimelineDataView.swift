import SwiftUI
import AppKit
import Foundation

// MARK: - Cached DateFormatters (creating DateFormatters is expensive due to ICU initialization)

private let cachedDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let cachedTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private struct CanvasConfig {
    static let hourHeight: CGFloat = 144           // 144px per hour (Canvas look)
    static let pixelsPerMinute: CGFloat = 2.4      // 2.4px = 1 minute (Canvas look)
    static let timeColumnWidth: CGFloat = 60
    static let startHour: Int = 4                  // 4 AM baseline
    static let endHour: Int = 28                   // 4 AM next day
}

struct TimelineTimeLabelFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
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
}

struct CanvasTimelineDataView: View {
    @Binding var selectedDate: Date
    @Binding var selectedActivity: TimelineActivity?
    @Binding var scrollToNowTick: Int
    @Binding var hasAnyActivities: Bool
    @Binding var refreshTrigger: Int

    @State private var selectedCardId: String? = nil
    @State private var positionedActivities: [CanvasPositionedActivity] = []
    @State private var refreshTimer: Timer?
    @State private var didInitialScrollInView: Bool = false
    @State private var isBreathing = false
    @State private var loadTask: Task<Void, Never>?
    // Staggered entrance animation state (Emil Kowalski principle: sequential reveal)
    @State private var cardEntranceProgress: [String: Bool] = [:]
    @EnvironmentObject private var categoryStore: CategoryStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var retryCoordinator: RetryCoordinator

    private let storageManager = StorageManager.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                timelineScrollContent()
            }
            .background(Color.clear)
            // Respond to external scroll nudges (initial or idle-triggered)
            .onChange(of: scrollToNowTick) {
                // Calculate which hour to scroll to for 80% positioning
                let currentHour = Calendar.current.component(.hour, from: Date())
                let hoursSince4AM = currentHour >= 4 ? currentHour - 4 : (24 - 4) + currentHour
                let targetHourIndex = max(0, min(hoursSince4AM, 24) - 2) // 2 hours before current

                // Scroll to the hour marker with 30-minute offset for better positioning
                proxy.scrollTo("hour-\(targetHourIndex)", anchor: UnitPoint(x: 0, y: 0.25))
            }
            // Scroll once right after activities are first loaded and laid out
            .onChange(of: positionedActivities.count) {
                guard !didInitialScrollInView, timelineIsToday(selectedDate) else { return }
                didInitialScrollInView = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Calculate which hour to scroll to for 80% positioning
                    let currentHour = Calendar.current.component(.hour, from: Date())
                    let hoursSince4AM = currentHour >= 4 ? currentHour - 4 : (24 - 4) + currentHour
                    let targetHourIndex = max(0, hoursSince4AM - 2) // 2 hours before current for 80% positioning
                    // 30-minute offset: y: 0.25 positions hour 25% down from top
                    proxy.scrollTo("hour-\(targetHourIndex)", anchor: UnitPoint(x: 0, y: 0.25))
                }
            }
            // Ensure we scroll on first appearance when viewing Today
            .onAppear {
                if timelineIsToday(selectedDate) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        // Calculate which hour to scroll to for 80% positioning
                        let currentHour = Calendar.current.component(.hour, from: Date())
                        let hoursSince4AM = currentHour >= 4 ? currentHour - 4 : (24 - 4) + currentHour
                        let targetHourIndex = max(0, hoursSince4AM - 2) // 2 hours before current for 80% positioning
                        // 30-minute offset: y: 0.25 positions hour 25% down from top
                    proxy.scrollTo("hour-\(targetHourIndex)", anchor: UnitPoint(x: 0, y: 0.25))
                    }
                }
            }
            // When the selected date changes back to Today (e.g., after idle), also scroll
            .onChange(of: selectedDate) { _, newDate in
                if timelineIsToday(newDate) {
                    didInitialScrollInView = false // allow the data-ready scroll to fire again
                    // Give the layout a moment to update before scrolling
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            // Calculate which hour to scroll to for 80% positioning
                            let currentHour = Calendar.current.component(.hour, from: Date())
                            let hoursSince4AM = currentHour >= 4 ? currentHour - 4 : (24 - 4) + currentHour
                            let targetHourIndex = max(0, hoursSince4AM - 2) // 2 hours before current for 80% positioning
                            // 30-minute offset: y: 0.25 positions hour 25% down from top
                    proxy.scrollTo("hour-\(targetHourIndex)", anchor: UnitPoint(x: 0, y: 0.25))
                        }
                    }
                }
            }
        }
        .background(Color.clear)
        .onAppear {
            loadActivities()
            startRefreshTimer()
        }
        .onDisappear {
            stopRefreshTimer()
            loadTask?.cancel()
            loadTask = nil
        }
        .onChange(of: selectedDate) {
            loadActivities()
        }
        .onChange(of: refreshTrigger) {
            loadActivities()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loadActivities(animate: false)
            if refreshTimer == nil {
                startRefreshTimer()
            }
            AnalyticsService.shared.capture("app_became_active", [
                "screen": "timeline",
                "selected_date_is_today": timelineIsToday(selectedDate)
            ])
        }
    }

    @ViewBuilder
    private func timelineScrollContent() -> some View {
        ZStack(alignment: .topLeading) {
            // Transparent background to let panel show through
            Color.clear
            // Invisible anchor positioned for "now" scroll target
            nowAnchorView()
                .zIndex(-1) // Behind other content

            // Hour lines layer
            hourLines
                .padding(.leading, CanvasConfig.timeColumnWidth)

            // Current time indicator
            currentTimeIndicator

            // Main content with time labels and cards
            mainTimelineRow
        }
        .frame(height: CGFloat(CanvasConfig.endHour - CanvasConfig.startHour) * CanvasConfig.hourHeight)
        .background(Color.clear)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<(CanvasConfig.endHour - CanvasConfig.startHour), id: \.self) { _ in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(hex: "E2A97B"))
                        .frame(height: 1)
                    Spacer()
                }
                .frame(height: CanvasConfig.hourHeight)
            }
        }
    }

    private var timeColumn: some View {
        VStack(spacing: 0) {
            ForEach(CanvasConfig.startHour..<CanvasConfig.endHour, id: \.self) { hour in
                let hourIndex = hour - CanvasConfig.startHour
                Text(formatHour(hour))
                    .font(.custom("Figtree", size: 13))
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
                    .frame(height: CanvasConfig.hourHeight, alignment: .top)
                    .offset(y: -8)
                    .id("hour-\(hourIndex)")
            }
        }
        .frame(width: CanvasConfig.timeColumnWidth)
    }

    private var cardsLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(positionedActivities.enumerated()), id: \.element.id) { index, item in
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
                            selectedCardId = nil
                            selectedActivity = nil
                        } else {
                            selectedCardId = item.id
                            selectedActivity = item.activity
                        }
                    },
                    faviconPrimaryRaw: item.faviconPrimaryRaw,
                    faviconSecondaryRaw: item.faviconSecondaryRaw,
                    faviconPrimaryHost: item.faviconPrimaryHost,
                    faviconSecondaryHost: item.faviconSecondaryHost,
                    statusLine: retryCoordinator.statusLine(for: item.activity.batchId)
                )
                .frame(height: item.height)
                .offset(y: item.yPosition)
                // Staggered entrance animation (Emil Kowalski: sequential reveal creates polish)
                .opacity(isVisible ? 1 : 0)
                .offset(x: isVisible ? 0 : 12)
                .animation(
                    .spring(response: 0.35, dampingFraction: 0.8)
                        .delay(Double(index) * 0.03), // 30ms stagger between cards
                    value: isVisible
                )
            }
        }
        .clipped() // Prevent shadows/animations from affecting scroll geometry
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var mainTimelineRow: some View {
        HStack(spacing: 0) {
            timeColumn
            cardsLayer
        }
    }

    @ViewBuilder
    private var currentTimeIndicator: some View {
        if timelineIsToday(selectedDate) {
            VStack(alignment: .leading, spacing: 5) {
                // Horizontal line with circle on left edge
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(hex: "FF986C"))
                        .frame(maxWidth: .infinity, maxHeight: 1)

                    ZStack {
                        // Outer glow layer - intense red pulse
                        Circle()
                            .fill(Color(hex: "FF5D44"))
                            .frame(width: 7, height: 7)
                            .blur(radius: isBreathing ? 8 : 3)
                            .opacity(isBreathing ? 0.8 : 0.4)
                            .scaleEffect(isBreathing ? 2.0 : 1.2)

                        // Mid glow layer
                        Circle()
                            .fill(Color(hex: "FF5D44"))
                            .frame(width: 7, height: 7)
                            .blur(radius: isBreathing ? 5 : 2)
                            .opacity(isBreathing ? 0.9 : 0.5)
                            .scaleEffect(isBreathing ? 1.6 : 1.1)

                        // Core dot - stays solid
                        Circle()
                            .fill(Color(hex: "FF5D44"))
                            .frame(width: 7, height: 7)
                            .scaleEffect(isBreathing ? 1.1 : 1.0)
                    }
                    .animation(
                        isBreathing
                            ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.3),
                        value: isBreathing
                    )
                }
                .frame(height: 1)
                .onAppear {
                    // Delay setting isBreathing to allow the view to settle first
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isBreathing = appState.isRecording
                    }
                }
                .onChange(of: appState.isRecording) { _, newValue in
                    isBreathing = newValue
                }

                // Status text
                Text(appState.isRecording
                    ? "Recording is in process. The timeline will update every 20-25 minutes."
                    : "Dayflow is paused.")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(Color(red: 0.62, green: 0.44, blue: 0.36))
                    .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: calculateYPosition(for: Date()))
            .padding(.leading, CanvasConfig.timeColumnWidth)
            .allowsHitTesting(false) // Don't interfere with card interactions
        }
    }


    private func loadActivities(animate: Bool = true) {
        // Cancel any in-flight database read to prevent query pileup
        loadTask?.cancel()

        loadTask = Task.detached(priority: .userInitiated) {
            let calendar = Calendar.current

            // Normalize to noon so time components do not leak into day jumps
            var logicalDate = await self.selectedDate
            logicalDate = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: logicalDate) ?? logicalDate

            // Derive the effective timeline day (handles the 4 AM boundary for "today")
            let timelineDate = timelineDisplayDate(from: logicalDate, now: Date())

            let dayString = cachedDayFormatter.string(from: timelineDate)

            // Check for cancellation before expensive database read
            guard !Task.isCancelled else { return }

            let timelineCards = self.storageManager.fetchTimelineCards(forDay: dayString)
            let activities = self.processTimelineCards(timelineCards, for: timelineDate)

            // Check for cancellation before expensive processing
            guard !Task.isCancelled else { return }

            // Mitigation transform: resolve visual overlaps by trimming larger cards
            // so that smaller cards "win". This is a display-only fix to handle
            // upstream card-generation overlap bugs without touching stored data.
            let segments = self.resolveOverlapsForDisplay(activities)

            let positioned = segments.map { seg -> CanvasPositionedActivity in
                let y = self.calculateYPosition(for: seg.start)
                // Card spacing: -2 total (1px top + 1px bottom)
                let durationMinutes = max(0, seg.end.timeIntervalSince(seg.start) / 60)
                let rawHeight = CGFloat(durationMinutes) * CanvasConfig.pixelsPerMinute
                let height = max(10, rawHeight - 2)
                // Raw values for pattern matching, normalized for network fetch
                let primaryRaw = seg.activity.appSites?.primary
                let secondaryRaw = seg.activity.appSites?.secondary
                let primaryHost = self.normalizeHost(primaryRaw)
                let secondaryHost = self.normalizeHost(secondaryRaw)

                return CanvasPositionedActivity(
                    id: seg.activity.id,
                    activity: seg.activity,
                    yPosition: y + 1, // 1px top spacing
                    height: height,
                    durationMinutes: durationMinutes,
                    title: seg.activity.title,
                    timeLabel: self.formatRange(start: seg.start, end: seg.end),
                    categoryName: seg.activity.category,
                    faviconPrimaryRaw: primaryRaw,
                    faviconSecondaryRaw: secondaryRaw,
                    faviconPrimaryHost: primaryHost,
                    faviconSecondaryHost: secondaryHost
                )
            }

            // Final cancellation check before updating UI
            guard !Task.isCancelled else { return }

            await MainActor.run {
                if animate {
                    // Clear entrance progress for new activities (triggers stagger animation)
                    self.cardEntranceProgress = [:]
                }
                self.positionedActivities = positioned
                self.hasAnyActivities = !positioned.isEmpty

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

    // Normalize a domain or URL-like string to just the host
    private func normalizeHost(_ site: String?) -> String? {
        guard var site = site, !site.isEmpty else { return nil }
        site = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: site), url.host != nil {
            return url.host
        }
        if site.contains("://") {
            if let url = URL(string: site), let host = url.host { return host }
        } else if site.contains("/") {
            if let url = URL(string: "https://" + site), let host = url.host { return host }
        } else {
            // If no TLD present, append .com for common sites like "YouTube" → "youtube.com"
            if !site.contains(".") {
                return site + ".com"
            }
            return site
        }
        return nil
    }

    private func processTimelineCards(_ cards: [TimelineCard], for date: Date) -> [TimelineActivity] {
        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: date)

        var results: [TimelineActivity] = []
        var idCounts: [String: Int] = [:]
        results.reserveCapacity(cards.count)

        for card in cards {
            guard let startDate = cachedTimeFormatter.date(from: card.startTimestamp),
                  let endDate = cachedTimeFormatter.date(from: card.endTimestamp) else {
                continue
            }

            let startComponents = calendar.dateComponents([.hour, .minute], from: startDate)
            let endComponents = calendar.dateComponents([.hour, .minute], from: endDate)

            guard let finalStartDate = calendar.date(
                bySettingHour: startComponents.hour ?? 0,
                minute: startComponents.minute ?? 0,
                second: 0,
                of: baseDate
            ),
            let finalEndDate = calendar.date(
                bySettingHour: endComponents.hour ?? 0,
                minute: endComponents.minute ?? 0,
                second: 0,
                of: baseDate
            ) else { continue }

            var adjustedStartDate = finalStartDate
            var adjustedEndDate = finalEndDate

            let startHour = calendar.component(.hour, from: finalStartDate)
            if startHour < 4 {
                adjustedStartDate = calendar.date(byAdding: .day, value: 1, to: finalStartDate) ?? finalStartDate
            }

            let endHour = calendar.component(.hour, from: finalEndDate)
            if endHour < 4 {
                adjustedEndDate = calendar.date(byAdding: .day, value: 1, to: finalEndDate) ?? finalEndDate
            }

            if adjustedEndDate < adjustedStartDate {
                adjustedEndDate = calendar.date(byAdding: .day, value: 1, to: adjustedEndDate) ?? adjustedEndDate
            }

            let baseId = TimelineActivity.stableId(
                recordId: card.recordId,
                batchId: card.batchId,
                startTime: adjustedStartDate,
                endTime: adjustedEndDate,
                title: card.title,
                category: card.category,
                subcategory: card.subcategory
            )

            let seenCount = idCounts[baseId, default: 0]
            idCounts[baseId] = seenCount + 1
            let finalId = seenCount == 0 ? baseId : "\(baseId)-\(seenCount)"
#if DEBUG
            if seenCount > 0 {
                print("[CanvasTimelineDataView] Duplicate TimelineActivity.id detected: \(baseId) -> \(finalId)")
            }
#endif

            results.append(TimelineActivity(
                id: finalId,
                recordId: card.recordId,
                batchId: card.batchId,
                startTime: adjustedStartDate,
                endTime: adjustedEndDate,
                title: card.title,
                summary: card.summary,
                detailedSummary: card.detailedSummary,
                category: card.category,
                subcategory: card.subcategory,
                distractions: card.distractions,
                videoSummaryURL: card.videoSummaryURL,
                screenshot: nil,
                appSites: card.appSites,
                isBackupGenerated: card.isBackupGenerated
            ))
        }

        return results
    }

    // Trims larger overlapping cards so smaller cards keep their full range.
    // This is a mitigation transform for occasional upstream timeline card overlap bugs.
    private struct DisplaySegment {
        let activity: TimelineActivity
        var start: Date
        var end: Date
    }

    private func resolveOverlapsForDisplay(_ activities: [TimelineActivity]) -> [DisplaySegment] {
        // Start with raw segments mirroring activity times
        var segments = activities.map { DisplaySegment(activity: $0, start: $0.startTime, end: $0.endTime) }
        guard segments.count > 1 else { return segments }

        // Sort by start time for deterministic processing
        segments.sort { $0.start < $1.start }

        // Iteratively resolve overlaps until stable, with a safety cap
        var changed = true
        var passes = 0
        let maxPasses = 8
        while changed && passes < maxPasses {
            changed = false
            passes += 1

            // Compare each pair that could overlap (sweep-style)
            var i = 0
            while i < segments.count {
                var j = i + 1
                while j < segments.count {
                    // Early exit if no chance to overlap (since sorted by start)
                    if segments[j].start >= segments[i].end { break }

                    // Compute overlap window
                    let s1 = segments[i]
                    let s2 = segments[j]
                    let overlapStart = max(s1.start, s2.start)
                    let overlapEnd = min(s1.end, s2.end)

                    if overlapEnd > overlapStart {
                        // There is overlap — decide small vs big by duration
                        let d1 = s1.end.timeIntervalSince(s1.start)
                        let d2 = s2.end.timeIntervalSince(s2.start)
                        let smallIdx = d1 <= d2 ? i : j
                        let bigIdx   = d1 <= d2 ? j : i

                        // Reload references after indices chosen
                        let small = segments[smallIdx]
                        var big = segments[bigIdx]

                        // Cases
                        if big.start < small.start && small.end < big.end {
                            // Small fully inside big — keep the longer side of big
                            let left  = small.start.timeIntervalSince(big.start)
                            let right = big.end.timeIntervalSince(small.end)
                            if right >= left {
                                big.start = small.end
                            } else {
                                big.end = small.start
                            }
                        } else if small.start <= big.start && big.start < small.end {
                            // Overlap at big start — trim big.start to small.end
                            big.start = small.end
                        } else if small.start < big.end && big.end <= small.end {
                            // Overlap at big end — trim big.end to small.start
                            big.end = small.start
                        }

                        // Validate and apply change
                        if big.end <= big.start {
                            // Trimmed away — remove big
                            segments.remove(at: bigIdx)
                            changed = true
                            // Restart inner loop from j = i+1 since indices shifted
                            j = i + 1
                            continue
                        } else if big.start != segments[bigIdx].start || big.end != segments[bigIdx].end {
                            segments[bigIdx] = big
                            changed = true
                            // Resort local order if start changed
                            segments.sort { $0.start < $1.start }
                            // Restart scanning from current i
                            j = i + 1
                            continue
                        }
                    }
                    j += 1
                }
                i += 1
            }
        }

        return segments
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
        return CGFloat(totalMinutes) * CanvasConfig.pixelsPerMinute
    }


    private func formatHour(_ hour: Int) -> String {
        let normalizedHour = hour >= 24 ? hour - 24 : hour
        let adjustedHour = normalizedHour > 12 ? normalizedHour - 12 : (normalizedHour == 0 ? 12 : normalizedHour)
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
        let matched = categories.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }
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
        let anchorY = yNow - (hoursAbove * CanvasConfig.hourHeight)
        
        // Create a frame that spans the full timeline height
        // Then position the anchor absolutely within it
        Color.clear
            .frame(width: 1, height: CGFloat(CanvasConfig.endHour - CanvasConfig.startHour) * CanvasConfig.hourHeight)
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

struct CanvasActivityCardStyle {
    let text: Color
    let time: Color
    let accent: Color
    let isIdle: Bool
}

struct CanvasActivityCard: View {
    @AppStorage("showTimelineAppIcons") private var showTimelineAppIcons: Bool = true
    @State private var isShowingBackupTooltip = false

    let title: String
    let time: String
    let height: CGFloat
    let durationMinutes: Double
    let style: CanvasActivityCardStyle
    let isSelected: Bool
    let isSystemCategory: Bool
    let isBackupGenerated: Bool
    let onTap: () -> Void
    // Raw values for pattern matching (may contain paths)
    let faviconPrimaryRaw: String?
    let faviconSecondaryRaw: String?
    // Normalized hosts for network fetch
    let faviconPrimaryHost: String?
    let faviconSecondaryHost: String?
    let statusLine: String?

    private var isFailedCard: Bool {
        title == "Processing failed"
    }

    private var isCompactCard: Bool {
        durationMinutes < 13
    }

    private var backupIndicator: some View {
        Text("!")
            .font(Font.custom("Nunito", size: 9).weight(.semibold))
            .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
            .frame(width: 14, height: 14)
            .background(
                Circle()
                    .fill(Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.9))
            )
            .overlay(
                Circle()
                    .stroke(Color(red: 0.9, green: 0.9, blue: 0.9), lineWidth: 0.75)
            )
            .onHover { isHovering in
                isShowingBackupTooltip = isHovering
            }
            .popover(isPresented: $isShowingBackupTooltip, arrowEdge: .top) {
                Text("This card fell back to a lower-quality Gemini model due to rate limiting, so output quality may be lower.")
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Color(hex: "2E261F"))
                    .multilineTextAlignment(.leading)
                    .frame(width: 260, alignment: .leading)
                    .padding(10)
            }
    }

    private var selectionStroke: Color {
        if isSystemCategory {
            return Color(red: 1, green: 0.16, blue: 0.11)
        }
        return style.accent
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                onTap()
            }
        }) {
            HStack(alignment: .top, spacing: isFailedCard ? 10 : 8) {
                if durationMinutes >= 10 {
                    if isFailedCard {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(title)
                                    .font(
                                        Font.custom("Nunito", size: 13)
                                            .weight(.semibold)
                                    )
                                    .foregroundColor(style.text)

                                Spacer()

                                Text(time)
                                    .font(
                                        Font.custom("Nunito", size: 10)
                                            .weight(.medium)
                                    )
                                    .foregroundColor(style.time)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }

                            if let statusLine = statusLine {
                                Text(statusLine)
                                    .font(Font.custom("Nunito", size: 10))
                                    .foregroundColor(Color(red: 0.55, green: 0.45, blue: 0.4))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    } else {
                        if showTimelineAppIcons && (faviconPrimaryRaw != nil || faviconSecondaryRaw != nil) {
                            FaviconOrSparkleView(
                                primaryRaw: faviconPrimaryRaw,
                                secondaryRaw: faviconSecondaryRaw,
                                primaryHost: faviconPrimaryHost,
                                secondaryHost: faviconSecondaryHost
                            )
                            .frame(width: 16, height: 16)
                        }

                        Text(title)
                            .font(
                                Font.custom("Nunito", size: 13)
                                    .weight(.semibold)
                            )
                            .foregroundColor(style.text)

                        Spacer()

                        HStack(spacing: 6) {
                            if isBackupGenerated {
                                backupIndicator
                            }

                            Text(time)
                                .font(
                                    Font.custom("Nunito", size: 10)
                                        .weight(.medium)
                                )
                                .foregroundColor(style.time)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isFailedCard ? 0 : (isCompactCard ? 0 : 6))
            .frame(
                maxWidth: .infinity,
                minHeight: height,
                maxHeight: height,
                alignment: isCompactCard ? .leading : .topLeading
            )
            .background(isFailedCard ? Color(hex: "FFECE4") : Color(hex: "FFFBF8"))
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .inset(by: 0.25)
                    .stroke(
                        isFailedCard ? Color(red: 1, green: 0.16, blue: 0.11) : Color(hex: "E8E8E8"),
                        style: isFailedCard ? StrokeStyle(lineWidth: 0.5, dash: [2.5, 2.5]) : StrokeStyle(lineWidth: 0.25)
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
                    .fill(style.accent)
                    .frame(width: 6)
                }
            }
            // Selection halo for the active activity
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(selectionStroke, lineWidth: 1.5)
                    .opacity(isSelected ? 1 : 0)
            )
        }
        .buttonStyle(CanvasCardButtonStyle())
        .padding(.horizontal, 6)
    }
}

struct CanvasCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(
                .spring(response: 0.3, dampingFraction: 0.6),
                value: configuration.isPressed
            )
    }
}


#Preview("Canvas Timeline Data View") {
    struct PreviewWrapper: View {
        @State private var date = Date()
        @State private var selected: TimelineActivity? = nil
        @State private var tick: Int = 0
        @State private var refresh: Int = 0
        var body: some View {
            CanvasTimelineDataView(selectedDate: $date,
                                   selectedActivity: $selected,
                                   scrollToNowTick: $tick,
                                   hasAnyActivities: .constant(true),
                                   refreshTrigger: $refresh)
                .frame(width: 800, height: 600)
                .environmentObject(CategoryStore())
                .environmentObject(AppState.shared)
                .environmentObject(RetryCoordinator())
        }
    }
    return PreviewWrapper()
}

private struct FaviconOrSparkleView: View {
    // Raw values for pattern matching (may contain paths like "developer.apple.com/xcode")
    let primaryRaw: String?
    let secondaryRaw: String?
    // Normalized hosts for network fetch
    let primaryHost: String?
    let secondaryHost: String?
    @State private var image: NSImage? = nil
    @State private var didStart = false

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            guard primaryRaw != nil || secondaryRaw != nil else { return }
            Task { @MainActor in
                if let img = await FaviconService.shared.fetchFavicon(
                    primaryRaw: primaryRaw,
                    secondaryRaw: secondaryRaw,
                    primaryHost: primaryHost,
                    secondaryHost: secondaryHost
                ) {
                    self.image = img
                }
            }
        }
    }
}
