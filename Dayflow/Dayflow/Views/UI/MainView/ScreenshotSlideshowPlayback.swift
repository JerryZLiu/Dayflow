//
//  ScreenshotSlideshowPlayback.swift
//  Dayflow
//
//  Playback engine for the screenshot slideshow: timeline/media state,
//  the display-tick playback model, and the background frame decoder.
//

import AppKit
import Foundation
import ImageIO
import QuartzCore

@MainActor
final class ScreenshotSlideshowPlaybackTimelineState: ObservableObject {
  @Published var currentTime: Double = 0
  @Published var duration: Double = 1
  @Published var speedLabel: String = "20x"
  @Published var isPlaying: Bool = true
}

@MainActor
final class ScreenshotSlideshowPlaybackMediaState: ObservableObject {
  @Published var currentImage: CGImage?
}

@MainActor
final class ScreenshotSlideshowPlaybackModel: ObservableObject {
  let frameCount: Int
  let mediaState = ScreenshotSlideshowPlaybackMediaState()
  let timelineState = ScreenshotSlideshowPlaybackTimelineState()

  private let loader: ScreenshotSlideshowFrameLoader
  private let frameOffsets: [Double]
  private let fallbackTimelineDurationSeconds: Double
  private let averageFrameIntervalSeconds: Double
  private static let speedDefaultsKey = "activitySlideshowPlaybackSpeedX"
  private let speedOptions: [Double] = [20, 40, 60]
  private var currentIndex = 0
  private var speedOptionIndex = 0
  private var requestID = 0
  private var wasPlayingBeforeScrubbing = false
  private var isPlaying = true
  private var lastDisplayTimestamp: CFTimeInterval?
  private var pendingFrameIndex: Int?

  init(screenshots: [Screenshot], maxRenderHeight: Int) {
    self.frameCount = screenshots.count
    self.loader = ScreenshotSlideshowFrameLoader(
      screenshots: screenshots, maxRenderHeight: maxRenderHeight)

    if let firstCapture = screenshots.first?.capturedAt {
      self.frameOffsets = screenshots.map { screenshot in
        Double(max(0, screenshot.capturedAt - firstCapture))
      }
    } else {
      self.frameOffsets = []
    }

    if screenshots.count > 1 {
      let totalSeconds = Double(
        max(1, screenshots.last!.capturedAt - screenshots.first!.capturedAt))
      self.fallbackTimelineDurationSeconds = totalSeconds
      self.averageFrameIntervalSeconds = max(0.1, totalSeconds / Double(screenshots.count - 1))
    } else {
      self.fallbackTimelineDurationSeconds = max(0.1, ScreenshotConfig.interval)
      self.averageFrameIntervalSeconds = max(0.1, ScreenshotConfig.interval)
    }

    if let savedIndex = Self.savedSpeedIndex(in: speedOptions) {
      speedOptionIndex = savedIndex
    }

    timelineState.duration = timelineDurationSeconds
    timelineState.speedLabel = currentSpeedLabel
    timelineState.isPlaying = isPlaying
  }

  func start() {
    guard frameCount > 0 else { return }
    lastDisplayTimestamp = nil
    scheduleFrameDisplay(at: currentIndex, updateTimelineTime: true)
  }

  func stop() {
    isPlaying = false
    timelineState.isPlaying = false
    lastDisplayTimestamp = nil
    pendingFrameIndex = nil
  }

  func togglePlayPause() {
    isPlaying.toggle()
    timelineState.isPlaying = isPlaying
    lastDisplayTimestamp = nil
  }

  func cycleSpeed() {
    speedOptionIndex = (speedOptionIndex + 1) % speedOptions.count
    timelineState.speedLabel = currentSpeedLabel
    UserDefaults.standard.set(speedOptions[speedOptionIndex], forKey: Self.speedDefaultsKey)
  }

  func seek(to index: Int) {
    guard frameCount > 0 else { return }
    let clamped = min(max(0, index), frameCount - 1)
    timelineState.currentTime = frameOffset(for: clamped)
    scheduleFrameDisplay(at: clamped, updateTimelineTime: false)
    lastDisplayTimestamp = nil
  }

  func seek(toTimelineTime seconds: Double) {
    guard frameCount > 0 else { return }
    let clampedSeconds = min(max(0, seconds), timelineDurationSeconds)
    timelineState.currentTime = clampedSeconds
    let nearest = frameIndex(forTimelineTime: clampedSeconds)
    seek(to: nearest)
  }

  func setScrubbing(_ isScrubbing: Bool) {
    if isScrubbing {
      wasPlayingBeforeScrubbing = self.isPlaying
      self.isPlaying = false
      timelineState.isPlaying = false
      lastDisplayTimestamp = nil
      return
    }
    isPlaying = wasPlayingBeforeScrubbing
    timelineState.isPlaying = isPlaying
    lastDisplayTimestamp = nil
  }

  var timelineDurationSeconds: Double {
    let offsetDuration = frameOffsets.last ?? 0
    return max(0.001, max(offsetDuration, fallbackTimelineDurationSeconds))
  }

  func handleDisplayTick(_ displayLink: CADisplayLink) {
    guard isPlaying, frameCount > 1 else {
      lastDisplayTimestamp = nil
      return
    }

    let previousTimestamp = lastDisplayTimestamp ?? displayLink.timestamp
    let currentTimestamp = max(displayLink.targetTimestamp, displayLink.timestamp)
    let deltaSeconds = min(max(currentTimestamp - previousTimestamp, 0), 0.1)
    lastDisplayTimestamp = currentTimestamp
    guard deltaSeconds > 0 else { return }

    var nextTime = timelineState.currentTime + (deltaSeconds * speedOptions[speedOptionIndex])
    let totalDuration = timelineDurationSeconds
    if nextTime >= totalDuration {
      nextTime.formTruncatingRemainder(dividingBy: totalDuration)
      if nextTime.isNaN || nextTime.isInfinite {
        nextTime = 0
      }
      currentIndex = 0
    }

    timelineState.currentTime = nextTime
    let nextIndex = frameIndex(forTimelineTime: nextTime)
    if nextIndex != currentIndex {
      scheduleFrameDisplay(at: nextIndex, updateTimelineTime: false)
    }
  }

  private var currentSpeedLabel: String {
    "\(Int(speedOptions[speedOptionIndex]))x"
  }

  private func frameOffset(for index: Int) -> Double {
    guard frameOffsets.indices.contains(index) else {
      return min(Double(index) * averageFrameIntervalSeconds, timelineDurationSeconds)
    }
    return frameOffsets[index]
  }

  private func frameIndex(forTimelineTime seconds: Double) -> Int {
    guard !frameOffsets.isEmpty else { return 0 }
    if let index = frameOffsets.lastIndex(where: { $0 <= seconds }) {
      return index
    }
    return 0
  }

  private func scheduleFrameDisplay(at index: Int, updateTimelineTime: Bool) {
    guard pendingFrameIndex != index else { return }
    pendingFrameIndex = index
    Task { [weak self] in
      await self?.displayFrame(at: index, updateTimelineTime: updateTimelineTime)
    }
  }

  private func displayFrame(at index: Int, updateTimelineTime: Bool) async {
    guard frameCount > 0 else { return }
    let clamped = min(max(0, index), frameCount - 1)
    requestID &+= 1
    let currentRequestID = requestID

    guard let image = await loader.image(at: clamped) else { return }
    guard currentRequestID == requestID else { return }

    currentIndex = clamped
    pendingFrameIndex = nil
    mediaState.currentImage = image
    if updateTimelineTime {
      timelineState.currentTime = frameOffset(for: clamped)
    }
    loader.prefetch(after: clamped, lookahead: 2)
  }

  private static func savedSpeedIndex(in options: [Double]) -> Int? {
    let saved = UserDefaults.standard.double(forKey: speedDefaultsKey)
    guard saved > 0 else { return nil }
    return options.firstIndex(where: { abs($0 - saved) < 0.001 })
  }
}

private final class ScreenshotSlideshowFrameLoader: @unchecked Sendable {
  private let screenshots: [Screenshot]
  private let maxPixelSize: Int
  private let decodeQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.dayflow.slideshow.decode"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 3
    return queue
  }()
  private let syncQueue = DispatchQueue(label: "com.dayflow.slideshow.decode.sync")
  private var cache: [Int: CGImage] = [:]
  private var cacheOrder: [Int] = []
  private var inflight: [Int: [(CGImage?) -> Void]] = [:]
  private let cacheLimit = 16

  init(screenshots: [Screenshot], maxRenderHeight: Int) {
    self.screenshots = screenshots
    let derivedWidth = Int((Double(maxRenderHeight) * 16.0 / 9.0).rounded())
    self.maxPixelSize = max(64, max(maxRenderHeight, derivedWidth))
  }

  func image(at index: Int) async -> CGImage? {
    if let cached = cachedImage(for: index) {
      return cached
    }

    return await withCheckedContinuation { continuation in
      requestImage(at: index) { image in
        continuation.resume(returning: image)
      }
    }
  }

  func prefetch(after index: Int, lookahead: Int) {
    guard !screenshots.isEmpty else { return }
    guard lookahead > 0 else { return }

    let total = screenshots.count
    let candidateIndices = (1...lookahead).map { (index + $0) % total }
    for idx in candidateIndices {
      requestImage(at: idx, completion: nil)
    }
  }

  private func requestImage(at index: Int, completion: ((CGImage?) -> Void)?) {
    guard screenshots.indices.contains(index) else {
      completion?(nil)
      return
    }

    if let cached = cachedImage(for: index) {
      completion?(cached)
      return
    }

    var shouldStart = false
    syncQueue.sync {
      if var callbacks = inflight[index] {
        if let completion {
          callbacks.append(completion)
        }
        inflight[index] = callbacks
      } else {
        inflight[index] = completion.map { [$0] } ?? []
        shouldStart = true
      }
    }

    guard shouldStart else { return }

    decodeQueue.addOperation { [weak self] in
      guard let self else { return }
      let decoded = autoreleasepool { self.decodeImage(at: index) }
      if let decoded {
        self.storeImage(decoded, for: index)
      }
      self.finish(index: index, image: decoded)
    }
  }

  private func cachedImage(for index: Int) -> CGImage? {
    syncQueue.sync {
      cache[index]
    }
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
      callbacks = inflight[index] ?? []
      inflight.removeValue(forKey: index)
    }

    guard !callbacks.isEmpty else { return }
    DispatchQueue.main.async {
      callbacks.forEach { $0(image) }
    }
  }

  private func decodeImage(at index: Int) -> CGImage? {
    guard screenshots.indices.contains(index) else { return nil }
    let url = screenshots[index].fileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      return nil
    }
    return cgImage
  }
}
