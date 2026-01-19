//
//  ScreenshotThumbnailCache.swift
//  Dayflow
//
//  On-demand screenshot thumbnail generation (no cache, memory efficient).
//

import Foundation
import AppKit
import ImageIO

final class ScreenshotThumbnailCache {
    static let shared = ScreenshotThumbnailCache()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.dayflow.screenshotthumbnailgen"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private init() {}

    func fetchThumbnail(fileURL: URL, targetSize: CGSize, completion: @escaping (NSImage?) -> Void) {
        queue.addOperation { [weak self] in
            let image = self?.generateThumbnail(url: fileURL, targetSize: targetSize)
            DispatchQueue.main.async {
                completion(image)
            }
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
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
