//
//  OnboardingLLMSelectionView.swift
//  Dayflow
//
//  LLM provider selection view for onboarding flow
//

import SwiftUI
import AppKit

struct OnboardingLLMSelectionView: View {
    // Navigation callbacks
    var onBack: () -> Void
    var onNext: (String) -> Void  // Now passes the selected provider
    
    @AppStorage("selectedLLMProvider") private var selectedProvider: String = "gemini" // Default to "Bring your own API"
    @State private var titleOpacity: Double = 0
    @State private var cardsOpacity: Double = 0
    @State private var bottomTextOpacity: Double = 0
    @State private var hasAppeared: Bool = false
    @State private var cliDetected: Bool = false
    @State private var cliDetectionTask: Task<Void, Never>?
    @State private var didUserSelectProvider: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            let windowWidth = geometry.size.width
            let windowHeight = geometry.size.height

            // Constants
            let edgePadding: CGFloat = 40
            let cardGap: CGFloat = 20
            let headerHeight: CGFloat = 70
            let footerHeight: CGFloat = 40

            // Card width calc (no min width, cap at 480)
            let availableWidth = windowWidth - (edgePadding * 2)
            let rawCardWidth = (availableWidth - (cardGap * 2)) / 3
            let cardWidth = max(1, min(480, floor(rawCardWidth)))

            // Card height calc
            let availableHeight = windowHeight - headerHeight - footerHeight
            let cardHeight = min(500, max(300, availableHeight - 20))

            // Title font size
            let titleSize: CGFloat = windowWidth <= 900 ? 32 : 48

            VStack(spacing: 0) {
                // Header
                    Text("Choose a way to run Dayflow")
                    .font(.custom("InstrumentSerif-Regular", size: titleSize))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .frame(height: headerHeight)
                    .opacity(titleOpacity)
                    .onAppear {
                        guard !hasAppeared else { return }
                        hasAppeared = true
                        detectCLIInstallation()
                        withAnimation(.easeOut(duration: 0.6)) { titleOpacity = 1 }
                        animateContent()
                    }

                // Dynamic card area
                Spacer(minLength: 10)

                HStack(spacing: cardGap) {
                    ForEach(providerCards, id: \.id) { card in
                        card
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
                .padding(.horizontal, edgePadding)
                .opacity(cardsOpacity)

                Spacer(minLength: 10)

                // Footer
                HStack(spacing: 0) {
                    Group {
                        if cliDetected {
                            Text("You have Codex/Claude CLI installed! ")
                                .foregroundColor(.black.opacity(0.6))
                            + Text("We recommend using it for the best experience.")
                                .fontWeight(.semibold)
                                .foregroundColor(.black.opacity(0.8))
                            + Text(" You can switch at any time in the settings.")
                                .foregroundColor(.black.opacity(0.6))
                        } else {
                            Text("Not sure which to choose? ")
                                .foregroundColor(.black.opacity(0.6))
                            + Text("Bring your own keys is the easiest setup (30s).")
                                .fontWeight(.semibold)
                                .foregroundColor(.black.opacity(0.8))
                            + Text(" You can switch at any time in the settings.")
                                .foregroundColor(.black.opacity(0.6))
                        }
                    }
                    .font(.custom("Nunito", size: 14))
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: footerHeight)
                .opacity(bottomTextOpacity)
            }
            .animation(.easeOut(duration: 0.2), value: cardWidth)
            .animation(.easeOut(duration: 0.2), value: cardHeight)
        }
        .onDisappear {
            cliDetectionTask?.cancel()
            cliDetectionTask = nil
        }
    }
    
    // Create provider cards as a computed property for reuse
    private var providerCards: [FlexibleProviderCard] {
        [
            // Run locally card
            FlexibleProviderCard(
                id: "ollama",
                title: "Use local AI",
                badgeText: "MOST PRIVATE",
                badgeType: .green,
                icon: "desktopcomputer",
                features: [
                    ("100% private - everything's processed on your computer", true),
                    ("Works completely offline", true),
                    ("Significantly less intelligence", false),
                    ("Requires the most setup", false),
                    ("16GB+ of RAM recommended", false),
                    ("Can be battery-intensive", false)
                ],
                isSelected: selectedProvider == "ollama",
                buttonMode: .onboarding(onProceed: {
                    // Only proceed if this provider is selected
                    if selectedProvider == "ollama" {
                        saveProviderSelection()
                        onNext("ollama")
                    } else {
                        // Select the card first
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            didUserSelectProvider = true
                            selectedProvider = "ollama"
                        }
                    }
                }),
                onSelect: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        didUserSelectProvider = true
                        selectedProvider = "ollama"
                    }
                }
            ),
            
            // Bring your own API card (selected by default)
            FlexibleProviderCard(
                id: "gemini",
                title: "Gemini",
                badgeText: cliDetected ? "NEW" : "RECOMMENDED",
                badgeType: cliDetected ? .blue : .orange,
                icon: "gemini_asset",
                features: [
                    ("Utilizes more intelligent AI via Google's Gemini models", true),
                    ("Uses Gemini's generous free tier (no credit card needed)", true),
                    ("Faster, more accurate than local models", true),
                    ("Requires getting an API key (takes 2 clicks)", false)
                ],
                isSelected: selectedProvider == "gemini",
                buttonMode: .onboarding(onProceed: {
                    // Only proceed if this provider is selected
                    if selectedProvider == "gemini" {
                        saveProviderSelection()
                        onNext("gemini")
                    } else {
                        // Select the card first
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            didUserSelectProvider = true
                            selectedProvider = "gemini"
                        }
                    }
                }),
                onSelect: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        didUserSelectProvider = true
                        selectedProvider = "gemini"
                    }
                }
            ),

            // ChatGPT/Claude CLI card
            FlexibleProviderCard(
                id: "chatgpt_claude",
                title: "ChatGPT or Claude",
                badgeText: cliDetected ? "RECOMMENDED" : "NEW",
                badgeType: cliDetected ? .orange : .blue,
                icon: "chatgpt_claude_asset",
                features: [
                    ("Perfect for existing ChatGPT Plus or Claude Pro subscribers", true),
                    ("Superior intelligence and reliability", true),
                    ("Minimal impact - uses <1% of your daily limit", true),
                    ("Requires installing Codex or Claude CLI", false),
                    ("Requires a paid ChatGPT or Claude subscription", false)
                ],
                isSelected: selectedProvider == "chatgpt_claude",
                buttonMode: .onboarding(onProceed: {
                    if selectedProvider == "chatgpt_claude" {
                        saveProviderSelection()
                        onNext("chatgpt_claude")
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            didUserSelectProvider = true
                            selectedProvider = "chatgpt_claude"
                        }
                    }
                }),
                onSelect: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        didUserSelectProvider = true
                        selectedProvider = "chatgpt_claude"
                    }
                }
            ),
            
            /*
            // Dayflow Pro card
            FlexibleProviderCard(
                id: "dayflow",
                title: "Dayflow Pro",
                badgeText: "EASIEST SETUP",
                badgeType: .blue,
                icon: "sparkles",
                features: [
                    ("Zero setup - just sign in and go", true),
                    ("Your data is processed then immediately deleted", true),
                    ("Never used to train AI models", true),
                    ("Always the fastest, most capable AI", true),
                    ("Fixed monthly pricing, no surprises", true),
                    ("Requires internet connection", false)
                ],
                isSelected: selectedProvider == "dayflow",
                buttonMode: .onboarding(onProceed: {
                    // Only proceed if this provider is selected
                    if selectedProvider == "dayflow" {
                        saveProviderSelection()
                        onNext("dayflow")
                    } else {
                        // Select the card first
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            selectedProvider = "dayflow"
                        }
                    }
                }),
                onSelect: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        selectedProvider = "dayflow"
                    }
                }
            )
            */
        ]
    }
    
    private func saveProviderSelection() {
        let providerType: LLMProviderType
        
        switch selectedProvider {
        case "ollama":
            providerType = .ollamaLocal()
        case "gemini":
            providerType = .geminiDirect
        case "dayflow":
            providerType = .dayflowBackend()
        case "chatgpt_claude":
            providerType = .chatGPTClaude
        default:
            providerType = .geminiDirect
        }
        
        UserDefaults.standard.set(selectedProvider, forKey: "selectedLLMProvider")
        if let encoded = try? JSONEncoder().encode(providerType) {
            UserDefaults.standard.set(encoded, forKey: "llmProviderType")
        }
    }
    
    private func animateContent() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.6)) {
                cardsOpacity = 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.4)) {
                bottomTextOpacity = 1
            }
        }
    }

    private func detectCLIInstallation() {
        cliDetectionTask?.cancel()
        cliDetectionTask = Task { @MainActor in
            let installed = await Task.detached(priority: .utility) {
                let codexInstalled = CLIDetector.isInstalled(.codex)
                let claudeInstalled = CLIDetector.isInstalled(.claude)
                return codexInstalled || claudeInstalled
            }.value

            guard !Task.isCancelled else { return }

            cliDetected = installed

            if !didUserSelectProvider {
                selectedProvider = installed ? "chatgpt_claude" : "gemini"
            }
        }
    }
}

struct OnboardingLLMSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingLLMSelectionView(
            onBack: {},
            onNext: { _ in }  // Takes provider string now
        )
        .frame(width: 1400, height: 900)
        .background(
            Image("OnboardingBackgroundv2")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        )
    }
}
