@preconcurrency import AVFoundation
import Foundation
import CoreGraphics
import ImageIO

enum VideoProcessingError: Error {
    case invalidInputURL
    case assetLoadFailed(Error?)
    case noVideoTracks
    case trackInsertionFailed
    case exportSessionCreationFailed
    case exportFailed(Error?)
    case exportStatusNotCompleted(AVAssetExportSession.Status)
    case assetReaderCreationFailed(Error?)
    case assetWriterCreationFailed(Error?)
    case assetWriterInputCreationFailed
    case assetWriterStartFailed(Error?)
    case frameReadFailed
    case frameAppendFailed
    case directoryCreationFailed(Error?)
    case fileSaveFailed(Error?)
    case noInputFiles
    case invalidImageData
    case pixelBufferCreationFailed
}

actor VideoProcessingService {
    enum VideoCodec: String, Sendable {
        case h264
        case hevc

        var avCodecType: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            }
        }
    }

    struct VideoEncodingOptions: Sendable {
        var maxOutputHeight: Int?
        var frameStride: Int
        var averageBitRate: Int
        var codec: VideoCodec
        var keyframeIntervalSeconds: Int

        static let `default` = VideoEncodingOptions(
            maxOutputHeight: nil,
            frameStride: 1,
            averageBitRate: 2_000_000,
            codec: .h264,
            keyframeIntervalSeconds: 10
        )
    }

    private let fileManager = FileManager.default
    private let persistentTimelapsesRootURL: URL
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        // Create a persistent directory for timelapses within Application Support
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.persistentTimelapsesRootURL = appSupportURL.appendingPathComponent("Dayflow/timelapses", isDirectory: true)

        // Ensure the root timelapses directory exists
        do {
            try fileManager.createDirectory(at: self.persistentTimelapsesRootURL,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
        } catch {
            // Log this, but don't fail initialization.
            print("Error creating persistent timelapses root directory: \(self.persistentTimelapsesRootURL.path). Error: \(error)")
        }
    }

    func generatePersistentTimelapseURL(for date: Date,
                                      originalFileName: String) -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)

        let dateSpecificDir = persistentTimelapsesRootURL
            .appendingPathComponent(dateString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: dateSpecificDir,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
        } catch {
            print("Error creating date-specific timelapse directory: \(dateSpecificDir.path). Error: \(error)")
            return persistentTimelapsesRootURL
                .appendingPathComponent(originalFileName + "_timelapse.mp4")
        }

        return dateSpecificDir
            .appendingPathComponent(originalFileName + "_timelapse.mp4")
    }

    private func makeEven(_ value: Int) -> Int {
        let even = value - (value % 2)
        return max(even, 2)
    }

    // MARK: - Screenshot to Video Compositing

    /// Composites a series of screenshot images into an MP4 video.
    /// Used for timelapse generation and Gemini provider (which requires video format).
    ///
    /// - Parameters:
    ///   - screenshots: Array of Screenshot objects, in chronological order
    ///   - outputURL: Where to write the output MP4
    ///   - fps: Output frames per second (default 1 = each screenshot is 1 second of video)
    ///   - useCompressedTimeline: If true, places frames at 1fps (compressed). If false, uses real timestamps.
    func generateVideoFromScreenshots(
        screenshots: [Screenshot],
        outputURL: URL,
        fps: Int = 1,
        useCompressedTimeline: Bool = true,
        options: VideoEncodingOptions = .default
    ) async throws {
        guard !screenshots.isEmpty else {
            throw VideoProcessingError.noInputFiles
        }

        let overallStart = Date()
        let scanStart = Date()
        let frameStride = max(1, options.frameStride)
        let selectedScreenshots = sampleScreenshots(screenshots, stride: frameStride)
        guard !selectedScreenshots.isEmpty else {
            throw VideoProcessingError.noInputFiles
        }

        guard let firstFrameSize = firstValidImageSize(in: selectedScreenshots) else {
            throw VideoProcessingError.invalidImageData
        }
        let (width, height) = resolvedCanvasSize(sourceWidth: firstFrameSize.width, sourceHeight: firstFrameSize.height, maxOutputHeight: options.maxOutputHeight)
        let decodeMaxPixel = max(width, height)
        let scanDuration = Date().timeIntervalSince(scanStart)

        // Ensure output directory exists
        let outputDir = outputURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: outputDir.path) {
            try? fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        // 2. Setup AVAssetWriter for H.264 video
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw VideoProcessingError.assetWriterCreationFailed(nil)
        }

        let safeFPS = max(1, fps)
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: max(100_000, options.averageBitRate),
            AVVideoMaxKeyFrameIntervalKey: safeFPS * max(1, options.keyframeIntervalSeconds)
        ]
        if options.codec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw VideoProcessingError.assetWriterInputCreationFailed
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw VideoProcessingError.assetWriterStartFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // 3. Write each screenshot as a frame
        let encodeStart = Date()
        var frameIndex = 0
        var skippedFrames = 0
        let baseTimestamp = selectedScreenshots.first!.capturedAt
        let pixelBufferPool = adaptor.pixelBufferPool

        for screenshot in selectedScreenshots {
            guard let cgImage = loadCGImage(from: screenshot.fileURL, maxPixelSize: decodeMaxPixel) else {
                print("⚠️ Skipping invalid image: \(screenshot.fileURL.lastPathComponent)")
                skippedFrames += 1
                continue
            }

            // Create pixel buffer with aspect-fit compositing (letterbox/pillarbox as needed)
            guard let pixelBuffer = createPixelBuffer(from: cgImage, canvasWidth: width, canvasHeight: height, pixelBufferPool: pixelBufferPool) else {
                print("⚠️ Failed to create pixel buffer for: \(screenshot.fileURL.lastPathComponent)")
                skippedFrames += 1
                continue
            }

            // Calculate presentation time
            let presentationTime: CMTime
            if useCompressedTimeline {
                // Compressed: each frame is 1/fps seconds apart
                // e.g., fps=2 means each frame is 0.5s apart (2 frames per second)
                let frameTime = Double(frameIndex) / Double(safeFPS)
                presentationTime = CMTime(seconds: frameTime, preferredTimescale: 600)
            } else {
                // Real timeline: use actual capture timestamps
                let elapsedSeconds = Double(screenshot.capturedAt - baseTimestamp)
                presentationTime = CMTime(seconds: elapsedSeconds, preferredTimescale: 600)
            }

            // Wait for writer to be ready
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            // Append frame
            if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                print("⚠️ Failed to append frame at \(CMTimeGetSeconds(presentationTime))s")
            }
            frameIndex += 1
        }
        let encodeDuration = Date().timeIntervalSince(encodeStart)

        // 4. Finish writing
        writerInput.markAsFinished()

        let finalizeStart = Date()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        let finalizeDuration = Date().timeIntervalSince(finalizeStart)

        guard writer.status == .completed else {
            print("Screenshot compositing failed. Status: \(writer.status). Error: \(writer.error?.localizedDescription ?? "nil")")
            throw VideoProcessingError.exportFailed(writer.error)
        }

        let videoDuration = useCompressedTimeline ? Double(frameIndex) / Double(safeFPS) : Double(selectedScreenshots.last!.capturedAt - baseTimestamp)
        print("✅ Generated \(useCompressedTimeline ? "compressed" : "realtime") video from \(frameIndex) screenshots (\(videoDuration)s): \(outputURL.lastPathComponent)")

        let totalDuration = Date().timeIntervalSince(overallStart)
        let timingSummary = String(
            format: "TIMING timelapse frames=%d/%d sampled=%d stride=%d skipped=%d size=%dx%d fps=%d bitrate=%d codec=%@ scan=%.2fs encode=%.2fs finalize=%.2fs total=%.2fs output=%@",
            frameIndex,
            screenshots.count,
            selectedScreenshots.count,
            frameStride,
            skippedFrames,
            width,
            height,
            safeFPS,
            max(100_000, options.averageBitRate),
            options.codec.rawValue,
            scanDuration,
            encodeDuration,
            finalizeDuration,
            totalDuration,
            outputURL.lastPathComponent
        )
        print(timingSummary)
    }

    /// Overload that accepts file URLs directly (convenience for legacy code paths)
    func generateVideoFromScreenshots(
        screenshotURLs: [URL],
        outputURL: URL,
        fps: Int = 10
    ) async throws {
        // Convert URLs to Screenshot-like objects with estimated timestamps
        // This is less accurate but works for cases where we only have URLs
        var screenshots: [Screenshot] = []
        let baseTimestamp = Int(Date().timeIntervalSince1970) - (screenshotURLs.count * 10) // Estimate

        for (index, url) in screenshotURLs.enumerated() {
            // Try to parse timestamp from filename (YYYYMMDD_HHmmssSSS.jpg)
            let filename = url.deletingPathExtension().lastPathComponent
            let timestamp: Int
            if let parsed = parseTimestampFromFilename(filename) {
                timestamp = parsed
            } else {
                timestamp = baseTimestamp + (index * 10) // Fall back to estimated
            }

            screenshots.append(Screenshot(
                id: Int64(index),
                capturedAt: timestamp,
                filePath: url.path,
                fileSize: nil,
                isDeleted: false
            ))
        }

        try await generateVideoFromScreenshots(screenshots: screenshots, outputURL: outputURL, fps: fps)
    }

    private func sampleScreenshots(_ screenshots: [Screenshot], stride: Int) -> [Screenshot] {
        let safeStride = max(1, stride)
        guard safeStride > 1 else { return screenshots }

        var sampled: [Screenshot] = []
        sampled.reserveCapacity(max(1, screenshots.count / safeStride))
        var index = 0
        while index < screenshots.count {
            sampled.append(screenshots[index])
            index += safeStride
        }
        return sampled
    }

    private func firstValidImageSize(in screenshots: [Screenshot]) -> (width: Int, height: Int)? {
        for screenshot in screenshots {
            if let size = imageSize(at: screenshot.fileURL) {
                return size
            }
        }
        return nil
    }

    private func imageSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    private func resolvedCanvasSize(sourceWidth: Int, sourceHeight: Int, maxOutputHeight: Int?) -> (Int, Int) {
        let safeSourceWidth = max(2, sourceWidth)
        let safeSourceHeight = max(2, sourceHeight)

        guard let maxOutputHeight, maxOutputHeight > 0 else {
            return (makeEven(safeSourceWidth), makeEven(safeSourceHeight))
        }

        if safeSourceHeight <= maxOutputHeight {
            return (makeEven(safeSourceWidth), makeEven(safeSourceHeight))
        }

        let scale = Double(maxOutputHeight) / Double(safeSourceHeight)
        let scaledWidth = Int((Double(safeSourceWidth) * scale).rounded())
        return (makeEven(max(2, scaledWidth)), makeEven(maxOutputHeight))
    }

    private func loadCGImage(from url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        // Prefer full decode and downscale during draw. In practice this can be
        // faster than ImageIO thumbnail generation for high frame-count batches.
        let fullDecodeOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true
        ]
        if let fullImage = CGImageSourceCreateImageAtIndex(source, 0, fullDecodeOptions as CFDictionary) {
            return fullImage
        }

        let safeMaxPixelSize = max(64, maxPixelSize)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: safeMaxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func parseTimestampFromFilename(_ filename: String) -> Int? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmssSSS"
        if let date = formatter.date(from: filename) {
            return Int(date.timeIntervalSince1970)
        }
        return nil
    }

    /// Creates a pixel buffer with the image composited onto a canvas using aspect-fit.
    /// The image is centered and letterboxed/pillarboxed with black if aspect ratios differ.
    private func createPixelBuffer(from cgImage: CGImage, canvasWidth: Int, canvasHeight: Int, pixelBufferPool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let status: CVReturn
        if let pixelBufferPool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                canvasWidth,
                canvasHeight,
                kCVPixelFormatType_32ARGB,
                attrs as CFDictionary,
                &pixelBuffer
            )
        }

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        // Fill with black (letterbox/pillarbox background)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        // Calculate aspect-fit scaling to center the image without distortion
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let canvasW = CGFloat(canvasWidth)
        let canvasH = CGFloat(canvasHeight)

        let scaleX = canvasW / imageWidth
        let scaleY = canvasH / imageHeight
        let scale = min(scaleX, scaleY)  // Aspect-fit: use smaller scale to fit entirely

        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let offsetX = (canvasW - scaledWidth) / 2.0
        let offsetY = (canvasH - scaledHeight) / 2.0

        // Draw the image centered and scaled
        context.draw(cgImage, in: CGRect(x: offsetX, y: offsetY, width: scaledWidth, height: scaledHeight))

        return buffer
    }
}
