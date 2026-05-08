//
//  ActivityCardReanalyzeMenu.swift
//  Dayflow
//
//  Per-card "Re-analyze with..." menu. Lets the user re-run LLM analysis
//  for a single card using any available provider, independent of the
//  app's configured primary provider. Used as an escape hatch when the
//  primary output is wrong or the user wants to try a different model.
//

import SwiftUI

struct ActivityCardReanalyzeMenu: View {
  @Binding var isPresented: Bool
  let isRunning: Bool

  var body: some View {
    Button(action: { isPresented.toggle() }) {
      ZStack {
        Circle()
          .fill(Color.white.opacity(0.76))
          .overlay(
            Circle()
              .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 0.5)
          )
        if isRunning {
          ProgressView().scaleEffect(0.5)
        } else {
          Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.1))
        }
      }
      .frame(width: 24, height: 24)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .disabled(isRunning)
    .accessibilityLabel(Text("Re-analyze this card"))
    .help("Re-analyze with another provider")
  }
}

struct ReanalyzePickerOverlay: View {
  let recordId: Int64?
  var onClose: () -> Void
  var onRunStart: () -> Void
  var onRunEnd: (Result<Void, Error>) -> Void
  var onCompleted: ((Int64) -> Void)?

  @State private var errorMessage: String? = nil

  var body: some View {
    let options = providerOptions()

    VStack(spacing: 12) {
      HStack {
        Text("Re-analyze with")
          .font(Font.custom("Nunito", size: 13).weight(.semibold))
          .foregroundColor(Color(red: 0.39, green: 0.35, blue: 0.33))
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(red: 0.39, green: 0.35, blue: 0.33))
            .frame(width: 20, height: 20)
            .background(Color.white.opacity(0.76))
            .clipShape(Circle())
            .overlay(
              Circle()
                .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(Text("Close re-analyze menu"))
      }

      if options.isEmpty {
        Text(
          "Configure a primary, secondary, or tertiary provider in Settings to re-analyze cards."
        )
        .font(Font.custom("Nunito", size: 12))
        .foregroundColor(Color(red: 0.39, green: 0.35, blue: 0.33))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        VStack(spacing: 6) {
          ForEach(options, id: \.id) { option in
            Button(action: { run(option) }) {
              HStack(spacing: 10) {
                Image(systemName: option.systemImage)
                  .font(.system(size: 12, weight: .medium))
                  .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                  .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                  Text(option.title)
                    .font(Font.custom("Nunito", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .lineLimit(1)
                  if let subtitle = option.subtitle {
                    Text(subtitle)
                      .font(Font.custom("Nunito", size: 11))
                      .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
                      .lineLimit(1)
                  }
                }
                Spacer(minLength: 6)
                Text(option.roleBadge)
                  .font(Font.custom("Nunito", size: 10).weight(.semibold))
                  .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color(red: 0.93, green: 0.93, blue: 0.96).opacity(0.9))
                  .cornerRadius(4)
                  .overlay(
                    RoundedRectangle(cornerRadius: 4)
                      .stroke(Color(red: 0.85, green: 0.85, blue: 0.92), lineWidth: 0.5)
                  )
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.white.opacity(0.76))
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .inset(by: 0.25)
                  .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 0.5)
              )
              .cornerRadius(6)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursorOnHover(reassertOnPressEnd: true)
          }
        }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(Font.custom("Nunito", size: 11))
          .foregroundColor(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(red: 0.98, green: 0.96, blue: 0.95).opacity(0.86)
        .background(.ultraThinMaterial)
    )
    .clipShape(
      UnevenRoundedRectangle(
        cornerRadii: .init(
          topLeading: 0,
          bottomLeading: 0,
          bottomTrailing: 0,
          topTrailing: 6
        )
      )
    )
    .overlay(
      UnevenRoundedRectangle(
        cornerRadii: .init(
          topLeading: 0,
          bottomLeading: 0,
          bottomTrailing: 0,
          topTrailing: 6
        )
      )
      .stroke(Color(red: 0.91, green: 0.88, blue: 0.87), lineWidth: 1)
    )
  }

  private func run(_ option: ProviderOption) {
    guard let recordId else { return }
    errorMessage = nil
    onRunStart()
    onClose()

    AnalysisManager.shared.reanalyzeCard(
      recordId,
      providerOverride: option.providerID,
      chatToolOverride: option.chatToolOverride,
      stepHandler: { _ in },
      completion: { result in
        DispatchQueue.main.async {
          switch result {
          case .success:
            if let batchId = StorageManager.shared.batchIdForTimelineCard(recordId) {
              onCompleted?(batchId)
            }
            onRunEnd(.success(()))
          case .failure(let err):
            errorMessage = err.localizedDescription
            onRunEnd(.failure(err))
          }
        }
      }
    )
  }

  private func providerOptions() -> [ProviderOption] {
    let primaryType = LLMProviderType.load()
    let primaryID = LLMProviderID.from(primaryType)
    let primaryTool: ChatCLITool? =
      primaryID == .chatGPTClaude ? preferredChatCLITool() : nil

    var seen = Set<String>()
    var result: [ProviderOption] = []

    if let option = makeOption(
      providerID: primaryID,
      chatTool: primaryTool,
      role: "PRIMARY"
    ), !seen.contains(option.id) {
      seen.insert(option.id)
      result.append(option)
    }

    if let secondary = LLMProviderRoutingPreferences.loadBackupProvider() {
      let tool =
        secondary == .chatGPTClaude
        ? (LLMProviderRoutingPreferences.loadBackupChatCLITool() ?? preferredChatCLITool()) : nil
      if let option = makeOption(
        providerID: secondary,
        chatTool: tool,
        role: "SECONDARY"
      ), !seen.contains(option.id) {
        seen.insert(option.id)
        result.append(option)
      }
    }

    if let tertiary = LLMProviderRoutingPreferences.loadTertiaryProvider() {
      let tool =
        tertiary == .chatGPTClaude
        ? (LLMProviderRoutingPreferences.loadTertiaryChatCLITool() ?? preferredChatCLITool()) : nil
      if let option = makeOption(
        providerID: tertiary,
        chatTool: tool,
        role: "TERTIARY"
      ), !seen.contains(option.id) {
        seen.insert(option.id)
        result.append(option)
      }
    }

    return result
  }

  private func makeOption(
    providerID: LLMProviderID,
    chatTool: ChatCLITool?,
    role: String
  ) -> ProviderOption? {
    let display = providerDisplay(providerID: providerID, chatTool: chatTool)
    return ProviderOption(
      id: "\(providerID.rawValue)_\(chatTool?.rawValue ?? "")_\(role)",
      title: display.title,
      subtitle: display.subtitle,
      systemImage: display.systemImage,
      providerID: providerID,
      chatToolOverride: chatTool,
      roleBadge: role
    )
  }

  private func providerDisplay(providerID: LLMProviderID, chatTool: ChatCLITool?) -> (
    title: String, subtitle: String?, systemImage: String
  ) {
    switch providerID {
    case .gemini:
      let modelName = GeminiModelPreference.load().primary.displayName
      return ("Gemini", modelName, "sparkles")
    case .dayflow:
      return ("Dayflow", nil, "cloud")
    case .ollama:
      let model = (UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let title = model.isEmpty ? "Local model" : model
      return (title, "Local", "desktopcomputer")
    case .chatGPTClaude:
      let tool = chatTool ?? preferredChatCLITool() ?? .codex
      let title = tool == .claude ? "Claude" : "ChatGPT"
      return (title, "CLI", "bubble.left.and.text.bubble.right")
    case .apfel:
      return ("Apple Intelligence", "On-device", "apple.logo")
    }
  }

  private func preferredChatCLITool() -> ChatCLITool? {
    guard let raw = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") else {
      return nil
    }
    return ChatCLITool(rawValue: raw)
  }
}

private struct ProviderOption: Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let systemImage: String
  let providerID: LLMProviderID
  let chatToolOverride: ChatCLITool?
  let roleBadge: String
}
