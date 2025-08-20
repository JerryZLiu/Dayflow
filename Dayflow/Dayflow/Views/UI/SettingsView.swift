//
//  SettingsView.swift
//  Dayflow
//
//  Refactored: split into small subviews to avoid type-check timeouts,
//  cache system info once, and keep provider toggle snappy.
//

import SwiftUI

// MARK: - Types

enum Provider: String, Codable, CaseIterable, Identifiable {
    case ollama, gemini, dayflow
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .gemini: return "Google Gemini"
        case .dayflow: return "Dayflow Cloud"
        }
    }

    var subtitle: String {
        switch self {
        case .ollama: return "Privacy-focused"
        case .gemini: return "Cloud-based"
        case .dayflow: return "Optimized"
        }
    }

    var icon: String {
        switch self {
        case .ollama: return "brain.head.profile"
        case .gemini: return "cloud"
        case .dayflow: return "server.rack"
        }
    }
}

/// Snapshot heavy system info once to avoid main-thread stalls on every render
struct SystemSnapshot {
    let model: String
    let chip: String
    let memory: String
    let macOS: String
    let arch: String

    static let empty = SystemSnapshot(model: "", chip: "", memory: "", macOS: "", arch: "")

    static func capture() -> SystemSnapshot {
        SystemSnapshot(
            model: HardwareInfo.shared.marketingName,
            chip: HardwareInfo.shared.chipName,
            memory: HardwareInfo.shared.memorySize,
            macOS: HardwareInfo.shared.macOSVersionName,
            arch: HardwareInfo.shared.isAppleSilicon ? "Apple Silicon" : "Intel"
        )
    }
}

// MARK: - View

struct SettingsView: View {
    // Selection & inputs
    @State private var selectedProvider: Provider = .ollama
    @State private var geminiAPIKey: String = ""
    @State private var dayflowToken: String = ""
    @State private var ollamaEndpoint: String = "http://localhost:11434"

    // UI state
    @State private var saveConfirmation = false
    @State private var sys: SystemSnapshot = .empty

    // Colors (reduces literal noise in view tree)
    private let accent = Color(red: 1, green: 0.42, blue: 0.02)

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                SettingsHeader(accent: accent)

                ProviderSection(
                    selectedProvider: $selectedProvider,
                    geminiAPIKey: $geminiAPIKey,
                    dayflowToken: $dayflowToken,
                    ollamaEndpoint: $ollamaEndpoint,
                    saveConfirmation: $saveConfirmation,
                    accent: accent,
                    onSave: saveSettings
                )
                .animation(.easeInOut(duration: 0.18), value: selectedProvider)

                SystemInfoSection(sys: sys, accent: accent)
                    .transaction { tx in tx.disablesAnimations = true }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: 800)
        .onAppear {
            if sys.model.isEmpty { sys = SystemSnapshot.capture() }
            loadSettings()
        }
    }

    // MARK: - Actions
    
    private func loadSettings() {
        // Load provider type from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "llmProviderType"),
           let providerType = try? JSONDecoder().decode(LLMProviderType.self, from: data) {
            switch providerType {
            case .geminiDirect:
                selectedProvider = .gemini
                // Load API key from Keychain
                geminiAPIKey = KeychainManager.shared.retrieve(for: "gemini") ?? ""
            case .dayflowBackend:
                selectedProvider = .dayflow
                // Load token from Keychain
                dayflowToken = KeychainManager.shared.retrieve(for: "dayflow") ?? ""
            case .ollamaLocal(let endpoint):
                selectedProvider = .ollama
                ollamaEndpoint = endpoint
            }
        }
    }

    private func saveSettings() {
        let provider: LLMProviderType
        switch selectedProvider {
        case .gemini:
            // Store API key in Keychain
            if !geminiAPIKey.isEmpty {
                KeychainManager.shared.store(geminiAPIKey, for: "gemini")
            }
            provider = .geminiDirect
        case .dayflow:
            // Store token in Keychain
            if !dayflowToken.isEmpty {
                KeychainManager.shared.store(dayflowToken, for: "dayflow")
            }
            provider = .dayflowBackend(endpoint: "https://api.dayflow.app")
        case .ollama:
            provider = .ollamaLocal(endpoint: ollamaEndpoint)
        }

        if let encoded = try? JSONEncoder().encode(provider) {
            UserDefaults.standard.set(encoded, forKey: "llmProviderType")

            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                saveConfirmation = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { saveConfirmation = false }
            }
        }
    }
}

// MARK: - Sections

private struct SettingsHeader: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 48))
                .foregroundColor(accent)

            Text("Settings")
                .font(.custom("InstrumentSerif-Regular", size: 36))
                .foregroundColor(.black.opacity(0.9))
        }
        .padding(.top, 40)
    }
}

private struct ProviderSection: View {
    @Binding var selectedProvider: Provider
    @Binding var geminiAPIKey: String
    @Binding var dayflowToken: String
    @Binding var ollamaEndpoint: String
    @Binding var saveConfirmation: Bool

    let accent: Color
    let onSave: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 20) {
                SectionTitle("AI Provider")

                VStack(spacing: 12) {
                    // Rows
                    ForEach(Provider.allCases) { p in
                        ProviderOptionRow(
                            title: p.title,
                            subtitle: p.subtitle,
                            icon: p.icon,
                            isSelected: selectedProvider == p,
                            accent: accent,
                            action: { selectedProvider = p }
                        )
                    }

                    // Inline config fields (minimal transitions keep type-checker happy)
                    ProviderConfigFields(
                        selectedProvider: selectedProvider,
                        geminiAPIKey: $geminiAPIKey,
                        dayflowToken: $dayflowToken,
                        ollamaEndpoint: $ollamaEndpoint
                    )
                }

                // Save Button
                HStack {
                    Spacer()
                    DayflowButton(
                        title: saveConfirmation ? "Saved!" : "Save Settings",
                        action: onSave,
                        width: 140,
                        fontSize: 14
                    )
                    .disabled(saveConfirmation)
                    Spacer()
                }
                .padding(.top, 12)
            }
        }
    }
}

private struct ProviderConfigFields: View {
    let selectedProvider: Provider
    @Binding var geminiAPIKey: String
    @Binding var dayflowToken: String
    @Binding var ollamaEndpoint: String

    var body: some View {
        switch selectedProvider {
        case .ollama:
            OllamaEndpointField(text: $ollamaEndpoint)
                .transition(.opacity)
        case .gemini:
            GeminiKeyField(text: $geminiAPIKey)
                .transition(.opacity)
        case .dayflow:
            DayflowTokenField(text: $dayflowToken)
                .transition(.opacity)
        }
    }
}

private struct SystemInfoSection: View {
    let sys: SystemSnapshot
    let accent: Color

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 20) {
                SectionTitle("System Information")

                VStack(alignment: .leading, spacing: 12) {
                    SystemInfoRow(label: "Model",        value: sys.model)
                    SystemInfoRow(label: "Chip",         value: sys.chip)
                    SystemInfoRow(label: "Memory",       value: sys.memory)
                    SystemInfoRow(label: "macOS",        value: sys.macOS)
                    SystemInfoRow(label: "Architecture", value: sys.arch)
                }
            }
        }
    }
}

// MARK: - Small Components

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.7))
                .dayflowShadow()
        )
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.custom("Nunito", size: 20))
            .fontWeight(.semibold)
            .foregroundColor(.black.opacity(0.8))
    }
}

private struct ProviderOptionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? accent : .black.opacity(0.6))
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))

                    Text(subtitle)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.6))
                }

                Spacer()

                SelectionDot(isSelected: isSelected, accent: accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? accent.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? accent : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SelectionDot: View {
    let isSelected: Bool
    let accent: Color

    var body: some View {
        Circle()
            .fill(isSelected ? accent : Color.gray.opacity(0.3))
            .frame(width: 20, height: 20)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
            )
    }
}

private struct SystemInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.6))
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.custom("Nunito", size: 14))
                .fontWeight(.medium)
                .foregroundColor(.black.opacity(0.8))

            Spacer()
        }
    }
}

// MARK: - Field Rows

private struct OllamaEndpointField: View {
    @Binding var text: String

    var body: some View {
        HStack {
            FieldLabel("Endpoint:")
            TextField("http://localhost:11434", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.custom("Nunito", size: 14))
        }
        .padding(.horizontal, 20)
    }
}

private struct GeminiKeyField: View {
    @Binding var text: String

    var body: some View {
        HStack {
            FieldLabel("API Key:")
            SecureField("Enter your Gemini API key", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.custom("Nunito", size: 14))
        }
        .padding(.horizontal, 20)
    }
}

private struct DayflowTokenField: View {
    @Binding var text: String

    var body: some View {
        HStack {
            FieldLabel("Token:")
            SecureField("Enter your Dayflow token", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.custom("Nunito", size: 14))
        }
        .padding(.horizontal, 20)
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.custom("Nunito", size: 14))
            .foregroundColor(.black.opacity(0.6))
            .frame(width: 100, alignment: .leading)
    }
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(width: 1200, height: 800)
            .background(Color.gray.opacity(0.1))
    }
}
