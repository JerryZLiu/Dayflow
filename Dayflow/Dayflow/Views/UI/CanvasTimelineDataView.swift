import SwiftUI
import AppKit
import Foundation

private struct CanvasConfig {
    static let hourHeight: CGFloat = 144           // 144px per hour (Canvas look)
    static let pixelsPerMinute: CGFloat = 2.4      // 2.4px = 1 minute (Canvas look)
    static let timeColumnWidth: CGFloat = 60
    static let startHour: Int = 4                  // 4 AM baseline
    static let endHour: Int = 28                   // 4 AM next day
}

// Positioned activity for Canvas rendering
private struct CanvasPositionedActivity: Identifiable {
    let id: UUID
    let activity: TimelineActivity
    let yPosition: CGFloat
    let height: CGFloat
    let durationMinutes: Double
    let title: String
    let timeLabel: String
    let categoryName: String
    let faviconPrimaryHost: String?
    let faviconSecondaryHost: String?
}

struct CanvasTimelineDataView: View {
    @Binding var selectedDate: Date
    @Binding var selectedActivity: TimelineActivity?
    @Binding var scrollToNowTick: Int
    @Binding var hasAnyActivities: Bool

    @State private var selectedCardId: UUID? = nil
    @State private var positionedActivities: [CanvasPositionedActivity] = []
    @State private var refreshTimer: Timer?
    @State private var didInitialScrollInView: Bool = false
    @EnvironmentObject private var categoryStore: CategoryStore

    private let storageManager = StorageManager.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                timelineScrollContent()
            }
            .background(Color.clear)
            // Respond to external scroll nudges (initial or idle-triggered)
            .onChange(of: scrollToNowTick) { _ in
                // Calculate which hour to scroll to for 80% positioning
                let currentHour = Calendar.current.component(.hour, from: Date())
                let hoursSince4AM = currentHour >= 4 ? currentHour - 4 : (24 - 4) + currentHour
                let targetHourIndex = max(0, min(hoursSince4AM, 24) - 2) // 2 hours before current
                
                // Scroll to the hour marker with 30-minute offset for better positioning
                proxy.scrollTo("hour-\(targetHourIndex)", anchor: UnitPoint(x: 0, y: 0.25))
            }
            // Scroll once right after activities are first loaded and laid out
            .onChange(of: positionedActivities.count) { _ in
                guard !didInitialScrollInView, Calendar.current.isDateInToday(selectedDate) else { return }
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
                if Calendar.current.isDateInToday(selectedDate) {
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
            .onChange(of: selectedDate) { newDate in
                if Calendar.current.isDateInToday(newDate) {
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
        }
        .onChange(of: selectedDate) { _ in
            loadActivities()
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
                    .frame(width: CanvasConfig.timeColumnWidth, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .allowsTightening(true)
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
            ForEach(positionedActivities) { item in
                CanvasActivityCard(
                    title: item.title,
                    time: item.timeLabel,
                    height: item.height,
                    durationMinutes: item.durationMinutes,
                    style: style(for: item.categoryName),
                    isSelected: selectedCardId == item.id,
                    onTap: {
                        if selectedCardId == item.id {
                            selectedCardId = nil
                            selectedActivity = nil
                        } else {
                            selectedCardId = item.id
                            selectedActivity = item.activity
                        }
                    },
                    faviconPrimaryHost: item.faviconPrimaryHost,
                    faviconSecondaryHost: item.faviconSecondaryHost
                )
                .frame(height: item.height)
                .offset(y: item.yPosition)
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


    private func loadActivities() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Determine logical date (4 AM boundary)
            var logicalDate = selectedDate
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: selectedDate)
            if hour < 4 {
                logicalDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dayString = formatter.string(from: logicalDate)

            let timelineCards = storageManager.fetchTimelineCards(forDay: dayString)
            let activities = processTimelineCards(timelineCards, for: logicalDate)

            // Mitigation transform: resolve visual overlaps by trimming larger cards
            // so that smaller cards "win". This is a display-only fix to handle
            // upstream card-generation overlap bugs without touching stored data.
            let segments = resolveOverlapsForDisplay(activities)

            let positioned = segments.map { seg -> CanvasPositionedActivity in
                let y = calculateYPosition(for: seg.start)
                // Preserve Canvas spacing: -4 total (2px top + 2px bottom)
                let durationMinutes = max(0, seg.end.timeIntervalSince(seg.start) / 60)
                let rawHeight = CGFloat(durationMinutes) * CanvasConfig.pixelsPerMinute
                let height = max(10, rawHeight - 4)
                let primaryHost = normalizeHost(seg.activity.appSites?.primary)
                let secondaryHost = normalizeHost(seg.activity.appSites?.secondary)

                return CanvasPositionedActivity(
                    id: seg.activity.id,
                    activity: seg.activity,
                    yPosition: y + 2, // 2px top spacing like original Canvas
                    height: height,
                    durationMinutes: durationMinutes,
                    title: seg.activity.title,
                    timeLabel: formatRange(start: seg.start, end: seg.end),
                    categoryName: seg.activity.category,
                    faviconPrimaryHost: primaryHost,
                    faviconSecondaryHost: secondaryHost
                )
            }

            DispatchQueue.main.async {
                self.positionedActivities = positioned
                self.hasAnyActivities = !positioned.isEmpty
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
            return site
        }
        return nil
    }

    private func processTimelineCards(_ cards: [TimelineCard], for date: Date) -> [TimelineActivity] {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: date)

        return cards.compactMap { card -> TimelineActivity? in
            guard let startDate = timeFormatter.date(from: card.startTimestamp),
                  let endDate = timeFormatter.date(from: card.endTimestamp) else {
                return nil
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
            ) else { return nil }

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

            return TimelineActivity(
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
                batchId: card.batchId
            )
        }
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
            loadActivities()
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

    private func calculateHeight(for activity: TimelineActivity) -> CGFloat {
        let durationMinutes = activity.endTime.timeIntervalSince(activity.startTime) / 60
        return CGFloat(durationMinutes) * CanvasConfig.pixelsPerMinute
    }

    private func formatHour(_ hour: Int) -> String {
        let normalizedHour = hour >= 24 ? hour - 24 : hour
        let adjustedHour = normalizedHour > 12 ? normalizedHour - 12 : (normalizedHour == 0 ? 12 : normalizedHour)
        let period = normalizedHour >= 12 ? "PM" : "AM"
        return "\(adjustedHour):00 \(period)"
    }

    private func formatRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let s = formatter.string(from: start)
        let e = formatter.string(from: end)
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

extension CanvasTimelineDataView {
    fileprivate func currentHourIndex() -> Int {
        let cal = Calendar.current
        let h = cal.component(.hour, from: Date())
        let idx: Int
        if h >= CanvasConfig.startHour {
            idx = h - CanvasConfig.startHour
        } else {
            idx = (24 - CanvasConfig.startHour) + h
        }
        return max(0, min(idx, (CanvasConfig.endHour - CanvasConfig.startHour) - 1))
    }
}

struct CanvasActivityCardStyle {
    let text: Color
    let time: Color
    let accent: Color
    let isIdle: Bool
}

struct CanvasActivityCard: View {
    let title: String
    let time: String
    let height: CGFloat
    let durationMinutes: Double
    let style: CanvasActivityCardStyle
    let isSelected: Bool
    let onTap: () -> Void
    let faviconPrimaryHost: String?
    let faviconSecondaryHost: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if durationMinutes >= 10 {
                FaviconOrSparkleView(primaryHost: faviconPrimaryHost, secondaryHost: faviconSecondaryHost)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(Color(hex: "FFF8F1"))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(style.accent)
                .frame(width: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}


#Preview("Canvas Timeline Data View") {
    struct PreviewWrapper: View {
        @State private var date = Date()
        @State private var selected: TimelineActivity? = nil
        @State private var tick: Int = 0
        var body: some View {
            CanvasTimelineDataView(selectedDate: $date,
                                   selectedActivity: $selected,
                                   scrollToNowTick: $tick,
                                   hasAnyActivities: .constant(true))
                .frame(width: 800, height: 600)
                .environmentObject(CategoryStore())
        }
    }
    return PreviewWrapper()
}

private struct FaviconOrSparkleView: View {
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
            guard primaryHost != nil || secondaryHost != nil else { return }
            Task { @MainActor in
                if let img = await FaviconService.shared.fetchFavicon(primary: primaryHost, secondary: secondaryHost) {
                    self.image = img
                }
            }
        }
    }
}
