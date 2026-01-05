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
    private let temporaryDirectoryURL: URL
    private let persistentTimelapsesRootURL: URL
    private let maxRenderDimension = 1080  // mirror capture target height while allowing wide exports

    private struct TrackInfo: Hashable { let width: Int; let height: Int }

    init() {
        self.temporaryDirectoryURL = fileManager.temporaryDirectory

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

    private func newTemporaryFileURL(`extension` ext: String = "mp4") -> URL {
        temporaryDirectoryURL.appendingPathComponent(UUID().uuidString + "." + ext)
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

    /// If multiple URLs, stitches them. If sizes/orientations differ, re-renders to a canvas sized for the largest segment.
    func prepareVideoForProcessing(urls: [URL]) async throws -> URL {
        guard !urls.isEmpty else { throw VideoProcessingError.invalidInputURL }
        let tempOutputURL = newTemporaryFileURL()

        // Single‑file fast path
        if urls.count == 1, let singleURL = urls.first {
            do {
                if fileManager.fileExists(atPath: tempOutputURL.path) {
                    try fileManager.removeItem(at: tempOutputURL)
                }
                try fileManager.copyItem(at: singleURL, to: tempOutputURL)
                return tempOutputURL
            } catch {
                print("Error copying single video to temporary location: \(error)")
                throw VideoProcessingError.fileSaveFailed(error)
            }
        }

        // Inspect tracks to decide homogeneous vs mixed pipeline
        var infos = Set<TrackInfo>()
        for url in urls {
            let asset = AVURLAsset(url: url)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let nat = try await track.load(.naturalSize)
                let xf = try await track.load(.preferredTransform)
                let upright = nat.applying(xf)
                let w = Int(abs(upright.width).rounded())
                let h = Int(abs(upright.height).rounded())
                infos.insert(TrackInfo(width: w, height: h))
            }
        }

        // If mixed dimensions, render to canvas for stability
        if infos.count > 1 {
            let canvasDims = targetCanvasDimensions(for: infos)
            return try await stitchToCanvas(
                urls: urls,
                canvas: CGSize(width: CGFloat(canvasDims.width), height: CGFloat(canvasDims.height))
            )
        }

        // Stitch multiple files (homogeneous path)
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VideoProcessingError.noVideoTracks }

        var currentTime = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let assetVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                print("Warning: No video track in asset: \(url.lastPathComponent)")
                continue
            }

            let timeRange = CMTimeRange(start: .zero,
                                        duration: try await asset.load(.duration))
            do {
                try videoTrack.insertTimeRange(timeRange,
                                               of: assetVideoTrack,
                                               at: currentTime)
                currentTime = currentTime + timeRange.duration
            } catch {
                print("Error inserting asset \(url.lastPathComponent): \(error)")
                throw VideoProcessingError.trackInsertionFailed
            }
        }

        guard let exportSession = AVAssetExportSession(asset: composition,
                                                       presetName: AVAssetExportPresetPassthrough) else {
            throw VideoProcessingError.exportSessionCreationFailed
        }

        exportSession.outputURL = tempOutputURL
        exportSession.outputFileType = .mp4
        await exportSession.export()

        guard exportSession.status == .completed else {
            print("Stitching export failed. Status: \(exportSession.status). Error: \(exportSession.error?.localizedDescription ?? "No error description available")")
            throw VideoProcessingError.exportFailed(exportSession.error)
        }

        return tempOutputURL
    }

    /// Stitch multiple inputs onto a fixed canvas with letterboxing/pillarboxing for mixed orientations.
    private func stitchToCanvas(urls: [URL], canvas: CGSize) async throws -> URL {
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoProcessingError.noVideoTracks
        }

        var currentTime = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first else { continue }

            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try compTrack.insertTimeRange(timeRange, of: srcTrack, at: currentTime)

            // Compute upright size and transform to center-fit within canvas
            let nat = try await srcTrack.load(.naturalSize)
            let pref = try await srcTrack.load(.preferredTransform)
            let upright = nat.applying(pref)
            let inW = abs(upright.width)
            let inH = abs(upright.height)
            let scale = min(canvas.width / inW, canvas.height / inH)
            let scaledW = inW * scale
            let scaledH = inH * scale
            let tx = (canvas.width - scaledW) / 2.0
            let ty = (canvas.height - scaledH) / 2.0

            // Build final transform: preferred rotation → scale → translate to center
            var t = pref
            t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            // Translate after scaling; convert pixel translation into pre-scaled space
            t = t.concatenating(CGAffineTransform(translationX: tx / scale, y: ty / scale))

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
            layer.setTransform(t, at: currentTime)

            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: currentTime, duration: duration)
            instr.layerInstructions = [layer]
            instructions.append(instr)

            currentTime = currentTime + duration
        }

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = canvas
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.instructions = instructions

        let outputURL = newTemporaryFileURL()
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoProcessingError.exportSessionCreationFailed
        }
        export.videoComposition = videoComp
        export.outputURL = outputURL
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else {
            print("Canvas stitch export failed. Status: \(export.status). Error: \(export.error?.localizedDescription ?? "No error description")")
            throw VideoProcessingError.exportFailed(export.error)
        }
        return outputURL
    }

    /// Extract a single segment from `sourceVideoURL`.
    func extractSegment(from sourceVideoURL: URL,
                        startTime: TimeInterval,
                        duration: TimeInterval) async throws -> URL {
        let asset = AVURLAsset(url: sourceVideoURL)
        let tempOutputURL = newTemporaryFileURL()

        guard
            let exportSession = AVAssetExportSession(asset: asset,
                                                     presetName: AVAssetExportPresetPassthrough)
        else { throw VideoProcessingError.exportSessionCreationFailed }

        let assetDuration = try await asset.load(.duration)
        let timescale = assetDuration.timescale

        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: timescale),
            duration: CMTime(seconds: duration, preferredTimescale: timescale)
        )
        exportSession.outputURL = tempOutputURL
                exportSession.outputFileType = .mp4
                await exportSession.export()

                guard exportSession.status == .completed else {
                    print("Stitching export failed. Status: \(exportSession.status). Error: \(exportSession.error?.localizedDescription ?? "No error description available")")
                    throw VideoProcessingError.exportFailed(exportSession.error)
                }

        return tempOutputURL
    }

    /// Generate a timelapse video by picking frames at interval and re-encoding at higher FPS
    func generateTimelapse(sourceVideoURL: URL,
                          outputTimelapseFileURL: URL,
                          speedupFactor: Int = 8,
                          outputFPS: Int = 15) async throws {  // Reduced from 30 to 15 FPS
        let asset = AVURLAsset(url: sourceVideoURL)
        guard let assetTrack = try await asset.loadTracks(withMediaType: .video).first else {
            print("Error: No video track in \(sourceVideoURL.lastPathComponent)")
            throw VideoProcessingError.noVideoTracks
        }

        // Get video properties
        let duration = try await asset.load(.duration)
        let naturalSize = try await assetTrack.load(.naturalSize)
        let preferredTransform = try await assetTrack.load(.preferredTransform)
        let actualSize = naturalSize.applying(preferredTransform)
        let width = Int(abs(actualSize.width).rounded())
        let height = Int(abs(actualSize.height).rounded())
        _ = try await assetTrack.load(.nominalFrameRate)

        // Create composition with time mapping for speedup
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoProcessingError.noVideoTracks
        }
        
        // Calculate new duration after speedup
        let scaledDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / Double(speedupFactor))
        
        // Insert the entire video but we'll use time mapping
        try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                           of: assetTrack,
                                           at: .zero)
        
        // Scale the time to achieve speedup
        compositionTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                                       toDuration: scaledDuration)
        
        // Ensure output directory exists
        let outputDir = outputTimelapseFileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: outputDir.path) {
            try? fileManager.createDirectory(at: outputDir,
                                           withIntermediateDirectories: true,
                                           attributes: nil)
        }
        if fileManager.fileExists(atPath: outputTimelapseFileURL.path) {
            try? fileManager.removeItem(at: outputTimelapseFileURL)
        }
        
        // Use custom compression with lower bitrate for smaller files
        guard let writer = try? AVAssetWriter(outputURL: outputTimelapseFileURL, fileType: .mp4) else {
            throw VideoProcessingError.assetWriterCreationFailed(nil)
        }
        
        let dims = normalizedDimensions(width: width, height: height)
        let outputWidth = dims.width
        let outputHeight = dims.height

        // Scale bitrate with pixel area to preserve quality on wide screens without huge files
        let baseBitrate = 3_000_000
        let minBitrate = 1_500_000
        let maxBitrate = 10_000_000
        let areaRatio = Double(outputWidth * outputHeight) / (1920.0 * 1080.0)
        let scaledBitrate = Int((Double(baseBitrate) * max(areaRatio, 0.5)).rounded())
        let bitrate = min(max(scaledBitrate, minBitrate), maxBitrate)

        print("🎬 Timelapse encoding: \(outputWidth)×\(outputHeight) @ \(outputFPS)fps, bitrate: \(Double(bitrate) / 1_000_000)Mbps")
        
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 150, // Keyframe every 10 seconds at 15fps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoExpectedSourceFrameRateKey: outputFPS,
                AVVideoAverageNonDroppableFrameRateKey: outputFPS
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform
        
        guard writer.canAdd(writerInput) else {
            throw VideoProcessingError.assetWriterInputCreationFailed
        }
        writer.add(writerInput)
        
        // Create reader for the composition
        guard let reader = try? AVAssetReader(asset: composition) else {
            throw VideoProcessingError.assetReaderCreationFailed(nil)
        }
        
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        
        // Apply video composition for proper rendering
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: CGFloat(outputWidth), height: CGFloat(outputHeight))
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(outputFPS))
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: scaledDuration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        readerOutput.videoComposition = videoComposition
        
        guard reader.canAdd(readerOutput) else {
            throw VideoProcessingError.assetReaderCreationFailed(nil)
        }
        reader.add(readerOutput)
        
        // Start reading and writing
        guard writer.startWriting() else {
            throw VideoProcessingError.assetWriterStartFailed(nil)
        }
        writer.startSession(atSourceTime: .zero)
        reader.startReading()
        
        // Process video frames
        // Create unsafe captures - these are used exclusively on the serial queue below
        let unsafeWriterInput = writerInput
        let unsafeReader = reader
        let unsafeReaderOutput = readerOutput
        let unsafeWriter = writer

        await withCheckedContinuation { continuation in
            unsafeWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.dayflow.timelapse")) {
                while unsafeWriterInput.isReadyForMoreMediaData {
                    if unsafeReader.status == .reading,
                       let sampleBuffer = unsafeReaderOutput.copyNextSampleBuffer() {
                        unsafeWriterInput.append(sampleBuffer)
                    } else {
                        unsafeWriterInput.markAsFinished()
                        unsafeWriter.finishWriting {
                            continuation.resume()
                        }
                        break
                    }
                }
            }
        }
        
        guard writer.status == .completed else {
            print("Timelapse export failed. Status: \(writer.status). Error: \(writer.error?.localizedDescription ?? "No error description available")")
            throw VideoProcessingError.exportFailed(writer.error)
        }

        TimelapseStorageManager.shared.purgeIfNeeded()
    }

    private func normalizedDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width: 2, height: 2) }

        var targetWidth = width
        var targetHeight = height

        if width >= height {
            if height > maxRenderDimension {
                let scale = Double(maxRenderDimension) / Double(height)
                targetHeight = maxRenderDimension
                targetWidth = max(Int((Double(width) * scale).rounded()), 2)
            }
        } else {
            if width > maxRenderDimension {
                let scale = Double(maxRenderDimension) / Double(width)
                targetWidth = maxRenderDimension
                targetHeight = max(Int((Double(height) * scale).rounded()), 2)
            }
        }

        targetWidth = makeEven(targetWidth)
        targetHeight = makeEven(targetHeight)

        return (targetWidth, targetHeight)
    }

    private func targetCanvasDimensions(for infos: Set<TrackInfo>) -> (width: Int, height: Int) {
        guard let maxWidth = infos.map(\.width).max(),
              let maxHeight = infos.map(\.height).max() else {
            return normalizedDimensions(width: maxRenderDimension, height: maxRenderDimension)
        }
        return normalizedDimensions(width: maxWidth, height: maxHeight)
    }

    private func makeEven(_ value: Int) -> Int {
        let even = value - (value % 2)
        return max(even, 2)
    }

    func cleanupTemporaryFile(at url: URL) {
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
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
        var frameIndex = 0
        let baseTimestamp = screenshots.first!.capturedAt

        for screenshot in screenshots {
            // Load image
            guard let imageData = try? Data(contentsOf: screenshot.fileURL),
                  let nsImage = NSImage(data: imageData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("⚠️ Skipping invalid image: \(screenshot.fileURL.lastPathComponent)")
                continue
            }

            // Create pixel buffer with aspect-fit compositing (letterbox/pillarbox as needed)
            guard let pixelBuffer = createPixelBuffer(from: cgImage, canvasWidth: width, canvasHeight: height) else {
                print("⚠️ Failed to create pixel buffer for: \(screenshot.fileURL.lastPathComponent)")
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

        // 4. Finish writing
        writerInput.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            print("Screenshot compositing failed. Status: \(writer.status). Error: \(writer.error?.localizedDescription ?? "nil")")
            throw VideoProcessingError.exportFailed(writer.error)
        }

        let videoDuration = useCompressedTimeline ? frameIndex : (screenshots.last!.capturedAt - baseTimestamp)
        print("✅ Generated \(useCompressedTimeline ? "compressed" : "realtime") video from \(frameIndex) screenshots (\(videoDuration)s): \(outputURL.lastPathComponent)")
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
