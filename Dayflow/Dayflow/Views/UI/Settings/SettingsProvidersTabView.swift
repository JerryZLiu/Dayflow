import AppKit
import SwiftUI

struct SettingsProvidersTabView: View {
    @ObservedObject var viewModel: ProvidersSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            // MARK: - Upgrade Banner
            if viewModel.currentProvider == "ollama", viewModel.showLocalModelUpgradeBanner {
                LocalModelUpgradeBanner(
                    preset: .qwen3VL4B,
                    onKeepLegacy: {
                        viewModel.markUpgradeBannerKeepLegacy()
                    },
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
                    .foregroundColor(Color(red: 0.06, green: 0.45, blue: 0.2))
                    .padding(.horizontal, 4)
            }

            // MARK: - Primary Provider
            SettingsCard(title: "Primary provider", subtitle: "The provider Dayflow uses for timeline summaries") {
                primaryProviderCard
            }

            // MARK: - Backup Provider
            SettingsCard(title: "Backup provider", subtitle: "Fallback when the primary is unavailable") {
                backupProviderCard
            }

            // MARK: - Connection Health
            SettingsCard(title: "Connection health", subtitle: "Run a quick test for the primary provider") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.connectionHealthLabel)
                        .font(.custom("Nunito", size: 14))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.72))

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
                            onTestComplete: { _ in
                                viewModel.handleLocalTestCompletion()
                            }
                        )
                    case "chatgpt_claude":
                        ChatCLITestView(
                            selectedTool: viewModel.preferredCLITool,
                            onTestComplete: { _ in }
                        )
                    default:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Dayflow Pro diagnostics coming soon")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.black.opacity(0.55))
                        }
                    }
                }
                .environment(\.colorScheme, .light)
            }

            // MARK: - Available Providers
            SettingsCard(title: "Available providers", subtitle: "Configure and assign roles to providers") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.routingProviders, id: \.id) { provider in
                        providerCard(for: provider)
                    }
                }
            }

            // MARK: - Model Preference & Prompt Customization
            if viewModel.currentProvider == "gemini" {
                SettingsCard(title: "Gemini model preference", subtitle: "Choose which Gemini model Dayflow should prioritize") {
                    GeminiModelSettingsCard(selectedModel: $viewModel.selectedGeminiModel) { model in
                        viewModel.persistGeminiModelSelection(model, source: "settings")
                    }
                }

                SettingsCard(title: "Gemini prompt customization", subtitle: "Override Dayflow's defaults to tailor card generation") {
                    geminiPromptCustomizationView
                }
            } else if viewModel.currentProvider == "ollama" {
                SettingsCard(title: "Local prompt customization", subtitle: "Adjust the prompts used for local timeline summaries") {
                    ollamaPromptCustomizationView
                }
            } else if viewModel.currentProvider == "chatgpt_claude" {
                SettingsCard(title: "ChatGPT / Claude prompt customization", subtitle: "Override Dayflow's defaults to tailor card generation") {
                    chatCLIPromptCustomizationView
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.editingProvider != nil },
            set: { if !$0 { viewModel.editingProvider = nil } }
        )) {
            if let providerId = viewModel.editingProvider {
                ProviderConfigEditor(
                    providerId: providerId,
                    viewModel: viewModel,
                    onDismiss: { viewModel.editingProvider = nil }
                )
                .frame(width: 480, height: 420)
                .preferredColorScheme(.light)
            }
        }
    }

    // MARK: - Primary Provider Card

    @ViewBuilder
    private var primaryProviderCard: some View {
        let primaryId = viewModel.primaryRoutingProviderId
        if let provider = viewModel.routingProviders.first(where: { $0.id == primaryId }) {
            VStack(alignment: .leading, spacing: 14) {
                ProviderCardView(
                    provider: provider,
                    isPrimary: true,
                    isSecondary: false,
                    isConfigured: viewModel.isProviderConfigured(primaryId),
                    statusDetail: viewModel.statusText(for: primaryId),
                    canSetPrimary: false,
                    canSetSecondary: false,
                    onEdit: { viewModel.editingProvider = primaryId },
                    onConfigure: { viewModel.beginProviderSetup(primaryId, role: .setupOnly) },
                    onRemove: { viewModel.removeProviderConfiguration(primaryId) },
                    onSetPrimary: {},
                    onSetSecondary: {}
                )

                if viewModel.currentProvider == "ollama" {
                    DayflowSurfaceButton(
                        action: { viewModel.isShowingLocalModelUpgradeSheet = true },
                        content: {
                            HStack(spacing: 6) {
                                Image(systemName: viewModel.usingRecommendedLocalModel ? "slider.horizontal.2.square" : "arrow.up.circle.fill")
                                    .font(.system(size: 14))
                                Text(viewModel.usingRecommendedLocalModel ? "Manage local model" : "Upgrade local model")
                                    .font(.custom("Nunito", size: 13))
                                    .fontWeight(.semibold)
                            }
                            .frame(minWidth: 160)
                        },
                        background: Color.white,
                        foreground: .black,
                        borderColor: Color.black.opacity(0.15),
                        cornerRadius: 8,
                        horizontalPadding: 16,
                        verticalPadding: 9,
                        showOverlayStroke: false
                    )
                    .padding(.top, 6)
                }
            }
        } else {
            Text("No primary provider configured")
                .font(.custom("Nunito", size: 13))
                .foregroundColor(.black.opacity(0.55))
        }
    }

    // MARK: - Backup Provider Card

    @ViewBuilder
    private var backupProviderCard: some View {
        if let backupId = viewModel.secondaryRoutingProviderId,
           let provider = viewModel.routingProviders.first(where: { $0.id == backupId }) {
            ProviderCardView(
                provider: provider,
                isPrimary: false,
                isSecondary: true,
                isConfigured: viewModel.isProviderConfigured(backupId),
                statusDetail: viewModel.statusText(for: backupId),
                canSetPrimary: viewModel.canAssignPrimary(backupId),
                canSetSecondary: false,
                onEdit: { viewModel.editingProvider = backupId },
                onConfigure: { viewModel.beginProviderSetup(backupId, role: .setupOnly) },
                onRemove: { viewModel.removeProviderConfiguration(backupId) },
                onSetPrimary: { viewModel.setPrimaryOrSetup(backupId) },
                onSetSecondary: {}
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not configured")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(.black.opacity(0.55))
                Text("Set a secondary provider in the Available Providers section below.")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.45))
            }
        }
    }

    // MARK: - Provider Card Factory

    private func providerCard(for provider: CompactProviderInfo) -> some View {
        let isConfigured = viewModel.isProviderConfigured(provider.id)
        let isPrimary = viewModel.primaryRoutingProviderId == provider.id
        let isSecondary = viewModel.isBackupProvider(provider.id)
        let canSetSecondary = viewModel.canAssignSecondary(provider.id) || !isConfigured

        return ProviderCardView(
            provider: provider,
            isPrimary: isPrimary,
            isSecondary: isSecondary,
            isConfigured: isConfigured,
            statusDetail: isConfigured ? viewModel.statusText(for: provider.id) : nil,
            canSetPrimary: !isPrimary && isConfigured,
            canSetSecondary: !isSecondary && canSetSecondary,
            onEdit: { viewModel.editingProvider = provider.id },
            onConfigure: { viewModel.beginProviderSetup(provider.id, role: .setupOnly) },
            onRemove: { viewModel.removeProviderConfiguration(provider.id) },
            onSetPrimary: { viewModel.setPrimaryOrSetup(provider.id) },
            onSetSecondary: { viewModel.setSecondaryOrSetup(provider.id) }
        )
    }

    private var geminiPromptCustomizationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Overrides apply only when their toggle is on. Unchecked sections fall back to Dayflow's defaults.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            promptSection(
                heading: "Card titles",
                description: "Shape how card titles read and tweak the example list.",
                isEnabled: $viewModel.useCustomGeminiTitlePrompt,
                text: $viewModel.geminiTitlePromptText,
                defaultText: GeminiPromptDefaults.titleBlock
            )

            promptSection(
                heading: "Card summaries",
                description: "Control tone and style for the summary field.",
                isEnabled: $viewModel.useCustomGeminiSummaryPrompt,
                text: $viewModel.geminiSummaryPromptText,
                defaultText: GeminiPromptDefaults.summaryBlock
            )

            promptSection(
                heading: "Detailed summaries",
                description: "Define the minute-by-minute breakdown format and examples.",
                isEnabled: $viewModel.useCustomGeminiDetailedPrompt,
                text: $viewModel.geminiDetailedPromptText,
                defaultText: GeminiPromptDefaults.detailedSummaryBlock
            )

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: viewModel.resetGeminiPromptOverrides,
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset to Dayflow defaults")
                                .font(.custom("Nunito", size: 13))
                        }
                        .padding(.horizontal, 2)
                    },
                    background: Color.white,
                    foreground: Color(red: 0.25, green: 0.17, blue: 0),
                    borderColor: Color(hex: "FFE0A5"),
                    cornerRadius: 8,
                    horizontalPadding: 18,
                    verticalPadding: 9,
                    showOverlayStroke: true
                )
            }
        }
    }

    private var ollamaPromptCustomizationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Customize the local model prompts for summary and title generation.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            promptSection(
                heading: "Timeline summaries",
                description: "Control how the local model writes its 2-3 sentence card summaries.",
                isEnabled: $viewModel.useCustomOllamaSummaryPrompt,
                text: $viewModel.ollamaSummaryPromptText,
                defaultText: OllamaPromptDefaults.summaryBlock
            )

            promptSection(
                heading: "Card titles",
                description: "Adjust the tone and examples for local title generation.",
                isEnabled: $viewModel.useCustomOllamaTitlePrompt,
                text: $viewModel.ollamaTitlePromptText,
                defaultText: OllamaPromptDefaults.titleBlock
            )

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: viewModel.resetOllamaPromptOverrides,
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset to Dayflow defaults")
                                .font(.custom("Nunito", size: 13))
                        }
                        .padding(.horizontal, 2)
                    },
                    background: Color.white,
                    foreground: Color(red: 0.25, green: 0.17, blue: 0),
                    borderColor: Color(hex: "FFE0A5"),
                    cornerRadius: 8,
                    horizontalPadding: 18,
                    verticalPadding: 9,
                    showOverlayStroke: true
                )
            }
        }
    }

    private var chatCLIPromptCustomizationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Overrides apply only when their toggle is on. Unchecked sections fall back to Dayflow's defaults.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            promptSection(
                heading: "Card titles",
                description: "Shape how card titles read and tweak the example list.",
                isEnabled: $viewModel.useCustomChatCLITitlePrompt,
                text: $viewModel.chatCLITitlePromptText,
                defaultText: ChatCLIPromptDefaults.titleBlock
            )

            promptSection(
                heading: "Card summaries",
                description: "Control tone and style for the summary field.",
                isEnabled: $viewModel.useCustomChatCLISummaryPrompt,
                text: $viewModel.chatCLISummaryPromptText,
                defaultText: ChatCLIPromptDefaults.summaryBlock
            )

            promptSection(
                heading: "Detailed summaries",
                description: "Define the minute-by-minute breakdown format and examples.",
                isEnabled: $viewModel.useCustomChatCLIDetailedPrompt,
                text: $viewModel.chatCLIDetailedPromptText,
                defaultText: ChatCLIPromptDefaults.detailedSummaryBlock
            )

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: viewModel.resetChatCLIPromptOverrides,
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset to Dayflow defaults")
                                .font(.custom("Nunito", size: 13))
                        }
                        .padding(.horizontal, 2)
                    },
                    background: Color.white,
                    foreground: Color(red: 0.25, green: 0.17, blue: 0),
                    borderColor: Color(hex: "FFE0A5"),
                    cornerRadius: 8,
                    horizontalPadding: 18,
                    verticalPadding: 9,
                    showOverlayStroke: true
                )
            }
        }
    }

    @ViewBuilder
    private func promptSection(heading: String,
                               description: String,
                               isEnabled: Binding<Bool>,
                               text: Binding<String>,
                               defaultText: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: isEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading)
                        .font(.custom("Nunito", size: 14))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.75))
                    Text(description)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.17, blue: 0)))
            .pointingHandCursor()

            promptEditorBlock(title: "Prompt text", text: text, isEnabled: isEnabled.wrappedValue, defaultText: defaultText)
        }
        .padding(16)
        .background(Color.white.opacity(0.95))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "FFE0A5"), lineWidth: 0.8)
        )
    }

    private func promptEditorBlock(title: String,
                                   text: Binding<String>,
                                   isEnabled: Bool,
                                   defaultText: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.custom("Nunito", size: 12))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.6))
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(defaultText)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)
                }

                TextEditor(text: text)
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(isEnabled ? 0.85 : 0.45))
                    .scrollContentBackground(.hidden)
                    .disabled(!isEnabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: isEnabled ? 140 : 120)
                    .background(Color.white)
            }
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )
            .cornerRadius(8)
            .opacity(isEnabled ? 1 : 0.6)
        }
    }

}

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
                DayflowSurfaceButton(
                    action: onKeepLegacy,
                    content: {
                        Text("Keep Qwen2.5").font(.custom("Nunito", size: 13)).fontWeight(.semibold)
                    },
                    background: Color.white.opacity(0.12),
                    foreground: .white,
                    borderColor: Color.white.opacity(0.25),
                    cornerRadius: 8,
                    horizontalPadding: 18,
                    verticalPadding: 10,
                    showOverlayStroke: false
                )
                DayflowSurfaceButton(
                    action: onUpgrade,
                    content: {
                        HStack(spacing: 6) {
                            Text("Upgrade now").font(.custom("Nunito", size: 13)).fontWeight(.semibold)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    },
                    background: Color.white,
                    foreground: .black,
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 18,
                    verticalPadding: 10,
                    showShadow: false
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.16, green: 0.11, blue: 0))
        )
    }
}

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
        _candidateBaseURL = State(initialValue: initialBaseURL.isEmpty ? startingEngine.defaultBaseURL : initialBaseURL)
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
                        Text("Follow the steps below, run a quick test, and Dayflow will switch you over automatically.")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.6))
                    }
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.black.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preset.highlightBullets, id: \.self) { bullet in
                        HStack(spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 12))
                                .foregroundColor(Color(red: 0.39, green: 0.23, blue: 0.02))
                            Text(bullet)
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.black.opacity(0.75))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Which local runtime are you using?")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.65))
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
                    modelPlaceholder: preset.modelId(for: selectedEngine == .custom ? .ollama : selectedEngine),
                    onTestComplete: { success in
                        if success && !didApplyUpgrade {
                            didApplyUpgrade = true
                            onUpgradeSuccess(selectedEngine, candidateBaseURL, candidateModelId, candidateAPIKey)
                        }
                    }
                )

                Text("Once the test succeeds, Dayflow updates your settings to \(preset.displayName) automatically.")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.55))

                HStack {
                    Spacer()
                    DayflowSurfaceButton(
                        action: onCancel,
                        content: {
                            Text("Close").font(.custom("Nunito", size: 13)).fontWeight(.semibold)
                        },
                        background: Color.white,
                        foreground: .black,
                        borderColor: Color.black.opacity(0.15),
                        cornerRadius: 8,
                        horizontalPadding: 18,
                        verticalPadding: 10,
                        showOverlayStroke: false
                    )
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
                .foregroundColor(.black.opacity(0.65))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(instruction.bullets.enumerated()), id: \.offset) { index, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.55))
                            .frame(width: 18, alignment: .leading)
                        Text(bullet)
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.8))
                    }
                }
            }

            if let command = instruction.command,
               let commandTitle = instruction.commandTitle,
               let commandSubtitle = instruction.commandSubtitle {
                TerminalCommandView(
                    title: commandTitle,
                    subtitle: commandSubtitle,
                    command: command
                )
            }

            if let buttonTitle = instruction.buttonTitle,
               let url = instruction.buttonURL {
                DayflowSurfaceButton(
                    action: { NSWorkspace.shared.open(url) },
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14))
                            Text(buttonTitle)
                                .font(.custom("Nunito", size: 13))
                                .fontWeight(.semibold)
                        }
                    },
                    background: Color(red: 0.25, green: 0.17, blue: 0),
                    foreground: .white,
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 20,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )
            }

            if let note = instruction.note {
                Text(note)
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.55))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct GeminiModelSettingsCard: View {
    @Binding var selectedModel: GeminiModel
    let onSelectionChanged: (GeminiModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gemini model")
                .font(.custom("Nunito", size: 13))
                .fontWeight(.semibold)
                .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))

            Picker("Gemini model", selection: $selectedModel) {
                ForEach(GeminiModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .environment(\.colorScheme, .light)

            Text(GeminiModelPreference(primary: selectedModel).fallbackSummary)
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.5))

            Text("Dayflow automatically downgrades if your chosen model is rate limited or unavailable.")
                .font(.custom("Nunito", size: 11))
                .foregroundColor(.black.opacity(0.45))
        }
        .onChange(of: selectedModel) { _, newValue in
            onSelectionChanged(newValue)
        }
    }
}
