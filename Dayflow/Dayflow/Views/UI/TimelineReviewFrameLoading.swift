import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

actor TimelineReviewScreenshotSource {
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

final class TimelineReviewFrameLoader: @unchecked Sendable {
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
