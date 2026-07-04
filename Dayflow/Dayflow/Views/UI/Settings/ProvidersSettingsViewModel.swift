import Foundation
import SwiftUI

@MainActor
final class ProvidersSettingsViewModel: ObservableObject {
  @Published var currentProvider: String = "gemini" {
    didSet {
      guard oldValue != currentProvider else { return }
      applyProviderChangeSideEffects(for: currentProvider)
    }
  }
  @Published var backupProvider: String?
  @Published var backupChatCLITool: CLITool?
  @Published var setupModalProvider: String? {
    didSet {
      if setupModalProvider == nil {
        pendingSetupRole = nil
        pendingSetupDisplayProviderId = nil
      }
    }
  }

  @Published var selectedGeminiModel: GeminiModel
  @Published var localEngine: LocalEngine {
    didSet {
      guard oldValue != localEngine else { return }
      guard !suppressLocalSettingsPersistence else { return }
      UserDefaults.standard.set(localEngine.rawValue, forKey: "llmLocalEngine")
      LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
      refreshUpgradeBannerState()
    }
  }
  @Published var localBaseURL: String {
    didSet {
      guard oldValue != localBaseURL else { return }
      guard !suppressLocalSettingsPersistence else { return }
      UserDefaults.standard.set(localBaseURL, forKey: "llmLocalBaseURL")
    }
  }
  @Published var localModelId: String {
    didSet {
      guard oldValue != localModelId else { return }
      guard !suppressLocalSettingsPersistence else { return }
      UserDefaults.standard.set(localModelId, forKey: "llmLocalModelId")
      LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
      refreshUpgradeBannerState()
    }
  }
  @Published var localAPIKey: String {
    didSet {
      guard oldValue != localAPIKey else { return }
      guard !suppressLocalSettingsPersistence else { return }
      persistLocalAPIKey(localAPIKey)
    }
  }
  @Published var showLocalModelUpgradeBanner = false
  @Published var isShowingLocalModelUpgradeSheet = false
  @Published var upgradeStatusMessage: String?
  @Published var preferredCLITool: CLITool?

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

  @Published var chatCLIPromptOverridesLoaded = false
  @Published var isUpdatingChatCLIPromptState = false
  @Published var useCustomChatCLITitlePrompt = false {
    didSet { persistChatCLIPromptOverridesIfReady() }
  }
  @Published var useCustomChatCLISummaryPrompt = false {
    didSet { persistChatCLIPromptOverridesIfReady() }
  }
  @Published var useCustomChatCLIDetailedPrompt = false {
    didSet { persistChatCLIPromptOverridesIfReady() }
  }
  @Published var chatCLITitlePromptText = ChatCLIPromptDefaults.titleBlock {
    didSet { persistChatCLIPromptOverridesIfReady() }
  }
  @Published var chatCLISummaryPromptText = ChatCLIPromptDefaults.summaryBlock {
    didSet { persistChatCLIPromptOverridesIfReady() }
  }
  @Published var chatCLIDetailedPromptText = ChatCLIPromptDefaults.detailedSummaryBlock {
    didSet { persistChatCLIPromptOverridesIfReady() }
  }

  private var hasLoadedProvider = false
  private var savedGeminiModel: GeminiModel
  private var pendingSetupRole: ProviderRoutingRole?
  private var pendingSetupDisplayProviderId: String?
  private var suppressLocalSettingsPersistence = false

  init() {
    let preference = GeminiModelPreference.load()
    selectedGeminiModel = preference.primary
    savedGeminiModel = preference.primary

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
    if let raw = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") {
      preferredCLITool = CLITool(rawValue: raw)
    } else {
      preferredCLITool = nil
    }
  }

  func handleOnAppear() {
    DayflowAuthManager.shared.loadStoredSessionIfNeeded()
    loadCurrentProvider()
    loadBackupProvider()
    reloadLocalProviderSettings()
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
    refreshUpgradeBannerState()
    loadGeminiPromptOverridesIfNeeded()
    loadOllamaPromptOverridesIfNeeded()
    loadChatCLIPromptOverridesIfNeeded()
  }

  func handleLocalTestCompletion() {
    UserDefaults.standard.set(localBaseURL, forKey: "llmLocalBaseURL")
    UserDefaults.standard.set(localModelId, forKey: "llmLocalModelId")
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
    persistLocalAPIKey(localAPIKey)
    refreshUpgradeBannerState()
  }

  func markUpgradeBannerKeepLegacy() {
    LocalModelPreferences.markUpgradeDismissed(true)
    showLocalModelUpgradeBanner = false
  }

  func markUpgradeBannerUpgrade() {
    LocalModelPreferences.markUpgradeDismissed(false)
  }

  func applyProviderChangeSideEffects(for provider: String) {
    reloadLocalProviderSettings()
    ensureBackupProviderIsValid(primaryProvider: provider)
    if provider == "gemini" {
      loadGeminiPromptOverridesIfNeeded(force: true)
    } else if provider == "ollama" {
      loadOllamaPromptOverridesIfNeeded(force: true)
    } else if provider == "chatgpt_claude" {
      loadChatCLIPromptOverridesIfNeeded(force: true)
    }
    refreshUpgradeBannerState()
  }

  func reloadLocalProviderSettings() {
    localBaseURL = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? localBaseURL
    localModelId = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? localModelId
    localAPIKey = UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? localAPIKey
    let raw = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? localEngine.rawValue
    localEngine = LocalEngine(rawValue: raw) ?? localEngine
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
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
    showLocalModelUpgradeBanner = shouldShow && currentProvider == "ollama"
  }

  func handleUpgradeSuccess(engine: LocalEngine, baseURL: String, modelId: String, apiKey: String) {
    let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    localEngine = engine
    localBaseURL = baseURL
    localModelId = modelId
    localAPIKey = normalizedKey
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

  func loadCurrentProvider() {
    guard !hasLoadedProvider else { return }

    let providerType = LLMProviderType.load()
    switch providerType {
    case .geminiDirect:
      currentProvider = "gemini"
      let preference = GeminiModelPreference.load()
      selectedGeminiModel = preference.primary
      savedGeminiModel = preference.primary
    case .dayflowBackend:
      currentProvider = "dayflow"
    case .ollamaLocal:
      currentProvider = "ollama"
    case .chatGPTClaude:
      currentProvider = "chatgpt_claude"
    }
    hasLoadedProvider = true
  }

  func loadBackupProvider() {
    let stored = LLMProviderRoutingPreferences.loadBackupProvider()
    guard let stored else {
      backupProvider = nil
      backupChatCLITool = nil
      return
    }

    let raw = stored.rawValue
    guard raw != currentProvider else {
      backupProvider = nil
      backupChatCLITool = nil
      LLMProviderRoutingPreferences.saveBackupProvider(nil)
      LLMProviderRoutingPreferences.saveBackupChatCLITool(nil)
      return
    }

    guard canUseProviderForRouting(raw) else {
      backupProvider = nil
      backupChatCLITool = nil
      LLMProviderRoutingPreferences.saveBackupProvider(nil)
      LLMProviderRoutingPreferences.saveBackupChatCLITool(nil)
      return
    }

    backupProvider = raw
    if stored == .chatGPTClaude {
      let backupTool = LLMProviderRoutingPreferences.loadBackupChatCLITool()
      backupChatCLITool = backupTool.flatMap { CLITool(rawValue: $0.rawValue) } ?? preferredCLITool
    } else {
      backupChatCLITool = nil
      LLMProviderRoutingPreferences.saveBackupChatCLITool(nil)
    }
  }

  var routingProviders: [CompactProviderInfo] {
    providerCatalog
  }

  func beginProviderSetup(_ providerId: String, role: ProviderRoutingRole) {
    guard providerCatalog.contains(where: { $0.id == providerId }) else { return }
    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return
    }

    pendingSetupRole = role
    pendingSetupDisplayProviderId = providerId
    setupModalProvider = canonicalProviderId(for: providerId)
  }

  func editProviderConfiguration(_ providerId: String) {
    guard providerCatalog.contains(where: { $0.id == providerId }) else { return }
    if canonicalProviderId(for: providerId) == "dayflow" {
      openAccountForDayflowProvider(providerId)
      return
    }

    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return
    }

    pendingSetupRole = .setupOnly
    pendingSetupDisplayProviderId = providerId
    setupModalProvider = canonicalProviderId(for: providerId)
  }

  func handleProviderSetupCompletion(_ providerId: String) {
    recordProviderSetupCompleted(providerId)

    if canonicalProviderId(for: providerId) == "ollama" {
      reloadLocalProviderSettings()
    }

    let role = pendingSetupRole ?? .setupOnly
    let displayProviderId =
      pendingSetupDisplayProviderId
      ?? displayProviderId(
        canonicalProviderId: providerId,
        preferredTool: preferredCLITool
      )
    pendingSetupRole = nil
    pendingSetupDisplayProviderId = nil

    switch role {
    case .primary:
      assignPrimaryProvider(displayProviderId)
    case .secondary:
      assignSecondaryProvider(displayProviderId)
    case .setupOnly:
      break
    }
  }

  func setPrimaryOrSetup(_ providerId: String) {
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

  func setSecondaryOrSetup(_ providerId: String) {
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

  var primaryRoutingProviderId: String {
    displayProviderId(canonicalProviderId: currentProvider, preferredTool: preferredCLITool)
  }

  var secondaryRoutingProviderId: String? {
    guard let backupProvider else { return nil }
    return displayProviderId(
      canonicalProviderId: backupProvider,
      preferredTool: backupChatCLITool ?? preferredCLITool
    )
  }

  func assignPrimaryProvider(_ providerId: String) {
    print(
      "🧭 [ProvidersSettings] assign primary requested provider=\(providerId) "
        + "current=\(primaryRoutingProviderId) signed_in=\(DayflowAuthManager.shared.isSignedIn) "
        + "pro_active=\(isDayflowProActive)"
    )
    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return
    }

    guard canAssignPrimary(providerId) else { return }

    let previousPrimaryDisplay = primaryRoutingProviderId
    let shouldSwapWithSecondary = secondaryRoutingProviderId == providerId
    let canonicalId = canonicalProviderId(for: providerId)
    let selectedTool = chatTool(for: providerId)

    applyPrimaryProvider(canonicalId, preferredChatTool: selectedTool)
    if shouldSwapWithSecondary {
      persistBackupSelection(displayProviderId: previousPrimaryDisplay, emitAnalytics: true)
    }

    AnalyticsService.shared.capture(
      "provider_primary_updated",
      [
        "from_provider": previousPrimaryDisplay,
        "to_provider": providerId,
        "underlying_provider": canonicalId,
        "swapped_with_secondary": shouldSwapWithSecondary,
      ])
  }

  func assignSecondaryProvider(_ providerId: String) {
    guard canUseProviderForRouting(providerId) else {
      openAccountForDayflowPro(providerId)
      return
    }

    guard canAssignSecondary(providerId) else { return }

    let currentPrimaryProviderId = primaryRoutingProviderId
    if providerId == currentPrimaryProviderId {
      guard let existingBackup = secondaryRoutingProviderId else { return }
      let previousPrimary = currentPrimaryProviderId

      applyPrimaryProvider(
        canonicalProviderId(for: existingBackup),
        preferredChatTool: chatTool(for: existingBackup)
      )
      persistBackupSelection(displayProviderId: previousPrimary, emitAnalytics: true)

      AnalyticsService.shared.capture(
        "provider_secondary_updated",
        [
          "secondary_provider": previousPrimary,
          "mode": "swap_with_primary",
        ])
      return
    }

    persistBackupSelection(displayProviderId: providerId, emitAnalytics: true)
    AnalyticsService.shared.capture(
      "provider_secondary_updated",
      [
        "secondary_provider": providerId,
        "underlying_provider": canonicalProviderId(for: providerId),
        "mode": "set",
      ])
  }

  func canAssignPrimary(_ providerId: String) -> Bool {
    providerId != primaryRoutingProviderId && isProviderConfigured(providerId)
  }

  func canAssignSecondary(_ providerId: String) -> Bool {
    guard isProviderConfigured(providerId) else { return false }

    let currentPrimaryProviderId = primaryRoutingProviderId
    if providerId == currentPrimaryProviderId {
      return secondaryRoutingProviderId != nil
    }

    let targetCanonical = canonicalProviderId(for: providerId)
    let primaryCanonical = canonicalProviderId(for: currentPrimaryProviderId)
    if targetCanonical == primaryCanonical {
      return false
    }

    return true
  }

  func isProviderConfigured(_ providerId: String) -> Bool {
    if providerId == primaryRoutingProviderId {
      return true
    }

    switch canonicalProviderId(for: providerId) {
    case "gemini":
      if let key = KeychainManager.shared.retrieve(for: "gemini") {
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return UserDefaults.standard.bool(forKey: "geminiSetupComplete")
    case "ollama":
      if UserDefaults.standard.bool(forKey: "ollamaSetupComplete") {
        return true
      }
      let baseURL = (UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let modelId = (UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return !baseURL.isEmpty && !modelId.isEmpty
    case "chatgpt_claude":
      if UserDefaults.standard.bool(forKey: "chatgpt_claudeSetupComplete") {
        return true
      }
      let preferredTool = (UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return !preferredTool.isEmpty
    case "dayflow":
      return isDayflowProActive
    default:
      return false
    }
  }

  func setBackupProvider(_ providerId: String?) {
    guard let providerId, !providerId.isEmpty else {
      persistBackupSelection(displayProviderId: nil, emitAnalytics: true)
      return
    }

    guard canAssignSecondary(providerId) else {
      if !canUseProviderForRouting(providerId) {
        openAccountForDayflowPro(providerId)
      }
      return
    }

    persistBackupSelection(displayProviderId: providerId, emitAnalytics: true)
  }

  func clearBackupProvider() {
    setBackupProvider(nil)
  }

  func isBackupProvider(_ providerId: String) -> Bool {
    secondaryRoutingProviderId == providerId
  }

  /// True when the user is allowed to wipe the persisted config (keychain
  /// entries, setup flags, endpoint URLs, etc.) for this provider. We
  /// refuse to remove the config of the active primary so the app never
  /// ends up in a state with no working primary.
  func canRemoveProviderConfig(_ providerId: String) -> Bool {
    let canonical = canonicalProviderId(for: providerId)
    // Dayflow Pro is a server-side entitlement, not local config.
    guard canonical != "dayflow" else { return false }
    guard isProviderConfigured(providerId) else { return false }
    guard canonicalProviderId(for: primaryRoutingProviderId) != canonical else { return false }
    return true
  }

  /// Wipes the persisted configuration for a provider — keychain entries,
  /// setup-complete flags, model selections, endpoint URLs, CLI tool
  /// preference. If the provider is currently the secondary slot, also
  /// clears the backup assignment so we don't leave a dangling reference.
  func removeProviderConfig(_ providerId: String) {
    guard canRemoveProviderConfig(providerId) else { return }
    let canonical = canonicalProviderId(for: providerId)

    if let backupProvider, backupProvider == canonical {
      clearBackupProvider()
    }

    switch canonical {
    case "gemini":
      KeychainManager.shared.delete(for: "gemini")
      UserDefaults.standard.removeObject(forKey: "geminiSetupComplete")
      GeminiModelPreference.clear()
    case "ollama":
      UserDefaults.standard.removeObject(forKey: "ollamaSetupComplete")
      UserDefaults.standard.removeObject(forKey: "llmLocalBaseURL")
      UserDefaults.standard.removeObject(forKey: "llmLocalModelId")
      UserDefaults.standard.removeObject(forKey: "llmLocalEngine")
      UserDefaults.standard.removeObject(forKey: "llmLocalAPIKey")
      LocalModelPreferences.clearPreset()
      resetLocalProviderFieldsAfterRemoval()
    case "chatgpt_claude":
      UserDefaults.standard.removeObject(forKey: "chatgpt_claudeSetupComplete")
      UserDefaults.standard.removeObject(forKey: "chatCLIPreferredTool")
      preferredCLITool = nil
    default:
      return
    }

    AnalyticsService.shared.capture(
      "provider_config_removed",
      [
        "provider": providerId,
        "underlying_provider": canonical,
      ])
    objectWillChange.send()
  }

  private func resetLocalProviderFieldsAfterRemoval() {
    suppressLocalSettingsPersistence = true
    defer { suppressLocalSettingsPersistence = false }

    localEngine = .ollama
    localBaseURL = LocalEngine.ollama.defaultBaseURL
    localModelId = LocalModelPreferences.defaultModelId(for: .ollama)
    localAPIKey = ""
    showLocalModelUpgradeBanner = false
  }

  var backupProviderDisplayName: String {
    guard let backupProvider = secondaryRoutingProviderId else { return "Not configured" }
    return providerDisplayName(backupProvider)
  }

  var isDayflowProActive: Bool {
    let entitlement = DayflowAuthManager.shared.entitlements
    return entitlement.plan == "pro" && entitlement.status == "active"
  }

  func shouldShowDayflowUpgradeAction(for providerId: String) -> Bool {
    canonicalProviderId(for: providerId) == "dayflow" && !isDayflowProActive
  }

  func openDayflowUpgradeAccount(from providerId: String) {
    openAccountForDayflowPro(providerId)
  }

  private func canUseProviderForRouting(_ providerId: String) -> Bool {
    canonicalProviderId(for: providerId) != "dayflow" || isDayflowProActive
  }

  private func openAccountForDayflowPro(_ providerId: String) {
    guard canonicalProviderId(for: providerId) == "dayflow" else { return }
    upgradeStatusMessage = "Dayflow Pro is required for hosted cards and transcription."
    openAccountForDayflowProvider(providerId)
  }

  private func openAccountForDayflowProvider(_ providerId: String) {
    guard canonicalProviderId(for: providerId) == "dayflow" else { return }
    if isDayflowProActive {
      upgradeStatusMessage = "Manage Dayflow Pro from Account."
    }
    NotificationCenter.default.post(name: .openAccountSettings, object: nil)
    AnalyticsService.shared.capture(
      "dayflow_backend_provider_paywall_opened",
      [
        "provider": providerId,
        "is_signed_in": DayflowAuthManager.shared.isSignedIn,
        "entitlement_plan": DayflowAuthManager.shared.entitlements.plan,
        "entitlement_status": DayflowAuthManager.shared.entitlements.status,
      ])
  }

  private func ensureBackupProviderIsValid(primaryProvider: String) {
    guard let backupProvider else { return }
    if backupProvider == primaryProvider {
      persistBackupSelection(displayProviderId: nil, emitAnalytics: false)
    }
  }

  private func applyPrimaryProvider(_ providerId: String, preferredChatTool: CLITool? = nil) {
    let providerType: LLMProviderType
    switch providerId {
    case "ollama":
      let endpoint =
        UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "http://localhost:11434"
      providerType = .ollamaLocal(endpoint: endpoint)
    case "gemini":
      providerType = .geminiDirect
    case "dayflow":
      providerType = .dayflowBackend()
    case "chatgpt_claude":
      providerType = .chatGPTClaude
    default:
      return
    }

    providerType.persist()
    print(
      "✅ [ProvidersSettings] persisted primary provider=\(providerId) "
        + "canonical=\(providerType.canonicalProviderID) "
        + "stored_selected=\(UserDefaults.standard.string(forKey: "selectedLLMProvider") ?? "nil")"
    )

    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
      currentProvider = providerId
    }

    if providerId == "chatgpt_claude", let preferredChatTool {
      preferredCLITool = preferredChatTool
      UserDefaults.standard.set(preferredChatTool.rawValue, forKey: "chatCLIPreferredTool")
    }

    if providerId == "gemini" {
      let preference = GeminiModelPreference.load()
      selectedGeminiModel = preference.primary
      savedGeminiModel = preference.primary
    }

    AnalyticsService.shared.setPersonProperties(["current_llm_provider": providerId])
  }

  private func persistBackupSelection(displayProviderId: String?, emitAnalytics: Bool) {
    guard let displayProviderId, !displayProviderId.isEmpty else {
      backupProvider = nil
      backupChatCLITool = nil
      LLMProviderRoutingPreferences.saveBackupProvider(nil)
      LLMProviderRoutingPreferences.saveBackupChatCLITool(nil)
      if emitAnalytics {
        AnalyticsService.shared.capture(
          "provider_backup_updated",
          [
            "backup_provider": "none",
            "primary_provider": currentProvider,
          ])
      }
      return
    }

    let providerId = canonicalProviderId(for: displayProviderId)
    guard providerId != currentProvider,
      let provider = LLMProviderID(rawValue: providerId),
      canUseProviderForRouting(displayProviderId)
    else {
      return
    }

    let backupTool = chatTool(for: displayProviderId) ?? preferredCLITool
    backupProvider = providerId
    backupChatCLITool = backupTool
    LLMProviderRoutingPreferences.saveBackupProvider(provider)
    let routingTool = backupTool.flatMap { ChatCLITool(rawValue: $0.rawValue) }
    LLMProviderRoutingPreferences.saveBackupChatCLITool(routingTool)
    if emitAnalytics {
      AnalyticsService.shared.capture(
        "provider_backup_updated",
        [
          "backup_provider": displayProviderId,
          "underlying_provider": providerId,
          "primary_provider": currentProvider,
        ])
    }
  }

  private func recordProviderSetupCompleted(_ providerId: String) {
    var props: [String: Any] = ["provider": providerId]
    if providerId == "ollama" {
      let localEngineValue = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
      let localModelValue = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "unknown"
      let localBaseValue = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "unknown"
      let localAPIKeyValue = (UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      props["local_engine"] = localEngineValue
      props["model_id"] = localModelValue
      props["base_url"] = localBaseValue
      props["has_api_key"] = !localAPIKeyValue.isEmpty
    } else if providerId == "chatgpt_claude" {
      props["chat_cli_tool"] =
        UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "unknown"
    }
    AnalyticsService.shared.capture("provider_setup_completed", props)
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

  private var providerCatalog: [CompactProviderInfo] {
    [
      CompactProviderInfo(
        id: "dayflow",
        title: "Dayflow Pro",
        summary: "Hosted cards & transcription • no API keys • requires Pro",
        badgeText: "PRO",
        badgeType: .blue,
        icon: "sparkles"
      ),
      CompactProviderInfo(
        id: "claude",
        title: "Claude",
        summary: "Uses Claude Code through your existing Claude plan",
        badgeText: "NEW",
        badgeType: .blue,
        icon: "ClaudeLogo"
      ),
      CompactProviderInfo(
        id: "chatgpt",
        title: "ChatGPT",
        summary: "Uses Codex CLI through your existing ChatGPT plan",
        badgeText: "NEW",
        badgeType: .blue,
        icon: "ChatGPTLogo"
      ),
      CompactProviderInfo(
        id: "gemini",
        title: "Gemini",
        summary: "Gemini free tier • fast & accurate",
        badgeText: "RECOMMENDED",
        badgeType: .orange,
        icon: "gemini_asset"
      ),
      CompactProviderInfo(
        id: "ollama",
        title: "Local",
        summary: "Private & offline • 16GB+ RAM • less intelligent",
        badgeText: "MOST PRIVATE",
        badgeType: .green,
        icon: "desktopcomputer"
      ),
    ]
  }

  func statusText(for providerId: String) -> String? {
    let canonicalId = canonicalProviderId(for: providerId)
    guard currentProvider == canonicalId else { return nil }

    switch canonicalId {
    case "ollama":
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
    case "gemini":
      return selectedGeminiModel.displayName
    case "chatgpt_claude":
      if providerId == "chatgpt" {
        return "ChatGPT – Codex CLI"
      }
      if providerId == "claude" {
        return "Claude Code CLI"
      }
      return chatCLIStatusLabel()
    case "dayflow":
      return isDayflowProActive ? "Dayflow Pro active" : "Requires Dayflow Pro"
    default:
      return nil
    }
  }

  func chatCLIStatusLabel() -> String {
    let preferredTool = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? ""
    switch preferredTool {
    case "codex":
      return "ChatGPT – Codex CLI"
    case "claude":
      return "Claude Code CLI"
    default:
      return "Codex or Claude CLI"
    }
  }

  var connectionHealthLabel: String {
    switch currentProvider {
    case "gemini":
      return "Gemini API"
    case "ollama":
      return "Local API"
    case "chatgpt_claude":
      if let tool = preferredCLITool {
        return "\(tool.shortName) CLI"
      }
      return "ChatGPT / Claude CLI"
    case "dayflow":
      return "Dayflow Backend"
    default:
      return "Diagnostics"
    }
  }

  func providerDisplayName(_ id: String) -> String {
    switch id {
    case "ollama": return "Local"
    case "gemini": return "Gemini"
    case "chatgpt": return "ChatGPT"
    case "claude": return "Claude"
    case "chatgpt_claude":
      if let preferredCLITool {
        return preferredCLITool == .codex ? "ChatGPT" : "Claude"
      }
      return "ChatGPT or Claude"
    case "dayflow": return "Dayflow Pro"
    default: return id.capitalized
    }
  }

  func canonicalProviderId(for displayProviderId: String) -> String {
    switch displayProviderId {
    case "chatgpt", "claude", "chatgpt_claude":
      return "chatgpt_claude"
    default:
      return displayProviderId
    }
  }

  private func displayProviderId(canonicalProviderId: String, preferredTool: CLITool?) -> String {
    if canonicalProviderId == "chatgpt_claude" {
      return preferredTool == .claude ? "claude" : "chatgpt"
    }
    return canonicalProviderId
  }

  private func chatTool(for providerId: String) -> CLITool? {
    switch providerId {
    case "chatgpt":
      return .codex
    case "claude":
      return .claude
    case "chatgpt_claude":
      return preferredCLITool
    default:
      return nil
    }
  }

  // Prompt override load/persist/reset lives in
  // ProvidersSettingsViewModel+PromptOverrides.swift.
}

struct CompactProviderInfo: Identifiable {
  let id: String
  let title: String
  let summary: String
  let badgeText: String
  let badgeType: BadgeType
  let icon: String

  var providerTableName: String {
    switch id {
    case "ollama": return "Local"
    case "gemini": return "Gemini"
    case "chatgpt": return "ChatGPT"
    case "claude": return "Claude"
    case "chatgpt_claude": return "ChatGPT / Claude"
    default: return title
    }
  }
}

enum ProviderRoutingRole {
  case primary
  case secondary
  case setupOnly
}
