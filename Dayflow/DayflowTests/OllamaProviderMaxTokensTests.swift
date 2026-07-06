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
}
