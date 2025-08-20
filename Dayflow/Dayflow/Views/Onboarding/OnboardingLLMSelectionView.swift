//
//  OnboardingLLMSelectionView.swift
//  Dayflow
//
//  LLM provider selection view for onboarding flow
//

import SwiftUI

struct OnboardingLLMSelectionView: View {
    // Navigation callbacks
    var onBack: () -> Void
    var onNext: () -> Void
    
    // MARK: - State
    @AppStorage("selectedLLMProvider") private var selectedProvider: String = "ollama"
    @State private var titleOpacity: Double = 0
    @State private var cardOffsets: [CGFloat] = [50, 50, 50]
    @State private var cardOpacities: [Double] = [0, 0, 0]
    @State private var buttonsOpacity: Double = 0
    
    // MARK: - LLM Provider Options
    private let providers: [(id: String, title: String, subtitle: String, description: String, icon: String, isRecommended: Bool)] = [
        (
            id: "ollama",
            title: "Ollama (Local)",
            subtitle: "Recommended",
            description: "Run AI models locally on your device. Completely private with no data leaving your computer. Free to use.",
            icon: "brain.head.profile",
            isRecommended: true
        ),
        (
            id: "gemini",
            title: "Google Gemini",
            subtitle: "Cloud-based",
            description: "Fast and accurate AI processing in the cloud. Requires an API key and sends data to Google's servers.",
            icon: "cloud",
            isRecommended: false
        ),
        (
            id: "dayflow",
            title: "Dayflow Cloud",
            subtitle: "Hosted",
            description: "Our hosted AI service optimized for Dayflow. Requires a subscription and sends data to our servers.",
            icon: "server.rack",
            isRecommended: false
        )
    ]
    
    var body: some View {
        VStack {
            Spacer()
            
            VStack(spacing: 40) {
                // MARK: - Title
                Text("Choose Your AI Assistant")
                    .font(.custom("InstrumentSerif-Regular", size: 48))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black.opacity(0.9))
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .opacity(titleOpacity)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.6)) {
                            titleOpacity = 1
                        }
                        animateCards()
                    }
                
                // MARK: - Provider Cards
                VStack(spacing: 16) {
                    ForEach(providers.indices, id: \.self) { index in
                        LLMProviderCard(
                            provider: providers[index],
                            isSelected: selectedProvider == providers[index].id,
                            onSelect: {
                                // Simplified - no animation on selection for better performance
                                selectedProvider = providers[index].id
                            }
                        )
                        .offset(y: cardOffsets[index])
                        .opacity(cardOpacities[index])
                    }
                }
                
                // MARK: - Navigation
                HStack {
                    DayflowButton(
                        title: "Back",
                        action: onBack,
                        width: 120,
                        fontSize: 14,
                        isSubtle: true
                    )
                    
                    Spacer()
                    
                    DayflowButton(
                        title: "Next",
                        action: {
                            // Save the selection and continue
                            saveProviderSelection()
                            onNext()
                        },
                        width: 120,
                        fontSize: 14
                    )
                }
                .frame(width: 600)
                .padding(.top, 20)
                .opacity(buttonsOpacity)
            }
            .frame(width: 600)
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Helper Methods
    private func saveProviderSelection() {
        // Convert selection to LLMProviderType for storage
        let providerType: LLMProviderType
        
        switch selectedProvider {
        case "ollama":
            providerType = .ollamaLocal()
        case "gemini":
            providerType = .geminiDirect
        case "dayflow":
            providerType = .dayflowBackend()
        default:
            providerType = .ollamaLocal()
        }
        
        // Save to UserDefaults
        if let encoded = try? JSONEncoder().encode(providerType) {
            UserDefaults.standard.set(encoded, forKey: "llmProviderType")
        }
    }
    
    private func animateCards() {
        for index in providers.indices {
            let delay = 0.3 + Double(index) * 0.1
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    cardOffsets[index] = 0
                    cardOpacities[index] = 1
                }
            }
        }
        
        // Animate buttons
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeInOut(duration: 0.4)) {
                buttonsOpacity = 1
            }
        }
    }
}

// MARK: - LLM Provider Card Component
struct LLMProviderCard: View {
    let provider: (id: String, title: String, subtitle: String, description: String, icon: String, isRecommended: Bool)
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 16) {
                // Icon
                VStack {
                    Image(systemName: provider.icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isSelected ? Color(red: 1, green: 0.42, blue: 0.02) : .black.opacity(0.6))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(isSelected ? Color(red: 1, green: 0.42, blue: 0.02).opacity(0.1) : Color.gray.opacity(0.1))
                        )
                    
                    Spacer()
                }
                
                // Content
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(provider.title)
                            .font(.custom("Nunito", size: 18))
                            .fontWeight(.semibold)
                            .foregroundColor(.black.opacity(0.9))
                        
                        if provider.isRecommended {
                            Text(provider.subtitle)
                                .font(.custom("Nunito", size: 12))
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .cornerRadius(8)
                        } else {
                            Text(provider.subtitle)
                                .font(.custom("Nunito", size: 12))
                                .fontWeight(.medium)
                                .foregroundColor(.black.opacity(0.6))
                        }
                        
                        Spacer()
                        
                        // Selection indicator
                        Circle()
                            .fill(isSelected ? Color(red: 1, green: 0.42, blue: 0.02) : Color.gray.opacity(0.3))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .fill(.white)
                                    .frame(width: 8, height: 8)
                                    .opacity(isSelected ? 1 : 0)
                                    .scaleEffect(isSelected ? 1 : 0.1)
                                    // Faster animation for snappier feel
                                    .animation(.easeOut(duration: 0.15), value: isSelected)
                            )
                    }
                    
                    Text(provider.description)
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(isSelected ? 0.9 : (isHovered ? 0.75 : 0.66)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isSelected ? 
                                Color(red: 1, green: 0.42, blue: 0.02) : 
                                Color.black.opacity(isHovered ? 0.2 : 0.1),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .shadow(
                color: isSelected ? 
                Color(red: 1, green: 0.42, blue: 0.02).opacity(0.2) : 
                Color.black.opacity(0.1),
                radius: isSelected ? 8 : 4,
                x: 0,
                y: isSelected ? 4 : 2
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            // Single animation modifier for both hover and selection
            .animation(.easeOut(duration: 0.2), value: isHovered)
            .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview
struct OnboardingLLMSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingLLMSelectionView(
            onBack: {},
            onNext: {}
        )
        .frame(width: 1200, height: 800)
        .background(
            Image("OnboardingBackgroundv2")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        )
    }
}