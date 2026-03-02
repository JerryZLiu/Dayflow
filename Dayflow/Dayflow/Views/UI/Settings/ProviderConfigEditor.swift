//
//  ProviderConfigEditor.swift
//  Dayflow
//
//  Simple form-based editor for provider configuration
//  Opens as a sheet instead of the full onboarding wizard
//

import SwiftUI

struct ProviderConfigEditor: View {
    let providerId: String  // canonical: "gemini", "ollama", "chatgpt_claude"
    @ObservedObject var viewModel: ProvidersSettingsViewModel
    let onDismiss: () -> Void

    @State private var geminiAPIKey: String = ""
    @State private var selectedCLITool: CLITool = .codex

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                header
                formContent
                Spacer(minLength: 20)
                bottomButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if providerId == "gemini" {
                geminiAPIKey = KeychainManager.shared.retrieve(for: "gemini") ?? ""
            }
            if providerId == "chatgpt_claude" {
                selectedCLITool = viewModel.preferredCLITool ?? .codex
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Edit \(providerName)")
                    .font(.custom("Nunito", size: 18))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.85))
                Text("Update your configuration without re-running setup")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.55))
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.black.opacity(0.35))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var formContent: some View {
        switch providerId {
        case "gemini":
            geminiForm
        case "ollama":
            ollamaForm
        case "chatgpt_claude":
            chatCLIForm
        default:
            Text("Unknown provider")
                .font(.custom("Nunito", size: 13))
                .foregroundColor(.black.opacity(0.55))
        }
    }

    // MARK: - Gemini

    private var geminiForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldGroup(label: "API Key") {
                SecureField("Enter your Gemini API key", text: $geminiAPIKey)
                    .font(.custom("Nunito", size: 13))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
            }

            fieldGroup(label: "Model Preference") {
                Picker("Gemini model", selection: $viewModel.selectedGeminiModel) {
                    ForEach(GeminiModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .environment(\.colorScheme, .light)
            }
        }
    }

    // MARK: - Ollama

    private var ollamaForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldGroup(label: "Engine") {
                Picker("Engine", selection: $viewModel.localEngine) {
                    Text("Ollama").tag(LocalEngine.ollama)
                    Text("LM Studio").tag(LocalEngine.lmstudio)
                    Text("Custom").tag(LocalEngine.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .environment(\.colorScheme, .light)
            }

            fieldGroup(label: "Base URL") {
                TextField(viewModel.localEngine.defaultBaseURL, text: $viewModel.localBaseURL)
                    .font(.custom("Nunito", size: 13))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
            }

            fieldGroup(label: "Model ID") {
                TextField("e.g. qwen2.5vl:3b", text: $viewModel.localModelId)
                    .font(.custom("Nunito", size: 13))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
            }

            fieldGroup(label: "API Key (optional)") {
                SecureField("Leave blank if not required", text: $viewModel.localAPIKey)
                    .font(.custom("Nunito", size: 13))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - ChatGPT / Claude

    private var chatCLIForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldGroup(label: "Preferred CLI Tool") {
                Picker("CLI Tool", selection: $selectedCLITool) {
                    ForEach(CLITool.allCases, id: \.self) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .environment(\.colorScheme, .light)
            }

            Text("Dayflow will use the selected CLI tool to generate timeline summaries.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.55))
        }
    }

    // MARK: - Shared Helpers

    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("Nunito", size: 13))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.65))
            content()
        }
    }

    // MARK: - Bottom Buttons

    private var bottomButtons: some View {
        HStack(spacing: 12) {
            Spacer()
            DayflowSurfaceButton(
                action: onDismiss,
                content: {
                    Text("Cancel")
                        .font(.custom("Nunito", size: 13))
                        .fontWeight(.semibold)
                },
                background: .white,
                foreground: .black,
                borderColor: Color.black.opacity(0.15),
                cornerRadius: 8,
                horizontalPadding: 18,
                verticalPadding: 10,
                showOverlayStroke: false
            )
            DayflowSurfaceButton(
                action: saveConfiguration,
                content: {
                    Text("Save")
                        .font(.custom("Nunito", size: 13))
                        .fontWeight(.semibold)
                },
                background: Color(red: 0.25, green: 0.17, blue: 0),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 18,
                verticalPadding: 10,
                showOverlayStroke: true
            )
        }
    }

    // MARK: - Save

    private func saveConfiguration() {
        switch providerId {
        case "gemini":
            let trimmed = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                KeychainManager.shared.store(trimmed, for: "gemini")
            }
            viewModel.persistGeminiModelSelection(viewModel.selectedGeminiModel, source: "config_editor")
        case "ollama":
            viewModel.handleLocalTestCompletion()
        case "chatgpt_claude":
            UserDefaults.standard.set(selectedCLITool.rawValue, forKey: "chatCLIPreferredTool")
            viewModel.preferredCLITool = selectedCLITool
        default:
            break
        }
        onDismiss()
    }

    private var providerName: String {
        switch providerId {
        case "gemini": return "Gemini"
        case "ollama": return "Local (Ollama)"
        case "chatgpt_claude": return "ChatGPT / Claude"
        default: return providerId.capitalized
        }
    }
}
