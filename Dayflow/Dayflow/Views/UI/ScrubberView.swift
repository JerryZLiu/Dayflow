//
//  ScrubberView.swift
//  Dayflow
//
//  Minimal custom scrubber with baseline, draggable playhead, time chip,
//  and filmstrip thumbnails generated from the video.
//

import SwiftUI
import AVFoundation
import AppKit

// MARK: - Cached DateFormatter (creating DateFormatters is expensive due to ICU initialization)

private let cachedScrubberTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
}()

final class FilmstripGenerator {
    static let shared = FilmstripGenerator()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.dayflow.filmstripgen"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private let syncQueue = DispatchQueue(label: "com.dayflow.filmstripgen.sync")
    private var cache: [String: [NSImage]] = [:]
    private var inflight: [String: [(Int, [NSImage]) -> Void]] = [:]

    private init() {}

    func generate(url: URL, frameCount: Int, targetHeight: CGFloat, completion: @escaping (Int, [NSImage]) -> Void) {
        // Key by file path + mtime + parameters
        let key = Self.cacheKey(for: url, frameCount: frameCount, targetHeight: targetHeight)

        if let images = syncQueue.sync(execute: { cache[key] }) {
            completion(frameCount, images)
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
            guard let self = self else { return }
            let asset = AVAsset(url: url)
            guard asset.isPlayable else {
                self.finish(key: key, frameCount: frameCount, images: [])
                return
            }

            let duration = CMTimeGetSeconds(asset.duration)
            if duration.isNaN || duration.isInfinite || duration <= 0 {
                self.finish(key: key, frameCount: frameCount, images: [])
                return
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Set a reasonable maximum size for thumbnails
            let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
            generator.maximumSize = CGSize(width: targetHeight * 16/9 * scale, height: targetHeight * scale)

            // Evenly spaced times across duration (avoid 0 exactly)
            let step = duration / Double(frameCount)
            let times: [NSValue] = (0..<frameCount).map { i in
                let t = max(0.001, Double(i) * step + step * 0.5)
                return NSValue(time: CMTime(seconds: t, preferredTimescale: 600))
            }
            var indexMap: [Int64: Int] = [:]
            for (i, v) in times.enumerated() {
                indexMap[v.timeValue.value] = i
            }

            var images: [NSImage] = Array(repeating: NSImage(), count: frameCount)
            var produced = 0
            let group = DispatchGroup()

            // Use generateCGImagesAsynchronously for better throughput
            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, cg, actualTime, result, error in
                if let cg = cg, result == .succeeded {
                    let index = indexMap[requestedTime.value] ?? Int((CMTimeGetSeconds(actualTime) / duration * Double(frameCount)).clamped(to: 0.0, Double(frameCount - 1)))
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    if index >= 0 && index < images.count {
                        images[index] = image
                    }
                }
                produced += 1
                if produced == frameCount {
                    self.syncQueue.sync {
                        self.cache[key] = images
                    }
                    self.finish(key: key, frameCount: frameCount, images: images)
                }
            }
        }
    }

    private func finish(key: String, frameCount: Int, images: [NSImage]) {
        var callbacks: [(Int, [NSImage]) -> Void] = []
        syncQueue.sync {
            callbacks = inflight[key] ?? []
            inflight.removeValue(forKey: key)
        }
        DispatchQueue.main.async {
            callbacks.forEach { $0(frameCount, images) }
        }
    }

    private static func cacheKey(for url: URL, frameCount: Int, targetHeight: CGFloat) -> String {
        var mtimeString = "-"
        if url.isFileURL, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date {
            mtimeString = String(Int(mtime.timeIntervalSince1970))
        }
        return "\(url.absoluteString)|m:\(mtimeString)|n:\(frameCount)|h:\(Int(targetHeight.rounded()))"
    }
}

struct ScrubberView: View {
    let url: URL
    let duration: Double
    let currentTime: Double
    let onSeek: (Double) -> Void
    let onScrubStateChange: (Bool) -> Void
    var absoluteStart: Date? = nil
    var absoluteEnd: Date? = nil

    @State private var images: [NSImage] = []
    @State private var isDragging: Bool = false

    private let frameCount = 12
    private let filmstripHeight: CGFloat = 64
    private let aspect: CGFloat = 16.0/9.0
    private let zoom: CGFloat = 1.2 // 20% zoom
    private let chipRowHeight: CGFloat = 28
    private let chipSpacing: CGFloat = 0  // no gap; chip overlaps filmstrip slightly via offset below
    private let sideGutter: CGFloat = 30  // outer gutters left/right of the strip
    // Total height = chip row + spacing + filmstrip
    private var totalHeight: CGFloat { chipRowHeight + chipSpacing + filmstripHeight }

    var body: some View {
        GeometryReader { outer in
            // Shared x-position for playhead based on full width
            let stripWidth = max(1, outer.size.width - sideGutter * 2)
            let xInsideRaw = xFor(time: currentTime, width: stripWidth)
            // Snap to device pixels to avoid shimmer
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let xInside = (xInsideRaw * scale).rounded() / scale
            let x = sideGutter + xInside

            ZStack(alignment: .topLeading) {
            VStack(spacing: chipSpacing) {
                // Time chip row (pill above filmstrip)
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(height: chipRowHeight)
                    Text(timeLabel(for: currentTime))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)  // minus 2px each side from 10
                        .padding(.vertical, 4)    // minus 2px each side from 6
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(12)
                        .scaleEffect(0.8) // shrink ~20%
                        .position(x: x, y: chipRowHeight/2) // lowered by ~3px
                }
                .zIndex(1) // ensure chip renders above the playhead bar

                // Filmstrip with white background, square corners, no border
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.white)

                    // Thumbnails row
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
                                let img: NSImage? = i < images.count ? images[i] : nil
                                Group {
                                    if let img = img {
                                        Image(nsImage: img)
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
                    .clipped() // cut last thumbnail at bounds
                    .onChange(of: columnsNeeded) { _, newValue in
                        generateFilmstripIfNeeded(count: newValue)
                    }
                    .onAppear { generateFilmstripIfNeeded(count: columnsNeeded) }

                    // Vertical playhead bar with black outline; extend ~3px into chip row
                    let barHeight = filmstripHeight + 3 // extend slightly into chip area
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
                .padding(.horizontal, sideGutter) // create outer gutters
            }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging { isDragging = true; onScrubStateChange(true) }
                        // Map global x → inner filmstrip x (accounting for outer gutters)
                        let stripWidth = max(1, outer.size.width - sideGutter * 2)
                        let xLocal = (value.location.x - sideGutter).clamped(to: 0, stripWidth)
                        let pct = xLocal / stripWidth
                        onSeek(Double(pct) * max(duration, 0.0001))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onScrubStateChange(false)
                    }
            )
        }
        .frame(height: totalHeight)
        .onAppear { /* filmstrip generation handled above */ }
    }

    private func xFor(time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func timeLabel(for time: Double) -> String {
        if let start = absoluteStart, let end = absoluteEnd, duration > 0 {
            let total = end.timeIntervalSince(start)
            let pct = max(0, min(1, time / duration))
            let absolute = start.addingTimeInterval(total * pct)
            return cachedScrubberTimeFormatter.string(from: absolute)
        } else {
            let mins = Int(time) / 60
            let secs = Int(time) % 60
            return String(format: "%d:%02d", mins, secs)
        }
    }

    private func generateFilmstripIfNeeded(count: Int) {
        guard count > 0 else { return }
        FilmstripGenerator.shared.generate(url: url, frameCount: count, targetHeight: filmstripHeight) { producedCount, imgs in
            // Only set if counts match current expectation to avoid race during resizes
            self.images = imgs
        }
    }
}

private extension Comparable {
    func clamped(to lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
