import XCTest

@testable import Dayflow

@MainActor
final class ProvidersSettingsViewModelTests: XCTestCase {
  private let defaultKeys = [
    "llmLocalEngine",
    "llmLocalBaseURL",
    "llmLocalModelId",
    "llmLocalAPIKey",
    "ollamaSetupComplete",
    "selectedLLMProvider",
    "selectedLLMProviderBaseURL",
    "selectedLLMProviderCanonical",
    "selectedLLMProviderDisplayName",
  ]

  private var savedDefaults: [String: Any?] = [:]

  override func setUp() {
    super.setUp()
    savedDefaults = Dictionary(
      uniqueKeysWithValues: defaultKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    )
    defaultKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
  }

  override func tearDown() {
    defaultKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    for (key, value) in savedDefaults {
      if let value {
        UserDefaults.standard.set(value, forKey: key)
      }
    }
    savedDefaults = [:]
    super.tearDown()
  }

  func testProviderSetupCompletionRefreshesLocalModelSettingsFromDefaults() {
    UserDefaults.standard.set(LocalEngine.ollama.rawValue, forKey: "llmLocalEngine")
    UserDefaults.standard.set("http://localhost:11434", forKey: "llmLocalBaseURL")
    UserDefaults.standard.set("qwen2.5vl:7b", forKey: "llmLocalModelId")

    let viewModel = ProvidersSettingsViewModel()
    XCTAssertEqual(viewModel.localEngine, .ollama)
    XCTAssertEqual(viewModel.localModelId, "qwen2.5vl:7b")

    UserDefaults.standard.set(LocalEngine.lmstudio.rawValue, forKey: "llmLocalEngine")
    UserDefaults.standard.set("http://localhost:1234", forKey: "llmLocalBaseURL")
    UserDefaults.standard.set("gemma-4-local", forKey: "llmLocalModelId")
    UserDefaults.standard.set("local-test-key", forKey: "llmLocalAPIKey")

    viewModel.handleProviderSetupCompletion("ollama")

    XCTAssertEqual(viewModel.localEngine, .lmstudio)
    XCTAssertEqual(viewModel.localBaseURL, "http://localhost:1234")
    XCTAssertEqual(viewModel.localModelId, "gemma-4-local")
    XCTAssertEqual(viewModel.localAPIKey, "local-test-key")
  }
}
