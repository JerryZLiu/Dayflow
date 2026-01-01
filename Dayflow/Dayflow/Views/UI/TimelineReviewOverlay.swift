import SwiftUI
import AppKit
import AVFoundation

// MARK: - Cached DateFormatter (creating DateFormatters is expensive due to ICU initialization)

private let cachedReviewTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private enum TimelineReviewRating: String, CaseIterable, Identifiable {
    case distracted
    case neutral
    case focused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distracted: return "Distracted"
        case .neutral: return "Neutral"
        case .focused: return "Focused"
        }
    }

    var overlayColor: Color {
        switch self {
        case .distracted: return Color(hex: "975D57").opacity(0.6)
        case .neutral: return Color(hex: "8C8379").opacity(0.55)
        case .focused: return Color(hex: "43765E").opacity(0.6)
        }
    }

    var overlayTextColor: Color {
        switch self {
        case .distracted: return Color(hex: "F9D8D4")
        case .neutral: return Color(hex: "F4F0ED")
        case .focused: return Color(hex: "D9F7E4")
        }
    }

    var barGradient: LinearGradient {
        switch self {
        case .distracted:
            return LinearGradient(
                colors: [Color(hex: "FFBDB1"), Color(hex: "FF8772")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .neutral:
            return LinearGradient(
                colors: [Color(hex: "FFFEFE"), Color(hex: "EAE0DB")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .focused:
            return LinearGradient(
                colors: [Color(hex: "92F1E3"), Color(hex: "42D0BB")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var barStroke: Color {
        switch self {
        case .distracted: return Color(hex: "FF8772")
        case .neutral: return Color(hex: "EAE0DB")
        case .focused: return Color(hex: "42D0BB")
        }
    }

    var labelColor: Color { Color(hex: "707070") }

    var iconTint: Color {
        switch self {
        case .distracted: return Color(hex: "FF7B67")
        case .neutral: return Color(hex: "C8C8C8")
        case .focused: return Color(hex: "47D2BD")
        }
    }

    var swipeOffset: CGSize {
        switch self {
        case .distracted: return CGSize(width: -560, height: 40)
        case .neutral: return CGSize(width: 0, height: -560)
        case .focused: return CGSize(width: 560, height: 40)
        }
    }

    var swipeRotation: Double {
        switch self {
        case .distracted: return -14
        case .neutral: return 0
        case .focused: return 14
        }
    }
}

private enum TimelineReviewInput: String {
    case drag
    case trackpad
    case keyboard
    case button
}

struct TimelineReviewOverlay: View {
    @Binding var isPresented: Bool
    let selectedDate: Date
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject private var categoryStore: CategoryStore

    @State private var activities: [TimelineActivity] = []
    @State private var currentIndex: Int = 0
    @State private var ratings: [String: TimelineReviewRating] = [:]
    @State private var dragOffset: CGSize = .zero
    @State private var dragRotation: Double = 0
    @State private var activeOverlayRating: TimelineReviewRating? = nil
    @State private var isAnimatingOut: Bool = false
    @State private var isLoading: Bool = true
    @State private var hasAnyActivities: Bool = false
    @State private var cardOpacity: Double = 1
    @State private var isTrackpadDragging = false
    @State private var trackpadTranslation: CGSize = .zero
    @State private var lastTrackpadDelta: CGSize = .zero
    @State private var isPointerOverSummary = false
    @State private var playbackToggleToken = 0
    @State private var lastCloseSource: TimelineReviewInput? = nil

    @State private var cardSize = CGSize(width: 340, height: 440)
    @State private var isBackAnimating = false
    @State private var dayRatingSummary = TimelineReviewSummary(durationByRating: [:])

    private enum ReviewLayout {
        static let baseCardSize = CGSize(width: 340, height: 440)
        static let topPadding: CGFloat = 20
        static let cardToTextSpacing: CGFloat = 10
        static let horizontalPadding: CGFloat = 20
        static let bottomPadding: CGFloat = 20
        static let minScale: CGFloat = 0.1
        static let maxScale: CGFloat = 1.4
        static let backAnimationDuration: Double = 0.35
    }

    var body: some View {
        ZStack {
            overlayBackground

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.8)
            } else if hasAnyActivities == false {
                emptyState
            } else if activities.isEmpty || currentIndex >= activities.count {
                summaryState
            } else {
                reviewState
            }

            closeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
            lastCloseSource = nil
            AnalyticsService.shared.capture("timeline_review_opened")
            loadActivities()
        }
        .onDisappear {
            AnalyticsService.shared.capture("timeline_review_closed", [
                "source": lastCloseSource?.rawValue ?? "unknown"
            ])
        }
        .onChange(of: selectedDate) { _, _ in
            loadActivities()
        }
        .background(
            TimelineReviewKeyHandler(
                onMove: { direction in
                    handleMoveCommand(direction)
                },
                onBack: {
                    goBackOneCard(input: .keyboard)
                },
                onEscape: {
                    dismissOverlay()
                },
                onTogglePlayback: {
                    playbackToggleToken &+= 1
                }
            )
            .frame(width: 0, height: 0)
        )
        .background(
            TrackpadScrollHandler(
                shouldHandleScroll: { delta in
                if isTrackpadDragging {
                    return true
                }
                guard isPointerOverSummary else {
                    return true
                }
                return abs(delta.width) > abs(delta.height) * 1.2
            },
                onScrollBegan: beginTrackpadDrag,
                onScrollChanged: handleTrackpadScroll(delta:),
                onScrollEnded: endTrackpadDrag
            )
            .frame(maxWidth: CGFloat.infinity, maxHeight: CGFloat.infinity)
        )
    }

    private var overlayBackground: some View {
        Rectangle()
            .fill(Color(hex: "FBE9E0").opacity(0.92))
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismissOverlay()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "FF6D00").opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.7))
                                .overlay(
                                    Circle()
                                        .stroke(Color(hex: "DABCA4"), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 22)
                .padding(.top, 16)
            }
            Spacer()
        }
    }

    private var reviewState: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width - ReviewLayout.horizontalPadding * 2, 1)
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: ReviewLayout.topPadding)

                GeometryReader { cardProxy in
                    let availableHeight = max(cardProxy.size.height, 1)
                    let scaleWidth = availableWidth / ReviewLayout.baseCardSize.width
                    let scaleHeight = availableHeight / ReviewLayout.baseCardSize.height
                    let scale = min(scaleWidth, scaleHeight)
                    let clampedScale = min(max(scale, ReviewLayout.minScale), ReviewLayout.maxScale)
                    let computedCardSize = CGSize(
                        width: ReviewLayout.baseCardSize.width * clampedScale,
                        height: ReviewLayout.baseCardSize.height * clampedScale
                    )
                    let visibleItems = visibleActivityIndices.map { index in
                        IndexedActivity(id: activities[index].id, index: index, activity: activities[index])
                    }

                    ZStack {
                        ForEach(visibleItems.reversed()) { item in
                            let activity = item.activity
                            let isActive = item.index == currentIndex
                            let card = TimelineReviewCard(
                                activity: activity,
                                categoryColor: categoryColor(for: activity.category),
                                progressText: progressText(index: item.index + 1),
                                overlayRating: isActive ? activeOverlayRating : nil,
                                highlightOpacity: 1,
                                isActive: isActive,
                                playbackToggleToken: playbackToggleToken,
                                onSummaryHover: { hovering in
                                    if isActive {
                                        isPointerOverSummary = hovering
                                    }
                                }
                            )
                            .frame(width: computedCardSize.width, height: computedCardSize.height)

                            Group {
                                if isActive {
                                    card
                                        .rotationEffect(.degrees(dragRotation))
                                        .offset(dragOffset)
                                        .opacity(cardOpacity)
                                    .simultaneousGesture(reviewDragGesture())
                                } else {
                                    card
                                }
                            }
                        }
                    }
                    .frame(width: computedCardSize.width, height: computedCardSize.height)
                    .position(x: cardProxy.size.width / 2, y: cardProxy.size.height / 2)
                    .background(
                        Color.clear
                            .onAppear {
                                if cardSize != computedCardSize {
                                    cardSize = computedCardSize
                                }
                            }
                            .onChange(of: computedCardSize) { _, newValue in
                                if cardSize != newValue {
                                    cardSize = newValue
                                }
                            }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer()
                    .frame(height: ReviewLayout.cardToTextSpacing)

                reviewBottomContent
                    .frame(width: availableWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)

                Spacer()
                    .frame(height: ReviewLayout.bottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var reviewBottomContent: some View {
        VStack(spacing: 14) {
            Text("Swipe on each card on your Timeline to review your day.")
                .font(.custom("Nunito", size: 14).weight(.medium))
                .foregroundColor(Color(hex: "98806D"))
                .lineLimit(1)
                .minimumScaleFactor(0.95)

            TimelineReviewRatingRow(onUndo: {
                goBackOneCard(input: .button)
            }, onSelect: { rating in
                commitRating(rating, input: .button)
            })
        }
    }

    private var summaryState: some View {
        let summary = ratingSummary
        return VStack(spacing: 30) {
            VStack(spacing: 12) {
                Text("All caught up!")
                    .font(.custom("InstrumentSerif-Regular", size: 40))
                    .foregroundColor(Color(hex: "333333"))
                Text("You've reviewed all your activities so far.\nThe Timeline right panel will be updated with your rating.")
                    .font(.custom("Nunito", size: 16).weight(.medium))
                    .foregroundColor(Color(hex: "333333"))
                    .multilineTextAlignment(.center)
            }

            TimelineReviewSummaryBars(summary: summary)

            Button {
                dismissOverlay()
            } label: {
                Text("Close")
                    .font(.custom("Nunito", size: 14).weight(.semibold))
                    .foregroundColor(Color(hex: "333333"))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "FFF9F1").opacity(0.9), Color(hex: "FDE8D1").opacity(0.9)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color(hex: "FF8904").opacity(0.5), lineWidth: 1.25)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 500)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("Nothing to review yet")
                .font(.custom("InstrumentSerif-Regular", size: 28))
                .foregroundColor(Color(hex: "333333"))
            Text("Come back after a few timeline cards appear.")
                .font(.custom("Nunito", size: 14).weight(.medium))
                .foregroundColor(Color(hex: "707070"))
        }
    }

    private var currentActivity: TimelineActivity? {
        guard currentIndex < activities.count else { return nil }
        return activities[currentIndex]
    }

    private var visibleActivityIndices: [Int] {
        guard currentIndex < activities.count else { return [] }
        let endIndex = min(currentIndex + 1, activities.count - 1)
        return Array(currentIndex...endIndex)
    }

    private func progressText(index: Int) -> String {
        "\(index)/\(max(activities.count, 1))"
    }

    private func categoryColor(for name: String) -> Color {
        if let match = categoryStore.categories.first(where: { $0.name == name }) {
            return Color(hex: match.colorHex)
        }
        return Color(hex: "B984FF")
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            commitRating(.distracted, predictedTranslation: TimelineReviewRating.distracted.swipeOffset, input: .keyboard)
        case .right:
            commitRating(.focused, predictedTranslation: TimelineReviewRating.focused.swipeOffset, input: .keyboard)
        case .up:
            commitRating(.neutral, predictedTranslation: TimelineReviewRating.neutral.swipeOffset, input: .keyboard)
        default:
            break
        }
    }

    private func goBackOneCard(input: TimelineReviewInput) {
        guard !isAnimatingOut, !isBackAnimating else { return }
        guard currentIndex > 0 else { return }
        AnalyticsService.shared.capture("timeline_review_undo", [
            "input": input.rawValue
        ])
        isBackAnimating = true
        currentIndex -= 1
        isPointerOverSummary = false
        isTrackpadDragging = false
        trackpadTranslation = .zero
        lastTrackpadDelta = .zero
        activeOverlayRating = nil
        dragRotation = 0
        cardOpacity = 1
        dragOffset = CGSize(width: 0, height: cardSize.height + 160)

        withAnimation(.spring(response: ReviewLayout.backAnimationDuration, dampingFraction: 0.85)) {
            dragOffset = .zero
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + ReviewLayout.backAnimationDuration) {
            isBackAnimating = false
        }
    }

    private func beginTrackpadDrag() {
        guard !isAnimatingOut, currentActivity != nil else { return }
        isTrackpadDragging = true
        trackpadTranslation = dragOffset
        lastTrackpadDelta = .zero
    }

    private func handleTrackpadScroll(delta: CGSize) {
        guard isTrackpadDragging, !isAnimatingOut else { return }
        trackpadTranslation.width += delta.width
        trackpadTranslation.height += delta.height
        lastTrackpadDelta = delta

        dragOffset = trackpadTranslation
        dragRotation = Double(trackpadTranslation.width / 18)
        activeOverlayRating = ratingForGesture(trackpadTranslation)
    }

    private func endTrackpadDrag() {
        guard isTrackpadDragging else { return }
        isTrackpadDragging = false

        let rating = ratingForGesture(trackpadTranslation, allowThreshold: true)
        if let rating {
            let predicted = CGSize(
                width: trackpadTranslation.width + (lastTrackpadDelta.width * 6),
                height: trackpadTranslation.height + (lastTrackpadDelta.height * 6)
            )
            commitRating(rating, predictedTranslation: predicted, input: .trackpad)
        } else {
            resetDragState()
        }
    }

    private func reviewDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isAnimatingOut else { return }
                if isPointerOverSummary && !isTrackpadDragging {
                    let isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                    if !isHorizontal { return }
                }
                dragOffset = value.translation
                dragRotation = Double(value.translation.width / 18)
                activeOverlayRating = ratingForGesture(value.translation)
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                if isPointerOverSummary && !isTrackpadDragging {
                    let isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                    if !isHorizontal { return }
                }
                let rating = ratingForGesture(value.translation, allowThreshold: true)
                if let rating {
                    commitRating(rating, predictedTranslation: value.predictedEndTranslation, input: .drag)
                } else {
                    resetDragState()
                }
            }
    }

    private func ratingForGesture(_ translation: CGSize, allowThreshold: Bool = false) -> TimelineReviewRating? {
        let horizontalThreshold: CGFloat = allowThreshold ? 140 : 30
        let verticalThreshold: CGFloat = allowThreshold ? 120 : 30

        if abs(translation.width) > abs(translation.height) {
            if translation.width > horizontalThreshold { return .focused }
            if translation.width < -horizontalThreshold { return .distracted }
        } else {
            if translation.height < -verticalThreshold { return .neutral }
        }
        return nil
    }

    private func commitRating(
        _ rating: TimelineReviewRating,
        predictedTranslation: CGSize? = nil,
        input: TimelineReviewInput
    ) {
        guard !isAnimatingOut, let activity = currentActivity else { return }
        isAnimatingOut = true
        isTrackpadDragging = false
        activeOverlayRating = rating

        let direction: String
        switch rating {
        case .distracted: direction = "left"
        case .neutral: direction = "up"
        case .focused: direction = "right"
        }
        AnalyticsService.shared.capture("timeline_review_swipe", [
            "direction": direction,
            "input": input.rawValue
        ])

        let startTs = Int(activity.startTime.timeIntervalSince1970)
        let endTs = Int(activity.endTime.timeIntervalSince1970)
        StorageManager.shared.applyReviewRating(
            startTs: startTs,
            endTs: endTs,
            rating: rating.rawValue
        )
        refreshRatingSummary()

        let exitOffset = swipeExitOffset(for: rating, predictedTranslation: predictedTranslation)
        let exitRotation = swipeExitRotation(for: rating, predictedTranslation: predictedTranslation)
        let exitDuration = swipeExitDuration(predictedTranslation: predictedTranslation)

        withAnimation(.easeIn(duration: exitDuration)) {
            dragOffset = exitOffset
            dragRotation = exitRotation
            cardOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration) {
            ratings[activity.id] = rating
            isPointerOverSummary = false
            currentIndex += 1
            resetDragState(animated: false)
            isAnimatingOut = false
        }
    }

    private func resetDragState(animated: Bool = true) {
        let reset = {
            dragOffset = .zero
            dragRotation = 0
            activeOverlayRating = nil
            cardOpacity = 1
            trackpadTranslation = .zero
            lastTrackpadDelta = .zero
        }

        if animated {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                reset()
            }
        } else {
            reset()
        }
    }

    private func swipeExitOffset(for rating: TimelineReviewRating, predictedTranslation: CGSize?) -> CGSize {
        let direction = swipeDirectionVector(predictedTranslation) ?? swipeDirectionVector(rating.swipeOffset) ?? CGSize(width: 0, height: -1)
        let distance = max(cardSize.width, cardSize.height) * 1.6
        return CGSize(width: direction.width * distance, height: direction.height * distance)
    }

    private func swipeDirectionVector(_ translation: CGSize?) -> CGSize? {
        guard let translation else { return nil }
        let magnitude = sqrt((translation.width * translation.width) + (translation.height * translation.height))
        guard magnitude > 4 else { return nil }
        return CGSize(width: translation.width / magnitude, height: translation.height / magnitude)
    }

    private func swipeExitRotation(for rating: TimelineReviewRating, predictedTranslation: CGSize?) -> Double {
        if let predicted = predictedTranslation, abs(predicted.width) > 8 {
            return Double(max(-18, min(18, predicted.width / 18)))
        }
        if abs(dragRotation) > 0.1 {
            return dragRotation
        }
        return rating.swipeRotation
    }

    private func swipeExitDuration(predictedTranslation: CGSize?) -> Double {
        guard let predictedTranslation else { return 0.24 }
        let magnitude = sqrt((predictedTranslation.width * predictedTranslation.width) + (predictedTranslation.height * predictedTranslation.height))
        let normalized = min(max(magnitude / 1200, 0), 1)
        return 0.28 - (0.1 * Double(normalized))
    }

    private func dismissOverlay() {
        isPresented = false
        onDismiss?()
    }

    private func loadActivities() {
        isLoading = true
        let timelineDate = timelineDisplayDate(from: selectedDate)
        let dayInfo = timelineDate.getDayInfoFor4AMBoundary()
        let dayString = dayInfo.dayString
        let dayStartTs = Int(dayInfo.startOfDay.timeIntervalSince1970)
        let dayEndTs = Int(dayInfo.endOfDay.timeIntervalSince1970)
        Task.detached(priority: .userInitiated) {
            let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
            let activities = makeTimelineActivities(from: cards, for: timelineDate)
                .filter { $0.category.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("System") != .orderedSame }
                .sorted { $0.startTime < $1.startTime }
            let ratingSegments = StorageManager.shared.fetchReviewRatingSegments(overlapping: dayStartTs, endTs: dayEndTs)
            let summary = Self.makeRatingSummary(
                segments: ratingSegments,
                dayStartTs: dayStartTs,
                dayEndTs: dayEndTs
            )
            let reviewActivities = Self.filterUnreviewedActivities(
                activities: activities,
                ratingSegments: ratingSegments,
                dayStartTs: dayStartTs,
                dayEndTs: dayEndTs
            )
            await MainActor.run {
                self.activities = reviewActivities
                self.currentIndex = 0
                self.ratings = [:]
                self.isPointerOverSummary = false
                self.hasAnyActivities = activities.isEmpty == false
                self.resetDragState()
                self.dayRatingSummary = summary
                self.isLoading = false
            }
        }
    }

    private var ratingSummary: TimelineReviewSummary {
        dayRatingSummary
    }

    private func refreshRatingSummary() {
        let timelineDate = timelineDisplayDate(from: selectedDate)
        let dayInfo = timelineDate.getDayInfoFor4AMBoundary()
        let dayStartTs = Int(dayInfo.startOfDay.timeIntervalSince1970)
        let dayEndTs = Int(dayInfo.endOfDay.timeIntervalSince1970)

        Task.detached(priority: .userInitiated) {
            let segments = StorageManager.shared.fetchReviewRatingSegments(overlapping: dayStartTs, endTs: dayEndTs)
            let summary = Self.makeRatingSummary(
                segments: segments,
                dayStartTs: dayStartTs,
                dayEndTs: dayEndTs
            )
            await MainActor.run {
                dayRatingSummary = summary
            }
        }
    }

    nonisolated private static func makeRatingSummary(
        segments: [TimelineReviewRatingSegment],
        dayStartTs: Int,
        dayEndTs: Int
    ) -> TimelineReviewSummary {
        var durationByRating: [TimelineReviewRating: TimeInterval] = [:]
        for segment in segments {
            guard let rating = TimelineReviewRating(rawValue: segment.rating) else { continue }
            let start = max(segment.startTs, dayStartTs)
            let end = min(segment.endTs, dayEndTs)
            guard end > start else { continue }
            durationByRating[rating, default: 0] += TimeInterval(end - start)
        }
        return TimelineReviewSummary(durationByRating: durationByRating)
    }

    private struct CoverageSegment {
        var start: Int
        var end: Int
    }

    nonisolated private static func filterUnreviewedActivities(
        activities: [TimelineActivity],
        ratingSegments: [TimelineReviewRatingSegment],
        dayStartTs: Int,
        dayEndTs: Int
    ) -> [TimelineActivity] {
        guard ratingSegments.isEmpty == false else { return activities }

        let mergedSegments = mergedCoverageSegments(
            segments: ratingSegments,
            dayStartTs: dayStartTs,
            dayEndTs: dayEndTs
        )
        guard mergedSegments.isEmpty == false else { return activities }

        var unreviewed: [TimelineActivity] = []
        var segmentIndex = 0

        for activity in activities {
            let start = Int(activity.startTime.timeIntervalSince1970)
            let end = Int(activity.endTime.timeIntervalSince1970)
            let duration = max(end - start, 1)
            let covered = overlapSeconds(
                start: start,
                end: end,
                segments: mergedSegments,
                segmentIndex: &segmentIndex
            )
            let coverageRatio = Double(covered) / Double(duration)
            if coverageRatio < 0.8 {
                unreviewed.append(activity)
            }
        }

        return unreviewed
    }

    nonisolated private static func mergedCoverageSegments(
        segments: [TimelineReviewRatingSegment],
        dayStartTs: Int,
        dayEndTs: Int
    ) -> [CoverageSegment] {
        var clipped: [CoverageSegment] = []
        clipped.reserveCapacity(segments.count)

        for segment in segments {
            let start = max(segment.startTs, dayStartTs)
            let end = min(segment.endTs, dayEndTs)
            if end > start {
                clipped.append(CoverageSegment(start: start, end: end))
            }
        }

        guard clipped.isEmpty == false else { return [] }
        clipped.sort { $0.start < $1.start }

        var merged: [CoverageSegment] = [clipped[0]]
        for segment in clipped.dropFirst() {
            var last = merged[merged.count - 1]
            if segment.start <= last.end {
                last.end = max(last.end, segment.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    nonisolated private static func overlapSeconds(
        start: Int,
        end: Int,
        segments: [CoverageSegment],
        segmentIndex: inout Int
    ) -> Int {
        guard end > start else { return 0 }

        while segmentIndex < segments.count, segments[segmentIndex].end <= start {
            segmentIndex += 1
        }

        var covered = 0
        var index = segmentIndex

        while index < segments.count, segments[index].start < end {
            let overlapStart = max(start, segments[index].start)
            let overlapEnd = min(end, segments[index].end)
            if overlapEnd > overlapStart {
                covered += overlapEnd - overlapStart
            }
            if segments[index].end <= end {
                index += 1
            } else {
                break
            }
        }

        return covered
    }
}

private struct TimelineReviewCard: View {
    let activity: TimelineActivity
    let categoryColor: Color
    let progressText: String
    let overlayRating: TimelineReviewRating?
    let highlightOpacity: Double
    let isActive: Bool
    let playbackToggleToken: Int
    let onSummaryHover: (Bool) -> Void

    @StateObject private var playerModel: TimelineReviewPlayerModel
    @State private var isHoveringMedia = false
    @State private var wasPlayingBeforeScrub = false

    init(
        activity: TimelineActivity,
        categoryColor: Color,
        progressText: String,
        overlayRating: TimelineReviewRating?,
        highlightOpacity: Double,
        isActive: Bool,
        playbackToggleToken: Int,
        onSummaryHover: @escaping (Bool) -> Void
    ) {
        self.activity = activity
        self.categoryColor = categoryColor
        self.progressText = progressText
        self.overlayRating = overlayRating
        self.highlightOpacity = highlightOpacity
        self.isActive = isActive
        self.playbackToggleToken = playbackToggleToken
        self.onSummaryHover = onSummaryHover
        _playerModel = StateObject(wrappedValue: TimelineReviewPlayerModel(videoURL: activity.videoSummaryURL))
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)

            VStack(spacing: 0) {
                TimelineReviewCardMedia(
                    player: playerModel.player,
                    onTogglePlayback: {
                        guard isActive else { return }
                        playerModel.togglePlay()
                    }
                )
                .frame(height: Design.mediaHeight)
                .overlay(alignment: .bottom) {
                    TimelineReviewPlaybackTimeline(
                        progress: playbackProgress,
                        timeText: playbackTimeText,
                        mediaHeight: Design.mediaHeight,
                        lineHeight: Design.progressLineHeight,
                        isInteractive: isActive,
                        onScrubStart: beginScrub,
                        onScrubChange: updateScrub(progress:),
                        onScrubEnd: endScrub
                    )
                }
                .overlay(alignment: .bottomTrailing) {
                    if isHoveringMedia && isActive {
                        speedChip
                            .padding(SpeedChipDesign.padding)
                            .zIndex(2)
                    }
                }
                .onHover { hovering in
                    isHoveringMedia = hovering
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(activity.title)
                        .font(.custom("InstrumentSerif-Regular", size: 24))
                        .foregroundColor(Color.black)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .center) {
                        TimelineReviewCategoryPill(name: activity.category, color: categoryColor)
                        Spacer()
                        TimelineReviewTimeRangePill(timeRange: timeRangeText)
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        Text(summaryText)
                            .font(.custom("Nunito", size: 14).weight(.medium))
                            .foregroundColor(Color(hex: "333333"))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 4)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        onSummaryHover(hovering)
                    }

                    HStack {
                        Spacer()
                        Text(progressText)
                            .font(.custom("Nunito", size: 10).weight(.medium))
                            .foregroundColor(Color(hex: "AFAFAF"))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let overlayRating = overlayRating {
                TimelineReviewOverlayBadge(rating: overlayRating)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
            }
        }
        .opacity(highlightOpacity)
        .onAppear {
            playerModel.setActive(isActive)
        }
        .onChange(of: isActive) { _, active in
            playerModel.setActive(active)
        }
        .onChange(of: activity.videoSummaryURL) { _, newValue in
            playerModel.updateVideo(url: newValue)
        }
        .onChange(of: playbackToggleToken) { _, _ in
            guard isActive else { return }
            playerModel.togglePlay()
        }
    }

    private var summaryText: String {
        activity.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var timeRangeText: String {
        let start = Self.timeFormatter.string(from: activity.startTime)
        let end = Self.timeFormatter.string(from: activity.endTime)
        return "\(start) - \(end)"
    }

    private var playbackProgress: CGFloat {
        let duration = max(playerModel.duration, 0.001)
        let progress = playerModel.currentTime / duration
        return CGFloat(min(max(progress, 0), 1))
    }

    private var playbackTimeText: String {
        let total = max(0, activity.endTime.timeIntervalSince(activity.startTime))
        let progressSeconds = total * Double(playbackProgress)
        let time = activity.startTime.addingTimeInterval(progressSeconds)
        return Self.timeFormatter.string(from: time)
    }

    private var speedLabel: String {
        "\(Int(playerModel.playbackSpeed * 20))x"
    }

    private func beginScrub() {
        guard isActive else { return }
        wasPlayingBeforeScrub = playerModel.isPlaying
        playerModel.pause()
    }

    private func updateScrub(progress: CGFloat) {
        guard isActive else { return }
        let seconds = Double(progress) * playerModel.duration
        playerModel.seek(to: seconds, resume: false)
    }

    private func endScrub() {
        guard isActive else { return }
        if wasPlayingBeforeScrub {
            playerModel.play()
        }
        wasPlayingBeforeScrub = false
    }

    private enum Design {
        static let mediaHeight: CGFloat = 220
        static let progressLineHeight: CGFloat = 4
    }

    private enum SpeedChipDesign {
        static let padding: CGFloat = 10
        static let background = Color.black.opacity(0.8)
        static let text = Color.white
    }

    private var speedChip: some View {
        Button(action: { playerModel.cycleSpeed() }) {
            Text(speedLabel)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(SpeedChipDesign.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(SpeedChipDesign.background)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

private final class TimelineReviewPlayerModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var playbackSpeed: Float = 3.0
    @Published var isPlaying: Bool = false
    @Published var didReachEnd: Bool = false

    let speedOptions: [Float] = [1.0, 2.0, 3.0, 6.0]

    var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: Any?
    private var shouldPlayWhenReady = false
    private var currentURL: String?

    init(videoURL: String?) {
        updateVideo(url: videoURL)
    }

    func updateVideo(url: String?) {
        guard url != currentURL else { return }
        currentURL = url
        cleanupPlayer()
        guard let url = url, let resolvedURL = resolveVideoURL(url) else { return }

        let player = AVPlayer(url: resolvedURL)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        self.player = player
        didReachEnd = false

        observeDuration(for: player.currentItem)
        addTimeObserver()
        addEndObserver(for: player.currentItem)
        if shouldPlayWhenReady {
            play()
        }
    }

    func setActive(_ active: Bool) {
        shouldPlayWhenReady = active
        if active {
            play()
        } else {
            pause()
        }
    }

    func cycleSpeed() {
        guard let idx = speedOptions.firstIndex(of: playbackSpeed) else {
            setPlaybackSpeed(speedOptions.last ?? 3.0)
            return
        }
        let next = speedOptions[(idx + 1) % speedOptions.count]
        setPlaybackSpeed(next)
    }

    func togglePlay() {
        if didReachEnd {
            seek(to: 0, resume: true)
            return
        }
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to seconds: Double, resume: Bool? = nil) {
        let clamped = min(max(seconds, 0), duration)
        guard let player else { return }
        didReachEnd = clamped >= max(duration - 0.01, 0)
        currentTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if let resume {
            resume ? play() : pause()
        }
    }

    private func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
        if player?.rate ?? 0 > 0 {
            player?.rate = speed
        }
    }

    func play() {
        guard let player else { return }
        if didReachEnd {
            didReachEnd = false
            currentTime = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        player.rate = playbackSpeed
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    private func observeDuration(for item: AVPlayerItem?) {
        guard let asset = item?.asset else { return }
        Task {
            do {
                let duration = try await asset.load(.duration)
                await MainActor.run {
                    let seconds = CMTimeGetSeconds(duration)
                    self.duration = seconds.isFinite && seconds > 0 ? seconds : 1
                }
            } catch {
                await MainActor.run {
                    self.duration = 1
                }
            }
        }
    }

    private func addTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }

    private func addEndObserver(for item: AVPlayerItem?) {
        guard let item else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.didReachEnd = true
            self?.isPlaying = false
        }
    }

    private func cleanupPlayer() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        currentTime = 0
        duration = 1
        isPlaying = false
        didReachEnd = false
    }

    private func resolveVideoURL(_ string: String) -> URL? {
        if string.hasPrefix("file://") {
            return URL(string: string)
        }
        return URL(fileURLWithPath: string)
    }

    deinit {
        cleanupPlayer()
    }
}

private struct TimelineReviewCardMedia: View {
    let player: AVPlayer?
    let onTogglePlayback: () -> Void

    private enum Design {
        static let mediaBorderColor = Color.white.opacity(0.2)
    }

    var body: some View {
        ZStack {
            if let player {
                WhiteBGVideoPlayer(player: player, videoGravity: .resizeAspectFill)
                    .allowsHitTesting(false)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [Color.black.opacity(0.25), Color.black.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTogglePlayback()
        }
        .overlay(
            Rectangle()
                .stroke(Design.mediaBorderColor, lineWidth: 1)
        )
    }
}

private struct TimelineReviewPlaybackTimeline: View {
    let progress: CGFloat
    let timeText: String
    let mediaHeight: CGFloat
    let lineHeight: CGFloat
    let isInteractive: Bool
    let onScrubStart: () -> Void
    let onScrubChange: (CGFloat) -> Void
    let onScrubEnd: () -> Void

    @State private var timePillSize: CGSize = .zero
    @State private var isScrubbing = false

    private enum Design {
        static let baseColor = Color(hex: "A3978D").opacity(0.5)
        static let progressColor = Color(hex: "FF6D00").opacity(0.65)
        static let pillColor = Color(hex: "F96E00")
        static let pillText = Color.white
        static let pillFont = Font.custom("Nunito", size: 8).weight(.semibold)
        static let pillTracking: CGFloat = -0.32
        static let pillPaddingX: CGFloat = 4
        static let pillPaddingY: CGFloat = 3
        static let pillCornerRadius: CGFloat = 4
        static let pillBottomSpacing: CGFloat = 3
        static let timelineHeight: CGFloat = 28
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clampedProgress = min(max(progress, 0), 1)
            let lineTop = min(mediaHeight, proxy.size.height - lineHeight)
            let lineCenterY = lineTop + (lineHeight / 2)
            let scrubHeight = max(lineHeight + 8, 12)
            let pillHeight = timePillSize.height == 0 ? 14 : timePillSize.height
            let pillCenterY = lineTop - Design.pillBottomSpacing - (pillHeight / 2)
            let targetX = width * clampedProgress
            let pillWidth = timePillSize.width == 0 ? 44 : timePillSize.width
            let halfPill = pillWidth / 2
            let clampedX = min(max(targetX, halfPill), width - halfPill)

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Design.baseColor)
                        .frame(width: width, height: lineHeight)
                        .position(x: width / 2, y: lineCenterY)

                    Rectangle()
                        .fill(Design.progressColor)
                        .frame(width: width * clampedProgress, height: lineHeight)
                        .position(x: (width * clampedProgress) / 2, y: lineCenterY)

                    Text(timeText)
                        .font(Design.pillFont)
                        .kerning(Design.pillTracking)
                        .foregroundColor(Design.pillText)
                        .padding(.horizontal, Design.pillPaddingX)
                        .padding(.vertical, Design.pillPaddingY)
                        .background(
                            RoundedRectangle(cornerRadius: Design.pillCornerRadius)
                                .fill(Design.pillColor)
                        )
                        .background(
                            GeometryReader { pillProxy in
                                Color.clear
                                    .preference(key: TimelineReviewTimePillSizeKey.self, value: pillProxy.size)
                            }
                        )
                        .position(x: clampedX, y: pillCenterY)
                }
                .allowsHitTesting(false)

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: width, height: scrubHeight)
                    .position(x: width / 2, y: lineCenterY)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isInteractive else { return }
                                if isScrubbing == false {
                                    isScrubbing = true
                                    onScrubStart()
                                }
                                let rawProgress = value.location.x / max(width, 1)
                                let scrubProgress = min(max(rawProgress, 0), 1)
                                onScrubChange(scrubProgress)
                            }
                            .onEnded { _ in
                                guard isInteractive else { return }
                                isScrubbing = false
                                onScrubEnd()
                            }
                    )
                    .allowsHitTesting(isInteractive)
            }
        }
        .frame(height: Design.timelineHeight)
        .onPreferenceChange(TimelineReviewTimePillSizeKey.self) { size in
            if size != .zero {
                timePillSize = size
            }
        }
    }
}

private struct TimelineReviewTimePillSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct TimelineReviewOverlayBadge: View {
    let rating: TimelineReviewRating

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    TimelineReviewRatingIcon(rating: rating, size: 48)
                    Text(rating.title)
                        .font(.custom("Nunito", size: 20).weight(.bold))
                        .foregroundColor(rating.overlayTextColor)
                }
                .frame(width: 140)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(rating.overlayColor)
    }
}

private struct TimelineReviewCategoryPill: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.custom("Nunito", size: 10).weight(.bold))
                .foregroundColor(Color(hex: "333333"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color, lineWidth: 0.75)
        )
    }
}

private struct TimelineReviewTimeRangePill: View {
    let timeRange: String

    var body: some View {
        Text(timeRange)
            .font(.custom("Nunito", size: 10).weight(.bold))
            .foregroundColor(Color(hex: "656565"))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(hex: "F5F0E9").opacity(0.9))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "E4E4E4"), lineWidth: 0.75)
            )
    }
}

private struct IndexedActivity: Identifiable {
    let id: String
    let index: Int
    let activity: TimelineActivity
}

private struct TimelineReviewRatingRow: View {
    let onUndo: () -> Void
    let onSelect: (TimelineReviewRating) -> Void

    var body: some View {
        HStack(spacing: 44) {
            undoButton
            ratingButton(.distracted)
            ratingButton(.neutral)
            ratingButton(.focused)
        }
    }

    private var undoButton: some View {
        Button {
            onUndo()
        } label: {
            VStack(spacing: 6) {
                ZUndoIcon(size: 16)
                Text("Undo")
                    .font(.custom("Nunito", size: 12).weight(.medium))
                    .foregroundColor(Color(hex: "98806D"))
            }
        }
        .buttonStyle(.plain)
    }

    private func ratingButton(_ rating: TimelineReviewRating) -> some View {
        Button {
            onSelect(rating)
        } label: {
            VStack(spacing: 6) {
                TimelineReviewFooterIcon(rating: rating, size: 16)
                Text(rating.title)
                    .font(.custom("Nunito", size: 12).weight(.medium))
                    .foregroundColor(Color(hex: "98806D"))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ZUndoIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: "D6AB8A").opacity(0.7))
            Text("Z")
                .font(.custom("Nunito", size: size * 0.525).weight(.bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct TimelineReviewRatingIcon: View {
    let rating: TimelineReviewRating
    let size: CGFloat

    var body: some View {
        switch rating {
        case .distracted:
            Image(systemName: "scribble")
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundColor(rating.iconTint)
                .frame(width: size, height: size)
        case .neutral:
            NeutralFaceIcon(size: size, color: rating.iconTint)
        case .focused:
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundColor(rating.iconTint)
                .frame(width: size, height: size)
        }
    }
}

private struct TimelineReviewFooterIcon: View {
    let rating: TimelineReviewRating
    let size: CGFloat

    private var rotation: Angle {
        switch rating {
        case .distracted:
            return .degrees(0)
        case .neutral:
            return .degrees(90)
        case .focused:
            return .degrees(180)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Color(hex: "D6AB8A").opacity(0.7))
            Path { path in
                path.move(to: CGPoint(x: size * 0.3125, y: size * 0.5))
                path.addLine(to: CGPoint(x: size * 0.59375, y: size * 0.33762))
                path.addLine(to: CGPoint(x: size * 0.59375, y: size * 0.66238))
                path.closeSubpath()
            }
            .fill(Color.white)
        }
        .frame(width: size, height: size)
        .rotationEffect(rotation)
    }
}

private struct NeutralFaceIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size * 0.23, height: size * 0.23)
                .offset(x: -size * 0.2, y: -size * 0.05)
            Circle()
                .fill(color)
                .frame(width: size * 0.35, height: size * 0.35)
                .offset(x: size * 0.15, y: -size * 0.08)

            HStack(spacing: size * 0.08) {
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.08, height: size * 0.05)
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.13, height: size * 0.05)
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.13, height: size * 0.05)
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.13, height: size * 0.05)
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.13, height: size * 0.05)
            }
            .offset(y: size * 0.25)
        }
        .frame(width: size, height: size)
    }
}

private struct TimelineReviewSummary {
    let durationByRating: [TimelineReviewRating: TimeInterval]

    var totalDuration: TimeInterval {
        durationByRating.values.reduce(0, +)
    }

    var nonZeroRatings: [TimelineReviewRating] {
        TimelineReviewRating.allCases.filter { (durationByRating[$0, default: 0]) > 0 }
    }

    func ratio(for rating: TimelineReviewRating) -> CGFloat {
        let total = totalDuration
        guard total > 0 else { return 0 }
        return CGFloat(durationByRating[rating, default: 0] / total)
    }
}

private struct TimelineReviewSummaryBars: View {
    let summary: TimelineReviewSummary

    var body: some View {
        VStack(spacing: 16) {
            SummaryBarRow(summary: summary)
            SummaryLabelRow(summary: summary)
        }
    }
}

private struct SummaryBarRow: View {
    let summary: TimelineReviewSummary

    var body: some View {
        GeometryReader { proxy in
            let ratings = summary.nonZeroRatings
            let spacing: CGFloat = 8
            let available = max(proxy.size.width - spacing * CGFloat(max(ratings.count - 1, 0)), 0)

            HStack(spacing: spacing) {
                ForEach(ratings) { rating in
                    let ratio = summary.ratio(for: rating)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(rating.barGradient)
                        .frame(width: available * ratio, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(rating.barStroke, lineWidth: 1)
                        )
                        .shadow(color: rating.barStroke.opacity(0.25), radius: 4, x: 0, y: 2)
                }
            }
            .frame(width: proxy.size.width, height: 40, alignment: .leading)
        }
        .frame(height: 40)
    }
}

private struct SummaryLabelRow: View {
    let summary: TimelineReviewSummary

    var body: some View {
        HStack(spacing: 28) {
            ForEach(summary.nonZeroRatings) { rating in
                let duration = summary.durationByRating[rating, default: 0]
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        TimelineReviewRatingIcon(rating: rating, size: 16)
                        Text(rating.title)
                            .font(.custom("Nunito", size: 12).weight(.regular))
                            .foregroundColor(rating.labelColor)
                    }
                    Text(formatDuration(duration))
                        .font(.custom("Nunito", size: 16).weight(.semibold))
                        .foregroundColor(Color(hex: "333333"))
                        .padding(.leading, 18)
                }
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(Int(duration / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}

private struct TimelineReviewKeyHandler: NSViewRepresentable {
    let onMove: (MoveCommandDirection) -> Void
    let onBack: () -> Void
    let onEscape: () -> Void
    let onTogglePlayback: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.onMove = onMove
        view.onBack = onBack
        view.onEscape = onEscape
        view.onTogglePlayback = onTogglePlayback
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? KeyCaptureView {
            view.onMove = onMove
            view.onBack = onBack
            view.onEscape = onEscape
            view.onTogglePlayback = onTogglePlayback
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    private final class KeyCaptureView: NSView {
        var onMove: ((MoveCommandDirection) -> Void)?
        var onBack: (() -> Void)?
        var onEscape: (() -> Void)?
        var onTogglePlayback: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if let characters = event.charactersIgnoringModifiers?.lowercased(),
               characters == "z" {
                onBack?()
                return
            }
            switch event.keyCode {
            case 53:
                onEscape?()
            case 49:
                onTogglePlayback?()
            case 123:
                onMove?(.left)
            case 124:
                onMove?(.right)
            case 126:
                onMove?(.up)
            default:
                super.keyDown(with: event)
            }
        }
    }
}

private struct TrackpadScrollHandler: NSViewRepresentable {
    let shouldHandleScroll: (CGSize) -> Bool
    let onScrollBegan: () -> Void
    let onScrollChanged: (CGSize) -> Void
    let onScrollEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldHandleScroll: shouldHandleScroll,
            onScrollBegan: onScrollBegan,
            onScrollChanged: onScrollChanged,
            onScrollEnded: onScrollEnded
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldHandleScroll = shouldHandleScroll
        context.coordinator.onScrollBegan = onScrollBegan
        context.coordinator.onScrollChanged = onScrollChanged
        context.coordinator.onScrollEnded = onScrollEnded
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator: NSObject {
        var shouldHandleScroll: (CGSize) -> Bool
        var onScrollBegan: () -> Void
        var onScrollChanged: (CGSize) -> Void
        var onScrollEnded: () -> Void
        private var monitor: Any?
        private var isTracking = false

        init(
            shouldHandleScroll: @escaping (CGSize) -> Bool,
            onScrollBegan: @escaping () -> Void,
            onScrollChanged: @escaping (CGSize) -> Void,
            onScrollEnded: @escaping () -> Void
        ) {
            self.shouldHandleScroll = shouldHandleScroll
            self.onScrollBegan = onScrollBegan
            self.onScrollChanged = onScrollChanged
            self.onScrollEnded = onScrollEnded
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self else { return event }
                if event.momentumPhase != [] {
                    if self.isTracking {
                        self.isTracking = false
                        self.onScrollEnded()
                    }
                    return event
                }

                var deltaX = event.scrollingDeltaX
                var deltaY = event.scrollingDeltaY
                if event.isDirectionInvertedFromDevice == false {
                    deltaX = -deltaX
                    deltaY = -deltaY
                }

                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
                let scaledDelta = CGSize(width: deltaX * scale, height: deltaY * scale)
                guard self.shouldHandleScroll(scaledDelta) else {
                    if event.phase == .ended || event.phase == .cancelled {
                        if self.isTracking {
                            self.isTracking = false
                            self.onScrollEnded()
                        }
                    }
                    return event
                }

                if event.phase == .began || event.phase == .mayBegin {
                    if self.isTracking == false {
                        self.isTracking = true
                        self.onScrollBegan()
                    }
                } else if self.isTracking == false {
                    self.isTracking = true
                    self.onScrollBegan()
                }

                self.onScrollChanged(scaledDelta)

                if event.phase == .ended || event.phase == .cancelled {
                    if self.isTracking {
                        self.isTracking = false
                        self.onScrollEnded()
                    }
                }

                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private func makeTimelineActivities(from cards: [TimelineCard], for date: Date) -> [TimelineActivity] {
    let calendar = Calendar.current
    let baseDate = calendar.startOfDay(for: date)

    var results: [TimelineActivity] = []
    var idCounts: [String: Int] = [:]
    results.reserveCapacity(cards.count)

    for card in cards {
        guard let startDate = cachedReviewTimeFormatter.date(from: card.startTimestamp),
              let endDate = cachedReviewTimeFormatter.date(from: card.endTimestamp) else {
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
            appSites: card.appSites
        ))
    }

    return results
}
