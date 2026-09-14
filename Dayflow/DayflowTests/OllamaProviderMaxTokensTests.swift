import XCTest

@testable import Dayflow

final class OllamaProviderMaxTokensTests: XCTestCase {
  private let key = "llmLocalMaxOutputTokens"
  private var savedValue: Any?

  override func setUp() {
    super.setUp()
    savedValue = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: key)
    if let savedValue {
      UserDefaults.standard.set(savedValue, forKey: key)
    }
    savedValue = nil
    super.tearDown()
  }

  func testMaxOutputTokensDefaultsTo4000WhenUnset() {
    XCTAssertEqual(OllamaProvider.configuredMaxOutputTokens, 4000)
  }

  func testMaxOutputTokensReadsUserDefaultsOverride() {
    UserDefaults.standard.set(32000, forKey: key)
    XCTAssertEqual(OllamaProvider.configuredMaxOutputTokens, 32000)
  }

  func testMaxOutputTokensFallsBackToDefaultForInvalidValues() {
    UserDefaults.standard.set(0, forKey: key)
    XCTAssertEqual(OllamaProvider.configuredMaxOutputTokens, 4000)

    UserDefaults.standard.set(-100, forKey: key)
    XCTAssertEqual(OllamaProvider.configuredMaxOutputTokens, 4000)
  }

  func testChatRequestUsesConfiguredMaxOutputTokens() {
    UserDefaults.standard.set(16000, forKey: key)
    let request = OllamaProvider.ChatRequest(model: "test-model", messages: [])
    XCTAssertEqual(request.max_tokens, 16000)
  }

  // Boundary: exactly 1 is the smallest value the `configured > 0` guard
  // treats as a real override (0 falls back, per the test above). Pins the
  // guard's exclusive-zero semantics so a future `>= 0` regression is caught.
  func testMaxOutputTokensAcceptsMinimumPositiveOverride() {
    UserDefaults.standard.set(1, forKey: key)
    XCTAssertEqual(OllamaProvider.configuredMaxOutputTokens, 1)
  }

  // Reasoning models (the #246 use case) can legitimately need very large
  // caps. Confirm a large override passes through unclamped, both via the
  // computed property and into the ChatRequest the network layer sends.
  func testMaxOutputTokensPassesLargeReasoningModelOverrideThrough() {
    UserDefaults.standard.set(131_072, forKey: key)
    XCTAssertEqual(OllamaProvider.configuredMaxOutputTokens, 131_072)
    let request = OllamaProvider.ChatRequest(model: "test-model", messages: [])
    XCTAssertEqual(request.max_tokens, 131_072)
  }

  // The default constant and the fallback path must agree — guards against a
  // future edit that changes one but not the other.
  func testDefaultConstantMatchesUnsetFallback() {
    XCTAssertEqual(OllamaProvider.defaultMaxOutputTokens, 4000)
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertEqual(
      OllamaProvider.configuredMaxOutputTokens,
      OllamaProvider.defaultMaxOutputTokens
    )
  }
}
