import XCTest

@testable import Dayflow

@MainActor
final class ProvidersSettingsViewModelTests: XCTestCase {
  private let defaultKeys = [
    "llmLocalEngine",
    "llmLocalBaseURL",
    "llmLocalModelId",
    "llmLocalAPIKey",
    "localSetupComplete",
    "chatGPTPromptOverrides",
    "claudePromptOverrides",
    "dayflowProviderEndpointV2",
    "chatgptSetupComplete",
    "claudeSetupComplete",
    "geminiSelectedModel_v3",
    LLMProviderRoutingStore.storageKey,
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

    viewModel.handleProviderSetupCompletion(.local)

    XCTAssertEqual(viewModel.localEngine, .lmstudio)
    XCTAssertEqual(viewModel.localBaseURL, "http://localhost:1234")
    XCTAssertEqual(viewModel.localModelId, "gemma-4-local")
    XCTAssertEqual(viewModel.localAPIKey, "local-test-key")
  }

  func testProviderSetupCompletionRefreshesGeminiModelPreference() {
    GeminiModelPreference(primary: .flash35).save()
    let viewModel = ProvidersSettingsViewModel()
    XCTAssertEqual(viewModel.selectedGeminiModel, .flash35)

    GeminiModelPreference(primary: .flashLite31).save()

    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.gemini))
    XCTAssertEqual(viewModel.selectedGeminiModel, .flashLite31)
  }

  func testProviderSetupStateHydratesTheSavedLocalConfiguration() {
    UserDefaults.standard.set(LocalEngine.custom.rawValue, forKey: "llmLocalEngine")
    UserDefaults.standard.set("https://local.example.test/v1", forKey: "llmLocalBaseURL")
    UserDefaults.standard.set("saved-vision-model", forKey: "llmLocalModelId")
    UserDefaults.standard.set("saved-local-key", forKey: "llmLocalAPIKey")

    let state = ProviderSetupState()

    XCTAssertEqual(state.localEngine, .custom)
    XCTAssertEqual(state.localBaseURL, "https://local.example.test/v1")
    XCTAssertEqual(state.localModelId, "saved-vision-model")
    XCTAssertEqual(state.localAPIKey, "saved-local-key")
  }

  func testFailedSetupAssignmentRetainsRoutingIntentForRetry() throws {
    UserDefaults.standard.set(
      Data("corrupt-routing".utf8),
      forKey: LLMProviderRoutingStore.storageKey
    )
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()
    viewModel.beginProviderSetup(.claude, role: .primary)

    XCTAssertFalse(viewModel.handleProviderSetupCompletion(.claude))
    XCTAssertEqual(viewModel.setupModalProvider, .claude)

    UserDefaults.standard.removeObject(forKey: LLMProviderRoutingStore.storageKey)
    viewModel.loadRouting()

    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.claude))
    XCTAssertEqual(viewModel.primaryRoutingProviderId, .claude)
  }
}
