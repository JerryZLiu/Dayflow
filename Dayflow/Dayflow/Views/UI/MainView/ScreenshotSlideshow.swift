import AppKit
import Foundation
import ImageIO
import QuartzCore
import SwiftUI

struct ScreenshotSlideshowModal: View {
  let screenshots: [Screenshot]
  let title: String?
  let startTime: Date?
  let endTime: Date?

  @Environment(\.dismiss) private var dismiss
  @StateObject private var playbackModel: ScreenshotSlideshowPlaybackModel
  @State private var keyMonitor: Any?

  init(
    screenshots: [Screenshot],
    title: String?,
    startTime: Date?,
    endTime: Date?
  ) {
    self.screenshots = screenshots
    self.title = title
    self.startTime = startTime
    self.endTime = endTime
    _playbackModel = StateObject(
      wrappedValue: ScreenshotSlideshowPlaybackModel(screenshots: screenshots, maxRenderHeight: 540)
    )
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 3) {
          if let title {
            Text(title)
              .font(.title3)
              .fontWeight(.semibold)
          }
          if let startTime, let endTime {
            Text(
              "\(Self.timeFormatter.string(from: startTime)) to \(Self.timeFormatter.string(from: endTime))"
            )
            .font(.caption)
            .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
          }
        }
        Spacer()
        Button(action: { dismiss() }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 20))
            .foregroundColor(Color.black.opacity(0.5))
        }
        .buttonStyle(PlainButtonStyle())
        .hoverScaleEffect(scale: 1.02)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(Color.white)

      Divider()

      ScreenshotSlideshowStageView(
        mediaState: playbackModel.mediaState,
        playbackState: playbackModel.timelineState,
        onTogglePlayback: {
          playbackModel.togglePlayPause()
        },
        onCycleSpeed: {
          playbackModel.cycleSpeed()
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      VStack(spacing: 12) {
        ScreenshotScrubberView(
          screenshots: screenshots,
          playbackState: playbackModel.timelineState,
          onSeek: { timelineTime in
            playbackModel.seek(toTimelineTime: timelineTime)
          },
          onScrubStateChange: { isScrubbing in
            playbackModel.setScrubbing(isScrubbing)
          },
          absoluteStart: startTime,
          absoluteEnd: endTime
        )
        .padding(.horizontal)
        .padding(.bottom, 12)
      }
      .background(Color.white)
    }
    .frame(minWidth: 960, minHeight: 640)
    .background(Color.white)
    .overlay {
      ScreenshotSlideshowDisplayLinkDriver(
        playbackState: playbackModel.timelineState,
        onTick: { displayLink in
          playbackModel.handleDisplayTick(displayLink)
        }
      )
      .allowsHitTesting(false)
    }
    .onAppear {
      playbackModel.start()
      setupKeyMonitor()
    }
    .onDisappear {
      playbackModel.stop()
      removeKeyMonitor()
    }
  }

  private func setupKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if let responder = NSApp.keyWindow?.firstResponder {
        if responder is NSTextField || responder is NSTextView || responder is NSText {
          return event
        }
        let className = NSStringFromClass(type(of: responder))
        if className.contains("TextField") || className.contains("TextEditor")
          || className.contains("TextInput")
        {
          return event
        }
      }

      if event.keyCode == 49
        && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
      {
        playbackModel.togglePlayPause()
        return nil
      }
      return event
    }
  }

  private func removeKeyMonitor() {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
  }
}

private struct ScreenshotSlideshowStageView: View {
  @ObservedObject var mediaState: ScreenshotSlideshowPlaybackMediaState
  @ObservedObject var playbackState: ScreenshotSlideshowPlaybackTimelineState
  let onTogglePlayback: () -> Void
  let onCycleSpeed: () -> Void

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.95)

        if let image = mediaState.currentImage {
          ScreenshotSlideshowLayerBackedImageView(image: image)
            .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
            .allowsHitTesting(false)
        } else {
          ProgressView()
            .controlSize(.large)
            .allowsHitTesting(false)
        }

        Rectangle()
          .fill(Color.clear)
          .contentShape(Rectangle())
          .onTapGesture {
            onTogglePlayback()
          }
          .pointingHandCursor()

        if !playbackState.isPlaying {
          ZStack {
            Circle()
              .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
              .frame(width: 68, height: 68)
              .background(Circle().fill(Color.black.opacity(0.35)))
            Image(systemName: "play.fill")
              .foregroundColor(.white)
              .font(.system(size: 26, weight: .bold))
          }
          .allowsHitTesting(false)
        }

        VStack {
          Spacer()
          HStack {
            Spacer()
            Button(action: onCycleSpeed) {
              Text(playbackState.speedLabel)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.8))
                .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            .hoverScaleEffect(scale: 1.02)
            .pointingHandCursorOnHover(reassertOnPressEnd: true)
            .padding(12)
          }
        }
      }
    }
  }
}

private final class ScreenshotSlideshowImageLayerHostView: NSView {
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
    layer.contentsGravity = .resizeAspect
    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    layer.magnificationFilter = .trilinear
    layer.minificationFilter = .trilinear
    layer.actions = [
      "contents": NSNull(),
      "bounds": NSNull(),
      "position": NSNull(),
    ]
  }
}

private struct ScreenshotSlideshowLayerBackedImageView: NSViewRepresentable {
  let image: CGImage

  func makeNSView(context: Context) -> ScreenshotSlideshowImageLayerHostView {
    let view = ScreenshotSlideshowImageLayerHostView()
    view.updateImage(image)
    return view
  }

  func updateNSView(_ nsView: ScreenshotSlideshowImageLayerHostView, context: Context) {
    nsView.updateImage(image)
  }
}

private struct ScreenshotSlideshowDisplayLinkDriver: View {
  @ObservedObject var playbackState: ScreenshotSlideshowPlaybackTimelineState
  let onTick: (CADisplayLink) -> Void

  var body: some View {
    ScreenshotSlideshowDisplayLinkView(
      isPaused: playbackState.isPlaying == false,
      onTick: onTick
    )
    .frame(width: 0, height: 0)
  }
}

private struct ScreenshotSlideshowDisplayLinkView: NSViewRepresentable {
  let isPaused: Bool
  let onTick: (CADisplayLink) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onTick: onTick)
  }

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

    init(onTick: @escaping (CADisplayLink) -> Void) {
      self.onTick = onTick
    }

    func attach(to view: HostView) {
      guard hostView !== view || displayLink == nil else { return }
      hostView = view
      rebuildDisplayLink()
    }

    func setPaused(_ paused: Bool) {
      displayLink?.isPaused = paused
    }

    func invalidate() {
      displayLink?.invalidate()
      displayLink = nil
      hostView = nil
    }

    @objc
    func handleDisplayLink(_ displayLink: CADisplayLink) {
      onTick(displayLink)
    }

    private func rebuildDisplayLink() {
      displayLink?.invalidate()
      guard let hostView else { return }
      let link = hostView.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
  }

  final class HostView: NSView {}
}

private let cachedScreenshotScrubberTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  return formatter
}()

private final class ScreenshotFilmstripGenerator {
  static let shared = ScreenshotFilmstripGenerator()

  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "com.dayflow.screenshotfilmstrip"
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .userInitiated
    return q
  }()

  private let syncQueue = DispatchQueue(label: "com.dayflow.screenshotfilmstrip.sync")
  private var cache: [String: [NSImage]] = [:]
  private var inflight: [String: [([NSImage]) -> Void]] = [:]

  private init() {}

  func generate(
    screenshots: [Screenshot],
    frameCount: Int,
    targetHeight: CGFloat,
    completion: @escaping ([NSImage]) -> Void
  ) {
    guard frameCount > 0, !screenshots.isEmpty else {
      completion([])
      return
    }

    let key = Self.cacheKey(for: screenshots, frameCount: frameCount, targetHeight: targetHeight)
    if let images = syncQueue.sync(execute: { cache[key] }) {
      completion(images)
      return
    }

    var shouldStart = false
    syncQueue.sync {
      if var callbacks = inflight[key] {
        callbacks.append(completion)
        inflight[key] = callbacks
      } else {
        inflight[key] = [completion]
        shouldStart = true
      }
    }

    guard shouldStart else { return }

    queue.addOperation { [weak self] in
      guard let self else { return }
      let sampled = Self.sampledIndices(total: screenshots.count, count: frameCount)
      let targetWidth = targetHeight * 16.0 / 9.0

      var generated: [NSImage] = []
      generated.reserveCapacity(sampled.count)

      for index in sampled {
        let url = screenshots[index].fileURL
        if let image = self.decodeThumbnail(url: url, targetHeight: targetHeight) {
          generated.append(image)
        } else {
          generated.append(self.placeholderImage(width: targetWidth, height: targetHeight))
        }
      }

      self.syncQueue.sync {
        self.cache[key] = generated
      }
      self.finish(key: key, images: generated)
    }
  }

  private func finish(key: String, images: [NSImage]) {
    var callbacks: [([NSImage]) -> Void] = []
    syncQueue.sync {
      callbacks = inflight[key] ?? []
      inflight.removeValue(forKey: key)
    }
    DispatchQueue.main.async {
      callbacks.forEach { $0(images) }
    }
  }

  private func decodeThumbnail(url: URL, targetHeight: CGFloat) -> NSImage? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    let targetWidth = targetHeight * 16.0 / 9.0
    let maxPixel = max(64, Int(max(targetHeight, targetWidth) * scale))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }

  private func placeholderImage(width: CGFloat, height: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    image.unlockFocus()
    return image
  }

  private static func cacheKey(
    for screenshots: [Screenshot], frameCount: Int, targetHeight: CGFloat
  ) -> String {
    let firstPath = screenshots.first?.filePath ?? "-"
    let lastPath = screenshots.last?.filePath ?? "-"
    let firstTs = screenshots.first?.capturedAt ?? 0
    let lastTs = screenshots.last?.capturedAt ?? 0
    return
      "\(screenshots.count)|\(firstTs)|\(lastTs)|\(firstPath)|\(lastPath)|n:\(frameCount)|h:\(Int(targetHeight.rounded()))"
  }

  private static func sampledIndices(total: Int, count: Int) -> [Int] {
    guard total > 0 else { return [] }
    guard count > 1 else { return [0] }
    if total == 1 { return Array(repeating: 0, count: count) }

    let maxIndex = total - 1
    return (0..<count).map { i in
      let ratio = Double(i) / Double(count - 1)
      return Int((ratio * Double(maxIndex)).rounded())
    }
  }
}

private struct ScreenshotScrubberView: View {
  let screenshots: [Screenshot]
  @ObservedObject var playbackState: ScreenshotSlideshowPlaybackTimelineState
  let onSeek: (Double) -> Void
  let onScrubStateChange: (Bool) -> Void
  var absoluteStart: Date? = nil
  var absoluteEnd: Date? = nil

  @State private var images: [NSImage] = []
  @State private var isDragging: Bool = false

  private let frameCount = 8
  private let filmstripHeight: CGFloat = 64
  private let aspect: CGFloat = 16.0 / 9.0
  private let zoom: CGFloat = 1.2
  private let chipRowHeight: CGFloat = 28
  private let chipSpacing: CGFloat = 0
  private let sideGutter: CGFloat = 30
  private var totalHeight: CGFloat { chipRowHeight + chipSpacing + filmstripHeight }

  var body: some View {
    GeometryReader { outer in
      let duration = max(0.001, playbackState.duration)
      let currentTime = playbackState.currentTime
      let stripWidth = max(1, outer.size.width - sideGutter * 2)
      let xInsideRaw = xFor(time: currentTime, width: stripWidth)
      let scale = NSScreen.main?.backingScaleFactor ?? 2.0
      let xInside = (xInsideRaw * scale).rounded() / scale
      let x = sideGutter + xInside

      ZStack(alignment: .topLeading) {
        VStack(spacing: chipSpacing) {
          ZStack(alignment: .topLeading) {
            Color.clear.frame(height: chipRowHeight)
            Text(timeLabel(for: currentTime))
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.white)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.black.opacity(0.85))
              .cornerRadius(12)
              .scaleEffect(0.8)
              .position(x: x, y: chipRowHeight / 2)
          }
          .zIndex(1)

          ZStack(alignment: .topLeading) {
            Rectangle()
              .fill(Color.white)

            let tileWidth = filmstripHeight * aspect
            let columnsNeeded = max(1, Int(ceil(stripWidth / tileWidth)))
            HStack(spacing: 0) {
              if images.count == columnsNeeded {
                ForEach(0..<images.count, id: \.self) { idx in
                  Image(nsImage: images[idx])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(zoom, anchor: .center)
                    .frame(width: tileWidth, height: filmstripHeight)
                    .clipped()
                }
              } else if images.isEmpty {
                ForEach(0..<columnsNeeded, id: \.self) { _ in
                  Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(width: tileWidth, height: filmstripHeight)
                }
              } else {
                ForEach(0..<columnsNeeded, id: \.self) { i in
                  let image = i < images.count ? images[i] : nil
                  Group {
                    if let image {
                      Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(zoom, anchor: .center)
                    } else {
                      Rectangle().fill(Color.black.opacity(0.06))
                    }
                  }
                  .frame(width: tileWidth, height: filmstripHeight)
                  .clipped()
                }
              }
            }
            .frame(width: stripWidth, alignment: .leading)
            .clipped()
            .onChange(of: columnsNeeded) { _, newValue in
              generateFilmstripIfNeeded(count: newValue)
            }
            .onAppear { generateFilmstripIfNeeded(count: columnsNeeded) }

            let barHeight = filmstripHeight + 3
            Rectangle()
              .fill(Color.black)
              .frame(width: 5, height: barHeight)
              .shadow(color: .black.opacity(0.25), radius: 1.0, x: 0, y: 0)
              .offset(x: xInside - 2.5, y: -3)
              .allowsHitTesting(false)
            Rectangle()
              .fill(Color.white)
              .frame(width: 3, height: barHeight)
              .offset(x: xInside - 1.5, y: -3)
              .allowsHitTesting(false)
          }
          .frame(width: stripWidth, height: filmstripHeight)
          .padding(.horizontal, sideGutter)
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            if !isDragging {
              isDragging = true
              onScrubStateChange(true)
            }
            let activeStripWidth = max(1, outer.size.width - sideGutter * 2)
            let xLocal = (value.location.x - sideGutter).clamped(to: 0, activeStripWidth)
            let pct = xLocal / activeStripWidth
            onSeek(Double(pct) * max(duration, 0.0001))
          }
          .onEnded { _ in
            isDragging = false
            onScrubStateChange(false)
          }
      )
    }
    .frame(height: totalHeight)
  }

  private func xFor(time: Double, width: CGFloat) -> CGFloat {
    let duration = max(0.001, playbackState.duration)
    guard duration > 0 else { return 0 }
    return CGFloat(time / duration) * width
  }

  private func timeLabel(for time: Double) -> String {
    let duration = max(0.001, playbackState.duration)
    if let absoluteStart, let absoluteEnd, duration > 0 {
      let total = absoluteEnd.timeIntervalSince(absoluteStart)
      let progress = max(0, min(1, time / duration))
      let absolute = absoluteStart.addingTimeInterval(total * progress)
      return cachedScreenshotScrubberTimeFormatter.string(from: absolute)
    }

    let mins = Int(time) / 60
    let secs = Int(time) % 60
    return String(format: "%d:%02d", mins, secs)
  }

  private func generateFilmstripIfNeeded(count: Int) {
    guard count > 0 else { return }
    ScreenshotFilmstripGenerator.shared.generate(
      screenshots: screenshots,
      frameCount: count,
      targetHeight: filmstripHeight
    ) { generated in
      images = generated
    }
  }
}

extension Comparable {
  fileprivate func clamped(to lower: Self, _ upper: Self) -> Self {
    min(max(self, lower), upper)
  }
}
