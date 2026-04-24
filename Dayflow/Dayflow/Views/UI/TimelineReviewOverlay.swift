import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - Main Overlay View

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
      AnalyticsService.shared.capture(
        "timeline_review_closed",
        [
          "source": lastCloseSource?.rawValue ?? "unknown"
        ])
    }
    .onChange(of: selectedDate) { _, _ in
      loadActivities()
    }
    .background(
      TimelineReviewKeyHandler(
        onMove: { direction in handleMoveCommand(direction) },
        onBack: { goBackOneCard(input: .keyboard) },
        onEscape: { dismissOverlay() },
        onTogglePlayback: { playbackToggleToken &+= 1 }
      )
      .frame(width: 0, height: 0)
    )
    .background(
      TrackpadScrollHandler(
        shouldHandleScroll: { delta in
          if isTrackpadDragging { return true }
          guard isPointerOverSummary else { return true }
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
                .overlay(Circle().stroke(Color(hex: "DABCA4"), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
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
        Spacer().frame(height: ReviewLayout.topPadding)

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
                  if isActive { isPointerOverSummary = hovering }
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
                if cardSize != computedCardSize { cardSize = computedCardSize }
              }
              .onChange(of: computedCardSize) { _, newValue in
                if cardSize != newValue { cardSize = newValue }
              }
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Spacer().frame(height: ReviewLayout.cardToTextSpacing)

        reviewBottomContent
          .frame(width: availableWidth)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.center)

        Spacer().frame(height: ReviewLayout.bottomPadding)
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

      TimelineReviewRatingRow(
        onUndo: { goBackOneCard(input: .button) },
        onSelect: { rating in commitRating(rating, input: .button) }
      )
    }
  }

  private var summaryState: some View {
    let summary = ratingSummary
    return VStack(spacing: 30) {
      VStack(spacing: 12) {
        Text("All caught up!")
          .font(.custom("InstrumentSerif-Regular", size: 40))
          .foregroundColor(Color(hex: "333333"))
        Text(
          "You've reviewed all your activities so far.\nThe Timeline right panel will be updated with your rating."
        )
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
                Capsule().stroke(Color(hex: "FF8904").opacity(0.5), lineWidth: 1.25)
              )
          )
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
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
      commitRating(
        .distracted, predictedTranslation: TimelineReviewRating.distracted.swipeOffset,
        input: .keyboard)
    case .right:
      commitRating(
        .focused, predictedTranslation: TimelineReviewRating.focused.swipeOffset, input: .keyboard)
    case .up:
      commitRating(
        .neutral, predictedTranslation: TimelineReviewRating.neutral.swipeOffset, input: .keyboard)
    default:
      break
    }
  }

  private func goBackOneCard(input: TimelineReviewInput) {
    guard !isAnimatingOut, !isBackAnimating else { return }
    guard currentIndex > 0 else { return }
    AnalyticsService.shared.capture("timeline_review_undo", ["input": input.rawValue])
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

    let minimumUpdateDelta: CGFloat = 2.5
    let deltaFromRenderedState = CGSize(
      width: trackpadTranslation.width - dragOffset.width,
      height: trackpadTranslation.height - dragOffset.height
    )
    guard
      abs(deltaFromRenderedState.width) >= minimumUpdateDelta
        || abs(deltaFromRenderedState.height) >= minimumUpdateDelta
    else {
      return
    }

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

  private func ratingForGesture(_ translation: CGSize, allowThreshold: Bool = false)
    -> TimelineReviewRating?
  {
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
    AnalyticsService.shared.capture(
      "timeline_review_swipe", ["direction": direction, "input": input.rawValue])

    let startTs = Int(activity.startTime.timeIntervalSince1970)
    let endTs = Int(activity.endTime.timeIntervalSince1970)
    StorageManager.shared.applyReviewRating(startTs: startTs, endTs: endTs, rating: rating.rawValue)
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
      withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { reset() }
    } else {
      reset()
    }
  }

  private func swipeExitOffset(for rating: TimelineReviewRating, predictedTranslation: CGSize?)
    -> CGSize
  {
    let direction =
      swipeDirectionVector(predictedTranslation) ?? swipeDirectionVector(rating.swipeOffset)
      ?? CGSize(width: 0, height: -1)
    let distance = max(cardSize.width, cardSize.height) * 1.6
    return CGSize(width: direction.width * distance, height: direction.height * distance)
  }

  private func swipeDirectionVector(_ translation: CGSize?) -> CGSize? {
    guard let translation else { return nil }
    let magnitude = sqrt(
      (translation.width * translation.width) + (translation.height * translation.height))
    guard magnitude > 4 else { return nil }
    return CGSize(width: translation.width / magnitude, height: translation.height / magnitude)
  }

  private func swipeExitRotation(for rating: TimelineReviewRating, predictedTranslation: CGSize?)
    -> Double
  {
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
    let magnitude = sqrt(
      (predictedTranslation.width * predictedTranslation.width)
        + (predictedTranslation.height * predictedTranslation.height))
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
        .filter {
          $0.category.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
            "System") != .orderedSame
        }
        .sorted { $0.startTime < $1.startTime }
      let ratingSegments = StorageManager.shared.fetchReviewRatingSegments(
        overlapping: dayStartTs, endTs: dayEndTs)
      let summary = Self.makeRatingSummary(
        segments: ratingSegments, dayStartTs: dayStartTs, dayEndTs: dayEndTs)
      let reviewActivities = Self.filterUnreviewedActivities(
        activities: activities, ratingSegments: ratingSegments, dayStartTs: dayStartTs,
        dayEndTs: dayEndTs)
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

  private var ratingSummary: TimelineReviewSummary { dayRatingSummary }

  private func refreshRatingSummary() {
    let timelineDate = timelineDisplayDate(from: selectedDate)
    let dayInfo = timelineDate.getDayInfoFor4AMBoundary()
    let dayStartTs = Int(dayInfo.startOfDay.timeIntervalSince1970)
    let dayEndTs = Int(dayInfo.endOfDay.timeIntervalSince1970)

    Task.detached(priority: .userInitiated) {
      let segments = StorageManager.shared.fetchReviewRatingSegments(
        overlapping: dayStartTs, endTs: dayEndTs)
      let summary = Self.makeRatingSummary(
        segments: segments, dayStartTs: dayStartTs, dayEndTs: dayEndTs)
      await MainActor.run {
        dayRatingSummary = summary
      }
    }
  }

  nonisolated private static func makeRatingSummary(
    segments: [TimelineReviewRatingSegment], dayStartTs: Int, dayEndTs: Int
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
    activities: [TimelineActivity], ratingSegments: [TimelineReviewRatingSegment], dayStartTs: Int,
    dayEndTs: Int
  ) -> [TimelineActivity] {
    guard ratingSegments.isEmpty == false else { return activities }
    let mergedSegments = mergedCoverageSegments(
      segments: ratingSegments, dayStartTs: dayStartTs, dayEndTs: dayEndTs)
    guard mergedSegments.isEmpty == false else { return activities }

    var unreviewed: [TimelineActivity] = []
    var segmentIndex = 0

    for activity in activities {
      let start = Int(activity.startTime.timeIntervalSince1970)
      let end = Int(activity.endTime.timeIntervalSince1970)
      let duration = max(end - start, 1)
      let covered = overlapSeconds(
        start: start, end: end, segments: mergedSegments, segmentIndex: &segmentIndex)
      let coverageRatio = Double(covered) / Double(duration)
      if coverageRatio < 0.8 {
        unreviewed.append(activity)
      }
    }
    return unreviewed
  }

  nonisolated private static func mergedCoverageSegments(
    segments: [TimelineReviewRatingSegment], dayStartTs: Int, dayEndTs: Int
  ) -> [CoverageSegment] {
    var clipped: [CoverageSegment] = []
    clipped.reserveCapacity(segments.count)

    for segment in segments {
      let start = max(segment.startTs, dayStartTs)
      let end = min(segment.endTs, dayEndTs)
      if end > start { clipped.append(CoverageSegment(start: start, end: end)) }
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
    start: Int, end: Int, segments: [CoverageSegment], segmentIndex: inout Int
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

// MARK: - Core Playback Management

// MARK: - AppKit Native 120Hz Progress Bar
// Eradicates ALL high-frequency SwiftUI Layout/GeometryReader loops. It calculates pure math directly on hardware layers.

// MARK: - Smaller Components
