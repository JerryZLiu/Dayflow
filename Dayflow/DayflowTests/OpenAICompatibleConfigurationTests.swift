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

  private final class InMemoryKeychain: OpenAICompatibleKeychainStoring {
    var values: [String: String] = [:]

    func retrieve(for provider: String) -> String? {
      values[provider]
    }

    @discardableResult
    func store(_ apiKey: String, for provider: String) -> Bool {
      values[provider] = apiKey
      return true
    }

    @discardableResult
    func delete(for provider: String) -> Bool {
      values.removeValue(forKey: provider)
      return true
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

  func testSiliconFlowPresetUsesVisionModelDefaults() {
    let configuration = OpenAICompatibleConfiguration.siliconFlow()

    XCTAssertEqual(configuration.preset, .siliconFlow)
    XCTAssertEqual(configuration.preset.displayName, "SiliconFlow")
    XCTAssertEqual(configuration.baseURL, "https://api.siliconflow.com/v1")
    XCTAssertEqual(configuration.modelID, "Qwen/Qwen3.6-35B-A3B")
    XCTAssertEqual(
      configuration.chatCompletionsURL?.absoluteString,
      "https://api.siliconflow.com/v1/chat/completions"
    )
    XCTAssertTrue(configuration.isComplete)
  }

  func testAPIKeyNormalizationRemovesPastedWhitespace() {
    XCTAssertEqual(
      OpenAICompatiblePreferences.normalizedAPIKey("  sk-test-\n 123 \t"),
      "sk-test-123"
    )
  }

  func testSiliconFlowTestRequestDisablesThinking() throws {
    let request = LocalLLMChatRequest(
      model: "Qwen/Qwen3.6-35B-A3B",
      messages: [],
      maxTokens: LocalLLMTestConstants.maxTestTokens,
      enableThinking: false
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let body = try JSONSerialization.jsonObject(
      with: try encoder.encode(request)
    ) as? [String: Any]

    XCTAssertEqual(body?["enable_thinking"] as? Bool, false)
  }

  func testChatRequestOnlySiliconFlowIncludesDisabledThinking() throws {
    for preset in OpenAICompatiblePreset.allCases {
      let configuration = OpenAICompatibleConfiguration(
        preset: preset,
        baseURL: "https://example.com/v1",
        modelID: "vision-model"
      )
      let runtimeConfiguration = OpenAICompatibleRuntimeConfiguration(
        configuration: configuration,
        bearerToken: nil
      )
      let provider = OllamaProvider(openAICompatible: runtimeConfiguration)
      let chatRequest = OllamaProvider.ChatRequest(
        model: provider.savedModelId,
        messages: [],
        enable_thinking: provider.enableThinkingParameter
      )

      let request = try provider.makeChatURLRequest(chatRequest)
      let body = try XCTUnwrap(request.httpBody)
      let decoded = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )

      if preset == .siliconFlow {
        XCTAssertEqual(decoded["enable_thinking"] as? Bool, false)
      } else {
        XCTAssertNil(decoded["enable_thinking"])
      }
    }
  }

  func testLegacyAPIKeyMigratesOnlyToSelectedPreset() {
    let keychain = InMemoryKeychain()
    keychain.values[OpenAICompatiblePreferences.keychainProvider] = " legacy-key\n"

    let migratedKey = OpenAICompatiblePreferences.apiKey(
      for: .siliconFlow,
      keychain: keychain
    )

    XCTAssertEqual(migratedKey, "legacy-key")
    XCTAssertEqual(
      keychain.values[OpenAICompatiblePreferences.keychainProvider(for: .siliconFlow)],
      "legacy-key"
    )
    XCTAssertNil(keychain.values[OpenAICompatiblePreferences.keychainProvider])
    XCTAssertNil(
      OpenAICompatiblePreferences.apiKey(
        for: .openRouter,
        migrateLegacyKey: false,
        keychain: keychain
      )
    )
    XCTAssertNil(
      OpenAICompatiblePreferences.apiKey(
        for: .custom,
        migrateLegacyKey: false,
        keychain: keychain
      )
    )
  }

  func testPresetAPIKeysRemainIsolated() {
    let keychain = InMemoryKeychain()
    for preset in OpenAICompatiblePreset.allCases {
      keychain.values[OpenAICompatiblePreferences.keychainProvider(for: preset)] =
        "\(preset.rawValue)-key"
    }

    for preset in OpenAICompatiblePreset.allCases {
      XCTAssertEqual(
        OpenAICompatiblePreferences.apiKey(
          for: preset,
          migrateLegacyKey: false,
          keychain: keychain
        ),
        "\(preset.rawValue)-key"
      )
    }
    XCTAssertNil(keychain.values[OpenAICompatiblePreferences.keychainProvider])
  }

  func testChatResponseAcceptsTextContentParts() throws {
    let data = Data(
      #"{"choices":[{"message":{"content":[{"type":"text","text":"white"}]}}]}"#.utf8
    )

    let response = try JSONDecoder().decode(OllamaProvider.ChatResponse.self, from: data)

    XCTAssertEqual(response.choices.first?.message.content, "white")
  }

  func testChatResponseRejectsNullOrUnsupportedContent() {
    let responses = [
      #"{"choices":[{"message":{"content":null}}]}"#,
      #"{"choices":[{"message":{"content":123}}]}"#,
    ]

    for response in responses {
      XCTAssertThrowsError(
        try JSONDecoder().decode(OllamaProvider.ChatResponse.self, from: Data(response.utf8))
      )
    }
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

  func testSiliconFlowConfigurationSurvivesReloadFromFreshDefaults() throws {
    let suiteName = "OpenAICompatibleConfigurationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configuration = OpenAICompatibleConfiguration.siliconFlow()

    XCTAssertTrue(OpenAICompatiblePreferences.save(configuration, to: defaults))

    // A new UserDefaults instance models the next app launch reading persisted configuration.
    let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let reloadedConfiguration = OpenAICompatiblePreferences.load(from: reloadedDefaults)
    XCTAssertEqual(reloadedConfiguration, configuration)
    XCTAssertEqual(reloadedConfiguration?.preset, .siliconFlow)
    XCTAssertEqual(reloadedConfiguration?.baseURL, OpenAICompatibleConfiguration.siliconFlowBaseURL)
    XCTAssertEqual(
      reloadedConfiguration?.modelID,
      OpenAICompatibleConfiguration.siliconFlowDefaultModelID
    )
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
