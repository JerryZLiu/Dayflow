import AppKit
import XCTest

@testable import Dayflow

final class OpenAICompatibleProviderTests: XCTestCase {
  private func configuration(_ endpoint: String = "https://openrouter.ai/api/v1")
    -> OpenAICompatibleRuntimeConfiguration
  {
    .init(
      configuration: .init(preset: .custom, baseURL: endpoint, modelID: "chosen-model"),
      bearerToken: "test-token")
  }

  func testReasoningOnlySentToOpenRouter() throws {
    for endpoint in ["https://openrouter.ai/api/v1", "https://example.com/v1"] {
      let provider = OpenAICompatibleProvider(configuration: configuration(endpoint))
      let request = provider.makeRequest(content: [])
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(body["model"] as? String, "chosen-model")
      if endpoint.contains("openrouter.ai") {
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
      } else {
        XCTAssertNil(body["reasoning"])
      }
    }
  }

  func testScreenshotsTravelTogetherWithActualTimestamps() async throws {
    let image = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString).jpg")
    try XCTUnwrap(image.representation(using: .jpeg, properties: [:])).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let screenshots = (0..<31).map { index in
      Screenshot(
        id: Int64(index), capturedAt: 1000 + index * 30, filePath: url.path,
        fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false)
    }
    var requests = 0
    let provider = OpenAICompatibleProvider(configuration: configuration()) {
      request, operation, _ in
      requests += 1
      XCTAssertEqual(operation, "transcribe_screenshots")
      let content = request.messages[1].content
      XCTAssertEqual(content.filter { $0.type == "image_url" }.count, 15)
      XCTAssertTrue(content.contains { $0.text == "Screenshot at 00:15:00:" })
      XCTAssertFalse(content[0].text!.contains("1 min apart"))
      return
        #"{"segments":[{"start":"00:00:00","end":"00:15:00","description":"Edited the release notes."}]}"#
    }
    let result = try await provider.transcribeScreenshots(
      screenshots, batchStartTime: Date(timeIntervalSince1970: 1000), batchId: 1)
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(result.observations.first?.startTs, 1000)
    XCTAssertEqual(result.observations.first?.endTs, 1900)
    XCTAssertEqual(result.observations.first?.llmModel, "chosen-model")
  }

  func testCardRetryRetainsFullContextAndReturnsDetailedCards() async throws {
    let previous = ActivityCardData(
      startTime: "1:00 PM", endTime: "1:15 PM", category: "Work", subcategory: "",
      title: "Release notes", summary: "Edited release notes.", detailedSummary: "Details",
      distractions: nil, appSites: nil)
    let context = ActivityGenerationContext(
      batchObservations: [], existingCards: [previous], currentTime: Date(), categories: [],
      hasPreviousCardWithinFiveMinutes: true)
    var requests = 0
    let provider = OpenAICompatibleProvider(configuration: configuration()) { request, _, _ in
      requests += 1
      let prompt = request.messages[1].content[0].text!
      XCTAssertTrue(prompt.contains("Previous cards:"))
      XCTAssertTrue(prompt.contains("Release notes"))
      if requests == 1 { return "[]" }
      XCTAssertTrue(prompt.contains("PREVIOUS ATTEMPT FAILED"))
      return "```json\n" + String(data: try JSONEncoder().encode([previous]), encoding: .utf8)!
        + "\n```"
    }
    let result = try await provider.generateActivityCards(
      observations: [], context: context, batchId: 1)
    XCTAssertEqual(requests, 2)
    XCTAssertEqual(result.cards.first?.detailedSummary, "Details")
  }
}
