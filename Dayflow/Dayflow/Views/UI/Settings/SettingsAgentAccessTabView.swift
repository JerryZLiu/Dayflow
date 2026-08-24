//
//  SettingsAgentAccessTabView.swift
//  Dayflow
//
//  The "AI Tools" tab: connect MCP clients to the bundled dayflow binary,
//  the edits toggle, and the optional terminal command.
//

import AppKit
import SwiftUI

struct SettingsAgentAccessTabView: View {
  @ObservedObject var viewModel: AgentAccessViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      clientsSection
      editsSection
      terminalSection
    }
    .onAppear { viewModel.refresh() }
  }

  private var clientsSection: some View {
    SettingsSection(
      title: "Connect to AI tools",
      subtitle:
        "Let Codex, Claude, Cursor, and other AI tools read your Dayflow timeline. "
        + "Connections are saved to each tool's user configuration, so Dayflow is "
        + "available across projects on this Mac. Nothing leaves your Mac except what "
        + "you send in your own conversations."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(viewModel.clients) { row in
          SettingsRow(
            label: row.client.displayName,
            subtitle: row.subtitle,
            showsDivider: true
          ) {
            clientControl(for: row)
          }
        }

        SettingsRow(
          label: "Other apps",
          subtitle: "Paste this into any MCP client's configuration.",
          showsDivider: false
        ) {
          SettingsSecondaryButton(
            title: viewModel.copiedSnippet ? "Copied" : "Copy config",
            systemImage: viewModel.copiedSnippet ? "checkmark" : "doc.on.doc"
          ) {
            viewModel.copySnippet()
          }
        }
      }
    }
  }

  @ViewBuilder
  private func clientControl(for row: AgentAccessViewModel.ClientRow) -> some View {
    switch row.state {
    case .notInstalled:
      Text("Not found")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(SettingsStyle.meta)
    case .connected:
      HStack(spacing: 10) {
        HStack(spacing: 5) {
          Circle().fill(SettingsStyle.statusGood).frame(width: 7, height: 7)
          Text("Connected")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.secondary)
        }
        SettingsSecondaryButton(title: "Disconnect") {
          viewModel.disconnect(row.client)
        }
      }
    case .available:
      SettingsSecondaryButton(title: "Connect") {
        viewModel.connect(row.client)
      }
    case .checking:
      Text("Checking…")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(SettingsStyle.meta)
    case .connecting:
      HStack(spacing: 7) {
        ProgressView().controlSize(.small)
        Text("Connecting…")
      }
      .font(.custom("Figtree", size: 12))
      .foregroundColor(SettingsStyle.secondary)
    case .disconnecting:
      HStack(spacing: 7) {
        ProgressView().controlSize(.small)
        Text("Disconnecting…")
      }
      .font(.custom("Figtree", size: 12))
      .foregroundColor(SettingsStyle.secondary)
    case .failed:
      SettingsSecondaryButton(title: "Retry") {
        viewModel.connect(row.client)
      }
    case .openedInstaller:
      Text("Finish in \(row.client.displayName)")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(SettingsStyle.secondary)
    }
  }

  private var editsSection: some View {
    SettingsSection(
      title: "Allow edits",
      subtitle:
        "Off means AI tools can read your timeline but never change it. On lets them "
        + "rename activities, manage categories, and set day goals. Deleting anything "
        + "always asks you first, and every edit is logged."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: viewModel.editsEnabled ? "Edits are on" : "Edits are off",
          subtitle: viewModel.editsEnabled
            ? "AI tools can make changes through Dayflow while it's running."
            : nil,
          showsDivider: false
        ) {
          SettingsToggle(isOn: $viewModel.editsEnabled)
        }
      }
    }
  }

  private var terminalSection: some View {
    SettingsSection(
      title: "Terminal command",
      subtitle:
        "Adds a `dayflow` command so you can see your timeline from any terminal. "
        + "This isn't a separate package like an npm install: it links to the CLI already "
        + "inside Dayflow, so the CLI always stays in sync with the app and can't break "
        + "when the app updates. Nothing is downloaded and your shell configuration isn't touched."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        SettingsRow(
          label: viewModel.terminalInstalled ? "Installed" : "Not installed",
          subtitle: viewModel.terminalInstalled ? "Try: dayflow timeline" : nil,
          showsDivider: false
        ) {
          SettingsSecondaryButton(
            title: viewModel.terminalInstalled ? "Remove" : "Install"
          ) {
            viewModel.toggleTerminalCommand()
          }
        }

        if let error = viewModel.terminalError {
          Text(error)
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.statusBad)
            .fixedSize(horizontal: false, vertical: true)
        }

        SettingsCommandBlock(
          command: AgentClientRegistration.manualTerminalInstallCommand,
          copied: viewModel.copiedTerminalCommand,
          copy: viewModel.copyTerminalCommand
        )
      }
    }
  }
}

private struct SettingsCommandBlock: View {
  let command: String
  let copied: Bool
  let copy: () -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Text(command)
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(SettingsStyle.ink.opacity(0.82))
        .textSelection(.enabled)
        .padding(.leading, 14)
        .padding(.trailing, 104)
        .padding(.vertical, 13)
        .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white.opacity(0.48))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.black.opacity(0.09), lineWidth: 1)
    )
    .overlay(alignment: .trailing) {
      Button(action: copy) {
        HStack(spacing: 5) {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 11, weight: .medium))
          Text(copied ? "Copied" : "Copy")
            .font(.custom("Figtree", size: 12))
            .fontWeight(.medium)
        }
        .foregroundColor(copied ? SettingsStyle.statusGood : SettingsStyle.ink.opacity(0.72))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.92))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.black.opacity(0.11), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .accessibilityLabel(copied ? "Terminal command copied" : "Copy terminal command")
      .padding(.trailing, 6)
    }
  }
}

// MARK: - View model

@MainActor
final class AgentAccessViewModel: ObservableObject {
  enum ClientState {
    case notInstalled
    case available
    case connected
    case checking
    case connecting
    case disconnecting
    case failed(String)
    case openedInstaller
  }

  struct ClientRow: Identifiable {
    let client: AgentClient
    let state: ClientState
    var id: String { client.id }

    var subtitle: String? {
      switch state {
      case .connected:
        return client == .codex
          ? "Restart Codex to pick up the connection."
          : "Restart it to pick up the connection."
      case .failed(let message): return message
      case .openedInstaller: return "Approve the install dialog it just showed."
      default: return nil
      }
    }
  }

  @Published var clients: [ClientRow] = []
  @Published var copiedSnippet = false
  @Published var copiedTerminalCommand = false
  @Published var terminalInstalled = false
  @Published var terminalError: String?

  @Published var editsEnabled: Bool = AgentAccessPreferences.editsEnabled {
    didSet {
      guard editsEnabled != AgentAccessPreferences.editsEnabled else { return }
      AgentAccessPreferences.editsEnabled = editsEnabled
      if editsEnabled {
        AgentBridgeServer.shared.start()
      } else {
        AgentBridgeServer.shared.stop()
      }
      AnalyticsService.shared.capture(
        "agent_edits_toggled", ["enabled": editsEnabled])
    }
  }

  private var deeplinkOpened: Set<AgentClient> = []
  private var clientStates: [AgentClient: ClientState] = [:]
  private var codexStatusTask: Task<Void, Never>?
  private var codexMutationTask: Task<Void, Never>?

  private var codexRegistration: CodexMCPRegistration {
    CodexMCPRegistration(cliPath: AgentClientRegistration.cliPath)
  }

  func refresh() {
    terminalInstalled = AgentClientRegistration.terminalCommandInstalled
    for client in AgentClient.allCases where client != .codex {
      clientStates[client] = synchronousState(for: client)
    }
    if codexMutationTask == nil {
      clientStates[.codex] = .checking
      refreshCodex()
    }
    publishClientRows()
  }

  func connect(_ client: AgentClient) {
    if client == .codex {
      connectCodex()
      return
    }

    switch AgentClientRegistration.connect(client) {
    case .connected:
      AnalyticsService.shared.capture("agent_client_connected", ["client": client.rawValue])
    case .openedInstaller:
      deeplinkOpened.insert(client)
      AnalyticsService.shared.capture("agent_client_deeplink", ["client": client.rawValue])
    case .failed(let message):
      terminalError = message
    }
    refresh()
  }

  func disconnect(_ client: AgentClient) {
    if client == .codex {
      disconnectCodex()
      return
    }

    AgentClientRegistration.disconnect(client)
    refresh()
  }

  private func synchronousState(for client: AgentClient) -> ClientState {
    if !AgentClientRegistration.isInstalled(client) {
      return .notInstalled
    }
    if AgentClientRegistration.isConnected(client) {
      return .connected
    }
    if deeplinkOpened.contains(client) {
      return .openedInstaller
    }
    return .available
  }

  private func publishClientRows() {
    clients = AgentClient.allCases.map { client in
      ClientRow(client: client, state: clientStates[client] ?? .checking)
    }
  }

  private func refreshCodex() {
    let registration = codexRegistration
    codexStatusTask?.cancel()
    codexStatusTask = Task { [weak self] in
      let status = await Task.detached(priority: .userInitiated) {
        registration.status()
      }.value
      guard !Task.isCancelled else { return }
      self?.applyCodexStatus(status)
    }
  }

  private func connectCodex() {
    guard codexMutationTask == nil else { return }
    codexStatusTask?.cancel()
    clientStates[.codex] = .connecting
    publishClientRows()

    let registration = codexRegistration
    codexMutationTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        registration.connect()
      }.value
      guard let self else { return }
      codexMutationTask = nil

      switch result {
      case .connected:
        clientStates[.codex] = .connected
        AnalyticsService.shared.capture("agent_client_connected", ["client": "codex"])
      case .notInstalled:
        clientStates[.codex] = .notInstalled
      case .disconnected:
        clientStates[.codex] = .available
      case .failed(let message):
        clientStates[.codex] = .failed(message)
      }
      publishClientRows()
    }
  }

  private func disconnectCodex() {
    guard codexMutationTask == nil else { return }
    codexStatusTask?.cancel()
    clientStates[.codex] = .disconnecting
    publishClientRows()

    let registration = codexRegistration
    codexMutationTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        registration.disconnect()
      }.value
      guard let self else { return }
      codexMutationTask = nil

      switch result {
      case .disconnected:
        clientStates[.codex] = .available
      case .notInstalled:
        clientStates[.codex] = .notInstalled
      case .connected:
        clientStates[.codex] = .connected
      case .failed(let message):
        clientStates[.codex] = .failed(message)
      }
      publishClientRows()
    }
  }

  private func applyCodexStatus(_ status: CodexMCPRegistration.Status) {
    switch status {
    case .notInstalled:
      clientStates[.codex] = .notInstalled
    case .available, .disabled, .stale:
      clientStates[.codex] = .available
    case .connected:
      clientStates[.codex] = .connected
    case .conflict(let message), .failed(let message):
      clientStates[.codex] = .failed(message)
    }
    publishClientRows()
  }

  func copySnippet() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      AgentClientRegistration.manualConfigSnippet, forType: .string)
    copiedSnippet = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.copiedSnippet = false
    }
  }

  func copyTerminalCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      AgentClientRegistration.manualTerminalInstallCommand,
      forType: .string
    )
    copiedTerminalCommand = true
    AnalyticsService.shared.capture("terminal_command_copied", ["source": "settings"])
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.copiedTerminalCommand = false
    }
  }

  func toggleTerminalCommand() {
    terminalError = nil
    if terminalInstalled {
      try? FileManager.default.removeItem(atPath: "/usr/local/bin/dayflow")
    } else {
      terminalError = AgentClientRegistration.installTerminalCommand()
    }
    refresh()
  }
}
