import AppKit
import Foundation
import SwiftUI

class ProviderSetupState: ObservableObject {
  @Published var steps: [SetupStep] = []
  @Published var currentStepIndex: Int = 0
  @Published var apiKey: String = ""
  @Published var geminiAPIKeySaveError: String?
  @Published var hasTestedConnection: Bool = false
  @Published var testSuccessful: Bool = false
  @Published var geminiModel: GeminiModel
  // Local engine configuration
  @Published var localEngine: LocalEngine = .lmstudio
  @Published var localBaseURL: String = LocalEngine.lmstudio.defaultBaseURL
  @Published var localModelId: String = LocalModelPreferences.defaultModelId(for: .lmstudio)
  @Published var localAPIKey: String = UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? ""
  // CLI detection
  @Published var codexCLIStatus: CLIDetectionState = .unknown
  @Published var claudeCLIStatus: CLIDetectionState = .unknown
  @Published var isCheckingCLIStatus: Bool = false
  @Published var codexCLIReport: CLIDetectionReport?
  @Published var claudeCLIReport: CLIDetectionReport?
  @Published var debugCommandInput: String = "which codex"
  @Published var debugCommandOutput: String = ""
  @Published var isRunningDebugCommand: Bool = false
  @Published var preferredCLITool: CLITool? = ProviderSetupState.loadStoredPreferredCLITool()

  var lastSavedGeminiModel: GeminiModel
  var hasStartedCLICheck = false
  init() {
    let preference = GeminiModelPreference.load()
    self.geminiModel = preference.primary
    self.lastSavedGeminiModel = preference.primary
  }

  var currentStep: SetupStep {
    guard currentStepIndex < steps.count else {
      return SetupStep(
        id: "fallback", title: "Setup", contentType: .information("Complete", "Setup is complete"))
    }
    return steps[currentStepIndex]
  }

  var canContinue: Bool {
    switch currentStep.contentType {
    case .apiKeyInput:
      return !apiKey.isEmpty && apiKey.count > 20
    case .cliDetection:
      return isSelectedCLIToolReady
    case .information(_, _):
      if currentStep.id == "verify" || currentStep.id == "test" {
        return testSuccessful
      }
      return true
    case .terminalCommand(_), .modelDownload(_), .localChoice, .localModelInstall,
      .apiKeyInstructions:
      return true
    }
  }

  var isLastStep: Bool {
    return currentStepIndex == steps.count - 1
  }

  func configureSteps(for provider: String) {
    switch provider {
    case "ollama":
      steps = [
        SetupStep(
          id: "intro",
          title: "Before you begin",
          contentType: .information(
            "For experienced users",
            "This path is recommended only if you're comfortable running LLMs locally and debugging technical issues. If terms like vLLM or API endpoint don't ring a bell, we recommend going back and picking ChatGPT, Claude, or Gemini. It's non-technical and takes about 30 seconds.\n\nFor local mode, Dayflow recommends Qwen3-VL 4B as the core vision-language model (Qwen2.5-VL 3B remains available if you need a smaller download)."
          )
        ),
        SetupStep(id: "choose", title: "Choose engine", contentType: .localChoice),
        SetupStep(id: "model", title: "Install model", contentType: .localModelInstall),
        SetupStep(
          id: "test", title: "Test connection",
          contentType: .information(
            "Test Connection",
            "Click the button below to verify your local server responds to a simple chat completion."
          )),
        SetupStep(
          id: "complete", title: "Complete",
          contentType: .information(
            "All set!", "Local AI is configured and ready to use with Dayflow.")),
      ]
    case "chatgpt_claude":
      preferredCLITool = ProviderSetupState.loadStoredPreferredCLITool()
      steps = [
        SetupStep(
          id: "intro",
          title: "Before you begin",
          contentType: .information(
            "Install Codex CLI (ChatGPT) or Claude Code",
            "If you have a paid ChatGPT/Claude account, you can have Dayflow tap into your existing usage limits. Everything flows through your current account - no extra charges - and you can opt out of training for privacy. You only need one CLI installed and signed in on this Mac; we'll verify it automatically next."
          )
        ),
        SetupStep(
          id: "detect",
          title: "Check installations",
          contentType: .cliDetection
        ),
        SetupStep(
          id: "test",
          title: "Test connection",
          contentType: .information(
            "Test Connection",
            "Run a quick test to verify your CLI is working and signed in."
          )
        ),
        SetupStep(
          id: "complete",
          title: "Complete",
          contentType: .information(
            "All set!",
            "ChatGPT and Claude tooling is ready. You can fine-tune which assistant to use anytime from Settings → AI Provider."
          )
        ),
      ]
      codexCLIStatus = .unknown
      claudeCLIStatus = .unknown
      codexCLIReport = nil
      claudeCLIReport = nil
      isCheckingCLIStatus = false
      hasStartedCLICheck = false
    default:  // gemini
      steps = [
        SetupStep(
          id: "getkey", title: "Get API key",
          contentType: .apiKeyInstructions),
        SetupStep(
          id: "enterkey", title: "Enter API key",
          contentType: .apiKeyInput),
        SetupStep(
          id: "verify", title: "Test connection",
          contentType: .information(
            "Test Connection", "Click the button below to verify your API key works with Gemini")),
        SetupStep(
          id: "complete", title: "Complete",
          contentType: .information(
            "All set!", "Gemini is now configured and ready to use with Dayflow.")),
      ]
    }
  }

  func goNext() {
    // Save API key to keychain when moving from API key input step
    if currentStep.contentType.isApiKeyInput && !apiKey.isEmpty {
      guard persistGeminiAPIKey(source: "onboarding_step") else { return }
    }

    if currentStepIndex < steps.count - 1 {
      currentStepIndex += 1
    }
  }

  func goBack() {
    if currentStepIndex > 0 {
      currentStepIndex -= 1
    }
  }

  func navigateToStep(_ stepId: String) {
    if let index = steps.firstIndex(where: { $0.id == stepId }) {
      if currentStep.contentType.isApiKeyInput && stepId != currentStep.id {
        guard persistGeminiAPIKey(source: "onboarding_sidebar") else { return }
      }
      // Reset test state when navigating to test step
      if stepId == "verify" || stepId == "test" {
        hasTestedConnection = false
        testSuccessful = false
      }
      // Allow free navigation between all steps
      currentStepIndex = index
    }
  }

  func markCurrentStepCompleted() {
    if currentStepIndex < steps.count {
      steps[currentStepIndex].markCompleted()
    }
  }

  func persistGeminiModelSelection(source: String) {
    guard geminiModel != lastSavedGeminiModel else { return }
    lastSavedGeminiModel = geminiModel
    GeminiModelPreference(primary: geminiModel).save()

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

  @discardableResult
  func persistGeminiAPIKey(source: String) -> Bool {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      geminiAPIKeySaveError = nil
      return true
    }

    if trimmed != apiKey {
      apiKey = trimmed
    }

    let stored = KeychainManager.shared.store(trimmed, for: "gemini")
    if stored {
      geminiAPIKeySaveError = nil
      hasTestedConnection = false
      testSuccessful = false
      persistGeminiModelSelection(source: source)
    } else {
      geminiAPIKeySaveError =
        "Couldn't save your API key to Keychain. Please unlock Keychain and try again."
    }
    return stored
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
    guard isToolAvailable(tool) else { return }
    preferredCLITool = tool
    persistPreferredCLITool()
    captureChatCLIToolSelected(tool)
  }

  func persistPreferredCLITool() {
    guard let tool = preferredCLITool else {
      UserDefaults.standard.removeObject(forKey: Self.cliPreferenceKey)
      return
    }
    UserDefaults.standard.set(tool.rawValue, forKey: Self.cliPreferenceKey)
  }

  func ensurePreferredCLIToolIsValid() {
    if let current = preferredCLITool, isToolAvailable(current) {
      return
    }
    if isToolAvailable(.codex) {
      preferredCLITool = .codex
    } else if isToolAvailable(.claude) {
      preferredCLITool = .claude
    } else {
      preferredCLITool = nil
    }
    persistPreferredCLITool()
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

  static func loadStoredPreferredCLITool() -> CLITool? {
    guard let raw = UserDefaults.standard.string(forKey: Self.cliPreferenceKey) else {
      return nil
    }
    return CLITool(rawValue: raw)
  }

  static let cliPreferenceKey = "chatCLIPreferredTool"

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
  case apiKeyInput
  case apiKeyInstructions
  case modelDownload(String)
  case information(String, String)
  case localChoice
  case localModelInstall
  case cliDetection

  var isApiKeyInput: Bool {
    if case .apiKeyInput = self {
      return true
    }
    return false
  }

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
    if engine != .custom {
      localBaseURL = engine.defaultBaseURL
    }
    let defaultModel = LocalModelPreferences.defaultModelId(
      for: engine == .custom ? .ollama : engine)
    localModelId = defaultModel
    LocalModelPreferences.syncPreset(for: engine, modelId: defaultModel)

    // Track local engine selection for analytics
    AnalyticsService.shared.capture(
      "local_engine_selected",
      [
        "engine": engine.rawValue,
        "base_url": localBaseURL,
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
