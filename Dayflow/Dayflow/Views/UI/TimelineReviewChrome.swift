import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - Timeline Review Chrome

struct TimelineReviewSpeedChip: View {
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

struct TimelineReviewDisplayLinkDriver: View {
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

struct TimelineReviewDisplayLinkView: NSViewRepresentable {
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

struct TimelineReviewOverlayBadge: View {
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

struct TimelineReviewCategoryPill: View {
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

struct TimelineReviewTimeRangePill: View {
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

struct TimelineReviewRatingRow: View {
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

struct ZUndoIcon: View {
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

struct TimelineReviewRatingIcon: View {
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

struct TimelineReviewFooterIcon: View {
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

struct NeutralFaceIcon: View {
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

struct TimelineReviewSummaryBars: View {
  let summary: TimelineReviewSummary
  var body: some View {
    VStack(spacing: 16) {
      SummaryBarRow(summary: summary)
      SummaryLabelRow(summary: summary)
    }
  }
}

struct SummaryBarRow: View {
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

struct SummaryLabelRow: View {
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

struct TimelineReviewKeyHandler: NSViewRepresentable {
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

struct TrackpadScrollHandler: NSViewRepresentable {
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
