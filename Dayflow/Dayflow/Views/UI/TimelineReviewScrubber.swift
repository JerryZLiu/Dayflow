import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - AppKit Native 120Hz Progress Bar
// Eradicates ALL high-frequency SwiftUI Layout/GeometryReader loops. It calculates pure math directly on hardware layers.

final class TimelineReviewScrubberNSView: NSView {
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

struct TimelineReviewPlaybackTimeline: NSViewRepresentable {
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
