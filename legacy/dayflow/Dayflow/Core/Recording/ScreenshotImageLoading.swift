//
//  ScreenshotImageLoading.swift
//  Dayflow
//
//  The one place consumers go to get pixels for a `Screenshot` row.
//  Everything decodes through `FrameStore`, so callers never care whether
//  the row points at an HEVC segment frame or a legacy JPEG file.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO

extension Screenshot {
  /// True when the row points at a frame inside an HEVC segment (vs. a legacy JPEG).
  var isSegmentFrame: Bool { frameIndex != nil }

  /// True when the backing file still exists on disk.
  var isAvailable: Bool {
    FileManager.default.fileExists(atPath: filePath)
  }

  /// Decodes the frame. Pass `maxPixelSize` to get a downscaled copy for thumbnails.
  func loadCGImage(maxPixelSize: Int? = nil) -> CGImage? {
    FrameStore.shared.image(for: self, maxPixelSize: maxPixelSize)
  }

  func loadNSImage() -> NSImage? {
    guard let image = loadCGImage() else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }

  /// Re-encodes the frame as JPEG, scaled down so its height is at most `maxHeight`.
  func jpegData(maxHeight: Int, quality: CGFloat) -> Data? {
    guard let image = loadCGImage() else { return nil }
    let maxPixelSize = Self.maxPixelSize(forHeight: maxHeight, image: image)
    guard let scaled = FrameStore.downscaled(image, maxPixelSize: maxPixelSize) else { return nil }
    return Self.encodeJPEG(scaled, quality: quality)
  }

  /// Writes a JPEG copy of the frame to `url`, for tools that need a file path.
  func writeJPEG(to url: URL, maxHeight: Int, quality: CGFloat) throws {
    guard let data = jpegData(maxHeight: maxHeight, quality: quality) else {
      throw ScreenshotImageLoadingError.decodeFailed(filePath)
    }
    try data.write(to: url, options: .atomic)
  }

  /// Converts a height cap into the max-dimension cap `FrameStore.downscaled` expects.
  private static func maxPixelSize(forHeight maxHeight: Int, image: CGImage) -> Int? {
    guard image.height > maxHeight else { return nil }
    let scale = Double(maxHeight) / Double(image.height)
    return Int((Double(max(image.width, image.height)) * scale).rounded())
  }

  private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}

enum ScreenshotImageLoadingError: LocalizedError {
  case decodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .decodeFailed(let path):
      return "Could not decode the screenshot at \(path)."
    }
  }
}
