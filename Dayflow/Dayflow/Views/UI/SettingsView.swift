//
//  SettingsView.swift
//  Dayflow
//
//  Settings screen with onboarding-inspired styling and split layout
//

import SwiftUI
import AppKit
import CoreGraphics

struct SettingsView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case storage
        case providers
        case other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .storage: return "Storage"
            case .providers: return "Providers"
            case .other: return "Other"
            }
        }

        var subtitle: String {
            switch self {
            case .storage: return "Recording status and disk usage"
            case .providers: return "Manage LLM providers and customize prompts"
            case .other: return "General preferences & support"
            }
        }
    }

    // Tab + analytics state
    @State private var selectedTab: SettingsTab = .storage
    @State private var previousTab: SettingsTab = .storage
    @State private var tabTransitionDirection: TabTransitionDirection = .none
    @State private var analyticsEnabled: Bool = AnalyticsService.shared.isOptedIn

    private enum TabTransitionDirection {
        case none, leading, trailing
    }

    // Namespace for animated sidebar selection (Emil Kowalski: shared layout animations)
    @Namespace private var sidebarSelectionNamespace

    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared

    // Provider state
    @State private var currentProvider: String = "gemini"
    @State private var setupModalProvider: String? = nil
    @State private var hasLoadedProvider = false
    @State private var selectedGeminiModel: GeminiModel = GeminiModelPreference.load().primary
    @State private var savedGeminiModel: GeminiModel = GeminiModelPreference.load().primary

    // Gemini prompt customization
    @State private var geminiPromptOverridesLoaded = false
    @State private var isUpdatingGeminiPromptState = false
    @State private var useCustomGeminiTitlePrompt = false
    @State private var useCustomGeminiSummaryPrompt = false
    @State private var useCustomGeminiDetailedPrompt = false
    @State private var geminiTitlePromptText = GeminiPromptDefaults.titleBlock
    @State private var geminiSummaryPromptText = GeminiPromptDefaults.summaryBlock
    @State private var geminiDetailedPromptText = GeminiPromptDefaults.detailedSummaryBlock

    // Ollama prompt customization
    @State private var ollamaPromptOverridesLoaded = false
    @State private var isUpdatingOllamaPromptState = false
    @State private var useCustomOllamaTitlePrompt = false
    @State private var useCustomOllamaSummaryPrompt = false
    @State private var ollamaTitlePromptText = OllamaPromptDefaults.titleBlock
    @State private var ollamaSummaryPromptText = OllamaPromptDefaults.summaryBlock

    // ChatCLI prompt customization
    @State private var chatCLIPromptOverridesLoaded = false
    @State private var isUpdatingChatCLIPromptState = false
    @State private var useCustomChatCLITitlePrompt = false
    @State private var useCustomChatCLISummaryPrompt = false
    @State private var useCustomChatCLIDetailedPrompt = false
    @State private var chatCLITitlePromptText = ChatCLIPromptDefaults.titleBlock
    @State private var chatCLISummaryPromptText = ChatCLIPromptDefaults.summaryBlock
    @State private var chatCLIDetailedPromptText = ChatCLIPromptDefaults.detailedSummaryBlock

    // Local provider cached settings
    @State private var localEngine: LocalEngine = {
        let raw = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
        return LocalEngine(rawValue: raw) ?? .ollama
    }()
    @State private var localBaseURL: String = {
        UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? LocalEngine.ollama.defaultBaseURL
    }()
    @State private var localModelId: String = {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: "llmLocalModelId") ?? ""
        let engineRaw = defaults.string(forKey: "llmLocalEngine") ?? "ollama"
        let engine = LocalEngine(rawValue: engineRaw) ?? .ollama
        if stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LocalModelPreferences.defaultModelId(for: engine)
        }
        return stored
    }()
    @State private var localAPIKey: String = {
        UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? ""
    }()
    @State private var showLocalModelUpgradeBanner = false
    @State private var isShowingLocalModelUpgradeSheet = false
    @State private var upgradeStatusMessage: String?

    // ChatGPT/Claude CLI state
    @State private var preferredCLITool: CLITool? = {
        guard let raw = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") else { return nil }
        return CLITool(rawValue: raw)
    }()

    // Storage metrics
    @State private var isRefreshingStorage = false
    @State private var storagePermissionGranted: Bool?
    @State private var lastStorageCheck: Date?
    @State private var recordingsUsageBytes: Int64 = 0
    @State private var timelapseUsageBytes: Int64 = 0
    @State private var recordingsLimitBytes: Int64 = StoragePreferences.recordingsLimitBytes
    @State private var timelapsesLimitBytes: Int64 = StoragePreferences.timelapsesLimitBytes
    @State private var recordingsLimitIndex: Int = 0
    @State private var timelapsesLimitIndex: Int = 0
    @State private var showLimitConfirmation = false
    @State private var pendingLimit: PendingLimit?

    // Timeline export
    @State private var exportStartDate = timelineDisplayDate(from: Date())
    @State private var exportEndDate = timelineDisplayDate(from: Date())
    @State private var isExportingTimelineRange = false
    @State private var exportStatusMessage: String?
    @State private var exportErrorMessage: String?

    // Debug options
    @AppStorage("showJournalDebugPanel") private var showJournalDebugPanel = false

    // Providers – debug log copy feedback

    private let usageFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 32) {
            sidebar

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    tabContent
                }
                .padding(.top, 24)
                .padding(.trailing, 16)
                .padding(.bottom, 24)
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .frame(maxWidth: 600, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.trailing, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentWithLifecycle: some View {
        mainContent
            .onAppear {
                loadCurrentProvider()
                analyticsEnabled = AnalyticsService.shared.isOptedIn
                refreshStorageIfNeeded()
                reloadLocalProviderSettings()
                LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
                refreshUpgradeBannerState()
                loadGeminiPromptOverridesIfNeeded()
                loadOllamaPromptOverridesIfNeeded()
                loadChatCLIPromptOverridesIfNeeded()
                let recordingsLimit = StoragePreferences.recordingsLimitBytes
                recordingsLimitBytes = recordingsLimit
                recordingsLimitIndex = indexForLimit(recordingsLimit)
                let timelapseLimit = StoragePreferences.timelapsesLimitBytes
                timelapsesLimitBytes = timelapseLimit
                timelapsesLimitIndex = indexForLimit(timelapseLimit)
                AnalyticsService.shared.capture("settings_opened")
                launchAtLoginManager.refreshStatus()
            }
            .onChange(of: analyticsEnabled) { enabled in
                AnalyticsService.shared.setOptIn(enabled)
            }
            .onChange(of: currentProvider) { newProvider in
                applyProviderChangeSideEffects(for: newProvider)
            }
            .onChange(of: selectedTab) { newValue in
                if newValue == .storage {
                    refreshStorageIfNeeded()
                }
            }
            .onChange(of: localEngine) { newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: "llmLocalEngine")
                LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
                refreshUpgradeBannerState()
            }
            .onChange(of: localModelId) { newValue in
                UserDefaults.standard.set(newValue, forKey: "llmLocalModelId")
                LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
                refreshUpgradeBannerState()
            }
            .onChange(of: localBaseURL) { newValue in
                UserDefaults.standard.set(newValue, forKey: "llmLocalBaseURL")
            }
            .onChange(of: localAPIKey) { newValue in
                persistLocalAPIKey(newValue)
            }
    }

    private var contentWithSheets: some View {
        contentWithLifecycle
            .sheet(item: Binding(
                get: { setupModalProvider.map { ProviderSetupWrapper(id: $0) } },
                set: { setupModalProvider = $0?.id }
            )) { wrapper in
                LLMProviderSetupView(
                    providerType: wrapper.id,
                    onBack: { setupModalProvider = nil },
                    onComplete: {
                        completeProviderSwitch(wrapper.id)
                        setupModalProvider = nil
                    }
                )
                .frame(minWidth: 900, minHeight: 650)
            }
            .sheet(isPresented: $isShowingLocalModelUpgradeSheet) {
                LocalModelUpgradeSheet(
                    preset: .qwen3VL4B,
                    initialEngine: localEngine,
                    initialBaseURL: localBaseURL,
                    initialModelId: localModelId,
                    initialAPIKey: localAPIKey,
                    onCancel: { isShowingLocalModelUpgradeSheet = false },
                    onUpgradeSuccess: { engine, baseURL, modelId, apiKey in
                        handleUpgradeSuccess(engine: engine, baseURL: baseURL, modelId: modelId, apiKey: apiKey)
                        isShowingLocalModelUpgradeSheet = false
                    }
                )
                .frame(minWidth: 720, minHeight: 560)
            }
            .alert(isPresented: $showLimitConfirmation) {
                guard let pending = pendingLimit,
                      Self.storageOptions.indices.contains(pending.index) else {
                    return Alert(title: Text("Adjust storage limit"), dismissButton: .default(Text("OK")))
                }

                let option = Self.storageOptions[pending.index]
                let categoryName = pending.category.displayName
                return Alert(
                    title: Text("Lower \(categoryName) limit?"),
                    message: Text("Reducing the \(categoryName) limit to \(option.label) will immediately delete the oldest \(categoryName) data to stay under the new cap."),
                    primaryButton: .destructive(Text("Confirm")) {
                        applyLimit(for: pending.category, index: pending.index)
                    },
                    secondaryButton: .cancel {
                        pendingLimit = nil
                        showLimitConfirmation = false
                    }
                )
            }
            // The settings palette is tailored for light mode
            .preferredColorScheme(.light)
    }

    var body: some View {
        contentWithSheets
            .onChange(of: useCustomGeminiTitlePrompt) { _ in persistGeminiPromptOverridesIfReady() }
            .onChange(of: useCustomGeminiSummaryPrompt) { _ in persistGeminiPromptOverridesIfReady() }
            .onChange(of: useCustomGeminiDetailedPrompt) { _ in persistGeminiPromptOverridesIfReady() }
            .onChange(of: geminiTitlePromptText) { _ in persistGeminiPromptOverridesIfReady() }
            .onChange(of: geminiSummaryPromptText) { _ in persistGeminiPromptOverridesIfReady() }
            .onChange(of: geminiDetailedPromptText) { _ in persistGeminiPromptOverridesIfReady() }
            .onChange(of: useCustomOllamaTitlePrompt) { _ in persistOllamaPromptOverridesIfReady() }
            .onChange(of: useCustomOllamaSummaryPrompt) { _ in persistOllamaPromptOverridesIfReady() }
            .onChange(of: ollamaTitlePromptText) { _ in persistOllamaPromptOverridesIfReady() }
            .onChange(of: ollamaSummaryPromptText) { _ in persistOllamaPromptOverridesIfReady() }
            .onChange(of: useCustomChatCLITitlePrompt) { _ in persistChatCLIPromptOverridesIfReady() }
            .onChange(of: useCustomChatCLISummaryPrompt) { _ in persistChatCLIPromptOverridesIfReady() }
            .onChange(of: useCustomChatCLIDetailedPrompt) { _ in persistChatCLIPromptOverridesIfReady() }
            .onChange(of: chatCLITitlePromptText) { _ in persistChatCLIPromptOverridesIfReady() }
            .onChange(of: chatCLISummaryPromptText) { _ in persistChatCLIPromptOverridesIfReady() }
            .onChange(of: chatCLIDetailedPromptText) { _ in persistChatCLIPromptOverridesIfReady() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.custom("InstrumentSerif-Regular", size: 42))
                .foregroundColor(.black.opacity(0.9))
                .padding(.leading, 10)

            Text("Manage how Dayflow runs")
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.55))
                .padding(.leading, 10)
                .padding(.bottom, 12)

            ForEach(SettingsTab.allCases) { tab in
                sidebarButton(for: tab)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Dayflow v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.45))
                    .padding(.leading, 10)
                Button {
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                } label: {
                    HStack(spacing: 6) {
                        Text("View release notes")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .font(.custom("Nunito", size: 12))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(Color(red: 0.45, green: 0.26, blue: 0.04))
                .padding(.leading, 10)
            }
        }
        .padding(.top, 0)
        .padding(.bottom, 16)
        .padding(.horizontal, 4)
        .frame(width: 198, alignment: .topLeading)
    }

    private func sidebarButton(for tab: SettingsTab) -> some View {
        Button {
            // Determine direction based on tab order (Emil Kowalski: direction-aware transitions)
            let tabs = SettingsTab.allCases
            let currentIndex = tabs.firstIndex(of: selectedTab) ?? 0
            let newIndex = tabs.firstIndex(of: tab) ?? 0
            let direction: TabTransitionDirection = newIndex > currentIndex ? .trailing : (newIndex < currentIndex ? .leading : .none)

            previousTab = selectedTab
            tabTransitionDirection = direction
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                selectedTab = tab
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title)
                    .font(.custom("Nunito", size: 15))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(selectedTab == tab ? 0.9 : 0.6))
                Text(tab.subtitle)
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(selectedTab == tab ? 0.55 : 0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background {
                // Animated selection indicator (Emil Kowalski: traveling selection creates continuity)
                if selectedTab == tab {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "FFE0A5") ?? Color.orange.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
                        .matchedGeometryEffect(id: "sidebarSelection", in: sidebarSelectionNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var tabContent: some View {
        // Direction-aware content transition (Emil Kowalski: spatial context through motion)
        let slideOffset: CGFloat = tabTransitionDirection == .trailing ? 20 : (tabTransitionDirection == .leading ? -20 : 0)

        Group {
            switch selectedTab {
            case .storage:
                storageContent
            case .providers:
                providersContent
            case .other:
                otherContent
            }
        }
        .id(selectedTab) // Forces view recreation for transition
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(x: slideOffset)),
                removal: .opacity.combined(with: .offset(x: -slideOffset))
            )
        )
    }

    // MARK: - Storage Tab

    private var storageContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsCard(title: "Recording Status", subtitle: "Ensure Dayflow can capture your screen") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        statusPill(icon: storagePermissionGranted == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                   tint: storagePermissionGranted == true ? Color(red: 0.35, green: 0.7, blue: 0.32) : Color(hex: "E91515"),
                                   text: storagePermissionGranted == true ? "Screen recording permission granted" : "Screen recording permission missing")

                        statusPill(icon: AppState.shared.isRecording ? "dot.radiowaves.left.and.right" : "pause.circle",
                                   tint: AppState.shared.isRecording ? Color(hex: "FF7506") : Color.black.opacity(0.25),
                                   text: AppState.shared.isRecording ? "Recorder active" : "Recorder idle")
                    }

                    HStack(spacing: 12) {
                        DayflowSurfaceButton(
                            action: refreshStorageMetrics,
                            content: {
                                HStack(spacing: 10) {
                                    if isRefreshingStorage {
                                        ProgressView().scaleEffect(0.75)
                                    }
                                    Text(isRefreshingStorage ? "Checking…" : "Run status check")
                                        .font(.custom("Nunito", size: 13))
                                        .fontWeight(.semibold)
                                }
                                .frame(minWidth: 170)
                            },
                            background: Color(red: 0.25, green: 0.17, blue: 0),
                            foreground: .white,
                            borderColor: .clear,
                            cornerRadius: 8,
                            horizontalPadding: 20,
                            verticalPadding: 11,
                            showOverlayStroke: true
                        )
                        .disabled(isRefreshingStorage)

                        if let last = lastStorageCheck {
                            Text("Last checked \(relativeDate(last))")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.45))
                        }
                    }
                }
            }

            SettingsCard(title: "Disk usage", subtitle: "Open folders or adjust per-type storage caps") {
                VStack(alignment: .leading, spacing: 18) {
                    usageRow(
                        category: .recordings,
                        label: "Recordings",
                        size: recordingsUsageBytes,
                        tint: Color(hex: "FF7506"),
                        limitIndex: recordingsLimitIndex,
                        limitBytes: recordingsLimitBytes,
                        actionTitle: "Open",
                        action: openRecordingsFolder
                    )
                    usageRow(
                        category: .timelapses,
                        label: "Timelapses",
                        size: timelapseUsageBytes,
                        tint: Color(hex: "1D7FFE"),
                        limitIndex: timelapsesLimitIndex,
                        limitBytes: timelapsesLimitBytes,
                        actionTitle: "Open",
                        action: openTimelapseFolder
                    )

                    Text(storageFooterText())
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func usageRow(category: StorageCategory, label: String, size: Int64, tint: Color, limitIndex: Int, limitBytes: Int64, actionTitle: String, action: @escaping () -> Void) -> some View {
        let usageString = usageFormatter.string(fromByteCount: size)
        let progress: Double? = limitBytes == Int64.max || limitBytes == 0 ? nil : min(Double(size) / Double(limitBytes), 1.0)
        let percentString: String? = progress.map { value in
            String(format: "%.0f%% of limit", value * 100)
        }
        let option = Self.storageOptions[limitIndex]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.custom("Nunito", size: 14))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.75))
                    HStack(spacing: 6) {
                        Text(usageString)
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.55))
                        if let percentString {
                            Text(percentString)
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.45))
                        }
                    }
                }
                Spacer()
                DayflowSurfaceButton(
                    action: action,
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                            Text(actionTitle)
                                .font(.custom("Nunito", size: 13))
                        }
                    },
                    background: Color.white,
                    foreground: Color(red: 0.25, green: 0.17, blue: 0),
                    borderColor: Color(hex: "FFE0A5"),
                    cornerRadius: 8,
                    horizontalPadding: 20,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )

                Menu {
                    ForEach(Self.storageOptions) { candidate in
                        Button(candidate.label) {
                            handleLimitSelection(for: category, index: candidate.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text(option.label)
                            .font(.custom("Nunito", size: 12))
                    }
                    .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "FFE0A5"), lineWidth: 1)
                    )
                }
                .menuStyle(BorderlessButtonMenuStyle())
            }

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: tint))
            }
        }
    }

    private func statusPill(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.65))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.75))
                .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 0.8))
        )
    }

    // MARK: - Providers Tab

    private var providersContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            if currentProvider == "ollama", showLocalModelUpgradeBanner {
                LocalModelUpgradeBanner(
                    preset: .qwen3VL4B,
                    onKeepLegacy: {
                        LocalModelPreferences.markUpgradeDismissed(true)
                        showLocalModelUpgradeBanner = false
                    },
                    onUpgrade: {
                        LocalModelPreferences.markUpgradeDismissed(false)
                        isShowingLocalModelUpgradeSheet = true
                    }
                )
                .transition(.opacity)
            }

            if let status = upgradeStatusMessage {
                Text(status)
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(Color(red: 0.06, green: 0.45, blue: 0.2))
                    .padding(.horizontal, 4)
            }

            SettingsCard(title: "Current configuration", subtitle: "Active provider and runtime details") {
                VStack(alignment: .leading, spacing: 14) {
                    providerSummary
                    DayflowSurfaceButton(
                        action: { setupModalProvider = currentProvider },
                        content: {
                            HStack(spacing: 8) {
                                Image(systemName: "slider.horizontal.3")
                                Text("Edit configuration")
                                    .font(.custom("Nunito", size: 13))
                            }
                            .frame(minWidth: 160)
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 20,
                        verticalPadding: 10,
                        showOverlayStroke: true
                    )
                    if currentProvider == "ollama" {
                        DayflowSurfaceButton(
                            action: { isShowingLocalModelUpgradeSheet = true },
                            content: {
                                HStack(spacing: 6) {
                                    Image(systemName: usingRecommendedLocalModel ? "slider.horizontal.2.square" : "arrow.up.circle.fill")
                                        .font(.system(size: 14))
                                    Text(usingRecommendedLocalModel ? "Manage local model" : "Upgrade local model")
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
            }

            SettingsCard(title: "Connection health", subtitle: "Run a quick test for the active provider") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(connectionHealthLabel)
                        .font(.custom("Nunito", size: 14))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.72))

                    switch currentProvider {
                    case "gemini":
                        TestConnectionView(onTestComplete: { _ in })
                    case "ollama":
                        LocalLLMTestView(
                            baseURL: $localBaseURL,
                            modelId: $localModelId,
                            apiKey: $localAPIKey,
                            engine: localEngine,
                            showInputs: localEngine == .custom,
                            onTestComplete: { _ in
                                UserDefaults.standard.set(localBaseURL, forKey: "llmLocalBaseURL")
                                UserDefaults.standard.set(localModelId, forKey: "llmLocalModelId")
                                LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
                                persistLocalAPIKey(localAPIKey)
                                refreshUpgradeBannerState()
                            }
                        )
                    case "chatgpt_claude":
                        ChatCLITestView(
                            selectedTool: preferredCLITool,
                            environment: [:],
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
            }

            SettingsCard(title: "Provider options", subtitle: "Switch providers at any time") {
                VStack(spacing: 12) {
                    ForEach(availableProviders, id: \.id) { provider in
                        CompactProviderRow(
                            provider: provider,
                            onSwitch: { switchToProvider(provider.id) }
                        )
                    }
                }
            }

            if currentProvider == "gemini" {
                SettingsCard(title: "Gemini model preference", subtitle: "Choose which Gemini model Dayflow should prioritize") {
                    GeminiModelSettingsCard(selectedModel: $selectedGeminiModel) { model in
                        persistGeminiModelSelection(model, source: "settings")
                    }
                }

                SettingsCard(title: "Gemini prompt customization", subtitle: "Override Dayflow's defaults to tailor card generation") {
                    geminiPromptCustomizationView
                }
            } else if currentProvider == "ollama" {
                SettingsCard(title: "Local prompt customization", subtitle: "Adjust the prompts used for local timeline summaries") {
                    ollamaPromptCustomizationView
                }
            } else if currentProvider == "chatgpt_claude" {
                SettingsCard(title: "ChatGPT / Claude prompt customization", subtitle: "Override Dayflow's defaults to tailor card generation") {
                    chatCLIPromptCustomizationView
                }
            }
        }
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
                isEnabled: $useCustomGeminiTitlePrompt,
                text: $geminiTitlePromptText,
                defaultText: GeminiPromptDefaults.titleBlock
            )

            promptSection(
                heading: "Card summaries",
                description: "Control tone and style for the summary field.",
                isEnabled: $useCustomGeminiSummaryPrompt,
                text: $geminiSummaryPromptText,
                defaultText: GeminiPromptDefaults.summaryBlock
            )

            promptSection(
                heading: "Detailed summaries",
                description: "Define the minute-by-minute breakdown format and examples.",
                isEnabled: $useCustomGeminiDetailedPrompt,
                text: $geminiDetailedPromptText,
                defaultText: GeminiPromptDefaults.detailedSummaryBlock
            )

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: resetGeminiPromptOverrides,
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
                isEnabled: $useCustomOllamaSummaryPrompt,
                text: $ollamaSummaryPromptText,
                defaultText: OllamaPromptDefaults.summaryBlock
            )

            promptSection(
                heading: "Card titles",
                description: "Adjust the tone and examples for local title generation.",
                isEnabled: $useCustomOllamaTitlePrompt,
                text: $ollamaTitlePromptText,
                defaultText: OllamaPromptDefaults.titleBlock
            )

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: resetOllamaPromptOverrides,
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
                isEnabled: $useCustomChatCLITitlePrompt,
                text: $chatCLITitlePromptText,
                defaultText: ChatCLIPromptDefaults.titleBlock
            )

            promptSection(
                heading: "Card summaries",
                description: "Control tone and style for the summary field.",
                isEnabled: $useCustomChatCLISummaryPrompt,
                text: $chatCLISummaryPromptText,
                defaultText: ChatCLIPromptDefaults.summaryBlock
            )

            promptSection(
                heading: "Detailed summaries",
                description: "Define the minute-by-minute breakdown format and examples.",
                isEnabled: $useCustomChatCLIDetailedPrompt,
                text: $chatCLIDetailedPromptText,
                defaultText: ChatCLIPromptDefaults.detailedSummaryBlock
            )

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: resetChatCLIPromptOverrides,
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

    @ViewBuilder
    private var providerSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryRow(label: "Active provider", value: providerDisplayName(currentProvider))

            switch currentProvider {
            case "ollama":
                summaryRow(label: "Engine", value: localEngine.displayName)
                summaryRow(label: "Model", value: localModelId.isEmpty ? "Not configured" : localModelId)
                summaryRow(label: "Endpoint", value: localBaseURL)
                let hasKey = !localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                summaryRow(label: "API key", value: hasKey ? "Stored in UserDefaults" : "Not set")
            case "gemini":
                summaryRow(label: "Model preference", value: selectedGeminiModel.displayName)
                summaryRow(label: "API key", value: KeychainManager.shared.retrieve(for: "gemini") != nil ? "Stored safely in Keychain" : "Not set")
            case "chatgpt_claude":
                summaryRow(label: "CLI preference", value: chatCLIStatusLabel())
                summaryRow(label: "Status", value: "Use Edit configuration to re-run CLI checks")
            default:
                summaryRow(label: "Status", value: "Coming soon")
            }
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.custom("Nunito", size: 13))
                .foregroundColor(.black.opacity(0.55))
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.78))
        }
    }

    private func providerDisplayName(_ id: String) -> String {
        switch id {
        case "ollama": return "Use local AI"
        case "gemini": return "Bring your own API keys"
        case "chatgpt_claude": return "Use ChatGPT or Claude"
        case "dayflow": return "Dayflow Pro"
        default: return id.capitalized
        }
    }

    // MARK: - Other Tab

    private var otherContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            timelineExportCard

            SettingsCard(title: "App preferences", subtitle: "General toggles and telemetry settings") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )) {
                        Text("Launch Dayflow at login")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .toggleStyle(.switch)

                    Text("Keeps the menu bar controller running right after you sign in so capture can resume instantly.")
                        .font(.custom("Nunito", size: 11.5))
                        .foregroundColor(.black.opacity(0.5))

                    Toggle(isOn: $analyticsEnabled) {
                        Text("Share crash reports and anonymous usage data")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $showJournalDebugPanel) {
                        Text("Show Journal debug panel")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .toggleStyle(.switch)

                    Text("Dayflow v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.45))
                }
            }
        }
    }

    private var timelineExportCard: some View {
        SettingsCard(title: "Export timeline", subtitle: "Download a Markdown export for any date range") {
            let rangeInvalid = timelineDisplayDate(from: exportStartDate) > timelineDisplayDate(from: exportEndDate)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    DatePicker("Start", selection: $exportStartDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .accessibilityLabel(Text("Export start date"))

                    Image(systemName: "arrow.right")
                        .foregroundColor(.black.opacity(0.35))

                    DatePicker("End", selection: $exportEndDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .accessibilityLabel(Text("Export end date"))
                }

                Text("Includes titles, summaries, and details for each card.")
                    .font(.custom("Nunito", size: 11.5))
                    .foregroundColor(.black.opacity(0.55))

                HStack(spacing: 10) {
                    DayflowSurfaceButton(
                        action: exportTimelineRange,
                        content: {
                            HStack(spacing: 8) {
                                if isExportingTimelineRange {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(isExportingTimelineRange ? "Exporting…" : "Export as Markdown")
                                    .font(.custom("Nunito", size: 13))
                                    .fontWeight(.semibold)
                            }
                            .frame(minWidth: 150)
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 20,
                        verticalPadding: 10,
                        showOverlayStroke: true
                    )
                    .disabled(isExportingTimelineRange || rangeInvalid)

                    if rangeInvalid {
                        Text("Start date must be on or before end date.")
                            .font(.custom("Nunito", size: 12))
                            .foregroundColor(Color(hex: "E91515"))
                    }
                }

                if let message = exportStatusMessage {
                    Text(message)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(Color(red: 0.1, green: 0.5, blue: 0.22))
                }

                if let error = exportErrorMessage {
                    Text(error)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(Color(hex: "E91515"))
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Storage helpers

    private func refreshStorageIfNeeded() {
        if storagePermissionGranted == nil && selectedTab == .storage {
            refreshStorageMetrics()
        }
    }

    private func refreshStorageMetrics() {
        guard !isRefreshingStorage else { return }
        isRefreshingStorage = true

        Task.detached(priority: .utility) {
            let permission = CGPreflightScreenCaptureAccess()
            let recordingsURL = StorageManager.shared.recordingsRoot
            let timelapseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Dayflow/timelapses", isDirectory: true)

            let recordingsSize = SettingsView.directorySize(at: recordingsURL)
            let timelapseSize = TimelapseStorageManager.shared.currentUsageBytes()

            await MainActor.run {
                self.storagePermissionGranted = permission
                self.recordingsUsageBytes = recordingsSize
                self.timelapseUsageBytes = timelapseSize
                self.lastStorageCheck = Date()
                self.isRefreshingStorage = false

                let recordingsLimit = StoragePreferences.recordingsLimitBytes
                let timelapseLimit = StoragePreferences.timelapsesLimitBytes
                self.recordingsLimitBytes = recordingsLimit
                self.timelapsesLimitBytes = timelapseLimit
                self.recordingsLimitIndex = indexForLimit(recordingsLimit)
                self.timelapsesLimitIndex = indexForLimit(timelapseLimit)
            }
        }
    }

    private func openRecordingsFolder() {
        let url = StorageManager.shared.recordingsRoot
        ensureDirectoryExists(url)
        NSWorkspace.shared.open(url)
    }

    private func openTimelapseFolder() {
        let url = TimelapseStorageManager.shared.rootURL
        ensureDirectoryExists(url)
        NSWorkspace.shared.open(url)
    }

    private func ensureDirectoryExists(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            print("⚠️ Failed to ensure directory exists at \(url.path): \(error)")
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Timeline export

    private func exportTimelineRange() {
        guard !isExportingTimelineRange else { return }

        let start = timelineDisplayDate(from: exportStartDate)
        let end = timelineDisplayDate(from: exportEndDate)

        guard start <= end else {
            exportErrorMessage = "Start date must be on or before end date."
            exportStatusMessage = nil
            return
        }

        isExportingTimelineRange = true
        exportStatusMessage = nil
        exportErrorMessage = nil

        Task.detached(priority: .userInitiated) {
            let calendar = Calendar.current
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"

            var cursor = start
            let endDate = end

            var sections: [String] = []
            var totalActivities = 0
            var dayCount = 0

            while cursor <= endDate {
                let dayString = dayFormatter.string(from: cursor)
                let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
                totalActivities += cards.count
                let section = TimelineClipboardFormatter.makeMarkdown(for: cursor, cards: cards)
                sections.append(section)
                dayCount += 1

                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }

            let divider = "\n\n---\n\n"
            let exportText = sections.joined(separator: divider)

            await MainActor.run {
                presentSavePanelAndWrite(
                    exportText: exportText,
                    startDate: start,
                    endDate: end,
                    dayCount: dayCount,
                    activityCount: totalActivities
                )
            }
        }
    }

    @MainActor
    private func presentSavePanelAndWrite(exportText: String,
                                          startDate: Date,
                                          endDate: Date,
                                          dayCount: Int,
                                          activityCount: Int) {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let savePanel = NSSavePanel()
        savePanel.title = "Export timeline"
        savePanel.prompt = "Export"
        savePanel.nameFieldStringValue = "Dayflow timeline \(dayFormatter.string(from: startDate)) to \(dayFormatter.string(from: endDate)).md"
        savePanel.allowedFileTypes = ["md", "markdown", "txt"]
        savePanel.canCreateDirectories = true

        let response = savePanel.runModal()

        defer { isExportingTimelineRange = false }

        guard response == .OK, let url = savePanel.url else {
            exportStatusMessage = nil
            exportErrorMessage = "Export canceled"
            return
        }

        do {
            try exportText.write(to: url, atomically: true, encoding: .utf8)
            exportErrorMessage = nil
            exportStatusMessage = "Saved \(activityCount) activit\(activityCount == 1 ? "y" : "ies") across \(dayCount) day\(dayCount == 1 ? "" : "s") to \(url.lastPathComponent)"

            AnalyticsService.shared.capture("timeline_exported", [
                "start_day": dayFormatter.string(from: startDate),
                "end_day": dayFormatter.string(from: endDate),
                "day_count": dayCount,
                "activity_count": activityCount,
                "format": "markdown",
                "file_extension": url.pathExtension.lowercased()
            ])
        } catch {
            exportStatusMessage = nil
            exportErrorMessage = "Couldn't save file: \(error.localizedDescription)"
        }
    }

    private func loadGeminiPromptOverridesIfNeeded(force: Bool = false) {
        if geminiPromptOverridesLoaded && !force { return }
        isUpdatingGeminiPromptState = true
        let overrides = GeminiPromptPreferences.load()

        let trimmedTitle = overrides.titleBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = overrides.summaryBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetailed = overrides.detailedBlock?.trimmingCharacters(in: .whitespacesAndNewlines)

        useCustomGeminiTitlePrompt = trimmedTitle?.isEmpty == false
        useCustomGeminiSummaryPrompt = trimmedSummary?.isEmpty == false
        useCustomGeminiDetailedPrompt = trimmedDetailed?.isEmpty == false

        geminiTitlePromptText = trimmedTitle ?? GeminiPromptDefaults.titleBlock
        geminiSummaryPromptText = trimmedSummary ?? GeminiPromptDefaults.summaryBlock
        geminiDetailedPromptText = trimmedDetailed ?? GeminiPromptDefaults.detailedSummaryBlock

        isUpdatingGeminiPromptState = false
        geminiPromptOverridesLoaded = true
    }

    private func persistGeminiPromptOverridesIfReady() {
        guard geminiPromptOverridesLoaded, !isUpdatingGeminiPromptState else { return }
        persistGeminiPromptOverrides()
    }

    private func persistGeminiPromptOverrides() {
        let overrides = GeminiPromptOverrides(
            titleBlock: normalizedOverride(text: geminiTitlePromptText, enabled: useCustomGeminiTitlePrompt),
            summaryBlock: normalizedOverride(text: geminiSummaryPromptText, enabled: useCustomGeminiSummaryPrompt),
            detailedBlock: normalizedOverride(text: geminiDetailedPromptText, enabled: useCustomGeminiDetailedPrompt)
        )

        if overrides.isEmpty {
            GeminiPromptPreferences.reset()
        } else {
            GeminiPromptPreferences.save(overrides)
        }
    }

    private func resetGeminiPromptOverrides() {
        isUpdatingGeminiPromptState = true
        useCustomGeminiTitlePrompt = false
        useCustomGeminiSummaryPrompt = false
        useCustomGeminiDetailedPrompt = false
        geminiTitlePromptText = GeminiPromptDefaults.titleBlock
        geminiSummaryPromptText = GeminiPromptDefaults.summaryBlock
        geminiDetailedPromptText = GeminiPromptDefaults.detailedSummaryBlock
        GeminiPromptPreferences.reset()
        isUpdatingGeminiPromptState = false
        geminiPromptOverridesLoaded = true
    }

    private func loadOllamaPromptOverridesIfNeeded(force: Bool = false) {
        if ollamaPromptOverridesLoaded && !force { return }
        isUpdatingOllamaPromptState = true
        let overrides = OllamaPromptPreferences.load()

        let trimmedSummary = overrides.summaryBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = overrides.titleBlock?.trimmingCharacters(in: .whitespacesAndNewlines)

        useCustomOllamaSummaryPrompt = trimmedSummary?.isEmpty == false
        useCustomOllamaTitlePrompt = trimmedTitle?.isEmpty == false

        ollamaSummaryPromptText = trimmedSummary ?? OllamaPromptDefaults.summaryBlock
        ollamaTitlePromptText = trimmedTitle ?? OllamaPromptDefaults.titleBlock

        isUpdatingOllamaPromptState = false
        ollamaPromptOverridesLoaded = true
    }

    private func persistOllamaPromptOverridesIfReady() {
        guard ollamaPromptOverridesLoaded, !isUpdatingOllamaPromptState else { return }
        persistOllamaPromptOverrides()
    }

    private func persistOllamaPromptOverrides() {
        let overrides = OllamaPromptOverrides(
            summaryBlock: normalizedOverride(text: ollamaSummaryPromptText, enabled: useCustomOllamaSummaryPrompt),
            titleBlock: normalizedOverride(text: ollamaTitlePromptText, enabled: useCustomOllamaTitlePrompt)
        )

        if overrides.isEmpty {
            OllamaPromptPreferences.reset()
        } else {
            OllamaPromptPreferences.save(overrides)
        }
    }

    private func resetOllamaPromptOverrides() {
        isUpdatingOllamaPromptState = true
        useCustomOllamaSummaryPrompt = false
        useCustomOllamaTitlePrompt = false
        ollamaSummaryPromptText = OllamaPromptDefaults.summaryBlock
        ollamaTitlePromptText = OllamaPromptDefaults.titleBlock
        OllamaPromptPreferences.reset()
        isUpdatingOllamaPromptState = false
        ollamaPromptOverridesLoaded = true
    }

    private func loadChatCLIPromptOverridesIfNeeded(force: Bool = false) {
        if chatCLIPromptOverridesLoaded && !force { return }
        isUpdatingChatCLIPromptState = true
        let overrides = ChatCLIPromptPreferences.load()

        let trimmedTitle = overrides.titleBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = overrides.summaryBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetailed = overrides.detailedBlock?.trimmingCharacters(in: .whitespacesAndNewlines)

        useCustomChatCLITitlePrompt = trimmedTitle?.isEmpty == false
        useCustomChatCLISummaryPrompt = trimmedSummary?.isEmpty == false
        useCustomChatCLIDetailedPrompt = trimmedDetailed?.isEmpty == false

        chatCLITitlePromptText = trimmedTitle ?? ChatCLIPromptDefaults.titleBlock
        chatCLISummaryPromptText = trimmedSummary ?? ChatCLIPromptDefaults.summaryBlock
        chatCLIDetailedPromptText = trimmedDetailed ?? ChatCLIPromptDefaults.detailedSummaryBlock

        isUpdatingChatCLIPromptState = false
        chatCLIPromptOverridesLoaded = true
    }

    private func persistChatCLIPromptOverridesIfReady() {
        guard chatCLIPromptOverridesLoaded, !isUpdatingChatCLIPromptState else { return }
        persistChatCLIPromptOverrides()
    }

    private func persistChatCLIPromptOverrides() {
        let overrides = ChatCLIPromptOverrides(
            titleBlock: normalizedOverride(text: chatCLITitlePromptText, enabled: useCustomChatCLITitlePrompt),
            summaryBlock: normalizedOverride(text: chatCLISummaryPromptText, enabled: useCustomChatCLISummaryPrompt),
            detailedBlock: normalizedOverride(text: chatCLIDetailedPromptText, enabled: useCustomChatCLIDetailedPrompt)
        )

        if overrides.isEmpty {
            ChatCLIPromptPreferences.reset()
        } else {
            ChatCLIPromptPreferences.save(overrides)
        }
    }

    private func resetChatCLIPromptOverrides() {
        isUpdatingChatCLIPromptState = true
        useCustomChatCLITitlePrompt = false
        useCustomChatCLISummaryPrompt = false
        useCustomChatCLIDetailedPrompt = false
        chatCLITitlePromptText = ChatCLIPromptDefaults.titleBlock
        chatCLISummaryPromptText = ChatCLIPromptDefaults.summaryBlock
        chatCLIDetailedPromptText = ChatCLIPromptDefaults.detailedSummaryBlock
        ChatCLIPromptPreferences.reset()
        isUpdatingChatCLIPromptState = false
        chatCLIPromptOverridesLoaded = true
    }

    private func normalizedOverride(text: String, enabled: Bool) -> String? {
        guard enabled else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            } catch {
                continue
            }
        }
        return total
    }

    // MARK: - Providers helpers

    // Storage limit helpers

    private func storageFooterText() -> String {
        let recordingsText = recordingsLimitBytes == Int64.max ? "Unlimited" : usageFormatter.string(fromByteCount: recordingsLimitBytes)
        let timelapsesText = timelapsesLimitBytes == Int64.max ? "Unlimited" : usageFormatter.string(fromByteCount: timelapsesLimitBytes)
        return "Recording cap: \(recordingsText) • Timelapse cap: \(timelapsesText). Lowering a cap immediately deletes the oldest files for that type. Timeline card text stays preserved. Please avoid deleting files manually so you do not remove Dayflow's database."
    }

    private func handleLimitSelection(for category: StorageCategory, index: Int) {
        guard Self.storageOptions.indices.contains(index) else { return }
        let newBytes = Self.storageOptions[index].resolvedBytes
        let currentBytes = limitBytes(for: category)
        guard newBytes != currentBytes else { return }

        if newBytes < currentBytes {
            pendingLimit = PendingLimit(category: category, index: index)
            showLimitConfirmation = true
        } else {
            applyLimit(for: category, index: index)
        }
    }

    private func applyLimit(for category: StorageCategory, index: Int) {
        guard Self.storageOptions.indices.contains(index) else { return }
        let option = Self.storageOptions[index]
        let newBytes = option.resolvedBytes
        let previousBytes = limitBytes(for: category)

        switch category {
        case .recordings:
            StorageManager.shared.updateStorageLimit(bytes: newBytes)
            recordingsLimitBytes = newBytes
            recordingsLimitIndex = index
        case .timelapses:
            TimelapseStorageManager.shared.updateLimit(bytes: newBytes)
            timelapsesLimitBytes = newBytes
            timelapsesLimitIndex = index
        }

        pendingLimit = nil
        showLimitConfirmation = false

        AnalyticsService.shared.capture("storage_limit_changed", [
            "category": category.analyticsKey,
            "previous_limit_bytes": previousBytes,
            "new_limit_bytes": newBytes
        ])

        refreshStorageMetrics()
    }

    private func limitBytes(for category: StorageCategory) -> Int64 {
        switch category {
        case .recordings: return recordingsLimitBytes
        case .timelapses: return timelapsesLimitBytes
        }
    }

    private func indexForLimit(_ bytes: Int64) -> Int {
        if bytes >= Int64.max {
            return Self.storageOptions.count - 1
        }
        if let exact = Self.storageOptions.firstIndex(where: { $0.resolvedBytes == bytes }) {
            return exact
        }
        for option in Self.storageOptions where option.bytes != nil {
            if bytes <= option.resolvedBytes {
                return option.id
            }
        }
        return Self.storageOptions.count - 1
    }

    // Debug log copy helpers removed per design request

    private func applyProviderChangeSideEffects(for provider: String) {
        reloadLocalProviderSettings()
        if provider == "gemini" {
            loadGeminiPromptOverridesIfNeeded(force: true)
        } else if provider == "ollama" {
            loadOllamaPromptOverridesIfNeeded(force: true)
        } else if provider == "chatgpt_claude" {
            loadChatCLIPromptOverridesIfNeeded(force: true)
        }
        refreshUpgradeBannerState()
    }

    private func reloadLocalProviderSettings() {
        localBaseURL = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? localBaseURL
        localModelId = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? localModelId
        localAPIKey = UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? localAPIKey
        let raw = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? localEngine.rawValue
        localEngine = LocalEngine(rawValue: raw) ?? localEngine
        LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
    }

    private var usingRecommendedLocalModel: Bool {
        let comparisonEngine = localEngine == .custom ? .ollama : localEngine
        let normalized = localModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let recommended = LocalModelPreset.recommended.modelId(for: comparisonEngine)
        if normalized.caseInsensitiveCompare(recommended) == .orderedSame {
            return true
        }
        return LocalModelPreferences.currentPreset() == .qwen3VL4B
    }

    private func refreshUpgradeBannerState() {
        let shouldShow = LocalModelPreferences.shouldShowUpgradeBanner(engine: localEngine, modelId: localModelId)
        showLocalModelUpgradeBanner = shouldShow && currentProvider == "ollama"
    }

    private func handleUpgradeSuccess(engine: LocalEngine, baseURL: String, modelId: String, apiKey: String) {
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
        AnalyticsService.shared.capture("local_model_upgraded", [
            "engine": engine.rawValue,
            "model": modelId
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            upgradeStatusMessage = nil
        }
    }

    private func persistLocalAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "llmLocalAPIKey")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "llmLocalAPIKey")
        }
    }

    private func loadCurrentProvider() {
        guard !hasLoadedProvider else { return }

        if let data = UserDefaults.standard.data(forKey: "llmProviderType"),
           let providerType = try? JSONDecoder().decode(LLMProviderType.self, from: data) {
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
        }
        hasLoadedProvider = true
    }

    private func switchToProvider(_ providerId: String) {
        if providerId == "dayflow" { return }

        let isEditingCurrent = providerId == currentProvider
        if isEditingCurrent {
            AnalyticsService.shared.capture("provider_edit_initiated", ["provider": providerId])
        } else {
            AnalyticsService.shared.capture("provider_switch_initiated", ["from": currentProvider, "to": providerId])
        }

        setupModalProvider = providerId
    }

    private func completeProviderSwitch(_ providerId: String) {
        let providerType: LLMProviderType
        switch providerId {
        case "ollama":
            let endpoint = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "http://localhost:11434"
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

        if let encoded = try? JSONEncoder().encode(providerType) {
            UserDefaults.standard.set(encoded, forKey: "llmProviderType")
        }
        UserDefaults.standard.set(providerId, forKey: "selectedLLMProvider")

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            currentProvider = providerId
        }
        applyProviderChangeSideEffects(for: providerId)

        if providerId == "gemini" {
            let preference = GeminiModelPreference.load()
            selectedGeminiModel = preference.primary
            savedGeminiModel = preference.primary
        }

        var props: [String: Any] = ["provider": providerId]
        if providerId == "ollama" {
            let localEngine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
            let localModelId = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "unknown"
            let localBaseURL = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "unknown"
            let localAPIKey = (UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            props["local_engine"] = localEngine
            props["model_id"] = localModelId
            props["base_url"] = localBaseURL
            props["has_api_key"] = !localAPIKey.isEmpty
        }
        AnalyticsService.shared.capture("provider_setup_completed", props)
        AnalyticsService.shared.setPersonProperties(["current_llm_provider": providerId])
    }

    private func persistGeminiModelSelection(_ model: GeminiModel, source: String) {
        guard model != savedGeminiModel else { return }
        savedGeminiModel = model
        GeminiModelPreference(primary: model).save()

        Task { @MainActor in
            await AnalyticsService.shared.capture("gemini_model_selected", [
                "source": source,
                "model": model.rawValue
            ])
        }
    }

    private var availableProviders: [CompactProviderInfo] {
        [
            CompactProviderInfo(
                id: "ollama",
                title: "Use local AI",
                summary: "Private & offline • 16GB+ RAM • less intelligent",
                badgeText: "MOST PRIVATE",
                badgeType: .green,
                icon: "desktopcomputer"
            ),
            CompactProviderInfo(
                id: "gemini",
                title: "Bring your own API keys",
                summary: "Gemini free tier • fast & accurate",
                badgeText: "RECOMMENDED",
                badgeType: .orange,
                icon: "key.fill"
            ),
            CompactProviderInfo(
                id: "chatgpt_claude",
                title: "Use ChatGPT or Claude",
                summary: "Free if you're already on a paid plan • hooks into their CLI tools",
                badgeText: "NEW",
                badgeType: .blue,
                icon: "bolt.horizontal.circle"
            )
        ].filter { $0.id != currentProvider }
    }

    private func statusText(for providerId: String) -> String? {
        guard currentProvider == providerId else { return nil }

        switch providerId {
        case "ollama":
            let engineName: String
            switch localEngine {
            case .ollama: engineName = "Ollama"
            case .lmstudio: engineName = "LM Studio"
            case .custom: engineName = "Custom"
            }
            let displayModel = localModelId.isEmpty ? "qwen2.5vl:3b" : localModelId
            let truncatedModel = displayModel.count > 30 ? String(displayModel.prefix(27)) + "..." : displayModel
            return "\(engineName) - \(truncatedModel)"
        case "gemini":
            return selectedGeminiModel.displayName
        case "chatgpt_claude":
            return chatCLIStatusLabel()
        default:
            return nil
        }
    }

    private func chatCLIStatusLabel() -> String {
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

    private var connectionHealthLabel: String {
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
        default:
            return "Diagnostics"
        }
    }
}

private struct ProviderSetupWrapper: Identifiable {
    let id: String
}

private struct CompactProviderInfo: Identifiable {
    let id: String
    let title: String
    let summary: String
    let badgeText: String
    let badgeType: BadgeType
    let icon: String
}

private struct CompactProviderRow: View {
    let provider: CompactProviderInfo
    let onSwitch: () -> Void

    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            Image(systemName: provider.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.black.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.7))
                .cornerRadius(8)

            // Title and summary
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.title)
                    .font(.custom("Nunito", size: 15))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.85))
                Text(provider.summary)
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.55))
            }

            Spacer()

            // Badge
            BadgeView(text: provider.badgeText, type: provider.badgeType)

            // Switch button
            DayflowSurfaceButton(
                action: onSwitch,
                content: {
                    Text("Switch")
                        .font(.custom("Nunito", size: 13))
                        .fontWeight(.semibold)
                },
                background: accentColor,
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 16,
                verticalPadding: 8,
                showOverlayStroke: true
            )
        }
        .padding(16)
        .background(Color.white.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.custom("Nunito", size: 18))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.85))
                if let subtitle {
                    Text(subtitle)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.45))
                }
            }
            content()
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 12)
        )
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

private struct LocalModelUpgradeSheet: View {
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
        .onChange(of: selectedEngine) { newEngine in
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
        .onChange(of: selectedModel) { newValue in
            onSelectionChanged(newValue)
        }
    }
}
private struct StorageLimitOption: Identifiable {
    let id: Int
    let label: String
    let bytes: Int64?

    var resolvedBytes: Int64 { bytes ?? Int64.max }
    var shortLabel: String {
        if bytes == nil { return "∞" }
        return label.replacingOccurrences(of: " GB", with: "")
    }
}

private extension SettingsView {
    static let storageOptions: [StorageLimitOption] = [
        StorageLimitOption(id: 0, label: "1 GB", bytes: 1_000_000_000),
        StorageLimitOption(id: 1, label: "2 GB", bytes: 2_000_000_000),
        StorageLimitOption(id: 2, label: "3 GB", bytes: 3_000_000_000),
        StorageLimitOption(id: 3, label: "5 GB", bytes: 5_000_000_000),
        StorageLimitOption(id: 4, label: "10 GB", bytes: 10_000_000_000),
        StorageLimitOption(id: 5, label: "20 GB", bytes: 20_000_000_000),
        StorageLimitOption(id: 6, label: "Unlimited", bytes: nil)
    ]
}

private enum StorageCategory {
    case recordings
    case timelapses

    var analyticsKey: String {
        switch self {
        case .recordings: return "recordings"
        case .timelapses: return "timelapses"
        }
    }

    var displayName: String {
        switch self {
        case .recordings: return "Recordings"
        case .timelapses: return "Timelapses"
        }
    }
}

private struct PendingLimit {
    let category: StorageCategory
    let index: Int
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(UpdaterManager.shared)
            .frame(width: 1400, height: 860)
    }
}
