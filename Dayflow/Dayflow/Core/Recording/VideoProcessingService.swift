@preconcurrency import AVFoundation
import Foundation
import CoreGraphics

import AppKit

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
    private let fileManager = FileManager.default
    private let persistentTimelapsesRootURL: URL

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
        useCompressedTimeline: Bool = true
    ) async throws {
        guard !screenshots.isEmpty else {
            throw VideoProcessingError.noInputFiles
        }

        let overallStart = Date()
        let scanStart = Date()

        // 1. Find the widest screenshot to use as canvas dimensions
        //    This ensures all aspect ratios are preserved via letterboxing/pillarboxing
        var canvasWidth = 0
        var canvasHeight = 0

        for screenshot in screenshots {
            guard let imageData = try? Data(contentsOf: screenshot.fileURL),
                  let nsImage = NSImage(data: imageData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }

            if cgImage.width > canvasWidth {
                canvasWidth = cgImage.width
                canvasHeight = cgImage.height
            }
        }

        // Fallback to first image if scanning failed
        guard canvasWidth > 0 && canvasHeight > 0 else {
            throw VideoProcessingError.invalidImageData
        }

        let scanDuration = Date().timeIntervalSince(scanStart)

        // Ensure even dimensions for H.264 codec
        canvasWidth = makeEven(canvasWidth)
        canvasHeight = makeEven(canvasHeight)

        let width = canvasWidth
        let height = canvasHeight

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

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,  // 2 Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 10  // Keyframe every 10 seconds
            ]
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
        let baseTimestamp = screenshots.first!.capturedAt

        for screenshot in screenshots {
            // Load image
            guard let imageData = try? Data(contentsOf: screenshot.fileURL),
                  let nsImage = NSImage(data: imageData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("⚠️ Skipping invalid image: \(screenshot.fileURL.lastPathComponent)")
                skippedFrames += 1
                continue
            }

            // Create pixel buffer with aspect-fit compositing (letterbox/pillarbox as needed)
            guard let pixelBuffer = createPixelBuffer(from: cgImage, canvasWidth: width, canvasHeight: height) else {
                print("⚠️ Failed to create pixel buffer for: \(screenshot.fileURL.lastPathComponent)")
                skippedFrames += 1
                continue
            }

            // Calculate presentation time
            let presentationTime: CMTime
            if useCompressedTimeline {
                // Compressed: each frame is 1/fps seconds apart
                // e.g., fps=2 means each frame is 0.5s apart (2 frames per second)
                let frameTime = Double(frameIndex) / Double(fps)
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

        let videoDuration = useCompressedTimeline ? frameIndex : (screenshots.last!.capturedAt - baseTimestamp)
        print("✅ Generated \(useCompressedTimeline ? "compressed" : "realtime") video from \(frameIndex) screenshots (\(videoDuration)s): \(outputURL.lastPathComponent)")

        let totalDuration = Date().timeIntervalSince(overallStart)
        let timingSummary = String(
            format: "TIMING timelapse frames=%d/%d skipped=%d size=%dx%d fps=%d scan=%.2fs encode=%.2fs finalize=%.2fs total=%.2fs output=%@",
            frameIndex,
            screenshots.count,
            skippedFrames,
            width,
            height,
            fps,
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
    private func createPixelBuffer(from cgImage: CGImage, canvasWidth: Int, canvasHeight: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            canvasWidth,
            canvasHeight,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )

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
            space: CGColorSpaceCreateDeviceRGB(),
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
