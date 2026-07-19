import Foundation
import SwiftUI

@MainActor
final class ProvidersSettingsViewModel: ObservableObject {
  @Published private(set) var routing = LLMProviderRouting(primary: .gemini)
  @Published private(set) var hasLoadedRouting = false
  @Published var setupModalProvider: LLMProviderID? {
    didSet {
      if setupModalProvider == nil {
        pendingSetupRole = nil
      }
    }
  }
  @Published var providerRoutingErrorMessage: String?

  @Published var selectedGeminiModel: GeminiModel
  @Published var selectedClaudeModel: ClaudeModel
  @Published var selectedCodexModel: CodexModel
  /// Live catalog of models the user can pick for the Chat CLI
  /// providers, populated by `ChatCLIModelCatalog.discover()`. When
  /// the catalog is empty (e.g. the CLI isn't installed), the
  /// Settings UI falls back to the static enum lists.
  @Published private(set) var chatCLIModelCatalog: ChatCLIModelCatalogResult =
    .empty
  @Published private(set) var isDiscoveringChatCLIModels = false
  @Published var localEngine: LocalEngine {
    didSet {
      guard oldValue != localEngine else { return }
      UserDefaults.standard.set(localEngine.rawValue, forKey: "llmLocalEngine")
      LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
      refreshUpgradeBannerState()
    }
  }
  @Published var localBaseURL: String {
    didSet {
      guard oldValue != localBaseURL else { return }
      UserDefaults.standard.set(localBaseURL, forKey: "llmLocalBaseURL")
    }
  }
  @Published var localModelId: String {
    didSet {
      guard oldValue != localModelId else { return }
      UserDefaults.standard.set(localModelId, forKey: "llmLocalModelId")
      LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
      refreshUpgradeBannerState()
    }
  }
  @Published var localAPIKey: String {
    didSet {
      guard oldValue != localAPIKey else { return }
      persistLocalAPIKey(localAPIKey)
    }
  }
  @Published var localTestBaseURL = ""
  @Published var localTestModelID = ""
  @Published var localTestAPIKey = ""
  @Published var showLocalModelUpgradeBanner = false
  @Published var isShowingLocalModelUpgradeSheet = false
  @Published var upgradeStatusMessage: String?
  @Published private(set) var openAICompatiblePreset: OpenAICompatiblePreset = .openRouter
  @Published private(set) var openAICompatibleBaseURL =
    OpenAICompatibleConfiguration.openRouterBaseURL
  @Published private(set) var openAICompatibleModelID = ""
  @Published private(set) var openAICompatibleAPIKey = ""
  @Published private(set) var codexCLIInstalled = false
  @Published private(set) var claudeCLIInstalled = false
  @Published private(set) var isCheckingCLIReadiness = false

  @Published var geminiPromptOverridesLoaded = false
  @Published var isUpdatingGeminiPromptState = false
  @Published var useCustomGeminiTitlePrompt = false {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var useCustomGeminiSummaryPrompt = false {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var useCustomGeminiDetailedPrompt = false {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var geminiTitlePromptText = GeminiPromptDefaults.titleBlock {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var geminiSummaryPromptText = GeminiPromptDefaults.summaryBlock {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var geminiDetailedPromptText = GeminiPromptDefaults.detailedSummaryBlock {
    didSet { persistGeminiPromptOverridesIfReady() }
  }

  @Published var ollamaPromptOverridesLoaded = false
  @Published var isUpdatingOllamaPromptState = false
  @Published var useCustomOllamaTitlePrompt = false {
    didSet { persistOllamaPromptOverridesIfReady() }
  }
  @Published var useCustomOllamaSummaryPrompt = false {
    didSet { persistOllamaPromptOverridesIfReady() }
  }
  @Published var ollamaTitlePromptText = OllamaPromptDefaults.titleBlock {
    didSet { persistOllamaPromptOverridesIfReady() }
  }
  @Published var ollamaSummaryPromptText = OllamaPromptDefaults.summaryBlock {
    didSet { persistOllamaPromptOverridesIfReady() }
  }

  @Published var agentPromptOverridesLoaded = false
  @Published var isUpdatingAgentPromptState = false
  @Published var useCustomAgentTitlePrompt = false {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var useCustomAgentSummaryPrompt = false {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var useCustomAgentDetailedPrompt = false {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var agentTitlePromptText = CodexPromptDefaults.titleBlock {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var agentSummaryPromptText = CodexPromptDefaults.summaryBlock {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var agentDetailedPromptText = CodexPromptDefaults.detailedSummaryBlock {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var selectedAgentPromptProvider: LLMProviderID = .chatGPT {
    didSet {
      guard oldValue != selectedAgentPromptProvider else { return }
      guard selectedAgentPromptProvider == .chatGPT || selectedAgentPromptProvider == .claude else {
        selectedAgentPromptProvider = oldValue
        return
      }
      loadAgentPromptOverridesIfNeeded(force: true)
    }
  }

  private var savedGeminiModel: GeminiModel
  private var pendingSetupRole: ProviderRoutingRole?

  init() {
    let preference = GeminiModelPreference.load()
    selectedGeminiModel = preference.primary
    savedGeminiModel = preference.primary

    // Load the Chat CLI model picks up-front. The Settings UI uses
    // these even before the catalog discovery completes, so the
    // picker is never empty for a returning user.
    selectedClaudeModel = ClaudeModelPreference.load().primary
    selectedCodexModel = CodexModelPreference.load().primary
    chatCLIModelCatalog = ChatCLIModelCatalog.cached() ?? .empty

    let rawEngine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
    let engine = LocalEngine(rawValue: rawEngine) ?? .ollama
    localEngine = engine
    localBaseURL =
      UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? LocalEngine.ollama.defaultBaseURL

    let defaults = UserDefaults.standard
    let storedModel = defaults.string(forKey: "llmLocalModelId") ?? ""
    if storedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      localModelId = LocalModelPreferences.defaultModelId(for: engine)
    } else {
      localModelId = storedModel
    }

    localAPIKey = UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? ""
    localTestBaseURL = localBaseURL
    localTestModelID = localModelId
    localTestAPIKey = localAPIKey

    if let configuration = OpenAICompatiblePreferences.load() {
      openAICompatiblePreset = configuration.preset
      openAICompatibleBaseURL = configuration.baseURL
      openAICompatibleModelID = configuration.modelID
    }
    openAICompatibleAPIKey =
      KeychainManager.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider) ?? ""
  }

  func handleOnAppear() {
    DayflowAuthManager.shared.loadStoredSessionIfNeeded()
    loadRouting()
    reloadLocalProviderSettings()
    reloadOpenAICompatibleSettings()
    refreshCLIReadiness()
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
    refreshUpgradeBannerState()
    loadGeminiPromptOverridesIfNeeded()
    loadOllamaPromptOverridesIfNeeded()
    if currentProvider == .chatGPT || currentProvider == .claude {
      selectedAgentPromptProvider = currentProvider
      // Probe the Chat CLI to populate the model picker. We only
      // kick this off when one of the CLI providers is active — the
      // Gemini/local/openai-compatible providers don't use it, so
      // there's no point spending the API calls. Uses the 1-hour
      // cache by default; the "Refresh" button forces a re-probe.
      if chatCLIModelCatalog.claude.isEmpty && chatCLIModelCatalog.codex.isEmpty {
        refreshChatCLIModelCatalog(force: false)
      }
    } else {
      loadAgentPromptOverridesIfNeeded()
    }
  }

  func handleLocalTestCompletion(success: Bool) {
    guard success else { return }

    localBaseURL = localTestBaseURL
    localModelId = localTestModelID
    localAPIKey = localTestAPIKey
    UserDefaults.standard.set(localTestBaseURL, forKey: "llmLocalBaseURL")
    UserDefaults.standard.set(localTestModelID, forKey: "llmLocalModelId")
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
    persistLocalAPIKey(localTestAPIKey)
    refreshUpgradeBannerState()
  }

  func markUpgradeBannerKeepLegacy() {
    LocalModelPreferences.markUpgradeDismissed(true)
    showLocalModelUpgradeBanner = false
  }

  func markUpgradeBannerUpgrade() {
    LocalModelPreferences.markUpgradeDismissed(false)
  }

  func applyProviderChangeSideEffects(for provider: LLMProviderID) {
    reloadLocalProviderSettings()
    reloadOpenAICompatibleSettings()
    if provider == .gemini {
      loadGeminiPromptOverridesIfNeeded(force: true)
    } else if provider == .local {
      loadOllamaPromptOverridesIfNeeded(force: true)
    } else if provider == .chatGPT || provider == .claude {
      selectedAgentPromptProvider = provider
      loadAgentPromptOverridesIfNeeded(force: true)
    }
    refreshUpgradeBannerState()
  }

  func reloadLocalProviderSettings() {
    localBaseURL = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? localBaseURL
    localModelId = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? localModelId
    localAPIKey = UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? localAPIKey
    let raw = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? localEngine.rawValue
    localEngine = LocalEngine(rawValue: raw) ?? localEngine
    localTestBaseURL = localBaseURL
    localTestModelID = localModelId
    localTestAPIKey = localAPIKey
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
  }

  func reloadOpenAICompatibleSettings() {
    let configuration = OpenAICompatiblePreferences.load() ?? .openRouter()
    openAICompatiblePreset = configuration.preset
    openAICompatibleBaseURL = configuration.baseURL
    openAICompatibleModelID = configuration.modelID
    openAICompatibleAPIKey =
      KeychainManager.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider) ?? ""
  }

  func refreshCLIReadiness() {
    guard !isCheckingCLIReadiness else { return }
    isCheckingCLIReadiness = true

    Task.detached { [weak self] in
      let codexInstalled = CLIDetector.isInstalled(.codex)
      let claudeInstalled = CLIDetector.isInstalled(.claude)
      await MainActor.run { [weak self] in
        self?.codexCLIInstalled = codexInstalled
        self?.claudeCLIInstalled = claudeInstalled
        self?.isCheckingCLIReadiness = false
      }
    }
  }

  var usingRecommendedLocalModel: Bool {
    let comparisonEngine = localEngine == .custom ? .ollama : localEngine
    let normalized = localModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    let recommended = LocalModelPreset.recommended.modelId(for: comparisonEngine)
    if normalized.caseInsensitiveCompare(recommended) == .orderedSame {
      return true
    }
    return LocalModelPreferences.currentPreset() == .qwen3VL4B
  }

  func refreshUpgradeBannerState() {
    let shouldShow = LocalModelPreferences.shouldShowUpgradeBanner(
      engine: localEngine, modelId: localModelId)
    showLocalModelUpgradeBanner = shouldShow && currentProvider == .local
  }

  func handleUpgradeSuccess(engine: LocalEngine, baseURL: String, modelId: String, apiKey: String) {
    let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    localEngine = engine
    localBaseURL = baseURL
    localModelId = modelId
    localAPIKey = normalizedKey
    localTestBaseURL = baseURL
    localTestModelID = modelId
    localTestAPIKey = normalizedKey
    UserDefaults.standard.set(baseURL, forKey: "llmLocalBaseURL")
    UserDefaults.standard.set(modelId, forKey: "llmLocalModelId")
    UserDefaults.standard.set(engine.rawValue, forKey: "llmLocalEngine")
    persistLocalAPIKey(normalizedKey)
    LocalModelPreferences.syncPreset(for: engine, modelId: modelId)
    LocalModelPreferences.markUpgradeDismissed(true)
    refreshUpgradeBannerState()
    upgradeStatusMessage = "Upgraded to \(LocalModelPreset.recommended.displayName)"
    AnalyticsService.shared.capture(
      "local_model_upgraded",
      [
        "engine": engine.rawValue,
        "model": modelId,
      ])

    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      self?.upgradeStatusMessage = nil
    }
  }

  func persistLocalAPIKey(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      UserDefaults.standard.removeObject(forKey: "llmLocalAPIKey")
    } else {
      UserDefaults.standard.set(trimmed, forKey: "llmLocalAPIKey")
    }
  }

  var currentProvider: LLMProviderID { routing.primary }

  var primaryRoutingProviderId: LLMProviderID { routing.primary }

  var secondaryRoutingProviderId: LLMProviderID? { routing.secondary }

  var hasCodexOrClaudeProviderInRouting: Bool {
    routing.primary == .chatGPT || routing.primary == .claude
      || routing.secondary == .chatGPT || routing.secondary == .claude
  }

  func loadRouting() {
    do {
      let storedRouting = try LLMProviderRoutingStore.load()
      routing = storedRouting
      hasLoadedRouting = true
      providerRoutingErrorMessage = nil
      applyProviderChangeSideEffects(for: storedRouting.primary)
    } catch {
      hasLoadedRouting = false
      providerRoutingErrorMessage =
        "Dayflow couldn't load your provider routing. Your saved providers were left unchanged."
    }
  }

  var routingProviders: [CompactProviderInfo] {
    providerCatalog
  }

  var canModifyRouting: Bool {
    hasLoadedRouting
  }

  func beginProviderSetup(_ providerId: LLMProviderID, role: ProviderRoutingRole) {
    guard providerCatalog.contains(where: { $0.id == providerId }) else { return }
    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return
    }

    pendingSetupRole = role
    setupModalProvider = providerId
  }

  func editProviderConfiguration(_ providerId: LLMProviderID) {
    guard providerCatalog.contains(where: { $0.id == providerId }) else { return }
    if providerId == .dayflow {
      openAccountForDayflowProvider(providerId)
      return
    }

    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return
    }

    pendingSetupRole = .setupOnly
    setupModalProvider = providerId
  }

  @discardableResult
  func handleProviderSetupCompletion(_ providerId: LLMProviderID) -> Bool {
    switch providerId {
    case .local:
      reloadLocalProviderSettings()
    case .openAICompatible:
      reloadOpenAICompatibleSettings()
    case .chatGPT:
      codexCLIInstalled = true
      refreshCLIReadiness()
    case .claude:
      claudeCLIInstalled = true
      refreshCLIReadiness()
    case .gemini:
      let preference = GeminiModelPreference.load()
      selectedGeminiModel = preference.primary
      savedGeminiModel = preference.primary
    case .dayflow:
      break
    }
    let role = pendingSetupRole ?? .setupOnly
    let routingSucceeded: Bool
    switch role {
    case .primary:
      routingSucceeded = assignPrimaryProvider(providerId, requiresReadinessCheck: false)
    case .secondary:
      routingSucceeded = assignSecondaryProvider(providerId, requiresReadinessCheck: false)
    case .setupOnly:
      routingSucceeded = true
    }
    guard routingSucceeded else { return false }

    recordProviderSetupCompleted(providerId)
    pendingSetupRole = nil
    return true
  }

  func cancelProviderSetup() {
    pendingSetupRole = nil
    setupModalProvider = nil
  }

  func setPrimaryOrSetup(_ providerId: LLMProviderID) {
    guard canModifyRouting else { return }
    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return
    }

    if isProviderConfigured(providerId) {
      assignPrimaryProvider(providerId)
    } else {
      beginProviderSetup(providerId, role: .primary)
    }
  }

  func setSecondaryOrSetup(_ providerId: LLMProviderID) {
    guard canModifyRouting else { return }
    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return
    }

    if isProviderConfigured(providerId) {
      assignSecondaryProvider(providerId)
    } else {
      beginProviderSetup(providerId, role: .secondary)
    }
  }

  @discardableResult
  func assignPrimaryProvider(
    _ providerId: LLMProviderID,
    requiresReadinessCheck: Bool = true
  ) -> Bool {
    guard canModifyRouting else { return false }
    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return false
    }
    guard providerId != routing.primary else { return true }
    if requiresReadinessCheck {
      guard isProviderConfigured(providerId) else { return false }
    }

    let previousPrimary = routing.primary
    let shouldSwapWithSecondary = routing.secondary == providerId
    let updatedRouting = LLMProviderRouting(
      primary: providerId,
      secondary: shouldSwapWithSecondary ? previousPrimary : routing.secondary
    )
    guard saveRouting(updatedRouting) else { return false }

    if providerId == .gemini {
      let preference = GeminiModelPreference.load()
      selectedGeminiModel = preference.primary
      savedGeminiModel = preference.primary
    }

    AnalyticsService.shared.setPersonProperties([
      "current_llm_provider": providerId.analyticsName,
      "current_llm_provider_id": providerId.rawValue,
    ])
    if shouldSwapWithSecondary {
      AnalyticsService.shared.capture(
        "provider_backup_updated",
        [
          "backup_provider": previousPrimary.rawValue,
          "provider_id": previousPrimary.rawValue,
          "primary_provider": providerId.rawValue,
        ])
    }
    AnalyticsService.shared.capture(
      "provider_primary_updated",
      [
        "from_provider": previousPrimary.rawValue,
        "to_provider": providerId.rawValue,
        "underlying_provider": providerId.rawValue,
        "provider_id": providerId.rawValue,
        "swapped_with_secondary": shouldSwapWithSecondary,
      ])
    return true
  }

  @discardableResult
  func assignSecondaryProvider(
    _ providerId: LLMProviderID,
    requiresReadinessCheck: Bool = true
  ) -> Bool {
    guard canModifyRouting else { return false }
    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return false
    }
    if requiresReadinessCheck {
      guard isProviderConfigured(providerId) else { return false }
    }

    if providerId == routing.secondary { return true }

    if providerId == routing.primary {
      guard let existingSecondary = routing.secondary else { return false }
      let previousPrimary = routing.primary
      let updatedRouting = LLMProviderRouting(
        primary: existingSecondary,
        secondary: previousPrimary
      )
      guard saveRouting(updatedRouting) else { return false }

      AnalyticsService.shared.setPersonProperties([
        "current_llm_provider": existingSecondary.analyticsName,
        "current_llm_provider_id": existingSecondary.rawValue,
      ])
      AnalyticsService.shared.capture(
        "provider_backup_updated",
        [
          "backup_provider": previousPrimary.rawValue,
          "provider_id": previousPrimary.rawValue,
          "primary_provider": existingSecondary.rawValue,
        ])
      AnalyticsService.shared.capture(
        "provider_secondary_updated",
        [
          "secondary_provider": previousPrimary.rawValue,
          "provider_id": previousPrimary.rawValue,
          "mode": "swap_with_primary",
        ])
      return true
    }

    let updatedRouting = LLMProviderRouting(primary: routing.primary, secondary: providerId)
    guard saveRouting(updatedRouting) else { return false }
    AnalyticsService.shared.capture(
      "provider_backup_updated",
      [
        "backup_provider": providerId.rawValue,
        "underlying_provider": providerId.rawValue,
        "provider_id": providerId.rawValue,
        "primary_provider": routing.primary.rawValue,
      ])
    AnalyticsService.shared.capture(
      "provider_secondary_updated",
      [
        "secondary_provider": providerId.rawValue,
        "underlying_provider": providerId.rawValue,
        "provider_id": providerId.rawValue,
        "mode": "set",
      ])
    return true
  }

  func canAssignPrimary(_ providerId: LLMProviderID) -> Bool {
    canModifyRouting && providerId != routing.primary && isProviderConfigured(providerId)
  }

  func canAssignSecondary(_ providerId: LLMProviderID) -> Bool {
    guard canModifyRouting else { return false }
    guard isProviderConfigured(providerId) else { return false }
    if providerId == routing.primary {
      return routing.secondary != nil
    }
    return true
  }

  func isProviderConfigured(_ providerId: LLMProviderID) -> Bool {
    switch providerId {
    case .dayflow:
      return isDayflowProActive
    case .gemini:
      let key = KeychainManager.shared.retrieve(for: "gemini") ?? ""
      return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .chatGPT:
      return codexCLIInstalled && LLMProviderSetupPreferences.isComplete(.chatGPT)
    case .claude:
      return claudeCLIInstalled && LLMProviderSetupPreferences.isComplete(.claude)
    case .openAICompatible:
      guard let configuration = OpenAICompatiblePreferences.load(), configuration.isComplete else {
        return false
      }
      if configuration.preset == .custom {
        return true
      }
      let key =
        KeychainManager.shared.retrieve(
          for: OpenAICompatiblePreferences.keychainProvider) ?? ""
      return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .local:
      let baseURL = (UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let modelId = (UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return !baseURL.isEmpty && !modelId.isEmpty
    }
  }

  func isProviderReadinessChecking(_ providerId: LLMProviderID) -> Bool {
    isCheckingCLIReadiness && (providerId == .chatGPT || providerId == .claude)
  }

  func clearBackupProvider() {
    guard canModifyRouting else { return }
    guard routing.secondary != nil else { return }
    let updatedRouting = LLMProviderRouting(primary: routing.primary)
    guard saveRouting(updatedRouting) else { return }
    AnalyticsService.shared.capture(
      "provider_backup_updated",
      [
        "backup_provider": "none",
        "provider_id": "none",
        "primary_provider": routing.primary.rawValue,
        "primary_provider_id": routing.primary.rawValue,
      ])
  }

  func isBackupProvider(_ providerId: LLMProviderID) -> Bool {
    routing.secondary == providerId
  }

  var backupProviderDisplayName: String {
    guard let backupProvider = routing.secondary else { return "Not configured" }
    return providerDisplayName(backupProvider)
  }

  var isDayflowProActive: Bool {
    let entitlement = DayflowAuthManager.shared.entitlements
    return entitlement.plan == "pro" && entitlement.status == "active"
  }

  func shouldShowDayflowUpgradeAction(for providerId: LLMProviderID) -> Bool {
    providerId == .dayflow && !isDayflowProActive
  }

  func openDayflowUpgradeAccount(from providerId: LLMProviderID) {
    openAccountForDayflowPro(providerId)
  }

  private func canUseProviderForRouting(_ providerId: LLMProviderID) -> Bool {
    providerId != .dayflow || isDayflowProActive
  }

  private func openAccountForDayflowPro(_ providerId: LLMProviderID) {
    guard providerId == .dayflow else { return }
    upgradeStatusMessage = "Dayflow Pro is required for hosted cards and transcription."
    openAccountForDayflowProvider(providerId)
  }

  private func openAccountForDayflowProvider(_ providerId: LLMProviderID) {
    guard providerId == .dayflow else { return }
    if isDayflowProActive {
      upgradeStatusMessage = "Manage Dayflow Pro from Account."
    }
    NotificationCenter.default.post(name: .openAccountSettings, object: nil)
    AnalyticsService.shared.capture(
      "dayflow_backend_provider_paywall_opened",
      [
        "provider": providerId.rawValue,
        "provider_id": providerId.rawValue,
        "is_signed_in": DayflowAuthManager.shared.isSignedIn,
        "entitlement_plan": DayflowAuthManager.shared.entitlements.plan,
        "entitlement_status": DayflowAuthManager.shared.entitlements.status,
      ])
  }

  @discardableResult
  private func saveRouting(_ updatedRouting: LLMProviderRouting) -> Bool {
    guard canModifyRouting else { return false }
    do {
      try LLMProviderRoutingStore.save(updatedRouting)
      withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
        routing = updatedRouting
      }
      providerRoutingErrorMessage = nil
      applyProviderChangeSideEffects(for: updatedRouting.primary)
      return true
    } catch {
      providerRoutingErrorMessage =
        "Dayflow couldn't save your provider routing. Your previous selection is still active."
      return false
    }
  }

  private func recordProviderSetupCompleted(_ providerId: LLMProviderID) {
    var properties: [String: Any] = [
      "provider": providerId.analyticsName,
      "provider_id": providerId.rawValue,
    ]
    if providerId == .local {
      properties["local_engine"] =
        UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
      properties["model_id"] =
        UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "unknown"
      let localAPIKey = (UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      properties["has_api_key"] = !localAPIKey.isEmpty
    } else if providerId == .chatGPT {
      properties["chat_cli_tool"] = "codex"
    } else if providerId == .claude {
      properties["chat_cli_tool"] = "claude"
    } else if providerId == .openAICompatible {
      properties["endpoint_kind"] = openAICompatiblePreset.rawValue
      properties["has_api_key"] =
        !openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    AnalyticsService.shared.capture("provider_setup_completed", properties)
  }

  func persistGeminiModelSelection(_ model: GeminiModel, source: String) {
    guard model != savedGeminiModel else { return }
    savedGeminiModel = model
    GeminiModelPreference(primary: model).save()

    Task { @MainActor in
      AnalyticsService.shared.capture(
        "gemini_model_selected",
        [
          "source": source,
          "model": model.rawValue,
        ])
    }
  }

  // MARK: - Chat CLI model selection (Claude / Codex)

  /// Re-runs the CLI probe to discover the live model list. Wired to
  /// the "Refresh" button in the Settings → Providers tab so users
  /// can force a re-probe after upgrading their subscription tier
  /// (which may unlock a model that wasn't available before).
  func refreshChatCLIModelCatalog(force: Bool = true) {
    guard !isDiscoveringChatCLIModels else { return }
    isDiscoveringChatCLIModels = true
    Task { [weak self] in
      let result = await ChatCLIModelCatalog.discover(refresh: force)
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.chatCLIModelCatalog = result
        self.isDiscoveringChatCLIModels = false
      }
    }
  }

  /// Persists the user's Claude model choice to `ClaudeModelPreference`
  /// and updates the cached catalog pick so the next batch uses the
  /// new model. No re-probe needed — the catalog already knows the
  /// alias is valid for this account.
  func persistClaudeModelSelection(_ model: ClaudeModel, source: String) {
    ClaudeModelPreference(primary: model).save()

    Task { @MainActor in
      AnalyticsService.shared.capture(
        "claude_model_selected",
        [
          "source": source,
          "model": model.rawValue,
        ])
    }
  }

  /// Persists the user's Codex model choice. Mirrors
  /// `persistClaudeModelSelection`.
  func persistCodexModelSelection(_ model: CodexModel, source: String) {
    CodexModelPreference(primary: model).save()

    Task { @MainActor in
      AnalyticsService.shared.capture(
        "codex_model_selected",
        [
          "source": source,
          "model": model.rawValue,
        ])
    }
  }

  /// Returns the picker rows for the Claude model section. Prefers
  /// the live catalog (which has display names like "Claude Sonnet 5")
  /// and falls back to the static enum list when the catalog is
  /// empty (e.g. CLI not installed or probe hasn't run yet).
  func claudeModelPickerRows() -> [DiscoveredChatCLIModel] {
    let catalogRows = chatCLIModelCatalog.claude
    if !catalogRows.isEmpty {
      return catalogRows
    }
    return ClaudeModel.allCases.map { alias in
      DiscoveredChatCLIModel(
        id: alias.rawValue,
        displayName: alias.displayName,
        fullName: alias.rawValue
      )
    }
  }

  /// Same as `claudeModelPickerRows` but for Codex.
  func codexModelPickerRows() -> [DiscoveredChatCLIModel] {
    let catalogRows = chatCLIModelCatalog.codex
    if !catalogRows.isEmpty {
      return catalogRows
    }
    return CodexModel.allCases.map { alias in
      DiscoveredChatCLIModel(
        id: alias.rawValue,
        displayName: alias.displayName,
        fullName: alias.rawValue
      )
    }
  }

  private var providerCatalog: [CompactProviderInfo] {
    [
      CompactProviderInfo(
        id: .dayflow,
        summary: "Hosted cards & transcription • no API keys • requires Pro"
      ),
      CompactProviderInfo(
        id: .claude,
        summary: "Uses Claude Code through your existing Claude plan"
      ),
      CompactProviderInfo(
        id: .chatGPT,
        summary: "Uses Codex CLI through your existing ChatGPT plan"
      ),
      CompactProviderInfo(
        id: .gemini,
        summary: "Gemini free tier • fast & accurate"
      ),
      CompactProviderInfo(
        id: .openAICompatible,
        summary: "OpenRouter or another OpenAI Chat Completions endpoint"
      ),
      CompactProviderInfo(
        id: .local,
        summary: "Private & offline • 16GB+ RAM • less intelligent"
      ),
    ]
  }

  func statusText(for providerId: LLMProviderID) -> String? {
    guard currentProvider == providerId else { return nil }

    switch providerId {
    case .local:
      let engineName: String
      switch localEngine {
      case .ollama: engineName = "Ollama"
      case .lmstudio: engineName = "LM Studio"
      case .custom: engineName = "Custom"
      }
      let displayModel = localModelId.isEmpty ? "qwen2.5vl:3b" : localModelId
      let truncatedModel =
        displayModel.count > 30 ? String(displayModel.prefix(27)) + "..." : displayModel
      return "\(engineName) - \(truncatedModel)"
    case .gemini:
      return selectedGeminiModel.displayName
    case .chatGPT:
      return cliStatusLabel(for: .chatGPT)
    case .claude:
      return cliStatusLabel(for: .claude)
    case .openAICompatible:
      return openAICompatibleModelID.isEmpty
        ? "OpenAI-compatible endpoint" : openAICompatibleModelID
    case .dayflow:
      return isDayflowProActive ? "Dayflow Pro active" : "Requires Dayflow Pro"
    }
  }

  func cliStatusLabel(for providerId: LLMProviderID) -> String {
    if isProviderReadinessChecking(providerId) {
      return "Checking installation…"
    }
    switch providerId {
    case .chatGPT:
      return codexCLIInstalled ? "Codex CLI detected" : "Codex CLI not detected"
    case .claude:
      return claudeCLIInstalled ? "Claude Code detected" : "Claude Code not detected"
    default:
      return "Not applicable"
    }
  }

  var connectionHealthLabel: String {
    switch currentProvider {
    case .gemini:
      return "Gemini API"
    case .local:
      return "Local API"
    case .chatGPT:
      return "Codex CLI"
    case .claude:
      return "Claude Code"
    case .openAICompatible:
      return "OpenAI-compatible API"
    case .dayflow:
      return "Dayflow Backend"
    }
  }

  func providerDisplayName(_ id: LLMProviderID) -> String {
    switch id {
    case .local: return "Local"
    case .gemini: return "Gemini"
    case .chatGPT: return "ChatGPT"
    case .claude: return "Claude"
    case .openAICompatible: return "OpenAI-compatible"
    case .dayflow: return "Dayflow Pro"
    }
  }

  // Prompt override load/persist/reset lives in
  // ProvidersSettingsViewModel+PromptOverrides.swift.
}

struct CompactProviderInfo: Identifiable {
  let id: LLMProviderID
  let summary: String

  var providerTableName: String {
    switch id {
    case .local: return "Local"
    case .gemini: return "Gemini"
    case .chatGPT: return "ChatGPT"
    case .claude: return "Claude"
    case .openAICompatible: return "OpenAI-compatible"
    case .dayflow: return "Dayflow Pro"
    }
  }
}

enum ProviderRoutingRole {
  case primary
  case secondary
  case setupOnly
}
