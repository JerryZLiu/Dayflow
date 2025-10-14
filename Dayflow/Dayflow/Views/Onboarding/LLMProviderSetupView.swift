//
//  LLMProviderSetupView.swift
//  Dayflow
//
//  LLM provider setup flow with step-by-step configuration
//

import SwiftUI

struct LLMProviderSetupView: View {
    let providerType: String // "ollama" or "gemini"
    let onBack: () -> Void
    let onComplete: () -> Void
    
    // Layout constants
    private let sidebarWidth: CGFloat = 250
    private let fixedOffset: CGFloat = 50
    
    @StateObject private var setupState = ProviderSetupState()
    @State private var sidebarOpacity: Double = 0
    @State private var contentOpacity: Double = 0
    @State private var nextButtonHovered: Bool = false // legacy, unused after refactor
    @State private var googleButtonHovered: Bool = false // legacy, unused after refactor
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with Back button and Title on same line
            HStack(alignment: .center, spacing: 0) {
                // Back button container matching sidebar width
                HStack {
                    Button(action: handleBack) {
                        HStack(spacing: 12) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.black.opacity(0.7))
                                .frame(width: 20, alignment: .center)
                            
                            Text("Back")
                                .font(.custom("Nunito", size: 15))
                                .fontWeight(.medium)
                                .foregroundColor(.black.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    // Position where sidebar items start: 20 + 16 = 36px
                    .padding(.leading, 36) // Align with sidebar item structure
                    .pointingHandCursor()
                    
                    Spacer()
                }
                .frame(width: sidebarWidth)
                
                // Title in the content area
                HStack {
                    Text(providerType == "ollama" ? "Use local AI" : "Bring your own API keys")
                        .font(.custom("Nunito", size: 32))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    
                    Spacer()
                }
                .padding(.leading, 40) // Gap between sidebar and content
            }
            .padding(.leading, fixedOffset)
            .padding(.top, fixedOffset)
            .padding(.bottom, 40)
            
            // Main content area with sidebar and content
            HStack(alignment: .top, spacing: 40) {
                // Sidebar - fixed width 250px
                VStack(alignment: .leading, spacing: 0) {
                    SetupSidebarView(
                        steps: setupState.steps,
                        currentStepId: setupState.currentStep.id,
                        onStepSelected: { setupState.navigateToStep($0) }
                    )
                    Spacer()
                }
                .frame(width: sidebarWidth)
                .opacity(sidebarOpacity)
                
                // Content area - wrapped in VStack to match sidebar alignment
                VStack(alignment: .leading, spacing: 0) {
                    currentStepContent
                        .frame(maxWidth: 500, alignment: .leading)
                    Spacer()
                }
                .opacity(contentOpacity)
                .textSelection(.enabled)
            }
            .padding(.leading, fixedOffset)
            
            Spacer() // Push everything to top
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            setupState.configureSteps(for: providerType)
            animateAppearance()
        }
        .preferredColorScheme(.light)
    }
    
    private var nextButtonText: String {
        if let title = setupState.currentStep.contentType.informationTitle {
            if (title == "Testing" || title == "Test Connection") && !setupState.testSuccessful {
                return "Test Required"
            }
        }
        return "Next"
    }
    
    @ViewBuilder
    private var nextButton: some View {
        if setupState.isLastStep {
            DayflowSurfaceButton(
                action: { saveConfiguration(); onComplete() },
                content: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                        Text("Complete Setup").font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                    }
                },
                background: Color(red: 0.25, green: 0.17, blue: 0),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: true
            )
        } else {
            DayflowSurfaceButton(
                action: handleContinue,
                content: {
                    HStack(spacing: 6) {
                        Text(nextButtonText).font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                        if nextButtonText == "Next" {
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        }
                    }
                },
                background: Color(red: 0.25, green: 0.17, blue: 0),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: true
            )
            .disabled(!setupState.canContinue)
            .opacity(!setupState.canContinue ? 0.5 : 1.0)
        }
    }
    
    @ViewBuilder
    private var currentStepContent: some View {
        let step = setupState.currentStep
        
        switch step.contentType {
        case .localChoice:
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose your local AI engine")
                        .font(.custom("Nunito", size: 24))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    Text("We strongly recommend LM Studio for the best reliability. Ollama is also supported, but tends to have more connection and timeout issues.")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                }
                HStack(alignment: .center, spacing: 12) {
                    DayflowSurfaceButton(
                        action: { setupState.selectEngine(.lmstudio); openLMStudioDownload() },
                        content: {
                            AsyncImage(url: URL(string: "https://lmstudio.ai/_next/image?url=%2F_next%2Fstatic%2Fmedia%2Flmstudio-app-logo.11b4d746.webp&w=96&q=75")) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFit()
                                case .failure(_): Image(systemName: "desktopcomputer").resizable().scaledToFit().foregroundColor(.white.opacity(0.6))
                                case .empty: ProgressView().scaleEffect(0.7)
                                @unknown default: EmptyView()
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text("Download LM Studio")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        showOverlayStroke: true
                    )
                    Text("or")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.5))
                        .padding(.horizontal, 4)
                    DayflowSurfaceButton(
                        action: { setupState.selectEngine(.ollama); openOllamaDownload() },
                        content: {
                            AsyncImage(url: URL(string: "https://ollama.com/public/ollama.png")) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundColor(.white)
                                case .failure(_): Image(systemName: "shippingbox").resizable().scaledToFit().foregroundColor(.white.opacity(0.6))
                                case .empty: ProgressView().scaleEffect(0.7)
                                @unknown default: EmptyView()
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text("Download Ollama")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        showOverlayStroke: true
                    )
                }
                Text("Already have a local server? Make sure it’s OpenAI-compatible. You can set a custom base URL in the next step.")
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(.black.opacity(0.6))
                HStack { Spacer(); nextButton }
            }
        case .localModelInstall:
            VStack(alignment: .leading, spacing: 16) {
                Text("Install Qwen 2.5 VLM")
                    .font(.custom("Nunito", size: 24))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.9))
                if setupState.localEngine == .ollama {
                    Text("After installing Ollama, run this in your terminal to download the model (≈3GB):")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                    TerminalCommandView(
                        title: "Run this command:",
                        subtitle: "Downloads Qwen 2.5 Vision 3B for Ollama",
                        command: "ollama pull qwen2.5vl:3b"
                    )
                } else if setupState.localEngine == .lmstudio {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("After installing LM Studio, download the recommended model:")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))

                        DayflowSurfaceButton(
                            action: openLMStudioModelDownload,
                            content: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 14))
                                    Text("Download Qwen 2.5 VL in LM Studio").font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                                }
                            },
                            background: Color(red: 0.25, green: 0.17, blue: 0),
                            foreground: .white,
                            borderColor: .clear,
                            cornerRadius: 8,
                            horizontalPadding: 24,
                            verticalPadding: 12,
                            showOverlayStroke: true
                        )

                        VStack(alignment: .leading, spacing: 6) {
                            Text("This will open LM Studio and prompt you to download the model (≈3GB).")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.black.opacity(0.65))

                            Text("Once downloaded, turn on 'Local Server' in LM Studio (default http://localhost:1234)")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.black.opacity(0.65))
                        }
                        .padding(.top, 4)

                        // Fallback manual instructions
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Manual setup:")
                                .font(.custom("Nunito", size: 12))
                                .fontWeight(.semibold)
                                .foregroundColor(.black.opacity(0.5))
                            Text("1. Open LM Studio → Models tab")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.45))
                            Text("2. Search for 'Qwen2.5-VL-3B' and install the Instruct variant")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.45))
                        }
                        .padding(.top, 8)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use any OpenAI-compatible VLM")
                            .font(.custom("Nunito", size: 16))
                            .fontWeight(.semibold)
                            .foregroundColor(.black.opacity(0.85))
                        Text("Make sure your server exposes the OpenAI Chat Completions API and has a Qwen 2.5 Vision model installed.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.75))
                    }
                }
                HStack { Spacer(); nextButton }
            }
        case .terminalCommand(let command):
            VStack(alignment: .leading, spacing: 24) {
                TerminalCommandView(
                    title: "Terminal command:",
                    subtitle: "Copy the code below and try running it in your terminal",
                    command: command
                )
                
                HStack {
                    Spacer()
                    nextButton
                }
            }
            
        case .apiKeyInput:
            VStack(alignment: .leading, spacing: 24) {
                APIKeyInputView(
                    apiKey: $setupState.apiKey,
                    title: "Enter your API key:",
                    subtitle: "Paste your Gemini API key below",
                    placeholder: "AIza...",
                    onValidate: { key in
                        // Basic validation for now
                        return key.hasPrefix("AIza") && key.count > 30
                    }
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose your Gemini model")
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.85))

                    Picker("Gemini model", selection: $setupState.geminiModel) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.shortLabel).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(GeminiModelPreference(primary: setupState.geminiModel).fallbackSummary)
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.55))
                }
                .onChange(of: setupState.geminiModel) { _ in
                    setupState.persistGeminiModelSelection(source: "onboarding_picker")
                }
                
                HStack {
                    Spacer()
                    nextButton
                }
            }
            
        case .modelDownload(let command):
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Download the AI model")
                        .font(.custom("Nunito", size: 24))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    
                    Text("This model enables Dayflow to understand what's on your screen")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                }
                
                TerminalCommandView(
                    title: "Run this command:",
                    subtitle: "This will download the Qwen 2.5 Vision model (about 3GB)",
                    command: command
                )
                
                HStack {
                    Spacer()
                    nextButton
                }
            }
            
        case .information(let title, let description):
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.custom("Nunito", size: 24))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(description)
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                        // Additional guidance for the local intro step
                        if step.id == "intro" {
                            (
                                Text("Advanced users can pick any ") +
                                Text("vision-capable").fontWeight(.bold) +
                                Text(" LLM, but we strongly recommend using Qwen 2.5-VL 3B based on our internal benchmarks.")
                            )
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        }
                    }
                }

                // Content area scrolls if needed; Next stays visible below
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        if title == "Testing" || title == "Test Connection" {
                            if providerType == "gemini" {
                                TestConnectionView(
                                    onTestComplete: { success in
                                        setupState.hasTestedConnection = true
                                        setupState.testSuccessful = success
                                    }
                                )
                            } else {
                                // Engine selection: Ollama, LM Studio, Other
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Which tool are you using?")
                                        .font(.custom("Nunito", size: 14))
                                        .foregroundColor(.black.opacity(0.65))
                                    Picker("Engine", selection: $setupState.localEngine) {
                                        Text("LM Studio").tag(LocalEngine.lmstudio)
                                        Text("Ollama").tag(LocalEngine.ollama)
                                        Text("Other").tag(LocalEngine.custom)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: 380)
                                }
                                .onChange(of: setupState.localEngine) { newValue in
                                    setupState.selectEngine(newValue)
                                }

                                LocalLLMTestView(
                                    baseURL: $setupState.localBaseURL,
                                    modelId: $setupState.localModelId,
                                    engine: setupState.localEngine,
                                    showInputs: setupState.localEngine == .custom,
                                    onTestComplete: { success in
                                        setupState.hasTestedConnection = true
                                        setupState.testSuccessful = success
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 420)

                HStack {
                    Spacer()
                    nextButton
                }
            }
            
        case .apiKeyInstructions:
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Get your Gemini API key")
                        .font(.custom("Nunito", size: 24))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    
                    Text("Google's Gemini offers a generous free tier that should allow you to run Dayflow 24/7 for free - no credit card required")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("1.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .frame(width: 20, alignment: .leading)
                        
                        Group {
                            Text("Visit Google AI Studio ")
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(.black.opacity(0.8))
                            + Text("(aistudio.google.com)")
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(Color(red: 1, green: 0.42, blue: 0.02))
                                .underline()
                        }
                        .onTapGesture { openGoogleAIStudio() }
                        .pointingHandCursor()
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Text("2.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .frame(width: 20, alignment: .leading)
                        
                        Text("Click \"Get API key\" in the top right")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.8))
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Text("3.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .frame(width: 20, alignment: .leading)
                        
                        Text("Create a new API key and copy it")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.8))
                    }
                }
                .padding(.vertical, 12)
                
                // Buttons row with Open Google AI Studio on left, Next on right
                HStack {
                    DayflowSurfaceButton(
                        action: openGoogleAIStudio,
                        content: {
                            HStack(spacing: 8) {
                                Image(systemName: "safari").font(.system(size: 14))
                                Text("Open Google AI Studio").font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                            }
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 24,
                        verticalPadding: 12,
                        showOverlayStroke: true
                    )
                    Spacer()
                    nextButton
                }
            }
        }
    }
    
    private func handleBack() {
        if setupState.currentStepIndex == 0 {
            onBack()
        } else {
            setupState.goBack()
        }
    }
    
    private func handleContinue() {
        // Persist local config immediately after a successful local test when user advances
        if providerType == "ollama" {
            if case .information(let title, _) = setupState.currentStep.contentType,
               (title == "Testing" || title == "Test Connection"),
               setupState.testSuccessful {
                persistLocalSettings()
            }
        }

        if setupState.isLastStep {
            saveConfiguration()
            onComplete()
        } else {
            setupState.markCurrentStepCompleted()
            setupState.goNext()
        }
    }
    
    private func saveConfiguration() {
        // Save API key to keychain for Gemini
        if providerType == "gemini" && !setupState.apiKey.isEmpty {
            KeychainManager.shared.store(setupState.apiKey, for: "gemini")
            GeminiModelPreference(primary: setupState.geminiModel).save()
        }
        
        // Save local endpoint for local engine selection
        if providerType == "ollama" {
            persistLocalSettings()
        }
        
        // Mark setup as complete
        UserDefaults.standard.set(true, forKey: "\(providerType)SetupComplete")
    }

    // Persist provider choice + local settings without marking setup complete
    private func persistLocalSettings() {
        let endpoint = setupState.localBaseURL
        let type = LLMProviderType.ollamaLocal(endpoint: endpoint)
        if let encoded = try? JSONEncoder().encode(type) {
            UserDefaults.standard.set(encoded, forKey: "llmProviderType")
        }
        // Store model id for local engines
        UserDefaults.standard.set(setupState.localModelId, forKey: "llmLocalModelId")
        // Store local engine selection for header/model defaults
        UserDefaults.standard.set(setupState.localEngine.rawValue, forKey: "llmLocalEngine")
        // Store selected provider key for robustness across relaunches
        UserDefaults.standard.set("ollama", forKey: "selectedLLMProvider")
        // Also store the endpoint explicitly for other parts of the app if needed
        UserDefaults.standard.set(endpoint, forKey: "llmLocalBaseURL")
    }
    
    private func openGoogleAIStudio() {
        if let url = URL(string: "https://aistudio.google.com/app/apikey") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openOllamaDownload() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openLMStudioDownload() {
        if let url = URL(string: "https://lmstudio.ai/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openLMStudioModelDownload() {
        if let url = URL(string: "https://model.lmstudio.ai/download/lmstudio-community/Qwen2.5-VL-3B-Instruct-GGUF") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func animateAppearance() {
        withAnimation(.easeOut(duration: 0.4)) {
            sidebarOpacity = 1
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.4)) {
                contentOpacity = 1
            }
        }
    }
}

class ProviderSetupState: ObservableObject {
    @Published var steps: [SetupStep] = []
    @Published var currentStepIndex: Int = 0
    @Published var apiKey: String = ""
    @Published var hasTestedConnection: Bool = false
    @Published var testSuccessful: Bool = false
    @Published var geminiModel: GeminiModel
    // Local engine configuration
    @Published var localEngine: LocalEngine = .ollama
    @Published var localBaseURL: String = "http://localhost:11434"
    @Published var localModelId: String = "qwen2.5vl:3b"

    private var lastSavedGeminiModel: GeminiModel

    init() {
        let preference = GeminiModelPreference.load()
        self.geminiModel = preference.primary
        self.lastSavedGeminiModel = preference.primary
    }
    
    var currentStep: SetupStep {
        guard currentStepIndex < steps.count else {
            return SetupStep(id: "fallback", title: "Setup", contentType: .information("Complete", "Setup is complete"))
        }
        return steps[currentStepIndex]
    }
    
    var canContinue: Bool {
        switch currentStep.contentType {
        case .apiKeyInput:
            return !apiKey.isEmpty && apiKey.count > 20
        case .terminalCommand(_), .modelDownload(_), .localChoice, .localModelInstall, .information(_, _), .apiKeyInstructions:
            return true
        }
    }
    
    var isLastStep: Bool {
        return currentStepIndex == steps.count - 1
    }
    
    func configureSteps(for provider: String) {
        if provider == "ollama" {
            steps = [
                SetupStep(
                    id: "intro",
                    title: "Before you begin",
                    contentType: .information(
                        "For experienced users",
                        "This path is recommended only if you're comfortable running LLMs locally and debugging technical issues. If terms like vLLM or API endpoint don't ring a bell, we recommend going back and picking 'Bring your own API keys'. It's non-technical and takes about 30 seconds.\n\nFor local mode, Dayflow recommends Qwen 2.5-VL 3B as the core vision-language model."
                    )
                ),
                SetupStep(id: "choose", title: "Choose engine", contentType: .localChoice),
                SetupStep(id: "model", title: "Install model", contentType: .localModelInstall),
                SetupStep(id: "test", title: "Test connection", contentType: .information("Test Connection", "Click the button below to verify your local server responds to a simple chat completion.")),
                SetupStep(id: "complete", title: "Complete", contentType: .information("All set!", "Local AI is configured and ready to use with Dayflow."))
            ]
        } else { // gemini
            steps = [
                SetupStep(id: "getkey", title: "Get API key", 
                         contentType: .apiKeyInstructions),
                SetupStep(id: "enterkey", title: "Enter API key", 
                         contentType: .apiKeyInput),
                SetupStep(id: "verify", title: "Test connection", 
                         contentType: .information("Test Connection", "Click the button below to verify your API key works with Gemini")),
                SetupStep(id: "complete", title: "Complete", 
                         contentType: .information("All set!", "Gemini is now configured and ready to use with Dayflow."))
            ]
        }
    }
    
    func goNext() {
        // Save API key to keychain when moving from API key input step
        if currentStep.contentType.isApiKeyInput && !apiKey.isEmpty {
            KeychainManager.shared.store(apiKey, for: "gemini")
            // Reset test state when API key changes
            hasTestedConnection = false
            testSuccessful = false
            persistGeminiModelSelection(source: "onboarding_step")
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
            await AnalyticsService.shared.capture("gemini_model_selected", [
                "source": source,
                "model": geminiModel.rawValue
            ])
        }

        // Changing models should prompt the user to re-run the connection test
        hasTestedConnection = false
        testSuccessful = false
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
    case apiKeyInput
    case apiKeyInstructions
    case modelDownload(String)
    case information(String, String)
    case localChoice
    case localModelInstall
    
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


enum LocalEngine: String {
    case ollama
    case lmstudio
    case custom
}

extension ProviderSetupState {
    @MainActor func selectEngine(_ engine: LocalEngine) {
        localEngine = engine
        switch engine {
        case .ollama:
            localBaseURL = "http://localhost:11434"
            localModelId = "qwen2.5vl:3b"
        case .lmstudio:
            localBaseURL = "http://localhost:1234"
            localModelId = "qwen2.5-vl-3b-instruct"
        case .custom:
            break
        }

        // Track local engine selection for analytics
        AnalyticsService.shared.capture("local_engine_selected", [
            "engine": engine.rawValue,
            "base_url": localBaseURL,
            "default_model": localModelId
        ])
    }
    
    var localCurlCommand: String {
        let payload = "{\"model\":\"\(localModelId)\",\"messages\":[{\"role\":\"user\",\"content\":\"Say 'hello' and your model name.\"}],\"max_tokens\":50}"
        let authHeader = localEngine == .lmstudio ? " -H \"Authorization: Bearer lm-studio\"" : ""
        return "curl -s \(localBaseURL)/v1/chat/completions -H \"Content-Type: application/json\"\(authHeader) -d '\(payload)'"
    }
}

struct LocalLLMTestView: View {
    @Binding var baseURL: String
    @Binding var modelId: String
    let engine: LocalEngine
    var showInputs: Bool = true
    let onTestComplete: (Bool) -> Void

    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    private let successAccentColor = Color(red: 0.34, green: 1, blue: 0.45)

    @State private var isTesting = false
    @State private var resultMessage: String?
    @State private var success: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showInputs {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Base URL")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.6))
                    TextField(engine == .lmstudio ? "http://localhost:1234" : "http://localhost:11434", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model ID")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.6))
                    TextField(engine == .lmstudio ? "qwen2.5-vl-3b-instruct" : "qwen2.5vl:3b", text: $modelId)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            DayflowSurfaceButton(
                action: runTest,
                content: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: success ? "checkmark.circle.fill" : "bolt.fill").font(.system(size: 14))
                        }
                        Text(isTesting ? "Testing..." : (success ? "Test Successful!" : "Test Local API")).font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                    }
                },
                background: success ? successAccentColor.opacity(0.2) : accentColor,
                foreground: success ? .black : .white,
                borderColor: success ? successAccentColor.opacity(0.3) : .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: !success
            )
            .disabled(isTesting)
            
            if let msg = resultMessage {
                Text(msg)
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(success ? .black.opacity(0.7) : Color(hex: "E91515"))
                    .padding(.vertical, 6)
                if !success {
                    Text("If you get stuck here, you can go back and choose the ‘Bring your own key’ option — it only takes a minute to set up.")
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.55))
                        .padding(.top, 2)
                }
            }
        }
    }
    private func runTest() {
        guard !isTesting else { return }
        isTesting = true
        success = false
        resultMessage = nil
        
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            resultMessage = "Invalid base URL"
            isTesting = false
            onTestComplete(false)
            return
        }
        
        struct Req: Codable { let model: String; let messages: [Msg]; let max_tokens: Int }
        struct Msg: Codable { let role: String; let content: String }
        let req = Req(model: modelId, messages: [Msg(role: "user", content: "Say 'hello' and your model name.")], max_tokens: 50)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if engine == .lmstudio { request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONEncoder().encode(req)
        request.timeoutInterval = 15
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.resultMessage = error.localizedDescription
                    self.isTesting = false
                    self.onTestComplete(false)
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self.resultMessage = "No response"; self.isTesting = false; self.onTestComplete(false); return
                }
                if http.statusCode == 200 {
                    // Success: don't print raw response body; keep UI clean
                    self.resultMessage = nil
                    self.success = true
                    self.isTesting = false
                    self.onTestComplete(true)
                } else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    self.resultMessage = "HTTP \(http.statusCode): \(body)"
                    self.isTesting = false
                    self.onTestComplete(false)
                }
            }
        }.resume()
    }
}
