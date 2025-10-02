//
//  ThumbnailCache.swift
//  Dayflow
//
//  In-memory thumbnail cache with background generation and de-duplication.
//

import Foundation
import AppKit
import AVFoundation

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.dayflow.thumbnailgen"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private let syncQueue = DispatchQueue(label: "com.dayflow.thumbnailcache.sync")
    private var inflight: [String: [(NSImage?) -> Void]] = [:]

    private init() {
        // Rough memory cap based on pixels; adjust as needed
        // Assume ~4 bytes per pixel, target about 100MB worth of thumbnails.
        cache.totalCostLimit = 25_000_000 // cost = width * height; translates via our cost calc below
    }

    // Public API: fetch or generate thumbnail; completion runs on main thread
    func fetchThumbnail(videoURL: String, targetSize: CGSize, completion: @escaping (NSImage?) -> Void) {
        let (normalizedURL, mtime) = normalize(urlString: videoURL)
        let key = cacheKey(url: normalizedURL, mtime: mtime, size: targetSize)

        if let image = cache.object(forKey: key as NSString) {
            DispatchQueue.main.async { completion(image) }
            return
        }

        // De-duplicate concurrent requests
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
            guard let self = self else { return }
            let image = self.generateThumbnail(urlString: normalizedURL, targetSize: targetSize)

            if let image = image {
                let cost = Int(max(1, image.size.width * image.size.height))
                self.cache.setObject(image, forKey: key as NSString, cost: cost)
            }

            var callbacks: [(NSImage?) -> Void] = []
            self.syncQueue.sync {
                callbacks = self.inflight[key] ?? []
                self.inflight.removeValue(forKey: key)
            }

            DispatchQueue.main.async {
                callbacks.forEach { $0(image) }
            }
        }
    }

    // Fire-and-forget prefetch
    func prefetch(videoURL: String, targetSize: CGSize) {
        fetchThumbnail(videoURL: videoURL, targetSize: targetSize) { _ in }
    }

    private func cacheKey(url: String, mtime: TimeInterval?, size: CGSize) -> String {
        // Include size rounded to integers to separate entries
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        let mt = mtime != nil ? String(Int(mtime!)) : "-"
        return "\(url)|\(mt)|\(w)x\(h)"
    }

    private func normalize(urlString: String) -> (String, TimeInterval?) {
        let processed = urlString.hasPrefix("file://") ? urlString : "file://" + urlString
        // Extract file path robustly
        let path: String
        if processed.hasPrefix("file://") {
            path = String(processed.dropFirst("file://".count))
        } else {
            path = processed
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mtime = attrs[.modificationDate] as? Date {
            return (processed, mtime.timeIntervalSince1970)
        }
        return (processed, nil)
    }

    private func generateThumbnail(urlString: String, targetSize: CGSize) -> NSImage? {
        let url: URL
        if urlString.hasPrefix("file://") {
            // Build a proper file URL that tolerates spaces/special chars
            let path = String(urlString.dropFirst("file://".count))
            url = URL(fileURLWithPath: path)
        } else if let u = URL(string: urlString) {
            url = u
        } else {
            return nil
        }
        if url.isFileURL {
            let path = url.path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
        }

        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Decode near display size to avoid full-res work
        if targetSize != .zero {
            // Multiply by screen scale ~2.0 to preserve sharpness
            let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
            generator.maximumSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        }

        // Prefer a representative mid-point (bounded) to avoid identical first frames
        let durationSec = CMTimeGetSeconds(asset.duration)
        let mid = max(0.5, min(5.0, durationSec / 2.0))
        let times: [CMTime] = [CMTime(seconds: mid, preferredTimescale: 600), CMTime(seconds: 1, preferredTimescale: 600), .zero]
        for t in times {
            do {
                let cg = try generator.copyCGImage(at: t, actualTime: nil)
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                return image
            } catch {
                continue
            }
        }
        return nil
    }
}
