import AppKit
import XCTest

@testable import Dayflow

final class ClaudeTranscriptionInputBuilderTests: XCTestCase {
  private final class MockRecognizer: ClaudeFrameTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var recognizedPaths: [String] = []
    let blocks: [ClaudeRecognizedTextBlock]
    let throwingCallIndex: Int?

    init(blocks: [ClaudeRecognizedTextBlock], throwingCallIndex: Int? = nil) {
      self.blocks = blocks
      self.throwingCallIndex = throwingCallIndex
    }

    func recognizeText(in imageURL: URL) throws -> [ClaudeRecognizedTextBlock] {
      lock.lock()
      recognizedPaths.append(imageURL.path)
      let callIndex = recognizedPaths.count - 1
      lock.unlock()
      if callIndex == throwingCallIndex {
        throw MockRecognizerError.recognitionFailed
      }
      return blocks
    }

    func paths() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return recognizedPaths
    }
  }

  private enum MockRecognizerError: Error {
    case recognitionFailed
  }

  private var testDirectory: URL!

  override func setUpWithError() throws {
    testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClaudeTranscriptionInputBuilderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: testDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let testDirectory {
      try? FileManager.default.removeItem(at: testDirectory)
    }
    testDirectory = nil
  }

  func testEvenlySpacedSamplingCapsAtFifteenAndIncludesEndpoints() {
    XCTAssertEqual(
      ClaudeTranscriptionInputBuilder.evenlySpacedIndices(itemCount: 30),
      [0, 2, 4, 6, 8, 10, 12, 15, 17, 19, 21, 23, 25, 27, 29]
    )
    XCTAssertEqual(
      ClaudeTranscriptionInputBuilder.evenlySpacedIndices(itemCount: 4),
      [0, 1, 2, 3]
    )
    XCTAssertEqual(
      ClaudeTranscriptionInputBuilder.evenlySpacedIndices(itemCount: 1),
      [0]
    )
    XCTAssertEqual(
      ClaudeTranscriptionInputBuilder.evenlySpacedIndices(itemCount: 0),
      []
    )
  }

  func testAppleVisionRequestUsesAccurateAutomaticUncorrectedRecognition() {
    let request = AppleVisionClaudeFrameTextRecognizer.makeRequest()

    XCTAssertEqual(request.recognitionLevel, .accurate)
    XCTAssertFalse(request.usesLanguageCorrection)
    if #available(macOS 13.0, *) {
      XCTAssertTrue(request.automaticallyDetectsLanguage)
    }
  }

  func testSpatialOCRSelectionDeduplicatesAndHonorsCharacterCap() throws {
    let blocks = fixtureOCRBlocks()
    let app = ClaudeTranscriptionInputBuilder.conservativeAppHint(from: blocks.first?.text)
    let text = try XCTUnwrap(
      ClaudeTranscriptionInputBuilder.selectedOCRText(from: blocks, appHint: app))

    XCTAssertEqual(app, "Google Chrome")
    XCTAssertLessThanOrEqual(text.count, 300)
    XCTAssertFalse(text.contains("Google Chrome File Edit View"))
    XCTAssertEqual(
      text.lowercased().components(separatedBy: "quarterly launch plan").count - 1,
      1
    )
    XCTAssertTrue(text.contains("Quarterly launch plan"))
  }

  func testConservativeAppHintRejectsUnrecognizedAndNumericMenuText() {
    XCTAssertEqual(
      ClaudeTranscriptionInputBuilder.conservativeAppHint(
        from: "Visual Studio Code File Edit View"),
      "Visual Studio Code"
    )
    XCTAssertNil(
      ClaudeTranscriptionInputBuilder.conservativeAppHint(from: "Project Phoenix Dashboard"))
    XCTAssertNil(ClaudeTranscriptionInputBuilder.conservativeAppHint(from: "Chrome 123"))
  }

  func testPrepareBuildsOriginalResolutionContactSheetMetadataAndCleansUp() async throws {
    let sourceDirectory = testDirectory.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)
    let screenshots = try (0..<20).map { index -> Screenshot in
      let url = sourceDirectory.appendingPathComponent(String(format: "frame_%02d.jpg", index))
      try writeFixtureImage(index: index, to: url)
      return Screenshot(
        id: Int64(index),
        capturedAt: 1_000 + index * 60,
        filePath: url.path,
        fileSize: nil,
        idleSecondsAtCapture: nil,
        isDeleted: false
      )
    }
    let recognizer = MockRecognizer(blocks: fixtureOCRBlocks())
    let outputRoot = testDirectory.appendingPathComponent("builder-output", isDirectory: true)
    let builder = ClaudeTranscriptionInputBuilder(
      recognizer: recognizer,
      temporaryDirectoryRoot: outputRoot
    )

    let prepared = try await builder.prepare(screenshots: Array(screenshots.reversed()))
    let generatedDirectory = prepared.contactSheetURL.deletingLastPathComponent()

    XCTAssertEqual(prepared.selectedScreenshots.count, 15)
    XCTAssertEqual(prepared.selectedScreenshots.first?.id, 0)
    XCTAssertEqual(prepared.selectedScreenshots.last?.id, 19)
    XCTAssertEqual(prepared.durationSeconds, 19 * 60)
    XCTAssertEqual(prepared.tiles.count, 15)
    XCTAssertEqual(prepared.tiles.first?.i, 1)
    XCTAssertEqual(prepared.tiles.first?.t, "00:00:00")
    XCTAssertEqual(prepared.tiles.last?.i, 15)
    XCTAssertEqual(prepared.tiles.last?.t, "00:19:00")
    XCTAssertTrue(prepared.tiles.allSatisfy { $0.app == "Google Chrome" })
    XCTAssertTrue(prepared.tiles.allSatisfy { ($0.ocr?.count ?? 0) <= 300 })

    let expectedPaths = prepared.selectedScreenshots.map(\.filePath)
    XCTAssertEqual(recognizer.paths(), expectedPaths)
    XCTAssertTrue(recognizer.paths().allSatisfy { $0.hasPrefix(sourceDirectory.path) })

    let jpegData = try Data(contentsOf: prepared.contactSheetURL)
    XCTAssertGreaterThan(jpegData.count, 2)
    XCTAssertEqual(Array(jpegData.prefix(2)), [0xFF, 0xD8])
    let representation = try XCTUnwrap(NSBitmapImageRep(data: jpegData))
    XCTAssertEqual(representation.pixelsWide, 2560)
    XCTAssertEqual(representation.pixelsHigh, 864)
    XCTAssertEqual(ClaudeTranscriptionInputBuilder.jpegCompressionQuality, 0.90)
    XCTAssertEqual(
      prepared.originalResolutionImagePaths,
      [prepared.contactSheetURL.path]
    )
    XCTAssertTrue(prepared.promptContext.contains("original 2560x864 resolution"))
    XCTAssertTrue(prepared.promptContext.contains(prepared.contactSheetURL.path))
    XCTAssertTrue(prepared.promptContext.contains(prepared.metadataJSON))

    let metadata = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(prepared.metadataJSON.utf8))
        as? [[String: Any]])
    XCTAssertEqual(metadata.count, 15)
    XCTAssertEqual(Set(metadata[0].keys), Set(["app", "i", "ocr", "t"]))
    XCTAssertEqual(metadata[0]["i"] as? Int, 1)
    XCTAssertEqual(metadata[0]["t"] as? String, "00:00:00")
    XCTAssertEqual(metadata[0]["app"] as? String, "Google Chrome")

    XCTAssertTrue(FileManager.default.fileExists(atPath: generatedDirectory.path))
    prepared.cleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: generatedDirectory.path))
    prepared.cleanup()
  }

  func testPrepareContinuesWhenOneFrameOCRFails() async throws {
    let sourceDirectory = testDirectory.appendingPathComponent(
      "failing-ocr-sources", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)
    let screenshots = try (0..<15).map { index -> Screenshot in
      let url = sourceDirectory.appendingPathComponent(String(format: "frame_%02d.jpg", index))
      try writeFixtureImage(index: index, to: url)
      return Screenshot(
        id: Int64(index),
        capturedAt: 1_000 + index * 60,
        filePath: url.path,
        fileSize: nil,
        idleSecondsAtCapture: nil,
        isDeleted: false
      )
    }
    let failedFrameIndex = 7
    let recognizer = MockRecognizer(
      blocks: fixtureOCRBlocks(),
      throwingCallIndex: failedFrameIndex
    )
    let builder = ClaudeTranscriptionInputBuilder(
      recognizer: recognizer,
      temporaryDirectoryRoot: testDirectory.appendingPathComponent(
        "failing-ocr-output", isDirectory: true)
    )

    let prepared = try await builder.prepare(screenshots: screenshots)
    defer { prepared.cleanup() }

    XCTAssertEqual(prepared.tiles.count, 15)
    XCTAssertEqual(recognizer.paths(), screenshots.map(\.filePath))
    XCTAssertNil(prepared.tiles[failedFrameIndex].app)
    XCTAssertNil(prepared.tiles[failedFrameIndex].ocr)
    XCTAssertTrue(
      prepared.tiles.enumerated().allSatisfy { index, tile in
        index == failedFrameIndex
          || (tile.app == "Google Chrome" && tile.ocr?.isEmpty == false)
      })
    XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.contactSheetURL.path))

    let representation = try XCTUnwrap(
      NSBitmapImageRep(data: Data(contentsOf: prepared.contactSheetURL)))
    XCTAssertEqual(representation.pixelsWide, 2560)
    XCTAssertEqual(representation.pixelsHigh, 864)

    let metadata = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(prepared.metadataJSON.utf8))
        as? [[String: Any]])
    XCTAssertEqual(metadata.count, 15)
    XCTAssertTrue(metadata[failedFrameIndex]["app"] is NSNull)
    XCTAssertTrue(metadata[failedFrameIndex]["ocr"] is NSNull)
  }

  private func fixtureOCRBlocks() -> [ClaudeRecognizedTextBlock] {
    [
      block(
        "Google Chrome File Edit View", confidence: 0.99,
        x: 0.01, y: 0.95, width: 0.32, height: 0.03),
      block(
        "Quarterly launch plan", confidence: 0.98,
        x: 0.22, y: 0.48, width: 0.56, height: 0.08),
      block(
        "quarterly launch plan", confidence: 0.70,
        x: 0.01, y: 0.02, width: 0.20, height: 0.012),
      block(
        String(repeating: "Roadmap evidence ", count: 20), confidence: 0.96,
        x: 0.18, y: 0.30, width: 0.64, height: 0.06),
      block(
        "12:34 PM", confidence: 0.92,
        x: 0.90, y: 0.96, width: 0.08, height: 0.02),
    ]
  }

  private func block(
    _ text: String,
    confidence: Float,
    x: Double,
    y: Double,
    width: Double,
    height: Double
  ) -> ClaudeRecognizedTextBlock {
    ClaudeRecognizedTextBlock(
      text: text,
      confidence: confidence,
      boundingBox: .init(x: x, y: y, width: width, height: height)
    )
  }

  private func writeFixtureImage(index: Int, to url: URL) throws {
    let width = 640
    let height = 360
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
    bitmap.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let hue = CGFloat(index % 20) / 20
    NSColor(calibratedHue: hue, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let label = "Frame \(index)" as NSString
    label.draw(
      at: NSPoint(x: 30, y: 150),
      withAttributes: [
        .font: NSFont.boldSystemFont(ofSize: 42),
        .foregroundColor: NSColor.white,
      ])
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let data = try XCTUnwrap(
      bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]))
    try data.write(to: url, options: .atomic)
  }
}
