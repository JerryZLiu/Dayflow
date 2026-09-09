//
//  FrameStore.swift
//  Dayflow
//
//  Stores captured frames as hardware-encoded HEVC segment files instead of
//  one JPEG per capture. Each `screenshots` row points at a segment file plus
//  a frame index; `image(for:)` decodes that frame back out on demand.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import VideoToolbox

final class FrameStore: @unchecked Sendable {
  static let shared = FrameStore()

  /// Encoder quality (0...1). 0.55 is the lowest setting that keeps small UI text legible.
  static let encodeQuality: Float = 0.55
  /// A segment is closed after this much wall-clock time or this many frames
  /// (600 frames is ten minutes at the fastest 1 s capture interval).
  static let segmentDuration: TimeInterval = 600
  static let maxFramesPerSegment = 600
  /// Every frame is decodable from at most this many frames back. Smaller means
  /// faster random access for thumbnails at a modest file-size cost.
  static let keyframeInterval = 30

  private let writeQueue = DispatchQueue(label: "com.dayflow.framestore.write", qos: .userInitiated)
  private var writer: SegmentWriter?

  private let readLock = NSLock()
  private var readers: [String: SegmentReader] = [:]
  private var readerOrder: [String] = []
  private let readerCacheLimit = 4

  private init() {}

  // MARK: - Writing

  /// Path of the segment currently being written, if any. Purge must never delete it.
  var activeSegmentPath: String? {
    writeQueue.sync { writer?.url.path }
  }

  /// Encodes one frame and records it in the database. Returns the new screenshot id.
  @discardableResult
  func append(_ image: CGImage, capturedAt: Date, idleSecondsAtCapture: Int?) -> Int64? {
    writeQueue.sync {
      if let current = writer, current.needsRotation(forWidth: image.width, height: image.height) {
        finishWriterLocked()
      }

      if writer == nil {
        let url = StorageManager.shared.nextSegmentURL()
        guard let created = SegmentWriter(url: url, width: image.width, height: image.height)
        else {
          print("❌ FrameStore: could not start segment at \(url.lastPathComponent)")
          return nil
        }
        writer = created
      }

      guard let current = writer else { return nil }
      guard let frameIndex = current.append(image) else {
        // A transient "not ready" just drops this frame; a failed writer closes the segment.
        if current.hasFailed {
          print("❌ FrameStore: writer failed, closing segment")
          finishWriterLocked()
        }
        return nil
      }

      return StorageManager.shared.saveScreenshot(
        segmentPath: current.url.path,
        frameIndex: frameIndex,
        capturedAt: capturedAt,
        idleSecondsAtCapture: idleSecondsAtCapture
      )
    }
  }

  /// Finalizes the open segment so it becomes readable. Safe to call when nothing is open.
  func finishCurrentSegment() {
    writeQueue.sync { finishWriterLocked() }
  }

  /// Must be called on `writeQueue`.
  private func finishWriterLocked() {
    guard let current = writer else { return }
    writer = nil

    let succeeded = current.finish()
    let path = current.url.path

    if succeeded {
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      StorageManager.shared.updateScreenshotFileSizes(segmentPath: path, totalBytes: bytes)
    } else {
      print("❌ FrameStore: segment failed to finalize, dropping \(current.url.lastPathComponent)")
      try? FileManager.default.removeItem(at: current.url)
      StorageManager.shared.markScreenshotsDeleted(segmentPath: path)
    }
  }

  /// Drops the most recent segment if a crash left it unreadable. Call once at launch.
  func reconcileAfterLaunch() {
    writeQueue.async {
      guard let path = StorageManager.shared.mostRecentSegmentPath() else { return }
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: path) else {
        StorageManager.shared.markScreenshotsDeleted(segmentPath: path)
        return
      }
      guard SegmentReader(url: url) != nil else {
        print(
          "⚠️ FrameStore: unreadable segment from previous run, dropping \(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: url)
        StorageManager.shared.markScreenshotsDeleted(segmentPath: path)
        return
      }
      // Readable, but a crash between finishWriting and the size update leaves NULL sizes.
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      if bytes > 0 {
        StorageManager.shared.updateScreenshotFileSizes(segmentPath: path, totalBytes: bytes)
      }
    }
  }

  // MARK: - Reading

  /// Decodes the frame for a screenshot row. Legacy JPEG rows are read directly.
  /// Pass `maxPixelSize` to get a downscaled copy for thumbnails.
  func image(for screenshot: Screenshot, maxPixelSize: Int? = nil) -> CGImage? {
    guard let frameIndex = screenshot.frameIndex else {
      return legacyJPEGImage(at: screenshot.fileURL, maxPixelSize: maxPixelSize)
    }

    // A segment that is still being written has no index yet; close it first.
    if activeSegmentPath == screenshot.filePath {
      finishCurrentSegment()
    }

    readLock.lock()
    defer { readLock.unlock() }

    guard let reader = reader(forPath: screenshot.filePath),
      let pixelBuffer = reader.frame(at: frameIndex)
    else { return nil }

    var decoded: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &decoded)
    guard let image = decoded else { return nil }
    return Self.downscaled(image, maxPixelSize: maxPixelSize)
  }

  /// Must be called with `readLock` held.
  private func reader(forPath path: String) -> SegmentReader? {
    if let existing = readers[path] {
      readerOrder.removeAll { $0 == path }
      readerOrder.append(path)
      return existing
    }

    guard let created = SegmentReader(url: URL(fileURLWithPath: path)) else { return nil }
    readers[path] = created
    readerOrder.append(path)
    while readerOrder.count > readerCacheLimit {
      let evicted = readerOrder.removeFirst()
      readers.removeValue(forKey: evicted)
    }
    return created
  }

  private func legacyJPEGImage(at url: URL, maxPixelSize: Int?) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    if let maxPixelSize {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      ]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
    return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
  }

  static func downscaled(_ image: CGImage, maxPixelSize: Int?) -> CGImage? {
    guard let maxPixelSize, max(image.width, image.height) > maxPixelSize else { return image }
    let scale = Double(maxPixelSize) / Double(max(image.width, image.height))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}

// MARK: - Segment writer

/// One HEVC segment file being appended to. Frame N sits at presentation time N seconds.
private final class SegmentWriter {
  let url: URL
  let width: Int
  let height: Int
  private let startedAt = Date()
  private var frameCount = 0

  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  init?(url: URL, width: Int, height: Int) {
    // Apple Silicon encoders take a quality target; the Intel encoder only takes a bitrate.
    let qualityMode: [String: Any] = [AVVideoQualityKey: FrameStore.encodeQuality]
    let bitrateMode: [String: Any] = [
      AVVideoAverageBitRateKey: Self.fallbackBitRate(width: width, height: height)
    ]

    guard
      let started = Self.startWriter(
        url: url, width: width, height: height, rateControl: qualityMode)
        ?? Self.startWriter(url: url, width: width, height: height, rateControl: bitrateMode)
    else { return nil }

    self.url = url
    self.width = width
    self.height = height
    self.writer = started.writer
    self.input = started.input
    self.adaptor = started.adaptor
  }

  var hasFailed: Bool { writer.status == .failed }

  private static func fallbackBitRate(width: Int, height: Int) -> Int {
    // ~2 Mbps at 1080p, scaled by pixel count. At one frame per 10 s this is tiny on disk.
    max(500_000, Int(2_000_000.0 * Double(width * height) / Double(1920 * 1080)))
  }

  private static func startWriter(
    url: URL, width: Int, height: Int, rateControl: [String: Any]
  ) -> (
    writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
  )? {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }

    var compression = rateControl
    compression[AVVideoMaxKeyFrameIntervalKey] = FrameStore.keyframeInterval
    compression[AVVideoAllowFrameReorderingKey] = false
    compression[AVVideoExpectedSourceFrameRateKey] = 1

    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ]
    )

    guard writer.canAdd(input) else { return nil }
    writer.add(input)
    guard writer.startWriting() else {
      print("❌ SegmentWriter: startWriting failed: \(String(describing: writer.error))")
      return nil
    }
    writer.startSession(atSourceTime: .zero)
    return (writer, input, adaptor)
  }

  func needsRotation(forWidth newWidth: Int, height newHeight: Int) -> Bool {
    newWidth != width || newHeight != height
      || frameCount >= FrameStore.maxFramesPerSegment
      || Date().timeIntervalSince(startedAt) >= FrameStore.segmentDuration
  }

  /// Appends a frame and returns its index within the segment.
  func append(_ image: CGImage) -> Int? {
    guard input.isReadyForMoreMediaData, writer.status == .writing else { return nil }
    guard let pixelBuffer = makePixelBuffer(from: image) else { return nil }

    let index = frameCount
    let time = CMTime(value: CMTimeValue(index), timescale: 1)
    guard adaptor.append(pixelBuffer, withPresentationTime: time) else { return nil }
    frameCount += 1
    return index
  }

  /// Blocks until the file is finalized. Returns false if the writer failed.
  func finish() -> Bool {
    guard writer.status == .writing else { return false }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    return writer.status == .completed && frameCount > 0
  }

  private func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
    guard let pool = adaptor.pixelBufferPool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        == kCVReturnSuccess,
      let buffer = pixelBuffer
    else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return nil }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}

// MARK: - Segment reader

/// Sequential decoder over one finished segment. Reading forward reuses the open
/// decoder; jumping backwards or far ahead restarts from the nearest keyframe.
private final class SegmentReader {
  private let asset: AVURLAsset
  private let track: AVAssetTrack
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var nextIndex = 0

  private static let maxSequentialSkip = 8

  init?(url: URL) {
    let asset = AVURLAsset(url: url)
    guard let track = Self.loadVideoTrack(from: asset) else { return nil }
    self.asset = asset
    self.track = track
  }

  func frame(at index: Int) -> CVPixelBuffer? {
    let canContinue =
      reader?.status == .reading && index >= nextIndex
      && index - nextIndex <= Self.maxSequentialSkip
    if !canContinue {
      guard restart(from: index) else { return nil }
    }

    guard let output else { return nil }
    while let sample = output.copyNextSampleBuffer() {
      let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      let sampleIndex = Int(seconds.rounded())
      nextIndex = sampleIndex + 1
      if sampleIndex == index {
        return CMSampleBufferGetImageBuffer(sample)
      }
      if sampleIndex > index {
        return nil
      }
    }
    return nil
  }

  private func restart(from index: Int) -> Bool {
    reader?.cancelReading()
    reader = nil
    output = nil

    guard let newReader = try? AVAssetReader(asset: asset) else { return false }
    let newOutput = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    newOutput.alwaysCopiesSampleData = false
    guard newReader.canAdd(newOutput) else { return false }
    newReader.add(newOutput)
    newReader.timeRange = CMTimeRange(
      start: CMTime(value: CMTimeValue(index), timescale: 1), duration: .positiveInfinity)
    guard newReader.startReading() else { return false }

    reader = newReader
    output = newOutput
    nextIndex = index
    return true
  }

  /// Blocks until the video track is loaded. Callers are already off the main thread.
  private static func loadVideoTrack(from asset: AVURLAsset) -> AVAssetTrack? {
    final class Result: @unchecked Sendable { var track: AVAssetTrack? }
    let result = Result()
    let done = DispatchSemaphore(value: 0)
    asset.loadTracks(withMediaType: .video) { tracks, _ in
      result.track = tracks?.first
      done.signal()
    }
    done.wait()
    return result.track
  }
}
