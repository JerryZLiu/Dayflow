//
//  ScreenshotScrubberView.swift
//  Dayflow
//
//  Scrubber that builds its filmstrip from screenshots instead of video.
//

import AppKit
import ImageIO
import SwiftUI

private let cachedScreenshotScrubberTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
}()

final class ScreenshotFilmstripGenerator {
    static let shared = ScreenshotFilmstripGenerator()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.dayflow.screenshotfilmstripgen"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private let syncQueue = DispatchQueue(label: "com.dayflow.screenshotfilmstripgen.sync")
    private var cache: [String: [NSImage]] = [:]
    private var inflight: [String: [(Int, [NSImage]) -> Void]] = [:]

    private init() {}

    func generate(screenshots: [Screenshot], frameCount: Int, targetHeight: CGFloat, completion: @escaping (Int, [NSImage]) -> Void) {
        let key = Self.cacheKey(for: screenshots, frameCount: frameCount, targetHeight: targetHeight)

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
            guard let self else { return }
            let samples = Self.sampleScreenshots(screenshots, count: frameCount)
            let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
            let targetWidth = targetHeight * (16.0 / 9.0)
            let maxPixel = max(64, Int(max(targetWidth, targetHeight) * scale))

            var images: [NSImage] = []
            images.reserveCapacity(frameCount)

            for screenshot in samples {
                if let image = Self.loadImage(url: screenshot.fileURL, maxPixel: maxPixel) {
                    images.append(image)
                } else {
                    images.append(NSImage())
                }
            }

            self.syncQueue.sync {
                self.cache[key] = images
            }
            self.finish(key: key, frameCount: frameCount, images: images)
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

    private static func sampleScreenshots(_ screenshots: [Screenshot], count: Int) -> [Screenshot] {
        guard screenshots.isEmpty == false, count > 0 else { return [] }
        if screenshots.count == 1 {
            return Array(repeating: screenshots[0], count: count)
        }
        let stride = Double(screenshots.count - 1) / Double(max(count - 1, 1))
        return (0..<count).map { idx in
            let raw = Int(round(Double(idx) * stride))
            let clamped = min(max(raw, 0), screenshots.count - 1)
            return screenshots[clamped]
        }
    }

    private static func loadImage(url: URL, maxPixel: Int) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
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

    private static func cacheKey(for screenshots: [Screenshot], frameCount: Int, targetHeight: CGFloat) -> String {
        let firstId = screenshots.first?.id ?? 0
        let lastId = screenshots.last?.id ?? 0
        return "s:\(firstId)-\(lastId)-\(screenshots.count)|n:\(frameCount)|h:\(Int(targetHeight.rounded()))"
    }
}

struct ScreenshotScrubberView: View {
    let screenshots: [Screenshot]
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
    private let aspect: CGFloat = 16.0 / 9.0
    private let zoom: CGFloat = 1.2
    private let chipRowHeight: CGFloat = 28
    private let chipSpacing: CGFloat = 0
    private let sideGutter: CGFloat = 30
    private var totalHeight: CGFloat { chipRowHeight + chipSpacing + filmstripHeight }
    private var screenshotsKey: String {
        let firstId = screenshots.first?.id ?? 0
        let lastId = screenshots.last?.id ?? 0
        return "\(firstId)-\(lastId)-\(screenshots.count)"
    }

    var body: some View {
        GeometryReader { outer in
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
                                    let img: NSImage? = i < images.count ? images[i] : nil
                                    Group {
                                        if let img {
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
                    .clipped()
                    .onChange(of: columnsNeeded) { _, newValue in
                        generateFilmstripIfNeeded(count: newValue)
                    }
                    .onChange(of: screenshotsKey) { _, _ in
                        generateFilmstripIfNeeded(count: columnsNeeded)
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
            return cachedScreenshotScrubberTimeFormatter.string(from: absolute)
        } else {
            let mins = Int(time) / 60
            let secs = Int(time) % 60
            return String(format: "%d:%02d", mins, secs)
        }
    }

    private func generateFilmstripIfNeeded(count: Int) {
        guard count > 0 else { return }
        guard screenshots.isEmpty == false else {
            images = []
            return
        }
        ScreenshotFilmstripGenerator.shared.generate(screenshots: screenshots, frameCount: count, targetHeight: filmstripHeight) { _, imgs in
            self.images = imgs
        }
    }
}

private extension Comparable {
    func clamped(to lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
