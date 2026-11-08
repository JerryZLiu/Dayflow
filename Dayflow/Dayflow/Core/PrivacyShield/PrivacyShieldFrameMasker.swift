import CoreGraphics
import CryptoKit
import Foundation
import Vision

/// Hides secrets in one captured frame: reads its text with Apple Vision, runs the privacy model and its rules,
/// and pixelates every masked character range before the frame is stored. Everything stays on this Mac.
///
/// The text reading matches `ocr_vision.py` in the Python lab (the same Vision settings as the rest of the app,
/// boxes in pixels from the top-left, lines sorted top to bottom then left to right), because that is how the
/// golden frames r38 was scored on were read.
final class PrivacyShieldFrameMasker: @unchecked Sendable {
  struct Result {
    let image: CGImage
    let maskedRegions: Int
  }

  private let runner: PIIModelRunner
  private let rules: PIIMaskRules

  /// The last frame's fingerprint and the boxes masked on it. About half of all captures are pixel-identical
  /// to the one before, and those reuse the boxes instead of reading the text again.
  private var lastFingerprint: Data?
  private var lastRects: [CGRect] = []

  init(runner: PIIModelRunner, rules: PIIMaskRules) {
    self.runner = runner
    self.rules = rules
  }

  /// Not thread-safe: the recorder captures one frame at a time.
  func mask(_ image: CGImage) throws -> Result {
    let fingerprint = Self.fingerprint(of: image)
    let rects: [CGRect]
    if let fingerprint, fingerprint == lastFingerprint {
      rects = lastRects
    } else {
      rects = try maskedRects(in: image)
      lastFingerprint = fingerprint
      lastRects = rects
    }
    guard !rects.isEmpty else { return Result(image: image, maskedRegions: 0) }
    return Result(image: Self.pixelate(image, rects: rects) ?? image, maskedRegions: rects.count)
  }

  /// Loads Vision's text model and each Core ML model onto the Neural Engine before the first real frame.
  /// Both are slow the first time in a process (tens of seconds on a Mac short on disk space), and that
  /// cost belongs to setup, not to a capture.
  /// Never throws: a failure here only means the first real frame pays the cost (or retries) itself.
  func warmUp() {
    if let blank = CGContext(
      data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    )?.makeImage() {
      _ = try? recognizeLines(in: blank)
    }
    // One line per model size: short, medium and a full 192-character window.
    let lines = [24, 160, 192].enumerated().map { index, length in
      PIIOCRLine(
        text: String(repeating: "a", count: length),
        box: CGRect(x: 0, y: CGFloat(index) * 20, width: 400, height: 12))
    }
    _ = try? runner.scores(lines: lines, page: PIIEncoder.page(lines))
  }

  // MARK: - Finding what to mask

  private struct RecognizedLine {
    let line: PIIOCRLine
    let candidate: VNRecognizedText
  }

  /// Pixel rects (top-left origin) of every masked character run on the frame.
  private func maskedRects(in image: CGImage) throws -> [CGRect] {
    let recognized = try recognizeLines(in: image)
    guard !recognized.isEmpty else { return [] }
    let lines = recognized.map(\.line)
    let page = PIIEncoder.page(lines)
    let scores = try runner.scores(lines: lines, page: page)
    let preds = rules.apply(lines: lines, sensitive: scores.sensitive, best: scores.best)

    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    var rects: [CGRect] = []
    for (index, pred) in preds.enumerated() {
      let candidate = recognized[index].candidate
      let scalars = candidate.string.unicodeScalars
      for run in Self.maskedRuns(pred) {
        let start = scalars.index(scalars.startIndex, offsetBy: run.lowerBound)
        let end = scalars.index(scalars.startIndex, offsetBy: run.upperBound)
        let range = start..<end
        let box: CGRect
        if let observation = try? candidate.boundingBox(for: range) {
          box = observation.boundingBox
        } else {
          box = Self.estimatedBox(
            of: run, in: recognized[index], length: scalars.count, imageSize: (width, height))
        }
        // Vision boxes are normalized with a bottom-left origin.
        rects.append(
          CGRect(
            x: box.minX * width, y: (1 - box.maxY) * height,
            width: box.width * width, height: box.height * height))
      }
    }
    return rects
  }

  private func recognizeLines(in image: CGImage) throws -> [RecognizedLine] {
    let request = AppleVisionClaudeFrameTextRecognizer.makeRequest()
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      // Vision sometimes fails once on the Neural Engine (e5rt error 13) and works on the next try.
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }
    let width = Double(image.width)
    let height = Double(image.height)

    let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first,
        !PIIPython.strip(candidate.string).isEmpty
      else { return nil }
      let box = observation.boundingBox
      let pixelBox = CGRect(
        x: Double(box.minX) * width, y: (1 - Double(box.minY) - Double(box.height)) * height,
        width: Double(box.width) * width, height: Double(box.height) * height)
      return RecognizedLine(
        line: PIIOCRLine(text: candidate.string, box: pixelBox), candidate: candidate)
    }
    // Top to bottom in 1%-of-height bands, then left to right. Python's round() rounds halves to even.
    let band = 0.01 * height
    return lines.sorted { lhs, rhs in
      let lhsRow = (Double(lhs.line.box.minY) / band).rounded(.toNearestOrEven)
      let rhsRow = (Double(rhs.line.box.minY) / band).rounded(.toNearestOrEven)
      if lhsRow != rhsRow { return lhsRow < rhsRow }
      return lhs.line.box.minX < rhs.line.box.minX
    }
  }

  /// Code point ranges of masked characters (keys, passwords, cards, bank details, government IDs).
  private static func maskedRuns(_ pred: [Int]) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    var i = 0
    while i < pred.count {
      guard PIILabel.masked.contains(pred[i]) else {
        i += 1
        continue
      }
      var j = i
      while j < pred.count && PIILabel.masked.contains(pred[j]) { j += 1 }
      runs.append(i..<j)
      i = j
    }
    return runs
  }

  /// When Vision can't box a character range, cover the matching share of the line's box, plus a little.
  private static func estimatedBox(
    of run: Range<Int>, in recognized: RecognizedLine, length: Int, imageSize: (CGFloat, CGFloat)
  ) -> CGRect {
    let lineBox = recognized.line.box
    let total = CGFloat(max(length, 1))
    let startShare = max(0, CGFloat(run.lowerBound) / total - 0.02)
    let endShare = min(1, CGFloat(run.upperBound) / total + 0.02)
    // Back to Vision's normalized, bottom-left space.
    return CGRect(
      x: (lineBox.minX + startShare * lineBox.width) / imageSize.0,
      y: 1 - lineBox.maxY / imageSize.1,
      width: (endShare - startShare) * lineBox.width / imageSize.0,
      height: lineBox.height / imageSize.1)
  }

  // MARK: - Pixelating

  /// Pixelates each rect with blocks at least as tall as the text, so no character survives inside a block
  /// (fine pixelation of text can be partly undone by matching tools; blocks bigger than a glyph can't).
  private static func pixelate(_ image: CGImage, rects: [CGRect]) -> CGImage? {
    let width = image.width
    let height = image.height
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(image, in: bounds)

    for rect in rects {
      let padded = rect.insetBy(dx: -3, dy: -3).integral.intersection(bounds)
      guard !padded.isEmpty, let crop = image.cropping(to: padded) else { continue }
      // One row of blocks as tall as the padded text, so each block is wider than a character.
      let block = max(10, padded.height)
      let columns = max(1, Int((padded.width / block).rounded(.up)))
      let rows = max(1, Int((padded.height / block).rounded(.up)))
      guard
        let small = CGContext(
          data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
      else { continue }
      small.interpolationQuality = .medium
      small.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
      guard let blocks = small.makeImage() else { continue }
      // CGContext draws with a bottom-left origin; the rects are top-left.
      let target = CGRect(
        x: padded.minX, y: CGFloat(height) - padded.maxY, width: padded.width, height: padded.height
      )
      context.interpolationQuality = .none
      context.draw(blocks, in: target)
    }
    return context.makeImage()
  }

  /// A SHA-256 of every pixel, to spot a frame identical to the last one. It has to be exact: a few typed
  /// characters change too few pixels for any thumbnail comparison to notice.
  private static func fingerprint(of image: CGImage) -> Data? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    return Data(SHA256.hash(data: data))
  }
}
