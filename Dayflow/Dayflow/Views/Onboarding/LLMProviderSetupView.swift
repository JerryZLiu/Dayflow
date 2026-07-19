import AppKit
import Foundation
import SwiftUI

struct LLMProviderSetupView: View {
  let providerType: LLMProviderID
  let onBack: () -> Void
  let onComplete: () -> Bool

  var headerTitle: String {
    switch providerType {
    case .local:
      return "Use local AI"
    case .chatGPT:
      return "Connect ChatGPT"
    case .claude:
      return "Connect Claude"
    case .openAICompatible:
      return "Connect an AI endpoint"
    case .minimax:
      return "Connect MiniMax M3"
    case .gemini:
      return "Gemini"
    case .dayflow:
      return "Dayflow Pro"
    }
  }

  // Layout constants
  let sidebarWidth: CGFloat = 250
  let fixedOffset: CGFloat = 50

  @StateObject var setupState = ProviderSetupState()
  @State var sidebarOpacity: Double = 0
  @State var contentOpacity: Double = 0

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
                .font(.custom("Figtree", size: 15))
                .fontWeight(.medium)
                .foregroundColor(.black.opacity(0.7))
            }
          }
          .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
          // Position where sidebar items start: 20 + 16 = 36px
          .padding(.leading, 36)  // Align with sidebar item structure
          .pointingHandCursor()

          Spacer()
        }
        .frame(width: sidebarWidth)

        // Title in the content area
        HStack {
          Text(headerTitle)
            .font(.custom("Figtree", size: 32))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.9))

          Spacer()
        }
        .padding(.leading, 40)  // Gap between sidebar and content
      }
      .padding(.leading, fixedOffset)
      .padding(.top, fixedOffset / 2)
      .padding(.bottom, 20)

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

      Spacer()  // Push everything to top
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      setupState.configureSteps(for: providerType)
      animateAppearance()
    }
    .preferredColorScheme(.light)
    .alert(
      "Couldn't finish setup",
      isPresented: Binding(
        get: { setupState.saveErrorMessage != nil },
        set: { isPresented in
          if !isPresented {
            setupState.saveErrorMessage = nil
          }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        setupState.saveErrorMessage = nil
      }
    } message: {
      Text(setupState.saveErrorMessage ?? "Please try again.")
    }
  }

  var nextButtonText: String {
    if let title = setupState.currentStep.contentType.informationTitle {
      if (title == "Testing" || title == "Test Connection") && !setupState.testSuccessful {
        return "Test Required"
      }
    }
    return "Next"
  }

  @ViewBuilder
  var nextButton: some View {
    if setupState.isLastStep {
      DayflowSurfaceButton(
        action: completeSetup,
        content: {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
            Text("Complete Setup").font(.custom("Figtree", size: 14)).fontWeight(.semibold)
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
            Text(nextButtonText).font(.custom("Figtree", size: 14)).fontWeight(.semibold)
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
  var currentStepContent: some View {
    let step = setupState.currentStep

    switch step.contentType {
    case .localChoice:
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Choose your local AI engine")
            .font(.custom("Figtree", size: 24))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.9))
          Text(
            "For local use, LM Studio is the most reliable; Ollama has a known thinking bug in onboarding (can't turn thinking off) and performance is unreliable."
          )
          .font(.custom("Figtree", size: 14))
          .foregroundColor(.black.opacity(0.6))
        }
        HStack(alignment: .center, spacing: 12) {
          DayflowSurfaceButton(
            action: {
              setupState.selectEngine(.lmstudio)
              openLMStudioDownload()
            },
            content: {
              AsyncImage(
                url: URL(
                  string:
                    "https://lmstudio.ai/_next/image?url=%2F_next%2Fstatic%2Fmedia%2Flmstudio-app-logo.11b4d746.webp&w=96&q=75"
                )
              ) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure(_):
                  Image(systemName: "desktopcomputer").resizable().scaledToFit().foregroundColor(
                    .white.opacity(0.6))
                case .empty: ProgressView().scaleEffect(0.7)
                @unknown default: EmptyView()
                }
              }
              .frame(width: 18, height: 18)
              Text("Download LM Studio")
                .font(.custom("Figtree", size: 14))
                .fontWeight(.semibold)
            },
            background: Color(red: 0.25, green: 0.17, blue: 0),
            foreground: .white,
            borderColor: .clear,
            cornerRadius: 8,
            showOverlayStroke: true
          )
        }
        Text(
          "Already have a local server? Make sure it’s OpenAI-compatible. You can set a custom base URL in the next step."
        )
        .font(.custom("Figtree", size: 13))
        .foregroundColor(.black.opacity(0.6))
        HStack {
          Spacer()
          nextButton
        }
      }
    case .localModelInstall:
      VStack(alignment: .leading, spacing: 16) {
        Text("Install Qwen3-VL 4B")
          .font(.custom("Figtree", size: 24))
          .fontWeight(.semibold)
          .foregroundColor(.black.opacity(0.9))
        if setupState.localEngine == .ollama {
          Text("After installing Ollama, run this in your terminal to download the model (≈5GB):")
            .font(.custom("Figtree", size: 14))
            .foregroundColor(.black.opacity(0.6))
          TerminalCommandView(
            title: "Run this command:",
            subtitle: "Downloads Qwen3 Vision 4B for Ollama",
            command: "ollama pull qwen3-vl:4b"
          )
        } else if setupState.localEngine == .lmstudio {
          VStack(alignment: .leading, spacing: 16) {
            Text("After installing LM Studio, download the recommended model:")
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.black.opacity(0.6))

            DayflowSurfaceButton(
              action: openLMStudioModelDownload,
              content: {
                HStack(spacing: 8) {
                  Image(systemName: "arrow.down.circle.fill").font(.system(size: 14))
                  Text("Download Qwen3-VL 4B in LM Studio").font(.custom("Figtree", size: 14))
                    .fontWeight(.semibold)
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
                .font(.custom("Figtree", size: 13))
                .foregroundColor(.black.opacity(0.65))

              Text(
                "Once downloaded, turn on 'Local Server' in LM Studio (default http://localhost:1234)"
              )
              .font(.custom("Figtree", size: 13))
              .foregroundColor(.black.opacity(0.65))
            }
            .padding(.top, 4)

            // Fallback manual instructions
            VStack(alignment: .leading, spacing: 4) {
              Text("Manual setup:")
                .font(.custom("Figtree", size: 12))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.5))
              Text("1. Open LM Studio → Models tab")
                .font(.custom("Figtree", size: 12))
                .foregroundColor(.black.opacity(0.45))
              Text("2. Search for 'Qwen3-VL-4B' and install the Instruct variant")
                .font(.custom("Figtree", size: 12))
                .foregroundColor(.black.opacity(0.45))
            }
            .padding(.top, 8)
          }
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text("Use any OpenAI-compatible VLM")
              .font(.custom("Figtree", size: 16))
              .fontWeight(.semibold)
              .foregroundColor(.black.opacity(0.85))
            Text(
              "Make sure your server exposes the OpenAI Chat Completions API and has Qwen3-VL 4B (or Qwen2.5-VL 3B if you need the legacy model) installed."
            )
            .font(.custom("Figtree", size: 14))
            .foregroundColor(.black.opacity(0.75))
          }
        }
        HStack {
          Spacer()
          nextButton
        }
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
          placeholder: "AQ...",
          onValidate: { key in
            key.components(separatedBy: .whitespacesAndNewlines).joined().count > 10
          }
        )
        .onChange(of: setupState.apiKey) { _, _ in
          setupState.clearGeminiAPIKeySaveError()
          setupState.hasTestedConnection = false
          setupState.testSuccessful = false
        }

        if let message = setupState.geminiAPIKeySaveError {
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 12))
              .foregroundColor(Color(hex: "E91515"))

            Text(message)
              .font(.custom("Figtree", size: 13))
              .foregroundColor(Color(hex: "E91515"))
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(Color(hex: "E91515").opacity(0.1))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(Color(hex: "E91515").opacity(0.3), lineWidth: 1)
          )
        }

        VStack(alignment: .leading, spacing: 12) {
          Text(
            "Choose your Gemini model. We recommend 3.5 Flash, with 3.1 Flash-Lite available as a fallback."
          )
          .font(.custom("Figtree", size: 16))
          .fontWeight(.semibold)
          .foregroundColor(.black.opacity(0.85))

          Picker("Gemini model", selection: $setupState.geminiModel) {
            ForEach(GeminiModel.allCases, id: \.self) { model in
              Text(model.shortLabel).tag(model)
            }
          }
          .pickerStyle(.segmented)

          Text(GeminiModelPreference(primary: setupState.geminiModel).fallbackSummary)
            .font(.custom("Figtree", size: 13))
            .foregroundColor(.black.opacity(0.55))
        }
        .onChange(of: setupState.geminiModel) {
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
            .font(.custom("Figtree", size: 24))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.9))

          Text("This model enables Dayflow to understand what's on your screen")
            .font(.custom("Figtree", size: 14))
            .foregroundColor(.black.opacity(0.6))
        }

        TerminalCommandView(
          title: "Run this command:",
          subtitle:
            "This will download the \(LocalModelPreset.qwen3VL4B.displayName) model (about 5GB)",
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
            .font(.custom("Figtree", size: 24))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.9))
          if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(description)
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.black.opacity(0.6))
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading)
              .lineLimit(nil)
            // Additional guidance for the local intro step only
            if step.id == "intro" && providerType == .local {
              (Text("Advanced users can pick any ") + Text("vision-capable").fontWeight(.bold)
                + Text(
                  " LLM, but we strongly recommend using Qwen3-VL 4B based on our internal benchmarks."
                ))
                .font(.custom("Figtree", size: 14))
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
              if providerType == .gemini {
                TestConnectionView(
                  apiKey: setupState.apiKey,
                  onTestComplete: { success in
                    setupState.hasTestedConnection = true
                    setupState.testSuccessful = success
                  }
                )
              } else if providerType == .chatGPT || providerType == .claude {
                ChatCLITestView(
                  selectedTool: setupState.preferredCLITool,
                  onTestComplete: { success in
                    setupState.hasTestedConnection = true
                    setupState.testSuccessful = success
                  }
                )
              } else if providerType == .openAICompatible {
                VStack(alignment: .leading, spacing: 12) {
                  Picker("Endpoint", selection: $setupState.openAICompatiblePreset) {
                    Text("OpenRouter").tag(OpenAICompatiblePreset.openRouter)
                    Text("Custom").tag(OpenAICompatiblePreset.custom)
                  }
                  .pickerStyle(.segmented)
                  .frame(maxWidth: 380)
                  .onChange(of: setupState.openAICompatiblePreset) { _, preset in
                    if preset == .openRouter {
                      setupState.openAICompatibleBaseURL =
                        OpenAICompatibleConfiguration.openRouterBaseURL
                    }
                    setupState.hasTestedConnection = false
                    setupState.testSuccessful = false
                  }

                  LocalLLMTestView(
                    baseURL: $setupState.openAICompatibleBaseURL,
                    modelId: $setupState.openAICompatibleModelID,
                    apiKey: $setupState.openAICompatibleAPIKey,
                    engine: .custom,
                    buttonLabel: "Test endpoint",
                    basePlaceholder: OpenAICompatibleConfiguration.openRouterBaseURL,
                    modelPlaceholder: "openai/gpt-5.4",
                    credentialStorageDescription:
                      "Stored safely in Keychain and sent only to this endpoint as a Bearer token.",
                    requiresMeaningfulResponse: true,
                    enforcesLocalLatencyLimit: false,
                    onTestComplete: { success in
                      setupState.hasTestedConnection = true
                      setupState.testSuccessful = success
                    }
                  )
                  .onChange(of: setupState.openAICompatibleBaseURL) {
                    setupState.hasTestedConnection = false
                    setupState.testSuccessful = false
                  }
                  .onChange(of: setupState.openAICompatibleModelID) {
                    setupState.hasTestedConnection = false
                    setupState.testSuccessful = false
                  }
                  .onChange(of: setupState.openAICompatibleAPIKey) {
                    setupState.hasTestedConnection = false
                    setupState.testSuccessful = false
                  }
                }
              } else {
                // Engine selection: LM Studio or Custom
                VStack(alignment: .leading, spacing: 12) {
                  Text("Which tool are you using?")
                    .font(.custom("Figtree", size: 14))
                    .foregroundColor(.black.opacity(0.65))
                  Picker("Engine", selection: $setupState.localEngine) {
                    Text("LM Studio").tag(LocalEngine.lmstudio)
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
                .onChange(of: setupState.localBaseURL) {
                  setupState.hasTestedConnection = false
                  setupState.testSuccessful = false
                }
                .onChange(of: setupState.localModelId) {
                  setupState.hasTestedConnection = false
                  setupState.testSuccessful = false
                }
                .onChange(of: setupState.localAPIKey) {
                  setupState.hasTestedConnection = false
                  setupState.testSuccessful = false
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
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
            .font(.custom("Figtree", size: 24))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.9))

          Text(
            "allows you to run Dayflow for free. All you need is a Google account - no credit card required."
          )
          .font(.custom("Figtree", size: 14))
          .foregroundColor(.black.opacity(0.6))
        }

        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .top, spacing: 12) {
            Text("1.")
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.black.opacity(0.6))
              .frame(width: 20, alignment: .leading)

            Button(action: openGoogleAIStudio) {
              Text("Visit Google AI Studio ")
                .font(.custom("Figtree", size: 14))
                .foregroundColor(.black.opacity(0.8))
                + Text("(aistudio.google.com)")
                .font(.custom("Figtree", size: 14))
                .foregroundColor(Color(red: 1, green: 0.42, blue: 0.02))
                .underline()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
          }

          HStack(alignment: .top, spacing: 12) {
            Text("2.")
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.black.opacity(0.6))
              .frame(width: 20, alignment: .leading)

            Text("Click \"Create API key\" in the top right")
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.black.opacity(0.8))
          }

          HStack(alignment: .top, spacing: 12) {
            Text("3.")
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.black.opacity(0.6))
              .frame(width: 20, alignment: .leading)

            Text("Create a new API key and copy it")
              .font(.custom("Figtree", size: 14))
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
                Text("Open Google AI Studio").font(.custom("Figtree", size: 14)).fontWeight(
                  .semibold)
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

  func handleBack() {
    if setupState.currentStepIndex == 0 {
      onBack()
    } else {
      setupState.goBack()
    }
  }

  func handleContinue() {
    if setupState.isLastStep {
      completeSetup()
    } else {
      setupState.markCurrentStepCompleted()
      setupState.goNext()
    }
  }

  @discardableResult
  func saveConfiguration() -> Bool {
    setupState.saveErrorMessage = nil
    guard setupState.testSuccessful else {
      setupState.saveErrorMessage = "Test this provider successfully before completing setup."
      return false
    }

    // Save API key to keychain for Gemini
    if providerType == .gemini {
      let cleanedKey = setupState.apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
      if !cleanedKey.isEmpty {
        guard KeychainManager.shared.store(cleanedKey, for: "gemini") else {
          let message =
            "Couldn't save your API key to Keychain. Please unlock Keychain and try again."
          setupState.geminiAPIKeySaveError = message
          setupState.saveErrorMessage = message
          return false
        }
      }
      GeminiModelPreference(primary: setupState.geminiModel).save()
    }

    // Save local endpoint for local engine selection
    if providerType == .local {
      persistLocalSettings()
    }

    if providerType == .openAICompatible {
      guard persistOpenAICompatibleSettings() else {
        setupState.saveErrorMessage =
          "Dayflow couldn't save this endpoint configuration. Your previous configuration is still active."
        return false
      }
    }

    do {
      try LLMProviderSetupPreferences.markComplete(providerType)
      return true
    } catch {
      setupState.saveErrorMessage =
        "Dayflow couldn't finish saving this provider. Please try again."
      return false
    }
  }

  func completeSetup() {
    guard saveConfiguration() else { return }
    guard onComplete() else {
      setupState.saveErrorMessage =
        "The provider is configured, but Dayflow couldn't update your routing. Your previous selection is still active."
      return
    }
  }

  func persistLocalSettings() {
    let endpoint = setupState.localBaseURL
    UserDefaults.standard.set(setupState.localModelId, forKey: "llmLocalModelId")
    LocalModelPreferences.syncPreset(for: setupState.localEngine, modelId: setupState.localModelId)
    // Store local engine selection for header/model defaults
    UserDefaults.standard.set(setupState.localEngine.rawValue, forKey: "llmLocalEngine")
    // Also store the endpoint explicitly for other parts of the app if needed
    UserDefaults.standard.set(endpoint, forKey: "llmLocalBaseURL")
    persistLocalAPIKey(setupState.localAPIKey)
  }

  func persistOpenAICompatibleSettings() -> Bool {
    let configuration = OpenAICompatibleConfiguration(
      preset: setupState.openAICompatiblePreset,
      baseURL: setupState.openAICompatibleBaseURL,
      modelID: setupState.openAICompatibleModelID
    )
    guard configuration.isComplete else { return false }

    let key = setupState.openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let previousKey = KeychainManager.shared.retrieve(
      for: OpenAICompatiblePreferences.keychainProvider)
    if key.isEmpty {
      guard KeychainManager.shared.delete(for: OpenAICompatiblePreferences.keychainProvider) else {
        return false
      }
    } else if !KeychainManager.shared.store(
      key,
      for: OpenAICompatiblePreferences.keychainProvider
    ) {
      return false
    }

    guard OpenAICompatiblePreferences.save(configuration) else {
      if let previousKey {
        _ = KeychainManager.shared.store(
          previousKey,
          for: OpenAICompatiblePreferences.keychainProvider
        )
      } else {
        _ = KeychainManager.shared.delete(for: OpenAICompatiblePreferences.keychainProvider)
      }
      return false
    }
    return true
  }

  func persistLocalAPIKey(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      UserDefaults.standard.removeObject(forKey: "llmLocalAPIKey")
    } else {
      UserDefaults.standard.set(trimmed, forKey: "llmLocalAPIKey")
    }
  }

  func openGoogleAIStudio() {
    if let url = URL(string: "https://aistudio.google.com/app/apikey") {
      NSWorkspace.shared.open(url)
    }
  }

  func openLMStudioDownload() {
    if let url = URL(string: "https://lmstudio.ai/") {
      NSWorkspace.shared.open(url)
    }
  }

  func openLMStudioModelDownload() {
    if let url = URL(
      string: "https://model.lmstudio.ai/download/lmstudio-community/Qwen3-VL-4B-Instruct-GGUF")
    {
      NSWorkspace.shared.open(url)
    }
  }

  func openChatCLIInstallPage(for tool: CLITool) {
    guard let url = tool.installURL else { return }
    NSWorkspace.shared.open(url)
  }

  func animateAppearance() {
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
