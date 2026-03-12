//
//  ScreenshotThumbnailCache.swift
//  Dayflow
//
//  Bounded in-memory cache for screenshot preview thumbnails.
//

import AppKit
import Foundation
import ImageIO

final class ScreenshotThumbnailCache {
  static let shared = ScreenshotThumbnailCache()

  private let cache = NSCache<NSString, NSImage>()
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "com.dayflow.screenshotthumbnailgen"
    q.maxConcurrentOperationCount = 2
    q.qualityOfService = .userInitiated
    return q
  }()
  private let syncQueue = DispatchQueue(label: "com.dayflow.screenshotthumbnailgen.sync")
  private var inflight: [String: [(NSImage?) -> Void]] = [:]

  private init() {
    cache.countLimit = 64
  }

  func fetchThumbnail(fileURL: URL, targetSize: CGSize, completion: @escaping (NSImage?) -> Void) {
    let key = cacheKey(fileURL: fileURL, targetSize: targetSize)

    if let cached = cache.object(forKey: key as NSString) {
      completion(cached)
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
      let image = self.generateThumbnail(url: fileURL, targetSize: targetSize)
      if let image {
        self.cache.setObject(image, forKey: key as NSString)
      }
      self.finish(key: key, image: image)
    }
  }

  private func generateThumbnail(url: URL, targetSize: CGSize) -> NSImage? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let targetMaxDimension = max(targetSize.width, targetSize.height)
    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    let maxPixel = max(64, Int(targetMaxDimension * scale))

    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }

  private func finish(key: String, image: NSImage?) {
    var callbacks: [(NSImage?) -> Void] = []
    syncQueue.sync {
      callbacks = inflight[key] ?? []
      inflight.removeValue(forKey: key)
    }

    DispatchQueue.main.async {
      callbacks.forEach { $0(image) }
    }
  }

  private func cacheKey(fileURL: URL, targetSize: CGSize) -> String {
    let width = Int(targetSize.width.rounded())
    let height = Int(targetSize.height.rounded())
    return "\(fileURL.path)|\(width)x\(height)"
  }
}
