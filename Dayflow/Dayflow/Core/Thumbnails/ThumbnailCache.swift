//
//  ThumbnailCache.swift
//  Dayflow
//
//  On-demand thumbnail generation (no caching - memory efficient).
//

import Foundation
import AppKit
import AVFoundation

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.dayflow.thumbnailgen"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private init() {}

    /// Generate thumbnail on demand; completion runs on main thread.
    func fetchThumbnail(videoURL: String, targetSize: CGSize, completion: @escaping (NSImage?) -> Void) {
        let normalizedURL = normalize(urlString: videoURL)

        queue.addOperation { [weak self] in
            let image = self?.generateThumbnail(urlString: normalizedURL, targetSize: targetSize)
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    /// No-op for API compatibility (prefetching makes no sense without a cache).
    func prefetch(videoURL: String, targetSize: CGSize) {
        // Intentionally empty - no cache to warm
    }

    private func normalize(urlString: String) -> String {
        urlString.hasPrefix("file://") ? urlString : "file://" + urlString
    }

    private func generateThumbnail(urlString: String, targetSize: CGSize) -> NSImage? {
        let url: URL
        if urlString.hasPrefix("file://") {
            let path = String(urlString.dropFirst("file://".count))
            url = URL(fileURLWithPath: path)
        } else if let u = URL(string: urlString) {
            url = u
        } else {
            return nil
        }

        guard !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        if targetSize != .zero {
            let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
            generator.maximumSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        }

        // Load duration to pick a representative frame
        let semaphore = DispatchSemaphore(value: 0)
        var durationSec: Double = 5.0

        Task {
            if let duration = try? await asset.load(.duration) {
                durationSec = CMTimeGetSeconds(duration)
            }
            semaphore.signal()
        }
        semaphore.wait()

        // Try mid-point first, then 1s, then start
        let mid = max(0.5, min(5.0, durationSec / 2.0))
        let times: [CMTime] = [
            CMTime(seconds: mid, preferredTimescale: 600),
            CMTime(seconds: 1, preferredTimescale: 600),
            .zero
        ]

        for t in times {
            if let cg = try? generator.copyCGImage(at: t, actualTime: nil) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return nil
    }
}
