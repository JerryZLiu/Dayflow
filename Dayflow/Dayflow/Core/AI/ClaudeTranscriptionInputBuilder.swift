import AppKit
import Foundation
import Vision

struct ClaudeRecognizedTextBlock: Equatable, Sendable {
  struct BoundingBox: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
      x = Double(rect.origin.x)
      y = Double(rect.origin.y)
      width = Double(rect.size.width)
      height = Double(rect.size.height)
    }

    init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  let text: String
  let confidence: Float
  let boundingBox: BoundingBox
}

protocol ClaudeFrameTextRecognizing: Sendable {
  func recognizeText(in imageURL: URL) throws -> [ClaudeRecognizedTextBlock]
}

struct AppleVisionClaudeFrameTextRecognizer: ClaudeFrameTextRecognizing {
  static func makeRequest() -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    if #available(macOS 13.0, *) {
      request.automaticallyDetectsLanguage = true
    }
    return request
  }

  func recognizeText(in imageURL: URL) throws -> [ClaudeRecognizedTextBlock] {
    let request = Self.makeRequest()
    let handler = VNImageRequestHandler(url: imageURL, options: [:])
    try handler.perform([request])

    return (request.results ?? [])
      .compactMap { observation -> ClaudeRecognizedTextBlock? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return ClaudeRecognizedTextBlock(
          text: candidate.string,
          confidence: candidate.confidence,
          boundingBox: .init(observation.boundingBox)
        )
      }
      .sorted { lhs, rhs in
        let lhsTop = lhs.boundingBox.y + lhs.boundingBox.height
        let rhsTop = rhs.boundingBox.y + rhs.boundingBox.height
        if abs(lhsTop - rhsTop) > 0.01 {
          return lhsTop > rhsTop
        }
        return lhs.boundingBox.x < rhs.boundingBox.x
      }
  }
}

struct ClaudeTranscriptionTileMetadata: Codable, Equatable, Sendable {
  let i: Int
  let t: String
  let app: String?
  let ocr: String?

  private enum CodingKeys: String, CodingKey {
    case i, t, app, ocr
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(i, forKey: .i)
    try container.encode(t, forKey: .t)
    if let app {
      try container.encode(app, forKey: .app)
    } else {
      try container.encodeNil(forKey: .app)
    }
    if let ocr {
      try container.encode(ocr, forKey: .ocr)
    } else {
      try container.encodeNil(forKey: .ocr)
    }
  }
}

final class ClaudePreparedTranscriptionInput: @unchecked Sendable {
  let contactSheetURL: URL
  let metadataJSON: String
  let tiles: [ClaudeTranscriptionTileMetadata]
  let selectedScreenshots: [Screenshot]
  let durationSeconds: TimeInterval

  /// This path must be handed directly to the Claude runner's original-resolution
  /// profile. Passing it through the shared image-preparation helper would resize it.
  var originalResolutionImagePaths: [String] { [contactSheetURL.path] }

  var promptContext: String {
    """
    The one local image below is a labeled 5-column by 3-row contact sheet. Read it exactly once at its original 2560x864 resolution. Tiles are chronological in row-major order; each numbered tile is a distinct screenshot.
    Contact sheet: \(contactSheetURL.path)
    Apple Vision OCR and app hints are fallible side-channel evidence. Screenshot pixels decide the foreground; OCR may add exact text only when it agrees with the pixels.
    Metadata: \(metadataJSON)
    """
  }

  private let temporaryDirectoryURL: URL
  private let cleanupLock = NSLock()
  private var hasCleanedUp = false

  init(
    contactSheetURL: URL,
    metadataJSON: String,
    tiles: [ClaudeTranscriptionTileMetadata],
    selectedScreenshots: [Screenshot],
    durationSeconds: TimeInterval,
    temporaryDirectoryURL: URL
  ) {
    self.contactSheetURL = contactSheetURL
    self.metadataJSON = metadataJSON
    self.tiles = tiles
    self.selectedScreenshots = selectedScreenshots
    self.durationSeconds = durationSeconds
    self.temporaryDirectoryURL = temporaryDirectoryURL
  }

  func cleanup() {
    cleanupLock.lock()
    guard !hasCleanedUp else {
      cleanupLock.unlock()
      return
    }
    hasCleanedUp = true
    cleanupLock.unlock()
    try? FileManager.default.removeItem(at: temporaryDirectoryURL)
  }

  deinit {
    cleanup()
  }
}

enum ClaudeTranscriptionInputBuilderError: LocalizedError {
  case noScreenshots
  case missingImage(String)
  case cannotLoadImage(String)
  case cannotCreateContactSheet
  case cannotEncodeContactSheet

  var errorDescription: String? {
    switch self {
    case .noScreenshots:
      return "No screenshots were supplied for Claude transcription."
    case .missingImage(let path):
      return "A selected screenshot does not exist at \(path)."
    case .cannotLoadImage(let path):
      return "A selected screenshot could not be decoded at \(path)."
    case .cannotCreateContactSheet:
      return "The Claude transcription contact sheet could not be created."
    case .cannotEncodeContactSheet:
      return "The Claude transcription contact sheet could not be encoded as JPEG."
    }
  }
}

struct ClaudeTranscriptionInputBuilder: Sendable {
  static let maximumFrameCount = 15
  static let contactSheetWidth = 2560
  static let contactSheetHeight = 864
  static let contactSheetColumns = 5
  static let contactSheetRows = 3
  static let jpegCompressionQuality: CGFloat = 0.90
  static let ocrCharacterLimit = 300

  private static let maximumSelectedOCRBlocks = 12
  private static let maximumOCRBlockCharacters = 180
  private static let minimumFinalOCRFragmentCharacters = 8

  private let recognizer: any ClaudeFrameTextRecognizing
  private let temporaryDirectoryRoot: URL

  init(
    recognizer: any ClaudeFrameTextRecognizing = AppleVisionClaudeFrameTextRecognizer(),
    temporaryDirectoryRoot: URL? = nil
  ) {
    self.recognizer = recognizer
    self.temporaryDirectoryRoot =
      temporaryDirectoryRoot
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "DayflowClaudeTranscription", isDirectory: true)
  }

  func prepare(screenshots: [Screenshot]) async throws -> ClaudePreparedTranscriptionInput {
    let recognizer = recognizer
    let temporaryDirectoryRoot = temporaryDirectoryRoot
    return try await Task.detached(priority: .utility) {
      try Self.prepareSynchronously(
        screenshots: screenshots,
        recognizer: recognizer,
        temporaryDirectoryRoot: temporaryDirectoryRoot
      )
    }.value
  }

  static func evenlySpacedIndices(itemCount: Int, maximumCount: Int = maximumFrameCount) -> [Int] {
    guard itemCount > 0, maximumCount > 0 else { return [] }
    guard itemCount > maximumCount, maximumCount > 1 else {
      return Array(0..<min(itemCount, maximumCount))
    }

    return (0..<maximumCount).map { position in
      Int(
        (Double(position) * Double(itemCount - 1) / Double(maximumCount - 1))
          .rounded(.toNearestOrAwayFromZero)
      )
    }
  }

  static func selectedOCRText(
    from blocks: [ClaudeRecognizedTextBlock],
    appHint: String?,
    characterLimit: Int = ocrCharacterLimit
  ) -> String? {
    guard characterLimit > 0 else { return nil }

    var bestByText: [String: OCRBlockFeatures] = [:]
    for (index, block) in blocks.enumerated() {
      let features = makeFeatures(for: block, index: index)
      if !features.isEligible || (appHint != nil && index == 0) { continue }

      let duplicateKey = features.text.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      if let prior = bestByText[duplicateKey] {
        if features.score > prior.score
          || (features.score == prior.score && features.index < prior.index)
        {
          bestByText[duplicateKey] = features
        }
      } else {
        bestByText[duplicateKey] = features
      }
    }

    let ranked = bestByText.values.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.areaMilli != rhs.areaMilli { return lhs.areaMilli > rhs.areaMilli }
      return lhs.index < rhs.index
    }

    var selected: [(index: Int, text: String)] = []
    var usedCharacters = 0
    for features in ranked {
      if selected.count >= maximumSelectedOCRBlocks { break }
      let separatorCharacters = selected.isEmpty ? 0 : 1
      let available = characterLimit - usedCharacters - separatorCharacters
      if available < minimumFinalOCRFragmentCharacters { break }

      let fragmentLimit = min(maximumOCRBlockCharacters, available)
      let fragment = String(features.text.prefix(fragmentLimit))
      if fragment.isEmpty { continue }
      selected.append((features.index, fragment))
      usedCharacters += separatorCharacters + fragment.count
      if usedCharacters >= characterLimit { break }
    }

    let text = selected.sorted { $0.index < $1.index }.map { $0.text }.joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  static func conservativeAppHint(from firstBlockText: String?) -> String? {
    guard let firstBlockText else { return nil }
    let token = normalizedAppToken(firstBlockText)
    guard token.count >= 3, !token.contains(where: \.isNumber) else { return nil }

    let canonicalNames = [
      "Arc", "Brave Browser", "Codex", "Dayflow", "Discord", "FaceTime", "Figma",
      "Finder", "Firefox", "Ghostty", "Google Chrome", "Granola", "League of Legends",
      "Mail", "Marii", "Messages", "Microsoft Edge", "Notion", "Photos", "Safari",
      "Slack", "System Settings", "Terminal", "Visual Studio Code", "Xcode",
    ]
    var candidates = Dictionary(
      uniqueKeysWithValues: canonicalNames.map { (normalizedAppToken($0), $0) })
    candidates["chrome"] = "Google Chrome"
    candidates["googlechrome"] = "Google Chrome"
    candidates["vscode"] = "Visual Studio Code"
    candidates["systemsettings"] = "System Settings"

    if let exact = candidates[token] { return exact }
    let menuSuffixes = ["file", "fileedit", "fileeditview", "view", "window", "help"]
    for (candidate, canonical) in candidates {
      if menuSuffixes.contains(where: { token == candidate + $0 }) {
        return canonical
      }
    }
    return nil
  }

  private static func prepareSynchronously(
    screenshots: [Screenshot],
    recognizer: any ClaudeFrameTextRecognizing,
    temporaryDirectoryRoot: URL
  ) throws -> ClaudePreparedTranscriptionInput {
    guard !screenshots.isEmpty else { throw ClaudeTranscriptionInputBuilderError.noScreenshots }

    let sortedScreenshots = screenshots.enumerated().sorted { lhs, rhs in
      if lhs.element.capturedAt != rhs.element.capturedAt {
        return lhs.element.capturedAt < rhs.element.capturedAt
      }
      return lhs.offset < rhs.offset
    }.map { $0.element }
    let indices = evenlySpacedIndices(itemCount: sortedScreenshots.count)
    let selectedScreenshots = indices.map { sortedScreenshots[$0] }

    for screenshot in selectedScreenshots {
      guard FileManager.default.fileExists(atPath: screenshot.filePath) else {
        throw ClaudeTranscriptionInputBuilderError.missingImage(screenshot.filePath)
      }
    }

    try FileManager.default.createDirectory(
      at: temporaryDirectoryRoot, withIntermediateDirectories: true)
    let temporaryDirectoryURL = temporaryDirectoryRoot.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectoryURL, withIntermediateDirectories: true)
    var shouldRemoveTemporaryDirectory = true
    defer {
      if shouldRemoveTemporaryDirectory {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
      }
    }

    let firstTimestamp = sortedScreenshots[0].capturedAt
    var tiles: [ClaudeTranscriptionTileMetadata] = []
    for (index, screenshot) in selectedScreenshots.enumerated() {
      let blocks = (try? recognizer.recognizeText(in: screenshot.fileURL)) ?? []
      let appHint = conservativeAppHint(from: blocks.first?.text)
      let ocr = selectedOCRText(from: blocks, appHint: appHint)
      tiles.append(
        ClaudeTranscriptionTileMetadata(
          i: index + 1,
          t: formatTimestamp(max(0, screenshot.capturedAt - firstTimestamp)),
          app: appHint,
          ocr: ocr
        ))
    }

    let contactSheetURL = temporaryDirectoryURL.appendingPathComponent(
      "contact_sheet_5x3_2560x864.jpg")
    try renderContactSheet(from: selectedScreenshots, to: contactSheetURL)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let metadataJSON = String(decoding: try encoder.encode(tiles), as: UTF8.self)

    let durationSeconds = TimeInterval(
      max(0, sortedScreenshots.last!.capturedAt - sortedScreenshots.first!.capturedAt))
    let result = ClaudePreparedTranscriptionInput(
      contactSheetURL: contactSheetURL,
      metadataJSON: metadataJSON,
      tiles: tiles,
      selectedScreenshots: selectedScreenshots,
      durationSeconds: durationSeconds,
      temporaryDirectoryURL: temporaryDirectoryURL
    )
    shouldRemoveTemporaryDirectory = false
    return result
  }

  private static func renderContactSheet(from screenshots: [Screenshot], to outputURL: URL) throws {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: contactSheetWidth,
        pixelsHigh: contactSheetHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0),
      let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      throw ClaudeTranscriptionInputBuilderError.cannotCreateContactSheet
    }

    bitmap.size = NSSize(width: contactSheetWidth, height: contactSheetHeight)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let canvasRect = NSRect(x: 0, y: 0, width: contactSheetWidth, height: contactSheetHeight)
    NSColor.black.setFill()
    canvasRect.fill()

    let tileWidth = CGFloat(contactSheetWidth / contactSheetColumns)
    let tileHeight = CGFloat(contactSheetHeight / contactSheetRows)
    let font = NSFont.boldSystemFont(ofSize: max(16, (tileHeight * 0.11).rounded()))
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white,
    ]

    for (index, screenshot) in screenshots.enumerated() {
      guard let image = NSImage(contentsOf: screenshot.fileURL) else {
        throw ClaudeTranscriptionInputBuilderError.cannotLoadImage(screenshot.filePath)
      }
      let pixelSize = imagePixelSize(image)
      guard pixelSize.width > 0, pixelSize.height > 0 else {
        throw ClaudeTranscriptionInputBuilderError.cannotLoadImage(screenshot.filePath)
      }

      let column = index % contactSheetColumns
      let row = index / contactSheetColumns
      let tileOriginX = CGFloat(column) * tileWidth
      let tileOriginY = CGFloat(contactSheetRows - row - 1) * tileHeight
      let scale = min(tileWidth / pixelSize.width, tileHeight / pixelSize.height)
      let fittedWidth = (pixelSize.width * scale).rounded(.down)
      let fittedHeight = (pixelSize.height * scale).rounded(.down)
      let destination = NSRect(
        x: tileOriginX + (tileWidth - fittedWidth) / 2,
        y: tileOriginY + (tileHeight - fittedHeight) / 2,
        width: fittedWidth,
        height: fittedHeight
      )
      image.draw(
        in: destination,
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
      )

      let label = String(index + 1) as NSString
      let labelSize = label.size(withAttributes: labelAttributes)
      let badgeWidth = max((tileWidth * 0.10).rounded(), labelSize.width + 12)
      let badgeHeight = max((tileHeight * 0.15).rounded(), labelSize.height + 8)
      let badgeRect = NSRect(
        x: tileOriginX,
        y: tileOriginY + tileHeight - badgeHeight,
        width: badgeWidth,
        height: badgeHeight
      )
      NSColor.black.setFill()
      badgeRect.fill()
      label.draw(
        at: NSPoint(
          x: badgeRect.minX + 6,
          y: badgeRect.minY + (badgeHeight - labelSize.height) / 2),
        withAttributes: labelAttributes
      )
    }
    graphicsContext.flushGraphics()

    guard
      let data = bitmap.representation(
        using: .jpeg,
        properties: [.compressionFactor: jpegCompressionQuality])
    else {
      throw ClaudeTranscriptionInputBuilderError.cannotEncodeContactSheet
    }
    try data.write(to: outputURL, options: .atomic)
  }

  private static func imagePixelSize(_ image: NSImage) -> NSSize {
    if let representation = image.representations.max(by: {
      $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
    }) {
      return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }
    return image.size
  }

  private static func formatTimestamp(_ seconds: Int) -> String {
    String(
      format: "%02d:%02d:%02d",
      seconds / 3600,
      (seconds % 3600) / 60,
      seconds % 60
    )
  }

  private static func normalizedAppToken(_ value: String) -> String {
    value.lowercased().unicodeScalars.compactMap { scalar -> String? in
      let value = scalar.value
      let isDigit = value >= 48 && value <= 57
      let isLowercaseLetter = value >= 97 && value <= 122
      return isDigit || isLowercaseLetter ? String(scalar) : nil
    }.joined()
  }

  private static func normalizedBlockText(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  private static func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
  }

  private static func milli(_ value: Double) -> Int {
    Int((clamp(value) * 1000).rounded(.toNearestOrAwayFromZero))
  }

  private static func textQuality(_ text: String) -> (qualityMilli: Int, alphanumericCount: Int) {
    let visible = text.filter { !$0.isWhitespace }
    guard !visible.isEmpty else { return (0, 0) }
    let alphanumericCount = visible.filter { $0.isLetter || $0.isNumber }.count
    let printableCount = visible.filter { character in
      character.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0)
      }
    }.count
    let replacementCount = visible.filter { "�□￼".contains($0) }.count
    var quality =
      0.72 * (Double(alphanumericCount) / Double(visible.count))
      + 0.28 * (Double(printableCount) / Double(visible.count))
    quality -= min(0.5, Double(replacementCount) / Double(visible.count))
    if visible.count <= 2 {
      quality *= 0.35
    } else if visible.count <= 4 {
      quality *= 0.7
    }
    return (milli(quality), alphanumericCount)
  }

  private struct OCRBlockFeatures {
    let index: Int
    let text: String
    let score: Int
    let areaMilli: Int
    let isEligible: Bool
  }

  private static func makeFeatures(
    for block: ClaudeRecognizedTextBlock, index: Int
  ) -> OCRBlockFeatures {
    let text = normalizedBlockText(block.text)
    let box = block.boundingBox
    let hasValidBox = [box.x, box.y, box.width, box.height].allSatisfy { $0.isFinite }
    let width = hasValidBox ? clamp(box.width) : 0
    let height = hasValidBox ? clamp(box.height) : 0
    let centerX = hasValidBox ? clamp(box.x + width / 2) : 0
    let centerY = hasValidBox ? clamp(box.y + height / 2) : 0
    let confidence = clamp(Double(block.confidence))
    let quality = textQuality(text)

    let dx = abs(centerX - 0.5) / 0.5
    let dy = abs(centerY - 0.5) / 0.5
    let centrality = max(0, 1 - (0.58 * dx + 0.42 * dy))
    let heightScore = clamp(height / 0.03)
    let widthScore = clamp(width / 0.40)
    let areaScore = clamp((width * height) / 0.008)
    var edgePenalty = 0.0
    if centerY >= 0.94 { edgePenalty += 0.9 }
    if centerY <= 0.055 { edgePenalty += 0.75 }
    if centerX <= 0.045 { edgePenalty += 0.35 }
    if centerX >= 0.975 { edgePenalty += 0.45 }
    edgePenalty = clamp(edgePenalty)
    let lengthScore = milli(text.isEmpty ? 0 : Double(min(text.count, 80)) / 80)
    let isLarge = height >= 0.02 || width * height >= 0.004
    let score =
      4 * milli(confidence)
      + 3 * milli(centrality)
      + 3 * milli(heightScore)
      + milli(widthScore)
      + milli(areaScore)
      + 2 * quality.qualityMilli
      + lengthScore
      + (isLarge ? 1000 : 0)
      - 4 * milli(edgePenalty)
    let isEligible =
      hasValidBox
      && text.count >= 2
      && quality.alphanumericCount >= 1
      && confidence >= 0.25
      && quality.qualityMilli >= 250

    return OCRBlockFeatures(
      index: index,
      text: text,
      score: score,
      areaMilli: milli(width * height),
      isEligible: isEligible
    )
  }
}
