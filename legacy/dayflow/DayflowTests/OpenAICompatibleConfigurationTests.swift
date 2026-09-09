import XCTest

@testable import Dayflow

final class OpenAICompatibleConfigurationTests: XCTestCase {
  private final class IgnoringUserDefaults: UserDefaults {
    var ignoredWriteKeys: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
      guard !ignoredWriteKeys.contains(defaultName) else { return }
      super.set(value, forKey: defaultName)
    }
  }

  func testOpenRouterPresetBuildsChatCompletionsURL() {
    let configuration = OpenAICompatibleConfiguration.openRouter(
      modelID: "  openai/example-model  ")

    XCTAssertEqual(configuration.preset, .openRouter)
    XCTAssertEqual(configuration.baseURL, "https://openrouter.ai/api/v1")
    XCTAssertEqual(configuration.modelID, "openai/example-model")
    XCTAssertEqual(
      configuration.chatCompletionsURL?.absoluteString,
      "https://openrouter.ai/api/v1/chat/completions"
    )
    XCTAssertTrue(configuration.isComplete)
  }

  func testConfigurationPreferencesRoundTripInIsolatedDefaults() throws {
    let suiteName = "OpenAICompatibleConfigurationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configuration = OpenAICompatibleConfiguration(
      preset: .custom,
      baseURL: "https://example.com/v1/chat/completions",
      modelID: "vision-model"
    )

    XCTAssertTrue(OpenAICompatiblePreferences.save(configuration, to: defaults))
    XCTAssertEqual(OpenAICompatiblePreferences.load(from: defaults), configuration)

    OpenAICompatiblePreferences.reset(in: defaults)
    XCTAssertNil(OpenAICompatiblePreferences.load(from: defaults))
    XCTAssertEqual(OpenAICompatiblePreferences.keychainProvider, "openai_compatible")
  }

  func testInjectedRuntimeBuildsIndependentBearerRequest() throws {
    let storedConfiguration = OpenAICompatibleConfiguration(
      preset: .custom,
      baseURL: "https://example.com/api/v1",
      modelID: "remote-vision-model"
    )
    let runtimeConfiguration = OpenAICompatibleRuntimeConfiguration(
      configuration: storedConfiguration,
      bearerToken: "  remote-secret  "
    )
    let provider = OllamaProvider(openAICompatible: runtimeConfiguration)
    let chatRequest = OllamaProvider.ChatRequest(
      model: provider.savedModelId,
      messages: [
        OllamaProvider.ChatMessage(
          role: "user",
          content: [
            OllamaProvider.MessageContent(type: "text", text: "hello", image_url: nil)
          ]
        )
      ],
      temperature: 0.2,
      max_tokens: 20,
      stream: false
    )

    let request = try provider.makeChatURLRequest(chatRequest)

    XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v1/chat/completions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer remote-secret")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(provider.savedModelId, "remote-vision-model")
    XCTAssertEqual(provider.localEngine, "openai_compatible")
    XCTAssertFalse(provider.isLMStudio)
    XCTAssertFalse(provider.isCustomEngine)
    XCTAssertNil(provider.customAPIKey)

    let body = try XCTUnwrap(request.httpBody)
    let decoded = try JSONDecoder().decode(OllamaProvider.ChatRequest.self, from: body)
    XCTAssertEqual(decoded.model, "remote-vision-model")
  }

  func testInjectedRuntimeOmitsEmptyBearerToken() throws {
    let configuration = OpenAICompatibleConfiguration(
      preset: .custom,
      baseURL: "https://example.com",
      modelID: "model"
    )
    let runtimeConfiguration = OpenAICompatibleRuntimeConfiguration(
      configuration: configuration,
      bearerToken: "   "
    )
    let provider = OllamaProvider(openAICompatible: runtimeConfiguration)
    let chatRequest = OllamaProvider.ChatRequest(
      model: "model",
      messages: [],
      temperature: 0.7,
      max_tokens: 10,
      stream: false
    )

    let request = try provider.makeChatURLRequest(chatRequest)

    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
  }

  func testFailedConfigurationWritePreservesPreviousValue() throws {
    let suiteName = "OpenAICompatibleConfigurationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(IgnoringUserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let previous = OpenAICompatibleConfiguration.openRouter(modelID: "previous-model")
    let replacement = OpenAICompatibleConfiguration(
      preset: .custom,
      baseURL: "https://replacement.example/v1",
      modelID: "replacement-model"
    )
    XCTAssertTrue(OpenAICompatiblePreferences.save(previous, to: defaults))
    defaults.ignoredWriteKeys = ["llmOpenAICompatibleConfigurationV1"]

    XCTAssertFalse(OpenAICompatiblePreferences.save(replacement, to: defaults))
    XCTAssertEqual(OpenAICompatiblePreferences.load(from: defaults), previous)
  }
}
