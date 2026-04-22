import AppKit
import SwiftUI

struct SettingsProvidersTabView: View {
  @ObservedObject var viewModel: ProvidersSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      if viewModel.currentProvider == "ollama", viewModel.showLocalModelUpgradeBanner {
        LocalModelUpgradeBanner(
          preset: .qwen3VL4B,
          onKeepLegacy: { viewModel.markUpgradeBannerKeepLegacy() },
          onUpgrade: {
            viewModel.markUpgradeBannerUpgrade()
            viewModel.isShowingLocalModelUpgradeSheet = true
          }
        )
        .transition(.opacity)
      }

      if let status = viewModel.upgradeStatusMessage {
        Text(status)
          .font(.custom("Nunito", size: 13))
          .foregroundColor(SettingsStyle.statusGood)
      }

      currentConfigurationSection
      connectionHealthSection
      failoverRoutingSection

      if viewModel.currentProvider == "gemini" {
        geminiModelSection
      }

      promptCustomizationSection
    }
  }

  // MARK: - Current configuration

  private var currentConfigurationSection: some View {
    SettingsSection(
      title: "Current configuration",
      subtitle: "Active provider and runtime details."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        summaryRows

        HStack(spacing: 8) {
          SettingsSecondaryButton(
            title: "Edit configuration",
            action: { viewModel.editProviderConfiguration(viewModel.primaryRoutingProviderId) }
          )

          if viewModel.currentProvider == "ollama" {
            SettingsSecondaryButton(
              title: viewModel.usingRecommendedLocalModel
                ? "Manage local model" : "Upgrade local model",
              action: { viewModel.isShowingLocalModelUpgradeSheet = true }
            )
          }
        }
        .padding(.top, 18)
      }
    }
  }

  @ViewBuilder
  private var summaryRows: some View {
    SettingsRow(label: "Primary provider") {
      HStack(spacing: 8) {
        SettingsMetadata(
          text: viewModel.providerDisplayName(viewModel.primaryRoutingProviderId))
        SettingsBadge(text: "PRIMARY", isAccent: true)
      }
    }

    if let backupProvider = viewModel.secondaryRoutingProviderId {
      SettingsRow(label: "Secondary provider") {
        HStack(spacing: 8) {
          SettingsMetadata(text: viewModel.providerDisplayName(backupProvider))
          SettingsBadge(text: "SECONDARY")
        }
      }
    } else {
      SettingsRow(label: "Secondary provider") {
        SettingsMetadata(text: "Not configured")
      }
    }

    switch viewModel.currentProvider {
    case "ollama":
      SettingsRow(label: "Engine") { SettingsMetadata(text: viewModel.localEngine.displayName) }
      SettingsRow(label: "Model") {
        SettingsMetadata(
          text: viewModel.localModelId.isEmpty ? "Not configured" : viewModel.localModelId)
      }
      SettingsRow(label: "Endpoint") { SettingsMetadata(text: viewModel.localBaseURL) }
      let hasKey = !viewModel.localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      SettingsRow(label: "API key", showsDivider: false) {
        SettingsMetadata(text: hasKey ? "Stored in UserDefaults" : "Not set")
      }
    case "gemini":
      SettingsRow(label: "Model preference") {
        SettingsMetadata(text: viewModel.selectedGeminiModel.displayName)
      }
      SettingsRow(label: "API key", showsDivider: false) {
        SettingsMetadata(
          text: KeychainManager.shared.retrieve(for: "gemini") != nil
            ? "Stored safely in Keychain" : "Not set")
      }
    case "chatgpt_claude":
      SettingsRow(label: "CLI preference") {
        SettingsMetadata(text: viewModel.chatCLIStatusLabel())
      }
      SettingsRow(label: "Status", showsDivider: false) {
        SettingsMetadata(text: "Use Edit configuration to re-run CLI checks")
      }
    default:
      SettingsRow(label: "Status", showsDivider: false) {
        SettingsMetadata(text: "Coming soon")
      }
    }
  }

  // MARK: - Connection health

  private var connectionHealthSection: some View {
    SettingsSection(
      title: "Connection health",
      subtitle: "Run a quick test for the primary provider."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        Text(viewModel.connectionHealthLabel)
          .font(.custom("Nunito", size: 13))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)

        switch viewModel.currentProvider {
        case "gemini":
          TestConnectionView(onTestComplete: { _ in })
        case "ollama":
          LocalLLMTestView(
            baseURL: $viewModel.localBaseURL,
            modelId: $viewModel.localModelId,
            apiKey: $viewModel.localAPIKey,
            engine: viewModel.localEngine,
            showInputs: viewModel.localEngine == .custom,
            onTestComplete: { _ in viewModel.handleLocalTestCompletion() }
          )
        case "chatgpt_claude":
          ChatCLITestView(
            selectedTool: viewModel.preferredCLITool,
            onTestComplete: { _ in }
          )
        default:
          Text("Dayflow Pro diagnostics coming soon")
            .font(.custom("Nunito", size: 13))
            .foregroundColor(SettingsStyle.secondary)
        }
      }
    }
  }

  // MARK: - Failover routing

  private var failoverRoutingSection: some View {
    SettingsSection(
      title: "Failover routing",
      subtitle: "Choose primary and secondary providers."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        let providers = viewModel.routingProviders
        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
          routingRow(
            provider: provider,
            showsDivider: index < providers.count - 1
          )
        }
      }
    }
  }

  private func routingRow(
    provider: CompactProviderInfo,
    showsDivider: Bool
  ) -> some View {
    let isConfigured = viewModel.isProviderConfigured(provider.id)
    let isPrimary = viewModel.primaryRoutingProviderId == provider.id
    let isSecondary = viewModel.isBackupProvider(provider.id)
    let canSetSecondary = viewModel.canAssignSecondary(provider.id) || !isConfigured

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        Text(provider.providerTableName)
          .font(.custom("Nunito", size: 14))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)

        Spacer()

        if isPrimary {
          SettingsBadge(text: "PRIMARY", isAccent: true)
        } else if isSecondary {
          SettingsBadge(text: "SECONDARY")
        } else if isConfigured {
          SettingsBadge(text: "CONFIGURED")
        } else {
          SettingsBadge(text: "NOT SET")
        }
      }

      Text(provider.summary)
        .font(.custom("Nunito", size: 12))
        .foregroundColor(SettingsStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        if !isConfigured {
          SettingsSecondaryButton(title: "Setup") {
            viewModel.beginProviderSetup(provider.id, role: .setupOnly)
          }
        }

        SettingsSecondaryButton(title: "Edit configuration") {
          viewModel.editProviderConfiguration(provider.id)
        }

        if !isPrimary {
          SettingsSecondaryButton(title: "Set primary") {
            viewModel.setPrimaryOrSetup(provider.id)
          }
        }

        if !isSecondary {
          SettingsSecondaryButton(title: "Set secondary", isDisabled: !canSetSecondary) {
            viewModel.setSecondaryOrSetup(provider.id)
          }
        }
      }
    }
    .padding(.vertical, 14)
    .overlay(alignment: .bottom) {
      if showsDivider {
        Rectangle().fill(SettingsStyle.divider).frame(height: 1)
      }
    }
  }

  // MARK: - Gemini model preference

  private var geminiModelSection: some View {
    SettingsSection(
      title: "Gemini model preference",
      subtitle: "Choose which Gemini model Dayflow should prioritize."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        Picker("Gemini model", selection: $viewModel.selectedGeminiModel) {
          ForEach(GeminiModel.allCases, id: \.self) { model in
            Text(model.displayName).tag(model)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .environment(\.colorScheme, .light)
        .onChange(of: viewModel.selectedGeminiModel) { _, newValue in
          viewModel.persistGeminiModelSelection(newValue, source: "settings")
        }

        Text(GeminiModelPreference(primary: viewModel.selectedGeminiModel).fallbackSummary)
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.secondary)

        Text(
          "Dayflow automatically downgrades if your chosen model is rate limited or unavailable."
        )
        .font(.custom("Nunito", size: 11))
        .foregroundColor(SettingsStyle.meta)
      }
    }
  }

  // MARK: - Prompt customization

  @ViewBuilder
  private var promptCustomizationSection: some View {
    switch viewModel.currentProvider {
    case "gemini":
      promptSection(
        title: "Gemini prompt customization",
        subtitle: "Override Dayflow's defaults to tailor card generation.",
        intro:
          "Overrides apply only when their toggle is on. Unchecked sections fall back to Dayflow's defaults.",
        sections: [
          promptEditorConfig(
            heading: "Card titles",
            description: "Shape how card titles read and tweak the example list.",
            isEnabled: $viewModel.useCustomGeminiTitlePrompt,
            text: $viewModel.geminiTitlePromptText,
            defaultText: GeminiPromptDefaults.titleBlock
          ),
          promptEditorConfig(
            heading: "Card summaries",
            description: "Control tone and style for the summary field.",
            isEnabled: $viewModel.useCustomGeminiSummaryPrompt,
            text: $viewModel.geminiSummaryPromptText,
            defaultText: GeminiPromptDefaults.summaryBlock
          ),
          promptEditorConfig(
            heading: "Detailed summaries",
            description: "Define the minute-by-minute breakdown format and examples.",
            isEnabled: $viewModel.useCustomGeminiDetailedPrompt,
            text: $viewModel.geminiDetailedPromptText,
            defaultText: GeminiPromptDefaults.detailedSummaryBlock
          ),
        ],
        onReset: viewModel.resetGeminiPromptOverrides
      )
    case "ollama":
      promptSection(
        title: "Local prompt customization",
        subtitle: "Adjust the prompts used for local timeline summaries.",
        intro: "Customize the local model prompts for summary and title generation.",
        sections: [
          promptEditorConfig(
            heading: "Timeline summaries",
            description: "Control how the local model writes its 2-3 sentence card summaries.",
            isEnabled: $viewModel.useCustomOllamaSummaryPrompt,
            text: $viewModel.ollamaSummaryPromptText,
            defaultText: OllamaPromptDefaults.summaryBlock
          ),
          promptEditorConfig(
            heading: "Card titles",
            description: "Adjust the tone and examples for local title generation.",
            isEnabled: $viewModel.useCustomOllamaTitlePrompt,
            text: $viewModel.ollamaTitlePromptText,
            defaultText: OllamaPromptDefaults.titleBlock
          ),
        ],
        onReset: viewModel.resetOllamaPromptOverrides
      )
    case "chatgpt_claude":
      promptSection(
        title: "ChatGPT / Claude prompt customization",
        subtitle: "Override Dayflow's defaults to tailor card generation.",
        intro:
          "Overrides apply only when their toggle is on. Unchecked sections fall back to Dayflow's defaults.",
        sections: [
          promptEditorConfig(
            heading: "Card titles",
            description: "Shape how card titles read and tweak the example list.",
            isEnabled: $viewModel.useCustomChatCLITitlePrompt,
            text: $viewModel.chatCLITitlePromptText,
            defaultText: ChatCLIPromptDefaults.titleBlock
          ),
          promptEditorConfig(
            heading: "Card summaries",
            description: "Control tone and style for the summary field.",
            isEnabled: $viewModel.useCustomChatCLISummaryPrompt,
            text: $viewModel.chatCLISummaryPromptText,
            defaultText: ChatCLIPromptDefaults.summaryBlock
          ),
          promptEditorConfig(
            heading: "Detailed summaries",
            description: "Define the minute-by-minute breakdown format and examples.",
            isEnabled: $viewModel.useCustomChatCLIDetailedPrompt,
            text: $viewModel.chatCLIDetailedPromptText,
            defaultText: ChatCLIPromptDefaults.detailedSummaryBlock
          ),
        ],
        onReset: viewModel.resetChatCLIPromptOverrides
      )
    default:
      EmptyView()
    }
  }

  private struct PromptEditorConfig {
    let heading: String
    let description: String
    let isEnabled: Binding<Bool>
    let text: Binding<String>
    let defaultText: String
  }

  private func promptEditorConfig(
    heading: String,
    description: String,
    isEnabled: Binding<Bool>,
    text: Binding<String>,
    defaultText: String
  ) -> PromptEditorConfig {
    PromptEditorConfig(
      heading: heading, description: description, isEnabled: isEnabled, text: text,
      defaultText: defaultText)
  }

  private func promptSection(
    title: String,
    subtitle: String,
    intro: String,
    sections: [PromptEditorConfig],
    onReset: @escaping () -> Void
  ) -> some View {
    SettingsSection(title: title, subtitle: subtitle) {
      VStack(alignment: .leading, spacing: 18) {
        Text(intro)
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.secondary)
          .fixedSize(horizontal: false, vertical: true)

        ForEach(sections.indices, id: \.self) { index in
          promptEditorBlock(config: sections[index])
        }

        HStack {
          Spacer()
          SettingsSecondaryButton(
            title: "Reset to Dayflow defaults",
            systemImage: "arrow.counterclockwise",
            action: onReset
          )
        }
      }
    }
  }

  /// A prompt-customization block: toggle + text-editor pair. Keeps its
  /// own subtle container because the text editor needs input-affordance
  /// against the paper background.
  private func promptEditorBlock(config: PromptEditorConfig) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(isOn: config.isEnabled) {
        VStack(alignment: .leading, spacing: 3) {
          Text(config.heading)
            .font(.custom("Nunito", size: 14))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          Text(config.description)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(SettingsStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(SwitchToggleStyle(tint: SettingsStyle.ink))
      .pointingHandCursor()

      ZStack(alignment: .topLeading) {
        if config.text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(config.defaultText)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(SettingsStyle.meta)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
        }

        TextEditor(text: config.text)
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.text.opacity(config.isEnabled.wrappedValue ? 1 : 0.4))
          .scrollContentBackground(.hidden)
          .disabled(!config.isEnabled.wrappedValue)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .frame(minHeight: config.isEnabled.wrappedValue ? 140 : 120)
      }
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color.white.opacity(0.7))
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(Color.black.opacity(0.12), lineWidth: 1)
          )
      )
      .opacity(config.isEnabled.wrappedValue ? 1 : 0.6)
    }
  }
}

// MARK: - Upgrade banner (kept as an exception — it's a promotional unit)
//
// This is the one dark surface on the settings page. Semantically it's
// advertising, not configuration, so it gets to play by different rules.

private struct LocalModelUpgradeBanner: View {
  let preset: LocalModelPreset
  let onKeepLegacy: () -> Void
  let onUpgrade: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "sparkles")
          .foregroundStyle(Color.white)
          .padding(8)
          .background(Color(red: 0.12, green: 0.09, blue: 0.02))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 4) {
          Text("Upgrade to \(preset.displayName)")
            .font(.custom("Nunito", size: 16))
            .fontWeight(.semibold)
            .foregroundColor(.white)
          Text("Upgrade to Qwen3VL for a big improvement in quality.")
            .font(.custom("Nunito", size: 13))
            .foregroundColor(.white.opacity(0.8))
        }
        Spacer()
      }

      VStack(alignment: .leading, spacing: 6) {
        ForEach(preset.highlightBullets, id: \.self) { bullet in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 12))
              .foregroundColor(Color(red: 0.76, green: 1, blue: 0.74))
              .padding(.top, 2)
            Text(bullet)
              .font(.custom("Nunito", size: 13))
              .foregroundColor(.white.opacity(0.85))
          }
        }
      }

      HStack(spacing: 12) {
        Button(action: onKeepLegacy) {
          Text("Keep Qwen2.5")
            .font(.custom("Nunito", size: 13))
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()

        Button(action: onUpgrade) {
          HStack(spacing: 6) {
            Text("Upgrade now")
              .font(.custom("Nunito", size: 13))
              .fontWeight(.semibold)
            Image(systemName: "arrow.right")
              .font(.system(size: 12, weight: .semibold))
          }
          .foregroundColor(.black)
          .padding(.horizontal, 18)
          .padding(.vertical, 9)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.white)
          )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(red: 0.16, green: 0.11, blue: 0))
    )
  }
}

// MARK: - Upgrade sheet (unchanged — it's a modal, not a settings surface)

struct LocalModelUpgradeSheet: View {
  let preset: LocalModelPreset
  let initialEngine: LocalEngine
  let initialBaseURL: String
  let initialModelId: String
  let initialAPIKey: String
  let onCancel: () -> Void
  let onUpgradeSuccess: (LocalEngine, String, String, String) -> Void

  @State private var selectedEngine: LocalEngine
  @State private var candidateBaseURL: String
  @State private var candidateModelId: String
  @State private var candidateAPIKey: String
  @State private var didApplyUpgrade = false

  init(
    preset: LocalModelPreset,
    initialEngine: LocalEngine,
    initialBaseURL: String,
    initialModelId: String,
    initialAPIKey: String,
    onCancel: @escaping () -> Void,
    onUpgradeSuccess: @escaping (LocalEngine, String, String, String) -> Void
  ) {
    self.preset = preset
    self.initialEngine = initialEngine
    self.initialBaseURL = initialBaseURL
    self.initialModelId = initialModelId
    self.initialAPIKey = initialAPIKey
    self.onCancel = onCancel
    self.onUpgradeSuccess = onUpgradeSuccess

    let startingEngine = initialEngine
    _selectedEngine = State(initialValue: startingEngine)
    _candidateBaseURL = State(
      initialValue: initialBaseURL.isEmpty ? startingEngine.defaultBaseURL : initialBaseURL)
    let recommendedModel = preset.modelId(for: startingEngine == .custom ? .ollama : startingEngine)
    _candidateModelId = State(initialValue: recommendedModel)
    _candidateAPIKey = State(initialValue: initialAPIKey)
  }

  var body: some View {
    ScrollView(.vertical, showsIndicators: true) {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("Upgrade to \(preset.displayName)")
              .font(.custom("Nunito", size: 22))
              .fontWeight(.semibold)
            Text(
              "Follow the steps below, run a quick test, and Dayflow will switch you over automatically."
            )
            .font(.custom("Nunito", size: 13))
            .foregroundColor(SettingsStyle.secondary)
          }
          Spacer()
          Button(action: onCancel) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 20))
              .foregroundColor(SettingsStyle.meta)
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }

        VStack(alignment: .leading, spacing: 6) {
          ForEach(preset.highlightBullets, id: \.self) { bullet in
            HStack(spacing: 8) {
              Image(systemName: "sparkle")
                .font(.system(size: 12))
                .foregroundColor(SettingsStyle.ink)
              Text(bullet)
                .font(.custom("Nunito", size: 13))
                .foregroundColor(SettingsStyle.text)
            }
          }
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("Which local runtime are you using?")
            .font(.custom("Nunito", size: 14))
            .foregroundColor(SettingsStyle.secondary)
          Picker("Engine", selection: $selectedEngine) {
            Text("Ollama").tag(LocalEngine.ollama)
            Text("LM Studio").tag(LocalEngine.lmstudio)
            Text("Custom").tag(LocalEngine.custom)
          }
          .pickerStyle(.segmented)
          .frame(maxWidth: 420)
        }

        instructionView(for: selectedEngine)

        LocalLLMTestView(
          baseURL: $candidateBaseURL,
          modelId: $candidateModelId,
          apiKey: $candidateAPIKey,
          engine: selectedEngine,
          showInputs: true,
          buttonLabel: "Test upgrade",
          basePlaceholder: selectedEngine.defaultBaseURL,
          modelPlaceholder: preset.modelId(
            for: selectedEngine == .custom ? .ollama : selectedEngine),
          onTestComplete: { success in
            if success && !didApplyUpgrade {
              didApplyUpgrade = true
              onUpgradeSuccess(selectedEngine, candidateBaseURL, candidateModelId, candidateAPIKey)
            }
          }
        )

        Text(
          "Once the test succeeds, Dayflow updates your settings to \(preset.displayName) automatically."
        )
        .font(.custom("Nunito", size: 12))
        .foregroundColor(SettingsStyle.secondary)

        HStack {
          Spacer()
          SettingsSecondaryButton(title: "Close", action: onCancel)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: selectedEngine) { _, newEngine in
      candidateModelId = preset.modelId(for: newEngine == .custom ? .ollama : newEngine)
      if newEngine != .custom {
        candidateBaseURL = newEngine.defaultBaseURL
        candidateAPIKey = ""
      }
    }
  }

  @ViewBuilder
  private func instructionView(for engine: LocalEngine) -> some View {
    let instruction = preset.instructions(for: engine == .custom ? .ollama : engine)
    VStack(alignment: .leading, spacing: 12) {
      Text(instruction.title)
        .font(.custom("Nunito", size: 16))
        .fontWeight(.semibold)
      Text(instruction.subtitle)
        .font(.custom("Nunito", size: 13))
        .foregroundColor(SettingsStyle.secondary)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(instruction.bullets.enumerated()), id: \.offset) { index, bullet in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1).")
              .font(.custom("Nunito", size: 13))
              .foregroundColor(SettingsStyle.secondary)
              .frame(width: 18, alignment: .leading)
            Text(bullet)
              .font(.custom("Nunito", size: 13))
              .foregroundColor(SettingsStyle.text)
          }
        }
      }

      if let command = instruction.command,
        let commandTitle = instruction.commandTitle,
        let commandSubtitle = instruction.commandSubtitle
      {
        TerminalCommandView(
          title: commandTitle,
          subtitle: commandSubtitle,
          command: command
        )
      }

      if let buttonTitle = instruction.buttonTitle,
        let url = instruction.buttonURL
      {
        SettingsPrimaryButton(
          title: buttonTitle,
          systemImage: "arrow.down.circle.fill",
          action: { NSWorkspace.shared.open(url) }
        )
      }

      if let note = instruction.note {
        Text(note)
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.secondary)
      }
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white)
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
    )
  }
}
