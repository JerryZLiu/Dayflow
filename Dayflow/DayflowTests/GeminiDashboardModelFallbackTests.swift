import XCTest

@testable import Dayflow

final class GeminiDashboardModelFallbackTests: XCTestCase {
  func testCoolingModelsAreSkippedUntilTheCooldownEndsButNeverAllOfThem() {
    let cooldowns = GeminiModelCooldowns()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let chain: [GeminiModel] = [.hydrogen, .flash38, .flash37]

    cooldowns.mark(.hydrogen, apiKey: "key", for: 600, now: now)
    XCTAssertEqual(cooldowns.usable(chain, apiKey: "key", now: now), [.flash38, .flash37])
    // Quota belongs to the key, so another key still starts at the top.
    XCTAssertEqual(cooldowns.usable(chain, apiKey: "other", now: now), chain)
    XCTAssertEqual(
      cooldowns.usable(chain, apiKey: "key", now: now.addingTimeInterval(601)), chain)

    cooldowns.mark(.flash38, apiKey: "key", for: 600, now: now)
    cooldowns.mark(.flash37, apiKey: "key", for: 600, now: now)
    XCTAssertEqual(cooldowns.usable(chain, apiKey: "key", now: now), chain)
  }

  func testCooldownLengthDependsOnTheRefusal() {
    XCTAssertEqual(
      GeminiModelCooldowns.cooldown(forStatus: 429, responseBody: "Resource exhausted"), 600)
    XCTAssertEqual(
      GeminiModelCooldowns.cooldown(
        forStatus: 429, responseBody: "quotaId: GenerateRequestsPerDayPerProjectPerModel"),
      3600)
    XCTAssertEqual(GeminiModelCooldowns.cooldown(forStatus: 503, responseBody: ""), 600)
    XCTAssertNil(GeminiModelCooldowns.cooldown(forStatus: 400, responseBody: ""))
    XCTAssertNil(GeminiModelCooldowns.cooldown(forStatus: 500, responseBody: ""))
  }

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
