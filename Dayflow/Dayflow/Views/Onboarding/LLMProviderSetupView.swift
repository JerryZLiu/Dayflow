//
//  LLMProviderSetupView.swift
//  Dayflow
//
//  LLM provider setup flow with step-by-step configuration
//

import SwiftUI
import Foundation
import AppKit

private let cliSearchPaths: [String] = {
    let home = NSHomeDirectory()
    var paths = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "\(home)/.npm-global/bin",
        "\(home)/.local/bin",
        "\(home)/.cargo/bin",
        "\(home)/.bun/bin",
        "\(home)/.pyenv/bin",
        "\(home)/.pyenv/shims",
        "\(home)/.npm-global/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/path",
        "\(home)/.codeium/windsurf/bin",
        "\(home)/.lmstudio/bin"
    ]

    // Add nvm paths if nvm is installed (handles dynamic node versions)
    let nvmBase = "\(home)/.nvm/versions/node"
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
        for version in versions {
            paths.append("\(nvmBase)/\(version)/bin")
        }
    }

    return paths
}()

struct CLIResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

@discardableResult
func runCLI(
    _ command: String,
    args: [String] = [],
    env: [String: String]? = nil,
    cwd: URL? = nil
) throws -> CLIResult {
    let process = Process()
    let expandedCommand = (command as NSString).expandingTildeInPath
    if expandedCommand.hasPrefix("/") {
        guard FileManager.default.isExecutableFile(atPath: expandedCommand) else {
            throw NSError(domain: "StreamingCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Executable not found: \(expandedCommand)"])
        }
        process.executableURL = URL(fileURLWithPath: expandedCommand)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [expandedCommand] + args
    }
    process.currentDirectoryURL = cwd
    
    var environment = ProcessInfo.processInfo.environment
    if let overrides = env {
        environment.merge(overrides, uniquingKeysWith: { _, new in new })
    }
    
    var pathComponents: [String] = environment["PATH"]
        .map { $0.split(separator: ":").map { String($0) } } ?? []
    for rawPath in cliSearchPaths {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if !pathComponents.contains(expanded) {
            pathComponents.append(expanded)
        }
    }
    environment["PATH"] = pathComponents.joined(separator: ":")
    environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
    process.environment = environment
    
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    try process.run()
    process.waitUntilExit()
    
    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    
    return CLIResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
}

final class StreamingCLI {
    private var process: Process?
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    
    func cancel() {
        process?.terminate()
    }
    
    func run(
        command: String,
        args: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        onStdout: @escaping (String) -> Void,
        onStderr: @escaping (String) -> Void,
        onFinish: @escaping (Int32) -> Void
    ) {
        let proc = Process()
        process = proc
        
        let expandedCommand = (command as NSString).expandingTildeInPath
        if expandedCommand.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: expandedCommand) else {
                DispatchQueue.main.async {
                    onStderr("Executable not found or not executable: \(expandedCommand)\n")
                    onFinish(-1)
                }
                return
            }
            proc.executableURL = URL(fileURLWithPath: expandedCommand)
            proc.arguments = args
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [expandedCommand] + args
        }
        proc.currentDirectoryURL = cwd
        
        var environment = ProcessInfo.processInfo.environment
        if let overrides = env {
            environment.merge(overrides, uniquingKeysWith: { _, new in new })
        }
        var pathComponents: [String] = environment["PATH"]
            .map { $0.split(separator: ":").map { String($0) } } ?? []
        for rawPath in cliSearchPaths {
            let expanded = (rawPath as NSString).expandingTildeInPath
            if !pathComponents.contains(expanded) {
                pathComponents.append(expanded)
            }
        }
        environment["PATH"] = pathComponents.joined(separator: ":")
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        proc.environment = environment
        
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                onStdout(chunk)
            }
        }
        
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                onStderr(chunk)
            }
        }
        
        do {
            try proc.run()
            proc.terminationHandler = { process in
                self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    onFinish(process.terminationStatus)
                }
            }
        } catch {
            DispatchQueue.main.async {
                onStderr("Failed to start \(command): \(error.localizedDescription)")
                onFinish(-1)
            }
        }
    }
}

struct LLMProviderSetupView: View {
    let providerType: String // "ollama" or "gemini"
    let onBack: () -> Void
    let onComplete: () -> Void
    
    private var activeProviderType: String { providerType }
    
    private var headerTitle: String {
        switch activeProviderType {
        case "ollama":
            return "Use local AI"
        case "chatgpt_claude":
            return "Connect ChatGPT or Claude"
        default:
            return "Bring your own API keys"
        }
    }
    
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
                    Text(headerTitle)
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
            setupState.configureSteps(for: activeProviderType)
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
                Text("Install Qwen3-VL 4B")
                    .font(.custom("Nunito", size: 24))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.9))
                if setupState.localEngine == .ollama {
                    Text("After installing Ollama, run this in your terminal to download the model (≈5GB):")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                    TerminalCommandView(
                        title: "Run this command:",
                        subtitle: "Downloads Qwen3 Vision 4B for Ollama",
                        command: "ollama pull qwen3-vl:4b"
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
                                    Text("Download Qwen3-VL 4B in LM Studio").font(.custom("Nunito", size: 14)).fontWeight(.semibold)
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
                            Text("2. Search for 'Qwen3-VL-4B' and install the Instruct variant")
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
                        Text("Make sure your server exposes the OpenAI Chat Completions API and has Qwen3-VL 4B (or Qwen2.5-VL 3B if you need the legacy model) installed.")
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
                    Text("Choose your Gemini model. If you're on the free tier, pick 2.5 Pro, it's the most powerful model and is completely free to use. If you're on a paid plan, which is not recommended, I recommend 2.5 Flash-Lite to minimize costs.")
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
                    subtitle: "This will download the \(LocalModelPreset.qwen3VL4B.displayName) model (about 5GB)",
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
                        // Additional guidance for the local intro step only
                        if step.id == "intro" && providerType == "ollama" {
                            (
                                Text("Advanced users can pick any ") +
                                Text("vision-capable").fontWeight(.bold) +
                                Text(" LLM, but we strongly recommend using Qwen3-VL 4B based on our internal benchmarks.")
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
                            } else if providerType == "chatgpt_claude" {
                                ChatCLITestView(
                                    selectedTool: setupState.preferredCLITool,
                                    environment: setupState.cliEnvironment(),
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
                                        Text("Custom model").tag(LocalEngine.custom)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: 380)
                                }
                                .onChange(of: setupState.localEngine) { _, newValue in
                                    setupState.selectEngine(newValue)
                                }

                                LocalLLMTestView(
                                    baseURL: $setupState.localBaseURL,
                                    modelId: $setupState.localModelId,
                                    apiKey: $setupState.localAPIKey,
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
            
        case .cliDetection:
            ChatCLIDetectionStepView(
                codexStatus: setupState.codexCLIStatus,
                codexReport: setupState.codexCLIReport,
                claudeStatus: setupState.claudeCLIStatus,
                claudeReport: setupState.claudeCLIReport,
                isChecking: setupState.isCheckingCLIStatus,
                onRetry: { setupState.refreshCLIStatuses() },
                onInstall: { tool in openChatCLIInstallPage(for: tool) },
                selectedTool: setupState.preferredCLITool,
                onSelectTool: { tool in setupState.selectPreferredCLITool(tool) },
                nextButton: { nextButton }
            )
            .onAppear {
                setupState.ensureCLICheckStarted()
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
        if activeProviderType == "ollama" {
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
        if activeProviderType == "gemini" && !setupState.apiKey.isEmpty {
            KeychainManager.shared.store(setupState.apiKey, for: "gemini")
            GeminiModelPreference(primary: setupState.geminiModel).save()
        }
        
        // Save local endpoint for local engine selection
        if activeProviderType == "ollama" {
            persistLocalSettings()
        }
        
        // Mark setup as complete
        UserDefaults.standard.set(true, forKey: "\(activeProviderType)SetupComplete")
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
        LocalModelPreferences.syncPreset(for: setupState.localEngine, modelId: setupState.localModelId)
        // Store local engine selection for header/model defaults
        UserDefaults.standard.set(setupState.localEngine.rawValue, forKey: "llmLocalEngine")
        // Store selected provider key for robustness across relaunches
        UserDefaults.standard.set("ollama", forKey: "selectedLLMProvider")
        // Also store the endpoint explicitly for other parts of the app if needed
        UserDefaults.standard.set(endpoint, forKey: "llmLocalBaseURL")
        persistLocalAPIKey(setupState.localAPIKey)
    }

    private func persistLocalAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "llmLocalAPIKey")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "llmLocalAPIKey")
        }
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
        if let url = URL(string: "https://model.lmstudio.ai/download/lmstudio-community/Qwen3-VL-4B-Instruct-GGUF") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openChatCLIInstallPage(for tool: CLITool) {
        guard let url = tool.installURL else { return }
        NSWorkspace.shared.open(url)
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
    @Published var localModelId: String = LocalModelPreferences.defaultModelId(for: .ollama)
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
    @Published var cliPrompt: String = "Say hello"
    @Published var codexStreamOutput: String = ""
    @Published var claudeStreamOutput: String = ""
    @Published var isRunningCodexStream: Bool = false
    @Published var isRunningClaudeStream: Bool = false
    @Published var preferredCLITool: CLITool? = ProviderSetupState.loadStoredPreferredCLITool()

    private var lastSavedGeminiModel: GeminiModel
    private var hasStartedCLICheck = false
    private let codexStreamer = StreamingCLI()
    private let claudeStreamer = StreamingCLI()

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
        case .cliDetection:
            return isSelectedCLIToolReady
        case .information(_, _):
            if currentStep.id == "verify" || currentStep.id == "test" {
                return testSuccessful
            }
            return true
        case .terminalCommand(_), .modelDownload(_), .localChoice, .localModelInstall, .apiKeyInstructions:
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
                        "This path is recommended only if you're comfortable running LLMs locally and debugging technical issues. If terms like vLLM or API endpoint don't ring a bell, we recommend going back and picking 'Bring your own API keys'. It's non-technical and takes about 30 seconds.\n\nFor local mode, Dayflow recommends Qwen3-VL 4B as the core vision-language model (Qwen2.5-VL 3B remains available if you need a smaller download)."
                    )
                ),
                SetupStep(id: "choose", title: "Choose engine", contentType: .localChoice),
                SetupStep(id: "model", title: "Install model", contentType: .localModelInstall),
                SetupStep(id: "test", title: "Test connection", contentType: .information("Test Connection", "Click the button below to verify your local server responds to a simple chat completion.")),
                SetupStep(id: "complete", title: "Complete", contentType: .information("All set!", "Local AI is configured and ready to use with Dayflow."))
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
                )
            ]
            codexCLIStatus = .unknown
            claudeCLIStatus = .unknown
            codexCLIReport = nil
            claudeCLIReport = nil
            isCheckingCLIStatus = false
            hasStartedCLICheck = false
            cancelCodexStream()
            cancelClaudeStream()
            codexStreamOutput = ""
            claudeStreamOutput = ""
            cliPrompt = "Say hello"
        default: // gemini
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
    
    private var isSelectedCLIToolReady: Bool {
        guard let preferredCLITool else { return false }
        return isToolAvailable(preferredCLITool)
    }
    
    func ensureCLICheckStarted() {
        guard !hasStartedCLICheck else { return }
        hasStartedCLICheck = true
        refreshCLIStatuses()
    }
    
    func refreshCLIStatuses() {
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
            await MainActor.run {
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
    
    func cliEnvironment(overrides: [String: String]? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var components = env["PATH"].map { $0.split(separator: ":").map { String($0) } } ?? []
        for raw in CLIDetector.searchPaths {
            let expanded = (raw as NSString).expandingTildeInPath
            if !components.contains(expanded) {
                components.append(expanded)
            }
        }
        env["PATH"] = components.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        if let overrides = overrides {
            env.merge(overrides, uniquingKeysWith: { _, new in new })
        }
        return env
    }
    
    func selectPreferredCLITool(_ tool: CLITool) {
        guard isToolAvailable(tool) else { return }
        preferredCLITool = tool
        persistPreferredCLITool()
    }
    
    func persistPreferredCLITool() {
        guard let tool = preferredCLITool else {
            UserDefaults.standard.removeObject(forKey: Self.cliPreferenceKey)
            return
        }
        UserDefaults.standard.set(tool.rawValue, forKey: Self.cliPreferenceKey)
    }
    
    private func ensurePreferredCLIToolIsValid() {
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
    
    private func isToolAvailable(_ tool: CLITool) -> Bool {
        switch tool {
        case .codex:
            if codexCLIStatus.isInstalled { return true }
            return codexCLIReport?.resolvedPath != nil
        case .claude:
            if claudeCLIStatus.isInstalled { return true }
            return claudeCLIReport?.resolvedPath != nil
        }
    }
    
    private static func loadStoredPreferredCLITool() -> CLITool? {
        guard let raw = UserDefaults.standard.string(forKey: Self.cliPreferenceKey) else {
            return nil
        }
        return CLITool(rawValue: raw)
    }
    
    private static let cliPreferenceKey = "chatCLIPreferredTool"
    
    func runCodexStream() {
        guard !isRunningCodexStream else { return }
        guard let path = CLIDetector.resolveExecutablePath(for: .codex) else {
            codexStreamOutput = "Codex CLI not found."
            return
        }
        let prompt = cliPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say hello" : cliPrompt
        codexStreamOutput = "Running \(path) with prompt: \(prompt)\n\n"
        isRunningCodexStream = true
        codexStreamer.run(
            command: path,
            args: ["exec", "--skip-git-repo-check", "-c", "model_reasoning_effort=high", "-c", "mcp_servers={}", "-c", "rmcp_client=false", "-c", "features.web_search_request=false", "--", prompt],
            env: cliEnvironment(),
            onStdout: { [weak self] chunk in
                self?.codexStreamOutput.append(chunk)
            },
            onStderr: { [weak self] chunk in
                self?.codexStreamOutput.append("\n[stderr] \(chunk)")
            },
            onFinish: { [weak self] code in
                guard let self else { return }
                self.codexStreamOutput.append("\n\nExited \(code)\n")
                self.isRunningCodexStream = false
            }
        )
    }
    
    func cancelCodexStream() {
        codexStreamer.cancel()
        if isRunningCodexStream {
            codexStreamOutput.append("\n\nCancelled.\n")
        }
        isRunningCodexStream = false
    }
    
    func runClaudeStream() {
        guard !isRunningClaudeStream else { return }
        guard let path = CLIDetector.resolveExecutablePath(for: .claude) else {
            claudeStreamOutput = "Claude CLI not found."
            return
        }
        let prompt = cliPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say hello" : cliPrompt
        claudeStreamOutput = "Running \(path) with prompt: \(prompt)\n\n"
        isRunningClaudeStream = true
        claudeStreamer.run(
            command: path,
            args: ["--print", "--output-format", "json", "--strict-mcp-config", "--", prompt],
            env: cliEnvironment(),
            onStdout: { [weak self] chunk in
                self?.claudeStreamOutput.append(chunk)
            },
            onStderr: { [weak self] chunk in
                self?.claudeStreamOutput.append("\n[stderr] \(chunk)")
            },
            onFinish: { [weak self] code in
                guard let self else { return }
                self.claudeStreamOutput.append("\n\nExited \(code)\n")
                self.isRunningClaudeStream = false
            }
        )
    }
    
    func cancelClaudeStream() {
        claudeStreamer.cancel()
        if isRunningClaudeStream {
            claudeStreamOutput.append("\n\nCancelled.\n")
        }
        isRunningClaudeStream = false
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
        let defaultModel = LocalModelPreferences.defaultModelId(for: engine == .custom ? .ollama : engine)
        localModelId = defaultModel
        LocalModelPreferences.syncPreset(for: engine, modelId: defaultModel)

        // Track local engine selection for analytics
        AnalyticsService.shared.capture("local_engine_selected", [
            "engine": engine.rawValue,
            "base_url": localBaseURL,
            "default_model": defaultModel,
            "has_api_key": !localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ])
    }
    
    var localCurlCommand: String {
        let payload = "{\"model\":\"\(localModelId)\",\"messages\":[{\"role\":\"user\",\"content\":\"Say 'hello' and your model name.\"}],\"max_tokens\":50}"
        let authHeader = localEngine == .lmstudio ? " -H \"Authorization: Bearer lm-studio\"" : ""
        let endpoint = LocalEndpointUtilities.chatCompletionsURL(baseURL: localBaseURL)?.absoluteString ?? "\(localBaseURL)/v1/chat/completions"
        return "curl -s \(endpoint) -H \"Content-Type: application/json\"\(authHeader) -d '\(payload)'"
    }
}

private enum LocalLLMTestConstants {
    static let blankImageDataURL = LocalLLMTestImageFactory.blankImageDataURL(width: 1280, height: 720)
    static let prompt = "What color is this image? Answer with a single word."
    static let slowMachineMessage = "It took longer than 30 seconds, so your machine doesn't appear powerful enough to run this model locally."
    static let maxLatency: TimeInterval = 30
}

private enum LocalLLMTestImageFactory {
    static func blankImageDataURL(width: Int, height: Int) -> String {
        guard let data = makeWhiteImageData(width: width, height: height) else {
            assertionFailure("Failed to build local LLM test image")
            return ""
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func makeWhiteImageData(width: Int, height: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            rect.fill()
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .jpeg, properties: [:])
    }
}

struct LocalLLMTestView: View {
    @Binding private var baseURL: String
    @Binding private var modelId: String
    @Binding private var apiKey: String
    private let engine: LocalEngine
    private let showInputs: Bool
    private let buttonLabel: String
    private let basePlaceholder: String?
    private let modelPlaceholder: String?
    private let onTestComplete: (Bool) -> Void

    init(
        baseURL: Binding<String>,
        modelId: Binding<String>,
        apiKey: Binding<String> = .constant(""),
        engine: LocalEngine,
        showInputs: Bool = true,
        buttonLabel: String = "Test Local API",
        basePlaceholder: String? = nil,
        modelPlaceholder: String? = nil,
        onTestComplete: @escaping (Bool) -> Void
    ) {
        _baseURL = baseURL
        _modelId = modelId
        _apiKey = apiKey
        self.engine = engine
        self.showInputs = showInputs
        self.buttonLabel = buttonLabel
        self.basePlaceholder = basePlaceholder
        self.modelPlaceholder = modelPlaceholder
        self.onTestComplete = onTestComplete
    }

    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    private let successAccentColor = Color(red: 0.34, green: 1, blue: 0.45)
    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                    TextField(basePlaceholder ?? engine.defaultBaseURL, text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model ID")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.6))
                    TextField(modelPlaceholder ?? LocalModelPreferences.defaultModelId(for: engine), text: $modelId)
                        .textFieldStyle(.roundedBorder)
                }

                if engine == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API key (optional)")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.6))
                        SecureField("sk-live-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        Text("Stored locally in UserDefaults and sent as a Bearer token for custom endpoints (LiteLLM, OpenRouter, etc.)")
                            .font(.custom("Nunito", size: 11))
                            .foregroundColor(.black.opacity(0.5))
                    }
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
                        let idleLabel = success ? "Test Successful!" : buttonLabel
                        Text(isTesting ? "Testing..." : idleLabel)
                            .font(.custom("Nunito", size: 14))
                            .fontWeight(.semibold)
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

        guard let url = LocalEndpointUtilities.chatCompletionsURL(baseURL: baseURL) else {
            resultMessage = "Invalid base URL"
            isTesting = false
            onTestComplete(false)
            return
        }

        let payload = LocalLLMChatRequest(
            model: modelId,
            messages: [
                LocalLLMChatMessage(
                    role: "user",
                    content: [
                        .text(LocalLLMTestConstants.prompt),
                        .imageDataURL(LocalLLMTestConstants.blankImageDataURL)
                    ]
                )
            ],
            maxTokens: 10
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if engine == .lmstudio { request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization") }
        if engine == .custom && !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try? encoder.encode(payload)
        request.timeoutInterval = 35

        let startedAt = Date()

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let duration = Date().timeIntervalSince(startedAt)
                if duration > LocalLLMTestConstants.maxLatency {
                    self.resultMessage = LocalLLMTestConstants.slowMachineMessage
                    self.success = false
                    self.isTesting = false
                    self.onTestComplete(false)
                    return
                }
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

private struct LocalLLMChatRequest: Codable {
    let model: String
    let messages: [LocalLLMChatMessage]
    let maxTokens: Int
}

private struct LocalLLMChatMessage: Codable {
    let role: String
    let content: [LocalLLMChatContent]
}

private struct LocalLLMChatContent: Codable {
    let type: String
    let text: String?
    let imageURL: LocalLLMChatImageURL?

    static func text(_ value: String) -> LocalLLMChatContent {
        LocalLLMChatContent(type: "text", text: value, imageURL: nil)
    }

    static func imageDataURL(_ url: String) -> LocalLLMChatContent {
        LocalLLMChatContent(type: "image_url", text: nil, imageURL: LocalLLMChatImageURL(url: url))
    }
}

private struct LocalLLMChatImageURL: Codable {
    let url: String
}

struct ChatCLITestView: View {
    let selectedTool: CLITool?
    let environment: [String: String]
    let onTestComplete: (Bool) -> Void

    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    private let successAccentColor = Color(red: 0.34, green: 1, blue: 0.45)

    @State private var isTesting = false
    @State private var success = false
    @State private var resultMessage: String?
    @State private var debugOutput: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("We'll ask your CLI to say hello to verify it's working and signed in.")
                .font(.custom("Nunito", size: 13))
                .foregroundColor(.black.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            DayflowSurfaceButton(
                action: runTest,
                content: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: success ? "checkmark.circle.fill" : "bolt.fill").font(.system(size: 14))
                        }
                        let idleLabel = success ? "Test Successful!" : "Test CLI"
                        Text(isTesting ? "Testing..." : idleLabel)
                            .font(.custom("Nunito", size: 14))
                            .fontWeight(.semibold)
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
            .disabled(isTesting || selectedTool == nil)
            .opacity(selectedTool == nil ? 0.5 : 1.0)

            if selectedTool == nil {
                Text("Select ChatGPT or Claude above before running the test.")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.6))
            }

            if let msg = resultMessage {
                Text(msg)
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(success ? .black.opacity(0.7) : Color(hex: "E91515"))
                    .padding(.vertical, 6)
            }

            // Debug output - shows raw CLI response for troubleshooting
            if let debug = debugOutput, !success {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Debug output:")
                        .font(.custom("Nunito", size: 11))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.5))
                    ScrollView {
                        Text(debug)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.black.opacity(0.6))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Color.black.opacity(0.03))
                    .cornerRadius(6)
                }
                .padding(.top, 4)
            }
        }
    }

    private func runTest() {
        guard !isTesting else { return }
        guard let tool = selectedTool else {
            resultMessage = "Pick ChatGPT or Claude first."
            return
        }

        isTesting = true
        success = false
        resultMessage = nil
        debugOutput = nil

        Task.detached {
            let outcome: Result<CLIResult, Error> = {
                do {
                    return .success(try performTest(for: tool))
                } catch {
                    return .failure(error)
                }
            }()

            await MainActor.run {
                isTesting = false
                switch outcome {
                case .success(let cliResult):
                    // Build debug output for troubleshooting
                    var debugParts: [String] = []
                    debugParts.append("Tool: \(tool.shortName)")
                    debugParts.append("Exit code: \(cliResult.exitCode)")
                    if !cliResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        debugParts.append("stdout:\n\(cliResult.stdout)")
                    }
                    if !cliResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        debugParts.append("stderr:\n\(cliResult.stderr)")
                    }
                    debugOutput = debugParts.joined(separator: "\n")

                    // Check exit code FIRST - non-zero means failure
                    if cliResult.exitCode != 0 {
                        success = false
                        if let authError = detectAuthError(cliResult, for: tool) {
                            resultMessage = authError
                        } else {
                            let stderrTrimmed = cliResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                            if stderrTrimmed.isEmpty {
                                if tool == .claude {
                                    resultMessage = "Claude CLI returned an error. You may need to sign in — run 'claude login' in Terminal."
                                } else {
                                    resultMessage = "Codex CLI returned an error. You may need to sign in — run 'codex auth' in Terminal."
                                }
                            } else {
                                resultMessage = "CLI error: \(stderrTrimmed.prefix(150))"
                            }
                        }
                        onTestComplete(false)
                        return
                    }

                    // Exit code is 0, now check for "hello" in response
                    let passed = parseForHello(cliResult)
                    success = passed
                    if passed {
                        resultMessage = "CLI is working!"
                        debugOutput = nil // Clear debug output on success
                    } else if cliResult.stdout.isEmpty {
                        resultMessage = "CLI returned empty response. Make sure you're signed in."
                    } else {
                        let preview = cliResult.stdout.prefix(100)
                        resultMessage = "Got: \"\(preview)\" — expected 'hello'"
                    }
                    onTestComplete(passed)
                case .failure(let error):
                    success = false
                    resultMessage = error.localizedDescription
                    debugOutput = "Tool: \(tool.shortName)\nError: \(error.localizedDescription)"
                    onTestComplete(false)
                }
            }
        }
    }

    private func performTest(for tool: CLITool) throws -> CLIResult {
        guard let path = CLIDetector.resolveExecutablePath(for: tool) else {
            throw NSError(domain: "ChatCLITest", code: 1, userInfo: [NSLocalizedDescriptionKey: "CLI not found for \(tool.shortName)."])
        }

        let prompt = "Say hello. Respond with just the word 'hello' and nothing else."
        // Use a sandboxed directory to avoid permission prompts for Downloads/Desktop
        let safeWorkingDir = FileManager.default.temporaryDirectory

        switch tool {
        case .codex:
            // Explicitly set reasoning effort to override any invalid stored values
            // --skip-git-repo-check needed because app runs from sandboxed directory
            // Disable MCP servers to avoid connecting to user's configured servers during test
            // -- separator ensures prompt isn't parsed as an option
            return try runCLI(path, args: ["exec", "--skip-git-repo-check", "-c", "model_reasoning_effort=high", "-c", "mcp_servers={}", "-c", "rmcp_client=false", "-c", "features.web_search_request=false", "--", prompt], env: environment, cwd: safeWorkingDir)
        case .claude:
            // --strict-mcp-config disables all user MCP servers
            // -- separator ensures prompt isn't parsed as an option
            return try runCLI(path, args: ["--print", "--output-format", "text", "--strict-mcp-config", "--", prompt], env: environment, cwd: safeWorkingDir)
        }
    }

    private func parseForHello(_ result: CLIResult) -> Bool {
        let combined = (result.stdout + " " + result.stderr).lowercased()
        return combined.contains("hello")
    }

    private func detectAuthError(_ result: CLIResult, for tool: CLITool) -> String? {
        let combined = (result.stdout + " " + result.stderr).lowercased()

        // Check for common auth failure patterns
        let isAuthError = combined.contains("invalid api key")
            || combined.contains("please run /login")
            || combined.contains("401 unauthorized")
            || combined.contains("not logged in")
            || combined.contains("codex auth")
            || combined.contains("claude login")
            || combined.contains("authentication required")
            || combined.contains("unauthorized")

        guard isAuthError else { return nil }

        // Return the correct message based on which tool we're actually testing
        switch tool {
        case .claude:
            return "Claude CLI is not signed in. Run 'claude login' in Terminal to authenticate."
        case .codex:
            return "Codex CLI is not signed in. Run 'codex auth' in Terminal to authenticate."
        }
    }
}

enum CLITool: String, CaseIterable {
    case codex
    case claude
    
    var displayName: String {
        switch self {
        case .codex: return "ChatGPT (Codex CLI)"
        case .claude: return "Claude Code"
        }
    }
    
    var shortName: String {
        switch self {
        case .codex: return "ChatGPT"
        case .claude: return "Claude"
        }
    }
    
    var subtitle: String {
        switch self {
        case .codex:
            return "OpenAI's ChatGPT desktop tooling with codex CLI"
        case .claude:
            return "Anthropic's Claude Code command-line helper"
        }
    }
    
    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }
    
    var versionCommand: String {
        "\(executableName) --version"
    }
    
    var installURL: URL? {
        switch self {
        case .codex:
            return URL(string: "https://developers.openai.com/codex/cli/")
        case .claude:
            return URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")
        }
    }
    
    var iconName: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "bolt.horizontal.circle"
        }
    }
}

enum CLIDetectionState: Equatable {
    case unknown
    case checking
    case installed(version: String)
    case notFound
    case failed(message: String)
    
    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
    
    var statusLabel: String {
        switch self {
        case .unknown:
            return "Not checked"
        case .checking:
            return "Checking…"
        case .installed:
            return "Installed"
        case .notFound:
            return "Not installed"
        case .failed:
            return "Error"
        }
    }
    
    var detailMessage: String? {
        switch self {
        case .installed(let version):
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }
}

struct CLIDetectionReport {
    let state: CLIDetectionState
    let resolvedPath: String?
    let stdout: String?
    let stderr: String?
}

struct CLIDetector {
    static var searchPaths: [String] { cliSearchPaths }
    
    static func detect(tool: CLITool) async -> CLIDetectionReport {
        guard let executablePath = resolveExecutablePath(for: tool) else {
            return CLIDetectionReport(state: .notFound, resolvedPath: nil, stdout: nil, stderr: nil)
        }
        do {
            let result = try runCLI(executablePath, args: ["--version"])
            if result.exitCode == 0 {
                let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
                let summary = firstLine.isEmpty ? "\(tool.shortName) detected" : firstLine
                return CLIDetectionReport(state: .installed(version: summary), resolvedPath: executablePath, stdout: result.stdout, stderr: result.stderr)
            }
            if result.exitCode == 127 || result.stderr.contains("not found") {
                return CLIDetectionReport(state: .notFound, resolvedPath: executablePath, stdout: result.stdout, stderr: result.stderr)
            }
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return CLIDetectionReport(state: .failed(message: "Exit code \(result.exitCode)"), resolvedPath: executablePath, stdout: result.stdout, stderr: result.stderr)
            }
            return CLIDetectionReport(state: .failed(message: message), resolvedPath: executablePath, stdout: result.stdout, stderr: result.stderr)
        } catch {
            return CLIDetectionReport(state: .failed(message: error.localizedDescription), resolvedPath: executablePath, stdout: nil, stderr: nil)
        }
    }
    
    static func resolveExecutablePath(for tool: CLITool) -> String? {
        resolveExecutablePath(named: tool.executableName)
    }
    
    private static func resolveExecutablePath(named name: String) -> String? {
        let fileManager = FileManager.default
        var searchDirectories: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            searchDirectories.append(contentsOf: envPath.split(separator: ":").map { String($0) })
        }
        searchDirectories.append(contentsOf: cliSearchPaths)
        var seen = Set<String>()
        for directory in searchDirectories {
            let expanded = (directory as NSString).expandingTildeInPath
            if !seen.insert(expanded).inserted {
                continue
            }
            let candidate = (expanded as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
    
    static func runDebugCommand(_ command: String) -> CLIResult {
        do {
            return try runCLI("bash", args: ["-lc", command])
        } catch {
            return CLIResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
    }
}

struct ChatCLIDetectionStepView<NextButton: View>: View {
    let codexStatus: CLIDetectionState
    let codexReport: CLIDetectionReport?
    let claudeStatus: CLIDetectionState
    let claudeReport: CLIDetectionReport?
    let isChecking: Bool
    let onRetry: () -> Void
    let onInstall: (CLITool) -> Void
    let selectedTool: CLITool?
    let onSelectTool: (CLITool) -> Void
    @ViewBuilder let nextButton: () -> NextButton
    
    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Dayflow can talk to ChatGPT (via the Codex CLI) or Claude Code. You only need one installed and signed in on this Mac. After installing, run `codex auth` or `claude login` in Terminal to connect it to your account.")
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.6))
            
            HStack(alignment: .top, spacing: 14) {
                ChatCLIToolStatusRow(
                    tool: .codex,
                    status: codexStatus,
                    onInstall: { onInstall(.codex) }
                )
                ChatCLIToolStatusRow(
                    tool: .claude,
                    status: claudeStatus,
                    onInstall: { onInstall(.claude) }
                )
            }
            
            Text("Tip: Once both are installed, you can choose which provider Dayflow uses from Settings → AI Provider.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.5))

            VStack(alignment: .leading, spacing: 10) {
                Text("Choose which provider Dayflow should use")
                    .font(.custom("Nunito", size: 13))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.65))
                HStack(spacing: 12) {
                    ForEach(CLITool.allCases, id: \.self) { tool in
                        selectionButton(for: tool)
                    }
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.5))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            
            HStack {
                DayflowSurfaceButton(
                    action: {
                        if !isChecking {
                            onRetry()
                        }
                    },
                    content: {
                        HStack(spacing: 8) {
                            if isChecking {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                            }
                            Text(isChecking ? "Checking…" : "Re-check")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        }
                    },
                    background: accentColor,
                    foreground: .white,
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 20,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )
                .disabled(isChecking)
                
                Spacer()
                
                nextButton()
                    .opacity(canContinue ? 1.0 : 0.5)
                    .allowsHitTesting(canContinue)
            }
        }
    }
    
    private var canContinue: Bool {
        guard let selectedTool else { return false }
        return isToolAvailable(selectedTool)
    }
    
    private func isToolAvailable(_ tool: CLITool) -> Bool {
        switch tool {
        case .codex:
            if codexStatus.isInstalled { return true }
            return codexReport?.resolvedPath != nil
        case .claude:
            if claudeStatus.isInstalled { return true }
            return claudeReport?.resolvedPath != nil
        }
    }
    
    @ViewBuilder
    private func selectionButton(for tool: CLITool) -> some View {
        let enabled = isToolAvailable(tool)
        Button(action: {
            if enabled {
                onSelectTool(tool)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: selectedTool == tool ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(enabled ? accentColor : Color.gray.opacity(0.6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.shortName)
                        .font(.custom("Nunito", size: 13))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(enabled ? 0.85 : 0.4))
                    Text(enabled ? "Ready to use" : "Install to enable")
                        .font(.custom("Nunito", size: 11))
                        .foregroundColor(.black.opacity(enabled ? 0.5 : 0.35))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selectedTool == tool ? Color.white.opacity(0.9) : Color.white.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selectedTool == tool ? accentColor.opacity(0.4) : Color.black.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
    }
}

struct ChatCLIToolStatusRow: View {
    let tool: CLITool
    let status: CLIDetectionState
    let onInstall: () -> Void

    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Icon and title row
            HStack(spacing: 10) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black.opacity(0.75))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.7))
                    .cornerRadius(6)

                Text(tool.shortName)
                    .font(.custom("Nunito", size: 15))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.9))

                Spacer()

                statusView
            }

            // Version info if installed
            if let detail = status.detailMessage, !detail.isEmpty {
                Text(detail)
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(.black.opacity(0.55))
                    .lineLimit(1)
            }

            // Install button if needed
            if shouldShowInstallButton {
                DayflowSurfaceButton(
                    action: onInstall,
                    content: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 11, weight: .semibold))
                            Text(installLabel)
                                .font(.custom("Nunito", size: 12))
                                .fontWeight(.semibold)
                        }
                    },
                    background: .white.opacity(0.85),
                    foreground: accentColor,
                    borderColor: accentColor.opacity(0.35),
                    cornerRadius: 6,
                    horizontalPadding: 12,
                    verticalPadding: 6,
                    showOverlayStroke: true
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .checking, .unknown:
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.5)
                Text(status.statusLabel)
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(accentColor.opacity(0.12))
            .cornerRadius(999)
        case .installed:
            Text(status.statusLabel)
                .font(.custom("Nunito", size: 11))
                .fontWeight(.semibold)
                .foregroundColor(Color(red: 0.13, green: 0.7, blue: 0.23))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0.13, green: 0.7, blue: 0.23).opacity(0.17))
                .cornerRadius(999)
        case .notFound:
            Text(status.statusLabel)
                .font(.custom("Nunito", size: 11))
                .fontWeight(.semibold)
                .foregroundColor(Color(hex: "E91515"))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(hex: "FFD1D1"))
                .cornerRadius(999)
        case .failed:
            Text(status.statusLabel)
                .font(.custom("Nunito", size: 11))
                .fontWeight(.semibold)
                .foregroundColor(Color(red: 0.91, green: 0.34, blue: 0.16))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0.91, green: 0.34, blue: 0.16).opacity(0.18))
                .cornerRadius(999)
        }
    }

    private var shouldShowInstallButton: Bool {
        switch status {
        case .notFound, .failed:
            return tool.installURL != nil
        default:
            return false
        }
    }

    private var installLabel: String {
        switch status {
        case .failed:
            return "Setup guide"
        default:
            return "Install"
        }
    }
}

struct DebugField: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("Nunito", size: 11))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.55))
            ScrollView(.vertical, showsIndicators: true) {
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.black.opacity(0.75))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.white.opacity(0.85))
                    .cornerRadius(6)
            }
            .frame(maxHeight: 100)
        }
    }
}

struct DebugCommandConsole: View {
    @Binding var command: String
    let output: String
    let isRunning: Bool
    let runAction: () -> Void
    
    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run a command as Dayflow")
                .font(.custom("Nunito", size: 13))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.7))
            Text("Helpful for checking PATH differences. We run using the same environment as the detection step.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.55))
            HStack(spacing: 10) {
                TextField("Command", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                DayflowSurfaceButton(
                    action: runAction,
                    content: {
                        HStack(spacing: 6) {
                            if isRunning {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                            }
                            Text(isRunning ? "Running..." : "Run")
                                .font(.custom("Nunito", size: 13))
                                .fontWeight(.semibold)
                        }
                    },
                    background: accentColor,
                    foreground: .white,
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )
                .disabled(isRunning)
            }
            ScrollView {
                Text(output.isEmpty ? "Output will appear here" : output)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.black.opacity(output.isEmpty ? 0.4 : 0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(0.85))
                    .cornerRadius(8)
            }
            .frame(maxHeight: 160)
        }
        .padding(16)
        .background(Color.white.opacity(0.55))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}
