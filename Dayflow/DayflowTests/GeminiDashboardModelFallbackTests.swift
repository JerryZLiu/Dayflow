import XCTest

@testable import Dayflow

final class GeminiDashboardModelFallbackTests: XCTestCase {
  func testFallsBackInRequestedOrderAndStopsOnSuccess() async throws {
    var attempted: [GeminiModel] = []
    let result = try await GeminiDirectProvider.withDashboardModelFallback { model in
      attempted.append(model)
      if model != .flash35 { throw NSError(domain: "Test", code: 503) }
      return .init(text: "OK", functionCalls: [], modelFunctionCallParts: [])
    }
    XCTAssertEqual(attempted, [.hydrogen, .flash38, .flash37, .flash36, .flash35])
    XCTAssertEqual(result.text, "OK")
  }

  func testExhaustionReachesFlashLiteAndPreservesLastError() async {
    var attempted: [GeminiModel] = []
    do {
      _ = try await GeminiDirectProvider.withDashboardModelFallback { model in
        attempted.append(model)
        throw NSError(domain: model.rawValue, code: 503)
      }
      XCTFail("Expected final failure")
    } catch {
      XCTAssertEqual((error as NSError).domain, "gemini-3.5-flash-lite")
    }
    XCTAssertEqual(attempted, [.hydrogen, .flash38, .flash37, .flash36, .flash35, .flashLite35])
  }

  func testCancellationDoesNotTryAnotherModel() async {
    var attempted: [GeminiModel] = []
    do {
      _ = try await GeminiDirectProvider.withDashboardModelFallback { model in
        attempted.append(model)
        throw CancellationError()
      }
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(attempted, [.hydrogen])
  }
}
