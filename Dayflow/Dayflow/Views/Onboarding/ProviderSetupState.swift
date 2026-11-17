import AppKit
import Foundation
import SwiftUI

class ProviderSetupState: ObservableObject {
  @Published var steps: [SetupStep] = []
  @Published var currentStepIndex: Int = 0
  /// The furthest step the user has reached. The sidebar only lets them jump back to steps up to
  /// this one, so they can't skip ahead past a test that hasn't passed.
  @Published private(set) var furthestStepIndex: Int = 0
  @Published var apiKey: String = ""
  @Published private(set) var hasStoredGeminiAPIKey = false
  @Published var geminiAPIKeySaveError: String?
  @Published var saveErrorMessage: String?
  @Published var hasTestedConnection: Bool = false
  @Published var testSuccessful: Bool = false
  @Published var geminiModel: GeminiModel
  // Local engine configuration
  @Published var localEngine: LocalEngine
  @Published var localBaseURL: String
  @Published var localModelId: String
  @Published var localAPIKey: String
  @Published var openAICompatiblePreset: OpenAICompatiblePreset = .openRouter
  @Published var openAICompatibleBaseURL: String = OpenAICompatibleConfiguration.openRouterBaseURL
  @Published var openAICompatibleModelID: String = ""
  @Published var openAICompatibleAPIKey: String = ""
  // CLI detection
  @Published var codexCLIStatus: CLIDetectionState = .unknown
  @Published var claudeCLIStatus: CLIDetectionState = .unknown
  @Published var isCheckingCLIStatus: Bool = false
  @Published var codexCLIReport: CLIDetectionReport?
  @Published var claudeCLIReport: CLIDetectionReport?
  @Published var debugCommandInput: String = "which codex"
  @Published var debugCommandOutput: String = ""
  @Published var isRunningDebugCommand: Bool = false
  @Published var preferredCLITool: CLITool?

  var lastSavedGeminiModel: GeminiModel
  var hasStartedCLICheck = false
  @Published private(set) var configuredProviderID: LLMProviderID?

  init() {
    let defaults = UserDefaults.standard
    let savedLocalEngine =
      defaults.string(forKey: "llmLocalEngine").flatMap(LocalEngine.init(rawValue:)) ?? .lmstudio
    let savedLocalBaseURL =
      defaults.string(forKey: "llmLocalBaseURL")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let savedLocalModelID =
      defaults.string(forKey: "llmLocalModelId")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.localEngine = savedLocalEngine
    self.localBaseURL =
      savedLocalBaseURL.isEmpty
      ? savedLocalEngine.defaultBaseURL : savedLocalBaseURL
    self.localModelId =
      savedLocalModelID.isEmpty
      ? LocalModelPreferences.defaultModelId(for: savedLocalEngine) : savedLocalModelID
    self.localAPIKey = defaults.string(forKey: "llmLocalAPIKey") ?? ""

    let preference = GeminiModelPreference.load()
    self.geminiModel = preference.primary
    self.lastSavedGeminiModel = preference.primary
    self.preferredCLITool = nil

    if let configuration = OpenAICompatiblePreferences.load() {
      openAICompatiblePreset = configuration.preset
      openAICompatibleBaseURL = configuration.baseURL
      openAICompatibleModelID = configuration.modelID
    }
    openAICompatibleAPIKey =
      KeychainManager.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider) ?? ""
  }

  var currentStep: SetupStep {
    guard currentStepIndex < steps.count else {
      return SetupStep(
        id: "fallback", title: String(localized: "Setup"),
        contentType: .information(
          String(localized: "Complete"), String(localized: "Setup is complete")))
    }
    return steps[currentStepIndex]
  }

  var canContinue: Bool {
    switch currentStep.contentType {
    case .cliDetection:
      return isSelectedCLIToolReady
    case .geminiKeySetup:
      return testSuccessful
    case .information(_, _):
      if currentStep.id == "verify" || currentStep.id == "test" {
        return testSuccessful
      }
      return true
    case .terminalCommand(_), .modelDownload(_), .localChoice, .localModelInstall:
      return true
    }
  }

  var isLastStep: Bool {
    return currentStepIndex == steps.count - 1
  }

  func configureSteps(for provider: LLMProviderID) {
    configuredProviderID = provider
    currentStepIndex = 0
    furthestStepIndex = 0
    switch provider {
    case .local:
      steps = [
        SetupStep(
          id: "intro",
          title: String(localized: "Before you begin"),
          contentType: .information(
            String(localized: "For experienced users"),
            String(
              localized:
                "This path is recommended only if you're comfortable running LLMs locally and debugging technical issues. If terms like vLLM or API endpoint don't ring a bell, we recommend going back and picking ChatGPT, Claude, or Gemini. It's non-technical and takes about 30 seconds.\n\nFor local mode, Dayflow recommends Qwen3-VL 4B as the core vision-language model (Qwen2.5-VL 3B remains available if you need a smaller download)."
            )
          )
        ),
        SetupStep(
          id: "choose", title: String(localized: "Choose engine"), contentType: .localChoice),
        SetupStep(
          id: "model", title: String(localized: "Install model"), contentType: .localModelInstall),
        SetupStep(
          id: "test", title: String(localized: "Test connection"),
          contentType: .information(
            String(localized: "Test Connection"),
            String(
              localized:
                "Click the button below to verify your local server responds to a simple chat completion."
            )
          )),
      ]
    case .chatGPT, .claude:
      preferredCLITool = provider == .claude ? .claude : .codex
      steps = chatCLISteps(for: provider)
      codexCLIStatus = .unknown
      claudeCLIStatus = .unknown
      codexCLIReport = nil
      claudeCLIReport = nil
      isCheckingCLIStatus = false
      hasStartedCLICheck = false
    case .openAICompatible:
      steps = [
        SetupStep(
          id: "intro",
          title: String(localized: "Configure endpoint"),
          contentType: .information(
            String(localized: "Connect an OpenAI-compatible endpoint"),
            String(
              localized:
                "Use OpenRouter or another endpoint that supports OpenAI Chat Completions with image input. The connection test sends one image and may incur a small provider charge."
            )
          )
        ),
        SetupStep(
          id: "test",
          title: String(localized: "Test connection"),
          contentType: .information(
            String(localized: "Test Connection"),
            String(
              localized:
                "Enter the endpoint, model, and API key, then verify a multimodal response.")
          )
        ),
      ]
    case .gemini, .dayflow:
      let storedGeminiKey =
        KeychainManager.shared.retrieve(for: "gemini")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      hasStoredGeminiAPIKey = !storedGeminiKey.isEmpty
      // One screen: where to get a key, the key field, and a check that runs on its own once a
      // key is pasted. The check only asks Google whether the key is valid, so it takes well
      // under a second.
      steps = [
        SetupStep(
          id: "verify", title: String(localized: "Add API key"),
          contentType: .geminiKeySetup)
      ]
    }
  }

  private func chatCLISteps(for provider: LLMProviderID) -> [SetupStep] {
    let isClaude = provider == .claude
    let providerName = isClaude ? "Claude" : "ChatGPT"
    let cliName = isClaude ? "Claude Code" : "Codex CLI"
    return [
      SetupStep(
        id: "intro",
        title: String(localized: "Before you begin"),
        contentType: .information(
          "",
          String(
            localized:
              "Dayflow uses \(cliName) through your existing \(providerName) subscription. Install it and sign in on this Mac, then we'll verify the connection."
          )
        )
      ),
      SetupStep(
        id: "detect",
        title: String(localized: "Check installations"),
        contentType: .cliDetection
      ),
      SetupStep(
        id: "test",
        title: String(localized: "Test connection"),
        contentType: .information(
          String(localized: "Test Connection"),
          String(localized: "Run a quick test to verify your CLI is working and signed in.")
        )
      ),
    ]
  }

  /// Swap the active chat-CLI provider mid-flow (e.g. user picked ChatGPT but selects
  /// Claude on the detection step). Rewrites the step copy in place without resetting
  /// detection results or the user's position in the flow.
  private func switchChatCLIProvider(to provider: LLMProviderID) {
    guard configuredProviderID == .chatGPT || configuredProviderID == .claude,
      provider == .chatGPT || provider == .claude,
      provider != configuredProviderID
    else { return }
    configuredProviderID = provider
    let refreshedSteps = chatCLISteps(for: provider)
    for (index, refreshed) in refreshedSteps.enumerated() where index < steps.count {
      var step = refreshed
      if steps[index].isCompleted {
        step.markCompleted()
      }
      steps[index] = step
    }
    // The connection test targets the selected CLI, so a switch invalidates it
    hasTestedConnection = false
    testSuccessful = false
  }

  func goNext() {
    if currentStepIndex < steps.count - 1 {
      currentStepIndex += 1
      furthestStepIndex = max(furthestStepIndex, currentStepIndex)
    }
  }

  func isStepReachable(_ stepId: String) -> Bool {
    guard let index = steps.firstIndex(where: { $0.id == stepId }) else { return false }
    return index <= furthestStepIndex
  }

  func goBack() {
    if currentStepIndex > 0 {
      currentStepIndex -= 1
    }
  }

  func navigateToStep(_ stepId: String) {
    // Only steps the user has already reached; later ones open through Next.
    guard let index = steps.firstIndex(where: { $0.id == stepId }), index <= furthestStepIndex,
      index != currentStepIndex
    else { return }
    // Reset test state when navigating to test step
    if stepId == "verify" || stepId == "test" {
      hasTestedConnection = false
      testSuccessful = false
    }
    currentStepIndex = index
  }

  func markCurrentStepCompleted() {
    if currentStepIndex < steps.count {
      steps[currentStepIndex].markCompleted()
    }
  }

  func persistGeminiModelSelection(source: String) {
    guard geminiModel != lastSavedGeminiModel else { return }
    lastSavedGeminiModel = geminiModel

    Task { @MainActor in
      AnalyticsService.shared.capture(
        "gemini_model_selected",
        [
          "source": source,
          "model": geminiModel.rawValue,
        ])
    }

    // Changing models should prompt the user to re-run the connection test
    hasTestedConnection = false
    testSuccessful = false
  }

  func clearGeminiAPIKeySaveError() {
    geminiAPIKeySaveError = nil
  }

  var isSelectedCLIToolReady: Bool {
    guard let preferredCLITool else { return false }
    return isToolAvailable(preferredCLITool)
  }

  func ensureCLICheckStarted() {
    guard !hasStartedCLICheck else { return }
    hasStartedCLICheck = true
    refreshCLIStatuses(source: "initial")
  }

  func refreshCLIStatuses(source: String = "manual_recheck") {
    if isCheckingCLIStatus { return }
    isCheckingCLIStatus = true
    codexCLIStatus = .checking
    claudeCLIStatus = .checking
    codexCLIReport = nil
    claudeCLIReport = nil

    Task.detached { [weak self] in
      guard let self else { return }
      async let codex = CLIDetector.detect(tool: .codex)
      async let claude = CLIDetector.detect(tool: .claude)
      let (codexResult, claudeResult) = await (codex, claude)

      await MainActor.run {
        self.codexCLIReport = codexResult
        self.claudeCLIReport = claudeResult
        self.codexCLIStatus = codexResult.state
        self.claudeCLIStatus = claudeResult.state
        self.isCheckingCLIStatus = false
        self.ensurePreferredCLIToolIsValid()
        self.captureChatCLIDetectionChecked(source: source)
      }
    }
  }

  /// Called when Dayflow comes back to the front on the detection step. Only checks while the
  /// chosen CLI is still missing, and not while Dayflow is installing Claude itself.
  @MainActor
  func recheckCLIsAfterReturningToDayflow() {
    guard hasStartedCLICheck, !isCheckingCLIStatus, !isSelectedCLIToolReady,
      ClaudeInstaller.shared.state != .installing
    else { return }
    refreshCLIStatuses(source: "app_became_active")
  }

  @MainActor
  func runDebugCommand() {
    guard !debugCommandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      debugCommandOutput = "Enter a command to run."
      return
    }
    if isRunningDebugCommand { return }
    isRunningDebugCommand = true
    debugCommandOutput = "Running..."

    let command = debugCommandInput
    Task.detached { [weak self] in
      let result = CLIDetector.runDebugCommand(command)
      await MainActor.run { [weak self] in
        guard let self else { return }
        var output = ""
        output += "Exit code: \(result.exitCode)\n"
        if !result.stdout.isEmpty {
          output += "\nstdout:\n\(result.stdout)"
        }
        if !result.stderr.isEmpty {
          output += "\nstderr:\n\(result.stderr)"
        }
        if result.stdout.isEmpty && result.stderr.isEmpty {
          output += "\n(no output)"
        }
        self.debugCommandOutput = output
        self.isRunningDebugCommand = false
      }
    }
  }

  func selectPreferredCLITool(_ tool: CLITool) {
    guard preferredCLITool != tool else { return }
    preferredCLITool = tool
    switchChatCLIProvider(to: tool == .claude ? .claude : .chatGPT)
    captureChatCLIToolSelected(tool)
  }

  func ensurePreferredCLIToolIsValid() {
    // Keep an explicit selection even if that CLI isn't installed yet — the
    // Next button stays disabled until it's detected.
    if preferredCLITool != nil {
      return
    }
    if isToolAvailable(.codex) {
      preferredCLITool = .codex
    } else if isToolAvailable(.claude) {
      preferredCLITool = .claude
    }
  }

  func captureChatCLIDetectionChecked(source: String) {
    AnalyticsService.shared.capture(
      "chat_cli_detection_checked",
      chatCLIDetectionAnalyticsProperties(
        source: source,
        selectedTool: preferredCLITool
      )
    )
  }

  func captureChatCLIToolSelected(_ tool: CLITool) {
    AnalyticsService.shared.capture(
      "chat_cli_tool_selected",
      chatCLIDetectionAnalyticsProperties(
        source: "detection_step",
        selectedTool: tool
      )
    )
  }

  func chatCLIDetectionAnalyticsProperties(
    source: String,
    selectedTool: CLITool?
  ) -> [String: Any] {
    let codexAvailable = isToolAvailable(.codex)
    let claudeAvailable = isToolAvailable(.claude)
    let availableToolCount = [codexAvailable, claudeAvailable].filter { $0 }.count
    let selectedToolAvailable = selectedTool.map(isToolAvailable(_:)) ?? false

    return [
      "source": source,
      "provider_id": configuredProviderID?.rawValue ?? "unknown",
      "setup_step": "detect",
      "selected_tool": selectedTool?.rawValue ?? "none",
      "selected_tool_available": selectedToolAvailable,
      "codex_available": codexAvailable,
      "claude_available": claudeAvailable,
      "any_cli_available": codexAvailable || claudeAvailable,
      "both_clis_available": codexAvailable && claudeAvailable,
      "available_tool_count": availableToolCount,
      "codex_status": analyticsValue(for: codexCLIStatus),
      "claude_status": analyticsValue(for: claudeCLIStatus),
    ]
  }

  func analyticsValue(for status: CLIDetectionState) -> String {
    switch status {
    case .unknown:
      return "unknown"
    case .checking:
      return "checking"
    case .installed:
      return "installed"
    case .notFound:
      return "not_found"
    case .failed:
      return "failed"
    }
  }

  func isToolAvailable(_ tool: CLITool) -> Bool {
    switch tool {
    case .codex:
      if codexCLIStatus.isInstalled { return true }
      return codexCLIReport?.resolvedPath != nil
    case .claude:
      if claudeCLIStatus.isInstalled { return true }
      return claudeCLIReport?.resolvedPath != nil
    }
  }

}

struct SetupStep: Identifiable {
  let id: String
  let title: String
  let contentType: StepContentType
  private(set) var isCompleted: Bool = false

  mutating func markCompleted() {
    isCompleted = true
  }
}

enum StepContentType {
  case terminalCommand(String)
  case modelDownload(String)
  case information(String, String)
  case localChoice
  case localModelInstall
  case cliDetection
  /// Gemini on one screen: where to get a key, the key field, and the key check.
  case geminiKeySetup

  var informationTitle: String? {
    if case .information(let title, _) = self {
      return title
    }
    return nil
  }
}

extension ProviderSetupState {
  @MainActor func selectEngine(_ engine: LocalEngine) {
    localEngine = engine
    hasTestedConnection = false
    testSuccessful = false
    if engine != .custom {
      localBaseURL = engine.defaultBaseURL
    }
    let defaultModel = LocalModelPreferences.defaultModelId(
      for: engine == .custom ? .ollama : engine)
    localModelId = defaultModel

    // Track local engine selection for analytics
    AnalyticsService.shared.capture(
      "local_engine_selected",
      [
        "engine": engine.rawValue,
        "default_model": defaultModel,
        "has_api_key": !localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      ])
  }

  var localCurlCommand: String {
    let payload =
      "{\"model\":\"\(localModelId)\",\"messages\":[{\"role\":\"user\",\"content\":\"Say 'hello' and your model name.\"}],\"max_tokens\":50}"
    let authHeader = localEngine == .lmstudio ? " -H \"Authorization: Bearer lm-studio\"" : ""
    let endpoint =
      LocalEndpointUtilities.chatCompletionsURL(baseURL: localBaseURL)?.absoluteString
      ?? "\(localBaseURL)/v1/chat/completions"
    return "curl -s \(endpoint) -H \"Content-Type: application/json\"\(authHeader) -d '\(payload)'"
  }
}
