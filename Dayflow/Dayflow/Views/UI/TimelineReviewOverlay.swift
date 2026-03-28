import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - Time Optimizations

/// O(1) Cache for display times to prevent severe UI thread stutter when formatting strings rapidly.
@MainActor
private final class TimelineReviewTimeCache {
  static let shared = TimelineReviewTimeCache()
  private var cache: [Int: String] = [:]

  private let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  func string(from date: Date) -> String {
    let minute = Int(date.timeIntervalSince1970) / 60
    if let str = cache[minute] {
      return str
    }
    // Prevent unbounded memory growth over long app sessions
    if cache.count > 500 {
      cache.removeAll(keepingCapacity: true)
    }
    let str = formatter.string(from: date)
    cache[minute] = str
    return str
  }
}

private let cachedReviewTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  formatter.locale = Locale(identifier: "en_US_POSIX")
  return formatter
}()

// MARK: - Enums

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

@MainActor
private final class TimelineReviewPlaybackTimelineState: ObservableObject {
  // EXPLICITLY NOT @Published to absolutely eradicate the 120fps SwiftUI layout diffing issue.
  // Changes here now trigger raw Core Animation logic seamlessly with 0% CPU impact.
  var currentTime: Double = 0 {
    didSet { onTimeChange?(currentTime) }
  }
  var duration: Double = 1 {
    didSet { onTimeChange?(currentTime) }
  }
  var onTimeChange: ((Double) -> Void)?

  @Published var speedLabel: String = "60x"
  @Published var isPlaying: Bool = false
}

@MainActor
private final class TimelineReviewPlaybackMediaState: ObservableObject {
  @Published var currentImage: CGImage?
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

  @AppStorage(TimelapsePreferences.saveAllTimelapsesToDiskKey) private var saveAllTimelapsesToDisk =
    false
  @StateObject private var playerModel: TimelineReviewPlayerModel
  @StateObject private var legacyPlayerModel: TimelineReviewLegacyPlayerModel
  private let previewSource = TimelineReviewScreenshotSource()
  @State private var isHoveringMedia = false
  @State private var previewImage: CGImage?
  @State private var previewRequestID: Int = 0
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
    _playerModel = StateObject(wrappedValue: TimelineReviewPlayerModel(activity: activity))
    _legacyPlayerModel = StateObject(wrappedValue: TimelineReviewLegacyPlayerModel())
  }

  var body: some View {
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.white)
        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)

      VStack(spacing: 0) {
        TimelineReviewCardMedia(
          previewImage: previewImage,
          playbackState: playerModel.mediaState,
          player: usingVideoPlayer ? legacyPlayerModel.player : nil,
          onTogglePlayback: {
            guard isActive else { return }
            togglePlayback()
          }
        )
        .frame(height: Design.mediaHeight)
        .overlay(alignment: .bottom) {
          TimelineReviewPlaybackTimeline(
            playbackState: activePlaybackState,
            activityStartTime: activity.startTime,
            activityEndTime: activity.endTime,
            mediaHeight: Design.mediaHeight,
            lineHeight: Design.progressLineHeight,
            isInteractive: isActive,
            onScrubStart: beginScrub,
            onScrubChange: updateScrub(progress:),
            onScrubEnd: endScrub
          )
          .frame(height: Design.timelineHeight)
        }
        .overlay(alignment: .bottomTrailing) {
          if isHoveringMedia && isActive {
            TimelineReviewSpeedChip(
              playbackState: activePlaybackState,
              onTap: {
                if usingVideoPlayer {
                  legacyPlayerModel.cycleSpeed()
                } else {
                  playerModel.cycleSpeed()
                }
              }
            )
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
          .onHover { hovering in onSummaryHover(hovering) }

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
    .overlay {
      if !usingVideoPlayer {
        TimelineReviewDisplayLinkDriver(
          playbackState: playerModel.timelineState,
          isEnabled: isActive,
          onTick: { displayLink in playerModel.handleDisplayTick(displayLink) }
        )
        .allowsHitTesting(false)
      }
    }
    .onAppear { syncPlaybackMode() }
    .onChange(of: isActive) { syncPlaybackMode() }
    .onChange(of: activity.id) { syncPlaybackMode() }
    .onChange(of: activity.videoSummaryURL) { syncPlaybackMode() }
    .onChange(of: saveAllTimelapsesToDisk) { syncPlaybackMode() }
    .onChange(of: playbackToggleToken) { _, _ in
      guard isActive else { return }
      togglePlayback()
    }
  }

  private var summaryText: String {
    activity.summary.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var timeRangeText: String {
    let start = TimelineReviewTimeCache.shared.string(from: activity.startTime)
    let end = TimelineReviewTimeCache.shared.string(from: activity.endTime)
    return "\(start) - \(end)"
  }

  private var usingVideoPlayer: Bool {
    usesLegacySavedTimelapsePlayback && legacyPlayerModel.player != nil
  }

  private func beginScrub() {
    guard isActive else { return }
    if usingVideoPlayer {
      wasPlayingBeforeScrub = legacyPlayerModel.timelineState.isPlaying
      legacyPlayerModel.pause()
    } else {
      wasPlayingBeforeScrub = playerModel.timelineState.isPlaying
      playerModel.pause()
    }
  }

  private func updateScrub(progress: CGFloat) {
    guard isActive else { return }
    let seconds = Double(progress) * activePlaybackState.duration
    if usingVideoPlayer {
      legacyPlayerModel.seek(to: seconds, resume: false)
    } else {
      playerModel.seek(to: seconds, resume: false)
    }
  }

  private func endScrub() {
    guard isActive else { return }
    if wasPlayingBeforeScrub {
      if usingVideoPlayer { legacyPlayerModel.play() } else { playerModel.play() }
    } else {
      // Force final seek to guarantee the exact frame is rendered if left paused
      if !usingVideoPlayer {
        playerModel.seek(to: playerModel.timelineState.currentTime, resume: false)
      }
    }
    wasPlayingBeforeScrub = false
  }

  private var activePlaybackState: TimelineReviewPlaybackTimelineState {
    usingVideoPlayer ? legacyPlayerModel.timelineState : playerModel.timelineState
  }

  private func togglePlayback() {
    if usingVideoPlayer { legacyPlayerModel.togglePlay() } else { playerModel.togglePlay() }
  }

  private var usesLegacySavedTimelapsePlayback: Bool {
    saveAllTimelapsesToDisk && !(activity.videoSummaryURL?.isEmpty ?? true)
  }

  private func syncPlaybackMode() {
    if usesLegacySavedTimelapsePlayback {
      previewRequestID &+= 1
      let requestID = previewRequestID
      playerModel.reset()
      legacyPlayerModel.updateVideo(url: activity.videoSummaryURL)
      legacyPlayerModel.setActive(isActive)

      // Generate a thumbnail from the video to show while the player loads
      if let videoURL = activity.videoSummaryURL {
        let targetSize = CGSize(width: 340, height: Design.mediaHeight)
        ThumbnailCache.shared.fetchThumbnail(videoURL: videoURL, targetSize: targetSize) { image in
          guard requestID == previewRequestID else { return }
          previewImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
      } else {
        previewImage = nil
      }
      return
    }

    legacyPlayerModel.resetIfNeeded()
    loadPreviewIfNeeded()

    if isActive {
      playerModel.updateActivity(activity)
      playerModel.setActive(true)
      return
    }
    playerModel.reset()
  }

  private func loadPreviewIfNeeded() {
    previewRequestID &+= 1
    let requestID = previewRequestID
    let targetSize = CGSize(width: 340, height: Design.mediaHeight)

    Task {
      let screenshotURL = await previewSource.previewScreenshotURL(for: activity)
      guard !Task.isCancelled else { return }

      guard let screenshotURL else {
        await MainActor.run {
          guard requestID == previewRequestID else { return }
          previewImage = nil
        }
        return
      }

      await MainActor.run {
        guard requestID == previewRequestID else { return }
        ScreenshotThumbnailCache.shared.fetchThumbnail(
          fileURL: screenshotURL, targetSize: targetSize
        ) { image in
          guard requestID == previewRequestID else { return }
          previewImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
      }
    }
  }

  private enum Design {
    static let mediaHeight: CGFloat = 220
    static let progressLineHeight: CGFloat = 4
    static let timelineHeight: CGFloat = 28
  }
  private enum SpeedChipDesign { static let padding: CGFloat = 10 }
}

@MainActor
private final class TimelineReviewLegacyPlayerModel: ObservableObject {
  let timelineState = TimelineReviewPlaybackTimelineState()

  private static let speedDefaultsKey = "timelineReviewPlaybackSpeedMultiplier"
  let speedOptions: [Float] = [1.0, 2.0, 3.0, 6.0]

  var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: Any?
  private var shouldPlayWhenReady = false
  private var currentURL: String?
  private var playbackSpeed: Float = 3.0
  private var didReachEnd = false

  init() {
    if let savedSpeed = Self.loadSavedSpeed(from: speedOptions) { playbackSpeed = savedSpeed }
    timelineState.speedLabel = currentSpeedLabel
  }

  func updateVideo(url: String?) {
    guard url != currentURL else { return }
    currentURL = url
    cleanupPlayer()
    guard let url, let resolvedURL = resolveVideoURL(url) else { return }

    let player = AVPlayer(url: resolvedURL)
    player.isMuted = true
    player.actionAtItemEnd = .pause
    self.player = player
    didReachEnd = false
    timelineState.currentTime = 0

    observeDuration(for: player.currentItem)
    addTimeObserver()
    addEndObserver(for: player.currentItem)
    if shouldPlayWhenReady { play() }
  }

  func setActive(_ active: Bool) {
    shouldPlayWhenReady = active
    if active { play() } else { pause() }
  }

  func resetIfNeeded() {
    shouldPlayWhenReady = false
    currentURL = nil
    cleanupPlayer()
  }

  func cycleSpeed() {
    guard let idx = speedOptions.firstIndex(of: playbackSpeed) else {
      setPlaybackSpeed(speedOptions.last ?? 3.0)
      return
    }
    setPlaybackSpeed(speedOptions[(idx + 1) % speedOptions.count])
  }

  func togglePlay() {
    if didReachEnd {
      seek(to: 0, resume: true)
      return
    }
    if timelineState.isPlaying { pause() } else { play() }
  }

  func seek(to seconds: Double, resume: Bool? = nil) {
    let clamped = min(max(seconds, 0), timelineState.duration)
    guard let player else { return }
    didReachEnd = clamped >= max(timelineState.duration - 0.01, 0)
    timelineState.currentTime = clamped
    let target = CMTime(seconds: clamped, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    if let resume { resume ? play() : pause() }
  }

  func play() {
    guard let player else { return }
    if didReachEnd {
      didReachEnd = false
      timelineState.currentTime = 0
      player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    player.play()
    player.rate = playbackSpeed
    timelineState.isPlaying = true
  }

  func pause() {
    player?.pause()
    timelineState.isPlaying = false
  }

  private func setPlaybackSpeed(_ speed: Float) {
    playbackSpeed = speed
    UserDefaults.standard.set(Double(speed), forKey: Self.speedDefaultsKey)
    timelineState.speedLabel = currentSpeedLabel
    if player?.rate ?? 0 > 0 { player?.rate = speed }
  }

  private func observeDuration(for item: AVPlayerItem?) {
    guard let asset = item?.asset else { return }
    Task { [weak self] in
      do {
        let loadedDuration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(loadedDuration)
        let resolvedDuration = seconds.isFinite && seconds > 0 ? seconds : 1
        DispatchQueue.main.async { [weak self] in self?.timelineState.duration = resolvedDuration }
      } catch {
        DispatchQueue.main.async { [weak self] in self?.timelineState.duration = 1 }
      }
    }
  }

  private func addTimeObserver() {
    guard let player else { return }
    let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    // Callbacks from AVPlayer directly to main thread triggers the native property update cleanly
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self] time in
      self?.timelineState.currentTime = CMTimeGetSeconds(time)
    }
  }

  private func addEndObserver(for item: AVPlayerItem?) {
    guard let item else { return }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.didReachEnd = true
        self?.timelineState.isPlaying = false
      }
    }
  }

  private func cleanupPlayer() {
    if let timeObserver, let player {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    player?.pause()
    player = nil
    timelineState.currentTime = 0
    timelineState.duration = 1
    timelineState.isPlaying = false
    didReachEnd = false
  }

  private func resolveVideoURL(_ string: String) -> URL? {
    if string.hasPrefix("file://") { return URL(string: string) }
    return URL(fileURLWithPath: string)
  }

  private static func loadSavedSpeed(from options: [Float]) -> Float? {
    let saved = UserDefaults.standard.double(forKey: speedDefaultsKey)
    guard saved > 0 else { return nil }
    let savedFloat = Float(saved)
    return options.first(where: { abs($0 - savedFloat) < 0.001 })
  }

  private var currentSpeedLabel: String { "\(Int(playbackSpeed * 20))x" }
}

@MainActor
private final class TimelineReviewPlayerModel: ObservableObject {
  private static let speedDefaultsKey = "timelineReviewPlaybackSpeedMultiplier"
  let speedOptions: [Float] = [1.0, 2.0, 3.0, 6.0]
  let mediaState = TimelineReviewPlaybackMediaState()
  let timelineState = TimelineReviewPlaybackTimelineState()

  private let screenshotSource = TimelineReviewScreenshotSource()
  private var frameLoader: TimelineReviewFrameLoader?
  private var frameOffsets: [Double] = []
  private var currentIndex = 0
  private var shouldPlayWhenReady = false
  private var currentActivityID: String?
  private var sourceRequestID = 0
  private var frameRequestID = 0
  private var fallbackDurationSeconds: Double = 1
  private var averageFrameIntervalSeconds: Double = max(0.1, ScreenshotConfig.interval)
  private var loadTask: Task<Void, Never>?
  private var playbackSpeed: Float = 3.0
  private var didReachEnd = false
  private var pendingFrameIndex: Int?

  private var internalCurrentTime: Double = 0
  private var lastDisplayTimestamp: CFTimeInterval?
  private var lastFrameDisplayTime: CFTimeInterval = 0

  init(activity: TimelineActivity) {
    if let savedSpeed = Self.loadSavedSpeed(from: speedOptions) { playbackSpeed = savedSpeed }
    timelineState.speedLabel = currentSpeedLabel
    updateActivity(activity)
  }

  deinit { loadTask?.cancel() }

  func reset() {
    loadTask?.cancel()
    loadTask = nil
    frameLoader = nil
    frameOffsets = []
    currentIndex = 0
    mediaState.currentImage = nil
    timelineState.currentTime = 0
    internalCurrentTime = 0
    timelineState.duration = 1
    timelineState.isPlaying = false
    didReachEnd = false
    shouldPlayWhenReady = false
    currentActivityID = nil
    sourceRequestID &+= 1
    frameRequestID &+= 1
    pendingFrameIndex = nil
    lastDisplayTimestamp = nil
    lastFrameDisplayTime = 0
  }

  func setActive(_ active: Bool) {
    shouldPlayWhenReady = active
    if active { play() } else { pause() }
  }

  func updateActivity(_ activity: TimelineActivity) {
    guard activity.id != currentActivityID else { return }
    currentActivityID = activity.id
    sourceRequestID &+= 1
    let requestID = sourceRequestID

    loadTask?.cancel()
    frameRequestID &+= 1
    frameLoader = nil
    frameOffsets = []
    currentIndex = 0
    mediaState.currentImage = nil
    timelineState.currentTime = 0
    internalCurrentTime = 0
    didReachEnd = false
    timelineState.isPlaying = false
    fallbackDurationSeconds = max(0.1, activity.endTime.timeIntervalSince(activity.startTime))
    timelineState.duration = fallbackDurationSeconds
    averageFrameIntervalSeconds = max(0.1, ScreenshotConfig.interval)
    pendingFrameIndex = nil
    lastDisplayTimestamp = nil
    lastFrameDisplayTime = 0

    loadTask = Task { [activity] in
      let screenshots = await screenshotSource.screenshots(for: activity)
      guard Task.isCancelled == false else { return }

      await MainActor.run {
        guard requestID == self.sourceRequestID else { return }
        self.configureScreenshots(screenshots)
        if self.shouldPlayWhenReady { self.play() }
      }
    }
  }

  func cycleSpeed() {
    guard let idx = speedOptions.firstIndex(of: playbackSpeed) else {
      setPlaybackSpeed(speedOptions.last ?? 3.0)
      return
    }
    setPlaybackSpeed(speedOptions[(idx + 1) % speedOptions.count])
  }

  func togglePlay() {
    if didReachEnd {
      seek(to: 0, resume: true)
      return
    }
    if timelineState.isPlaying { pause() } else { play() }
  }

  func seek(to seconds: Double, resume: Bool? = nil) {
    guard frameCount > 0 else { return }
    let clamped = min(max(seconds, 0), timelineDurationSeconds)
    didReachEnd = clamped >= max(timelineDurationSeconds - 0.01, 0)

    // Updates UI internal time immediately overriding any clock throttles
    internalCurrentTime = clamped
    timelineState.currentTime = clamped

    let index = frameIndex(forTimelineTime: clamped)

    let now = CACurrentMediaTime()
    if resume != nil || now - lastFrameDisplayTime >= (1.0 / 30.0) {
      lastFrameDisplayTime = now
      triggerFrameDecode(at: index, updateTimelineTime: false)
    }

    lastDisplayTimestamp = nil
    if let resume { resume ? play() : pause() }
  }

  private func setPlaybackSpeed(_ speed: Float) {
    playbackSpeed = speed
    UserDefaults.standard.set(Double(speed), forKey: Self.speedDefaultsKey)
    timelineState.speedLabel = currentSpeedLabel
  }

  func play() {
    guard frameCount > 0 else { return }
    if didReachEnd {
      didReachEnd = false
      seek(to: 0, resume: false)
    }
    timelineState.isPlaying = true
    lastDisplayTimestamp = nil
  }

  func pause() {
    timelineState.isPlaying = false
    lastDisplayTimestamp = nil
  }

  private var frameCount: Int { frameOffsets.count }

  private func configureScreenshots(_ screenshots: [Screenshot]) {
    frameLoader =
      screenshots.isEmpty
      ? nil
      : TimelineReviewFrameLoader(
        screenshots: screenshots, targetSize: CGSize(width: 340, height: 220))

    if let firstCapture = screenshots.first?.capturedAt {
      frameOffsets = screenshots.map { Double(max(0, $0.capturedAt - firstCapture)) }
    } else {
      frameOffsets = []
    }

    if screenshots.count > 1, let firstCapture = screenshots.first?.capturedAt,
      let lastCapture = screenshots.last?.capturedAt
    {
      let totalSeconds = Double(max(1, lastCapture - firstCapture))
      fallbackDurationSeconds = max(fallbackDurationSeconds, totalSeconds)
      averageFrameIntervalSeconds = max(0.1, totalSeconds / Double(screenshots.count - 1))
    } else {
      averageFrameIntervalSeconds = max(0.1, ScreenshotConfig.interval)
    }

    timelineState.duration = timelineDurationSeconds
    currentIndex = 0
    internalCurrentTime = 0
    timelineState.currentTime = 0
    didReachEnd = false
    mediaState.currentImage = nil

    guard frameCount > 0 else { return }
    triggerFrameDecode(at: 0, updateTimelineTime: true)
  }

  func handleDisplayTick(_ displayLink: CADisplayLink) {
    guard timelineState.isPlaying, frameCount > 1 else {
      lastDisplayTimestamp = nil
      return
    }

    let previousTimestamp = lastDisplayTimestamp ?? displayLink.timestamp
    let currentTimestamp = max(displayLink.targetTimestamp, displayLink.timestamp)
    let deltaSeconds = min(max(currentTimestamp - previousTimestamp, 0), 0.1)
    lastDisplayTimestamp = currentTimestamp
    guard deltaSeconds > 0 else { return }

    let speedMultiplier = max(1.0, Double(playbackSpeed) * 20.0)
    let nextTime = min(
      timelineDurationSeconds, internalCurrentTime + (deltaSeconds * speedMultiplier))
    internalCurrentTime = nextTime

    // Direct NSView layer updates without SwiftUI tracking (0% CPU diffing impact)
    timelineState.currentTime = nextTime

    let nextIndex = frameIndex(forTimelineTime: nextTime)
    if nextIndex != currentIndex {
      // CoreGraphics decode hardware capped strictly to ~30 FPS preventing Core Starvation
      if currentTimestamp - lastFrameDisplayTime >= (1.0 / 30.0) {
        lastFrameDisplayTime = currentTimestamp
        triggerFrameDecode(at: nextIndex, updateTimelineTime: false)
      }
    }

    if nextTime >= timelineDurationSeconds {
      didReachEnd = true
      timelineState.isPlaying = false
      timelineState.currentTime = timelineDurationSeconds
    }
  }

  private func frameOffset(for index: Int) -> Double {
    guard frameOffsets.indices.contains(index) else {
      return min(Double(index) * averageFrameIntervalSeconds, timelineDurationSeconds)
    }
    return frameOffsets[index]
  }

  private var timelineDurationSeconds: Double {
    max(0.001, max(frameOffsets.last ?? 0, fallbackDurationSeconds))
  }
  private var currentSpeedLabel: String { "\(Int(playbackSpeed * 20))x" }

  private func frameIndex(forTimelineTime seconds: Double) -> Int {
    guard !frameOffsets.isEmpty else { return 0 }
    // Binary Search guarantees 0(log n) efficiency at exactly 0.00 ms duration hit
    var low = 0
    var high = frameOffsets.count - 1
    var bestIndex = 0
    while low <= high {
      let mid = low + (high - low) / 2
      if frameOffsets[mid] <= seconds {
        bestIndex = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return bestIndex
  }

  // Eliminated all Async Task Allocations inside the loop for raw GCD closures.
  private func triggerFrameDecode(at index: Int, updateTimelineTime: Bool) {
    guard pendingFrameIndex != index else { return }
    pendingFrameIndex = index

    let clamped = min(max(0, index), frameCount - 1)
    frameRequestID &+= 1
    let requestID = frameRequestID

    let speedMultiplier = Double(playbackSpeed) * 20.0
    let step = max(1, Int(speedMultiplier * (1.0 / 30.0) / averageFrameIntervalSeconds))

    // Aggressive surgical queue clearing stops invisible processing.
    let window = (step * 3) + 2
    frameLoader?.cancelPending(keepingNear: clamped, lookahead: window)

    frameLoader?.requestImage(at: clamped) { [weak self] image in
      guard let self = self else { return }
      guard requestID == self.frameRequestID else { return }

      self.currentIndex = clamped
      self.pendingFrameIndex = nil
      self.mediaState.currentImage = image

      if updateTimelineTime {
        self.internalCurrentTime = self.frameOffset(for: clamped)
        self.timelineState.currentTime = self.internalCurrentTime
      }

      self.frameLoader?.prefetch(after: clamped, lookahead: 1, step: step)
    }
  }

  private static func loadSavedSpeed(from options: [Float]) -> Float? {
    let saved = UserDefaults.standard.double(forKey: speedDefaultsKey)
    guard saved > 0 else { return nil }
    let savedFloat = Float(saved)
    return options.first(where: { abs($0 - savedFloat) < 0.001 })
  }
}

private actor TimelineReviewScreenshotSource {
  private let storage: any StorageManaging

  init(storage: any StorageManaging = StorageManager.shared) {
    self.storage = storage
  }

  func screenshots(for activity: TimelineActivity) -> [Screenshot] {
    if let recordId = activity.recordId,
      let timelineCard = storage.fetchTimelineCard(byId: recordId)
    {
      let screenshots = storage.fetchScreenshotsInTimeRange(
        startTs: timelineCard.startTs, endTs: timelineCard.endTs)
      if screenshots.isEmpty == false { return screenshots }
    }
    let startTs = Int(activity.startTime.timeIntervalSince1970)
    let endTs = Int(activity.endTime.timeIntervalSince1970)
    guard endTs > startTs else { return [] }
    return storage.fetchScreenshotsInTimeRange(startTs: startTs, endTs: endTs)
  }

  func previewScreenshotURL(for activity: TimelineActivity) -> URL? {
    let screenshots = screenshots(for: activity)
    guard screenshots.isEmpty == false else { return nil }
    return screenshots[screenshots.count / 2].fileURL
  }
}

private final class TimelineReviewFrameLoader: @unchecked Sendable {
  private let screenshots: [Screenshot]
  private let maxPixelSize: Int
  private let decodeQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.dayflow.timelineReview.decode"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 2  // Throttled maximum concurrency to save Cores
    return queue
  }()
  private let syncQueue = DispatchQueue(label: "com.dayflow.timelineReview.decode.sync")
  private var cache: [Int: CGImage] = [:]
  private var cacheOrder: [Int] = []
  private var inflight: [Int: [(CGImage?) -> Void]] = [:]
  private var inflightOperations: [Int: BlockOperation] = [:]
  private let cacheLimit = 40

  init(screenshots: [Screenshot], targetSize: CGSize) {
    self.screenshots = screenshots
    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    let targetMaxDimension = max(targetSize.width, targetSize.height)
    self.maxPixelSize = max(64, Int(targetMaxDimension * scale))
  }

  func cancelPending(keepingNear targetIndex: Int, lookahead: Int) {
    var cancelledCallbacks: [(CGImage?) -> Void] = []

    syncQueue.sync {
      let keys = inflightOperations.keys
      for key in keys {
        if abs(key - targetIndex) > lookahead {
          if let op = inflightOperations[key] { op.cancel() }
          if let cbs = inflight.removeValue(forKey: key) {
            cancelledCallbacks.append(contentsOf: cbs)
          }
          inflightOperations.removeValue(forKey: key)
        }
      }
    }

    if !cancelledCallbacks.isEmpty {
      DispatchQueue.main.async {
        for cb in cancelledCallbacks { cb(nil) }
      }
    }
  }

  func prefetch(after index: Int, lookahead: Int, step: Int) {
    guard screenshots.isEmpty == false, lookahead > 0 else { return }
    let total = screenshots.count
    let safeStep = max(1, step)
    let candidateIndices = Set((1...lookahead).map { min(index + ($0 * safeStep), total - 1) })

    for idx in candidateIndices {
      requestImage(at: idx, completion: nil)
    }
  }

  func requestImage(at index: Int, completion: ((CGImage?) -> Void)?) {
    guard screenshots.indices.contains(index) else {
      completion?(nil)
      return
    }

    if let cached = cachedImage(for: index) {
      completion?(cached)
      return
    }

    var shouldStart = false
    var operationToStart: BlockOperation?

    syncQueue.sync {
      if var callbacks = inflight[index] {
        if let completion { callbacks.append(completion) }
        inflight[index] = callbacks
      } else {
        inflight[index] = completion.map { [$0] } ?? []

        let operation = BlockOperation()
        inflightOperations[index] = operation
        operationToStart = operation
        shouldStart = true
      }
    }

    guard shouldStart, let operation = operationToStart else { return }

    operation.addExecutionBlock { [weak self, weak operation] in
      guard let self else { return }
      if operation?.isCancelled == true {
        self.finish(index: index, image: nil)
        return
      }

      let decoded = autoreleasepool { self.decodeImage(at: index) }

      if operation?.isCancelled == true {
        self.finish(index: index, image: nil)
        return
      }

      if let decoded { self.storeImage(decoded, for: index) }
      self.finish(index: index, image: decoded)
    }

    decodeQueue.addOperation(operation)
  }

  private func cachedImage(for index: Int) -> CGImage? {
    syncQueue.sync { cache[index] }
  }

  private func storeImage(_ image: CGImage, for index: Int) {
    syncQueue.sync {
      cache[index] = image
      cacheOrder.removeAll { $0 == index }
      cacheOrder.append(index)

      while cacheOrder.count > cacheLimit {
        let evicted = cacheOrder.removeFirst()
        cache.removeValue(forKey: evicted)
      }
    }
  }

  private func finish(index: Int, image: CGImage?) {
    var callbacks: [(CGImage?) -> Void] = []
    syncQueue.sync {
      callbacks = inflight.removeValue(forKey: index) ?? []
      inflightOperations.removeValue(forKey: index)
    }
    guard !callbacks.isEmpty else { return }
    DispatchQueue.main.async { callbacks.forEach { $0(image) } }
  }

  private func decodeImage(at index: Int) -> CGImage? {
    guard screenshots.indices.contains(index) else { return nil }
    let url = screenshots[index].fileURL
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    // Silently requests the machine's Hardware Media Engines (M1/M2) to bypass the CPU for JPEG operations.
    var finalOptions = options
    finalOptions["kCGImageSourceUseHardwareAcceleration" as CFString] = true

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, finalOptions as CFDictionary)
    else { return nil }
    return cgImage
  }
}

private struct TimelineReviewCardMedia: View {
  let previewImage: CGImage?
  @ObservedObject var playbackState: TimelineReviewPlaybackMediaState
  let player: AVPlayer?
  let onTogglePlayback: () -> Void

  @State private var isPlayerReady = false

  private enum Design {
    static let mediaBorderColor = Color.white.opacity(0.2)
  }

  var body: some View {
    ZStack {
      if let player {
        WhiteBGVideoPlayer(
          player: player,
          videoGravity: .resizeAspectFill,
          onReadyForDisplay: { ready in isPlayerReady = ready }
        )
        .allowsHitTesting(false)
        .clipped()
        .opacity(isPlayerReady ? 1 : 0)

        // Show thumbnail until the player layer has rendered its first frame
        if !isPlayerReady, let image = previewImage {
          TimelineReviewLayerBackedImageView(image: image)
            .allowsHitTesting(false)
            .clipped()
        }
      } else if let image = playbackState.currentImage ?? previewImage {
        TimelineReviewLayerBackedImageView(image: image)
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { onTogglePlayback() }
    .pointingHandCursor()
    .overlay(
      Rectangle().stroke(Design.mediaBorderColor, lineWidth: 1)
    )
    .onChange(of: player) {
      isPlayerReady = false
    }
  }
}

private final class TimelineReviewImageLayerHostView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = CALayer()
    configureLayer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    layer = CALayer()
    configureLayer()
  }

  override func layout() {
    super.layout()
    layer?.frame = bounds
  }

  func updateImage(_ image: CGImage) {
    guard let layer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = image
    CATransaction.commit()
  }

  private func configureLayer() {
    guard let layer else { return }
    layer.masksToBounds = true
    layer.contentsGravity = .resizeAspectFill
    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    layer.magnificationFilter = .trilinear
    layer.minificationFilter = .trilinear
    layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
  }
}

private struct TimelineReviewLayerBackedImageView: NSViewRepresentable {
  let image: CGImage

  func makeNSView(context: Context) -> TimelineReviewImageLayerHostView {
    let view = TimelineReviewImageLayerHostView()
    view.updateImage(image)
    return view
  }

  func updateNSView(_ nsView: TimelineReviewImageLayerHostView, context: Context) {
    nsView.updateImage(image)
  }
}

// MARK: - AppKit Native 120Hz Progress Bar
// Eradicates ALL high-frequency SwiftUI Layout/GeometryReader loops. It calculates pure math directly on hardware layers.

private final class TimelineReviewScrubberNSView: NSView {
  private let trackLayer = CALayer()
  private let progressLayer = CALayer()
  private let pillLayer = CALayer()
  private let textLayer = CATextLayer()

  var playbackState: TimelineReviewPlaybackTimelineState? {
    didSet {
      oldValue?.onTimeChange = nil
      playbackState?.onTimeChange = { [weak self] _ in
        self?.updateScrubberFrames()
      }
      updateScrubberFrames()
    }
  }

  var activityStartTime: Date = Date()
  var activityEndTime: Date = Date()
  var lineHeight: CGFloat = 4
  var isInteractive: Bool = false

  var onScrubStart: (() -> Void)?
  var onScrubChange: ((CGFloat) -> Void)?
  var onScrubEnd: (() -> Void)?

  private var isScrubbing = false

  // Reverses the coordinate system so Y=0 is exactly at the top, perfectly mimicking SwiftUI.
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay

    trackLayer.backgroundColor =
      NSColor(red: 163 / 255, green: 151 / 255, blue: 141 / 255, alpha: 0.5).cgColor
    layer?.addSublayer(trackLayer)

    progressLayer.backgroundColor =
      NSColor(red: 255 / 255, green: 109 / 255, blue: 0 / 255, alpha: 0.65).cgColor
    layer?.addSublayer(progressLayer)

    pillLayer.backgroundColor =
      NSColor(red: 249 / 255, green: 110 / 255, blue: 0 / 255, alpha: 1.0).cgColor
    pillLayer.cornerRadius = 4
    layer?.addSublayer(pillLayer)

    textLayer.fontSize = 8
    textLayer.font = NSFont(name: "Nunito-SemiBold", size: 8)
    textLayer.foregroundColor = NSColor.white.cgColor
    textLayer.alignmentMode = .center
    textLayer.isWrapped = false
    pillLayer.addSublayer(textLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    textLayer.contentsScale = scale
  }

  override func layout() {
    super.layout()
    updateScrubberFrames()
  }

  func updateScrubberFrames() {
    guard let state = playbackState else { return }
    let duration = max(state.duration, 0.001)
    let progress = CGFloat(min(max(state.currentTime / duration, 0), 1))
    let clampedProgress = min(max(progress, 0), 1)

    let total = max(0, activityEndTime.timeIntervalSince(activityStartTime))
    let currentDisplayTime = activityStartTime.addingTimeInterval(total * Double(progress))
    let timeText = TimelineReviewTimeCache.shared.string(from: currentDisplayTime)

    // Bypass 0.25s Implicit Animations from Core Animation
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    let w = bounds.width
    let lineTop = bounds.height - lineHeight

    trackLayer.frame = CGRect(x: 0, y: lineTop, width: w, height: lineHeight)
    let pWidth = w * clampedProgress
    progressLayer.frame = CGRect(x: 0, y: lineTop, width: pWidth, height: lineHeight)

    let pillW: CGFloat = 48
    let pillH: CGFloat = 16
    let halfPill = pillW / 2
    let clampedX = min(max(pWidth, halfPill), w - halfPill)

    let pillBottomSpacing: CGFloat = 3
    let pillY = lineTop - pillBottomSpacing - pillH
    pillLayer.frame = CGRect(x: clampedX - halfPill, y: pillY, width: pillW, height: pillH)

    textLayer.string = timeText
    textLayer.frame = CGRect(x: 0, y: 2, width: pillW, height: pillH)  // Pushed down visually by 2 points to sit center.

    CATransaction.commit()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let view = super.hitTest(point)
    return isInteractive ? view : nil
  }

  override func mouseDown(with event: NSEvent) {
    guard isInteractive else { return }
    isScrubbing = true
    onScrubStart?()
    handleMouse(event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard isInteractive, isScrubbing else { return }
    handleMouse(event)
  }

  override func mouseUp(with event: NSEvent) {
    guard isInteractive, isScrubbing else { return }
    isScrubbing = false
    handleMouse(event)
    onScrubEnd?()
  }

  private func handleMouse(_ event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    let w = max(bounds.width, 1)
    let scrubProgress = min(max(location.x / w, 0), 1)
    onScrubChange?(scrubProgress)
  }
}

private struct TimelineReviewPlaybackTimeline: NSViewRepresentable {
  let playbackState: TimelineReviewPlaybackTimelineState
  let activityStartTime: Date
  let activityEndTime: Date
  let mediaHeight: CGFloat
  let lineHeight: CGFloat
  let isInteractive: Bool
  let onScrubStart: () -> Void
  let onScrubChange: (CGFloat) -> Void
  let onScrubEnd: () -> Void

  func makeNSView(context: Context) -> TimelineReviewScrubberNSView {
    let view = TimelineReviewScrubberNSView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: TimelineReviewScrubberNSView, context: Context) {
    nsView.playbackState = playbackState
    nsView.activityStartTime = activityStartTime
    nsView.activityEndTime = activityEndTime
    nsView.lineHeight = lineHeight
    nsView.isInteractive = isInteractive
    nsView.onScrubStart = onScrubStart
    nsView.onScrubChange = onScrubChange
    nsView.onScrubEnd = onScrubEnd
    nsView.updateScrubberFrames()
  }
}

// MARK: - Smaller Components

private struct TimelineReviewSpeedChip: View {
  @ObservedObject var playbackState: TimelineReviewPlaybackTimelineState
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Text(playbackState.speedLabel)
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.8))
        .cornerRadius(4)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

private struct TimelineReviewDisplayLinkDriver: View {
  @ObservedObject var playbackState: TimelineReviewPlaybackTimelineState
  let isEnabled: Bool
  let onTick: (CADisplayLink) -> Void

  var body: some View {
    TimelineReviewDisplayLinkView(
      isPaused: !isEnabled || playbackState.isPlaying == false,
      onTick: onTick
    )
    .frame(width: 0, height: 0)
  }
}

private struct TimelineReviewDisplayLinkView: NSViewRepresentable {
  let isPaused: Bool
  let onTick: (CADisplayLink) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onTick: onTick) }

  func makeNSView(context: Context) -> HostView {
    let view = HostView()
    context.coordinator.attach(to: view)
    context.coordinator.setPaused(isPaused)
    return view
  }

  func updateNSView(_ nsView: HostView, context: Context) {
    context.coordinator.onTick = onTick
    context.coordinator.attach(to: nsView)
    context.coordinator.setPaused(isPaused)
  }

  static func dismantleNSView(_ nsView: HostView, coordinator: Coordinator) {
    coordinator.invalidate()
  }

  final class Coordinator: NSObject {
    var onTick: (CADisplayLink) -> Void
    private weak var hostView: HostView?
    private var displayLink: CADisplayLink?

    init(onTick: @escaping (CADisplayLink) -> Void) { self.onTick = onTick }

    func attach(to view: HostView) {
      guard hostView !== view || displayLink == nil else { return }
      hostView = view
      rebuildDisplayLink()
    }

    func setPaused(_ paused: Bool) { displayLink?.isPaused = paused }
    func invalidate() {
      displayLink?.invalidate()
      displayLink = nil
      hostView = nil
    }

    @objc func handleDisplayLink(_ displayLink: CADisplayLink) { onTick(displayLink) }

    private func rebuildDisplayLink() {
      displayLink?.invalidate()
      guard let hostView else { return }
      let link = hostView.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))

      // Free UI GPU limits: we constrain ProMotion Macs to a 60 FPS maximum hardware tick limit, halving the refresh cost.
      if #available(macOS 12.0, *) {
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
      }

      link.add(to: .main, forMode: .common)
      displayLink = link
    }
  }

  final class HostView: NSView {}
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
      Circle().fill(color).frame(width: 8, height: 8)
      Text(name)
        .font(.custom("Nunito", size: 10).weight(.bold))
        .foregroundColor(Color(hex: "333333"))
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(color.opacity(0.1))
    .cornerRadius(6)
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 0.75))
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
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "E4E4E4"), lineWidth: 0.75))
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
    .pointingHandCursor()
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
    .pointingHandCursor()
  }
}

private struct ZUndoIcon: View {
  let size: CGFloat
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4).fill(Color(hex: "D6AB8A").opacity(0.7))
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
    case .distracted: return .degrees(0)
    case .neutral: return .degrees(90)
    case .focused: return .degrees(180)
    }
  }
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.25).fill(Color(hex: "D6AB8A").opacity(0.7))
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
      Circle().fill(color).frame(width: size * 0.23, height: size * 0.23).offset(
        x: -size * 0.2, y: -size * 0.05)
      Circle().fill(color).frame(width: size * 0.35, height: size * 0.35).offset(
        x: size * 0.15, y: -size * 0.08)
      HStack(spacing: size * 0.08) {
        Capsule().fill(color).frame(width: size * 0.08, height: size * 0.05)
        Capsule().fill(color).frame(width: size * 0.13, height: size * 0.05)
        Capsule().fill(color).frame(width: size * 0.13, height: size * 0.05)
        Capsule().fill(color).frame(width: size * 0.13, height: size * 0.05)
        Capsule().fill(color).frame(width: size * 0.13, height: size * 0.05)
      }
      .offset(y: size * 0.25)
    }
    .frame(width: size, height: size)
  }
}

private struct TimelineReviewSummary {
  let durationByRating: [TimelineReviewRating: TimeInterval]
  var totalDuration: TimeInterval { durationByRating.values.reduce(0, +) }
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
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(rating.barStroke, lineWidth: 1))
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
    if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h" }
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
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let view = nsView as? KeyCaptureView {
      view.onMove = onMove
      view.onBack = onBack
      view.onEscape = onEscape
      view.onTogglePlayback = onTogglePlayback
      DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
  }

  private final class KeyCaptureView: NSView {
    var onMove: ((MoveCommandDirection) -> Void)?
    var onBack: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
      if let characters = event.charactersIgnoringModifiers?.lowercased(), characters == "z" {
        onBack?()
        return
      }
      switch event.keyCode {
      case 53: onEscape?()
      case 49: onTogglePlayback?()
      case 123: onMove?(.left)
      case 124: onMove?(.right)
      case 126: onMove?(.up)
      default: super.keyDown(with: event)
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
      shouldHandleScroll: shouldHandleScroll, onScrollBegan: onScrollBegan,
      onScrollChanged: onScrollChanged, onScrollEnded: onScrollEnded)
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
      shouldHandleScroll: @escaping (CGSize) -> Bool, onScrollBegan: @escaping () -> Void,
      onScrollChanged: @escaping (CGSize) -> Void, onScrollEnded: @escaping () -> Void
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

private func makeTimelineActivities(from cards: [TimelineCard], for date: Date)
  -> [TimelineActivity]
{
  let calendar = Calendar.current
  let baseDate = calendar.startOfDay(for: date)

  var results: [TimelineActivity] = []
  var idCounts: [String: Int] = [:]
  results.reserveCapacity(cards.count)

  let timeFormatter = DateFormatter()
  timeFormatter.dateFormat = "h:mm a"
  timeFormatter.locale = Locale(identifier: "en_US_POSIX")

  for card in cards {
    guard let startDate = timeFormatter.date(from: card.startTimestamp),
      let endDate = timeFormatter.date(from: card.endTimestamp)
    else { continue }

    let startComponents = calendar.dateComponents([.hour, .minute], from: startDate)
    let endComponents = calendar.dateComponents([.hour, .minute], from: endDate)

    guard
      let finalStartDate = calendar.date(
        bySettingHour: startComponents.hour ?? 0, minute: startComponents.minute ?? 0, second: 0,
        of: baseDate),
      let finalEndDate = calendar.date(
        bySettingHour: endComponents.hour ?? 0, minute: endComponents.minute ?? 0, second: 0,
        of: baseDate)
    else { continue }

    var adjustedStartDate = finalStartDate
    var adjustedEndDate = finalEndDate

    if calendar.component(.hour, from: finalStartDate) < 4 {
      adjustedStartDate =
        calendar.date(byAdding: .day, value: 1, to: finalStartDate) ?? finalStartDate
    }
    if calendar.component(.hour, from: finalEndDate) < 4 {
      adjustedEndDate = calendar.date(byAdding: .day, value: 1, to: finalEndDate) ?? finalEndDate
    }
    if adjustedEndDate < adjustedStartDate {
      adjustedEndDate =
        calendar.date(byAdding: .day, value: 1, to: adjustedEndDate) ?? adjustedEndDate
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

    results.append(
      TimelineActivity(
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
