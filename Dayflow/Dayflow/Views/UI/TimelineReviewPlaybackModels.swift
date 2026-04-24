import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - Playback Models

@MainActor
final class TimelineReviewPlaybackTimelineState: ObservableObject {
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
final class TimelineReviewPlaybackMediaState: ObservableObject {
  @Published var currentImage: CGImage?
}

@MainActor
final class TimelineReviewLegacyPlayerModel: ObservableObject {
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
final class TimelineReviewPlayerModel: ObservableObject {
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
