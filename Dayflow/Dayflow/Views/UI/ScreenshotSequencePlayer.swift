//
//  ScreenshotSequencePlayer.swift
//  Dayflow
//
//  Lightweight screenshot sequence playback with a small frame buffer.
//

import AppKit
import Foundation
import ImageIO
import QuartzCore

final class ScreenshotSequencePlayerModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var isPlaying: Bool = false
    @Published var playbackSpeed: Float = 1.0
    @Published var didReachEnd: Bool = false
    @Published var currentFrame: NSImage? = nil
    @Published var aspectRatio: CGFloat = 16.0 / 9.0
    @Published var isDragging: Bool = false

    @Published private(set) var screenshots: [Screenshot] = []
    let speedOptions: [Float] = [1.0, 2.0, 3.0]

    private let bufferRadius = 2
    private var frameIndex: Int = 0
    private var lastRenderedIndex: Int = -1
    private var frameCache: [Int: NSImage] = [:]
    private var inflight: Set<Int> = []
    private var targetSize: CGSize = .zero
    private var timer: Timer?
    private var loadToken: Int = 0
    private var imageGeneration: Int = 0
    private var playbackStartClock: TimeInterval = 0
    private var playbackStartTime: Double = 0
    private var pendingPlay = false
    private let loadQueue = DispatchQueue(label: "com.dayflow.screenshotplayer", qos: .userInitiated)

    var isEmpty: Bool { screenshots.isEmpty }

    func loadScreenshots(startTime: Date?, endTime: Date?) {
        loadToken &+= 1
        let token = loadToken
        guard let startTime, let endTime else {
            setScreenshots([])
            return
        }
        let startTs = Int(min(startTime.timeIntervalSince1970, endTime.timeIntervalSince1970))
        let endTs = Int(max(startTime.timeIntervalSince1970, endTime.timeIntervalSince1970))

        DispatchQueue.global(qos: .userInitiated).async {
            let screenshots = StorageManager.shared.fetchScreenshotsInTimeRange(startTs: startTs, endTs: endTs)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.loadToken else { return }
                self.setScreenshots(screenshots)
            }
        }
    }

    func setTargetSize(_ size: CGSize) {
        let clamped = CGSize(width: max(1, size.width), height: max(1, size.height))
        guard clamped != targetSize else { return }
        targetSize = clamped
        frameCache.removeAll()
        inflight.removeAll()
        imageGeneration &+= 1
        updateFrame(index: frameIndex)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !screenshots.isEmpty else {
            pendingPlay = true
            return
        }
        pendingPlay = false
        if didReachEnd {
            seek(to: 0, resume: false)
        }
        isPlaying = true
        resetPlaybackBaseline()
        startTimer()
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    func seek(to time: Double, resume: Bool? = nil) {
        guard !screenshots.isEmpty else {
            currentTime = 0
            return
        }
        let clampedTime = min(max(time, 0), duration)
        let isAtEnd = clampedTime >= (duration - 0.0001)
        let index = isAtEnd ? (screenshots.count - 1) : Int(clampedTime / baseFrameDuration)
        frameIndex = min(max(index, 0), screenshots.count - 1)
        currentTime = isAtEnd ? duration : (Double(frameIndex) * baseFrameDuration)
        didReachEnd = isAtEnd
        updateFrame(index: frameIndex)
        if let resume {
            resume ? play() : pause()
        } else if isPlaying {
            resetPlaybackBaseline()
        }
    }

    func cycleSpeed() {
        guard let idx = speedOptions.firstIndex(of: playbackSpeed) else {
            setPlaybackSpeed(speedOptions.first ?? 1.0)
            return
        }
        let next = speedOptions[(idx + 1) % speedOptions.count]
        setPlaybackSpeed(next)
    }

    func cleanup() {
        pause()
        screenshots = []
        frameCache.removeAll()
        inflight.removeAll()
        currentFrame = nil
        currentTime = 0
        duration = 1
        didReachEnd = false
    }

    deinit {
        cleanup()
    }

    private var baseFrameDuration: Double {
        max(0.05, ScreenshotConfig.interval / 20.0)
    }

    private func setScreenshots(_ screenshots: [Screenshot]) {
        let sorted = screenshots.sorted { $0.capturedAt < $1.capturedAt }
        pause()
        self.screenshots = sorted
        frameIndex = 0
        lastRenderedIndex = -1
        currentTime = 0
        didReachEnd = false
        duration = max(baseFrameDuration * Double(max(sorted.count, 1)), baseFrameDuration)
        frameCache.removeAll()
        inflight.removeAll()
        imageGeneration &+= 1
        currentFrame = nil
        aspectRatio = 16.0 / 9.0

        if sorted.isEmpty == false {
            updateFrame(index: 0)
            if pendingPlay {
                play()
            }
        }
    }

    private func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying {
            resetPlaybackBaseline()
            startTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = 1.0 / 60.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advanceFrame() {
        guard !isDragging else { return }
        guard !screenshots.isEmpty else { return }
        let elapsed = CACurrentMediaTime() - playbackStartClock
        let nextTime = playbackStartTime + (elapsed * Double(playbackSpeed))
        if nextTime >= duration {
            currentTime = duration
            frameIndex = max(0, screenshots.count - 1)
            didReachEnd = true
            updateFrameIfNeeded()
            pause()
            return
        }

        currentTime = nextTime
        let nextIndex = min(max(Int(nextTime / baseFrameDuration), 0), screenshots.count - 1)
        frameIndex = nextIndex
        updateFrameIfNeeded()
    }

    private func updateFrame(index: Int) {
        guard screenshots.indices.contains(index) else { return }
        if let cached = frameCache[index] {
            currentFrame = cached
            updateAspectRatio(from: cached)
        } else {
            loadFrame(index: index)
        }
        prefetchAround(index: index)
    }

    private func updateFrameIfNeeded() {
        guard frameIndex != lastRenderedIndex else { return }
        lastRenderedIndex = frameIndex
        updateFrame(index: frameIndex)
    }

    private func prefetchAround(index: Int) {
        guard !screenshots.isEmpty else { return }
        let lower = max(0, index - bufferRadius)
        let upper = min(screenshots.count - 1, index + bufferRadius)
        for i in lower...upper {
            loadFrame(index: i)
        }
        trimCache(keeping: lower...upper)
    }

    private func trimCache(keeping range: ClosedRange<Int>) {
        let keysToRemove = frameCache.keys.filter { !range.contains($0) }
        keysToRemove.forEach { frameCache.removeValue(forKey: $0) }
    }

    private func loadFrame(index: Int) {
        guard screenshots.indices.contains(index), inflight.contains(index) == false else { return }
        inflight.insert(index)
        let screenshot = screenshots[index]
        let targetSize = targetSize
        let generation = imageGeneration

        loadQueue.async { [weak self] in
            let image = Self.loadImage(url: screenshot.fileURL, targetSize: targetSize)
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.imageGeneration else { return }
                self.inflight.remove(index)
                if let image {
                    self.frameCache[index] = image
                    if index == self.frameIndex {
                        self.currentFrame = image
                        self.updateAspectRatio(from: image)
                    }
                }
            }
        }
    }

    private func updateAspectRatio(from image: NSImage) {
        let w = image.size.width
        let h = image.size.height
        guard h > 0 else { return }
        aspectRatio = max(0.1, w / h)
    }

    private func resetPlaybackBaseline() {
        playbackStartClock = CACurrentMediaTime()
        playbackStartTime = currentTime
    }

    private static func loadImage(url: URL, targetSize: CGSize) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let targetMax = max(targetSize.width, targetSize.height)
        let maxDim = targetMax > 0 ? targetMax : 1280
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let maxPixel = max(64, Int(maxDim * scale))

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
