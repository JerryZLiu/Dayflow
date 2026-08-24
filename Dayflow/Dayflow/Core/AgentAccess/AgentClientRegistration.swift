//
//  AgentClientRegistration.swift
//  Dayflow
//
//  Connects MCP clients to the bundled `dayflow` binary. Clients with their
//  own install flow (Cursor, VS Code) get a deeplink and write their own
//  config after their own consent dialog. Claude Code and Claude Desktop are
//  configured directly, and only ever the "dayflow" entry we own.
//
//  Configs record an absolute path into the app bundle, which goes stale if
//  the app moves — repairStaleRegistrations() runs at launch and fixes any
//  entry we previously wrote.
//

import AppKit
import Foundation

enum AgentClient: String, CaseIterable, Identifiable {
  case codex
  case claudeCode
  case claudeDesktop
  case cursor
  case vsCode

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .codex: return "Codex"
    case .claudeCode: return "Claude Code"
    case .claudeDesktop: return "Claude Desktop"
    case .cursor: return "Cursor"
    case .vsCode: return "VS Code"
    }
  }
}

@MainActor
enum AgentClientRegistration {

  /// The bundled CLI. This is what every client config points at.
  /// Lives in Contents/Helpers, NOT Contents/MacOS — the filesystem is
  /// case-insensitive, so "dayflow" next to the "Dayflow" app executable
  /// would overwrite it.
  static var cliPath: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dayflow").path
  }

  /// The JSON snippet for clients we don't integrate with directly.
  static var manualConfigSnippet: String {
    """
    "dayflow": {
      "command": "\(cliPath)",
      "args": ["mcp"]
    }
    """
  }

  private static var claudeCodeConfigURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
  }

  private static var claudeDesktopConfigURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Claude/claude_desktop_config.json")
  }

  // MARK: - Detection

  static func isInstalled(_ client: AgentClient) -> Bool {
    let fileManager = FileManager.default
    switch client {
    case .codex:
      return CodexExecutableResolver.shared.resolve() != nil
    case .claudeCode:
      return fileManager.fileExists(atPath: claudeCodeConfigURL.path)
    case .claudeDesktop:
      return fileManager.fileExists(
        atPath: claudeDesktopConfigURL.deletingLastPathComponent().path)
    case .cursor:
      return fileManager.fileExists(atPath: "/Applications/Cursor.app")
    case .vsCode:
      return fileManager.fileExists(atPath: "/Applications/Visual Studio Code.app")
    }
  }

  /// True when the client's config already has a dayflow entry we can see.
  /// Deeplink clients own their config, so this is only knowable for the two
  /// we write directly.
  static func isConnected(_ client: AgentClient) -> Bool {
    switch client {
    case .codex:
      return CodexMCPRegistration(cliPath: cliPath).status() == .connected
    case .claudeCode:
      return dayflowEntry(inConfigAt: claudeCodeConfigURL) != nil
    case .claudeDesktop:
      return dayflowEntry(inConfigAt: claudeDesktopConfigURL) != nil
    case .cursor, .vsCode:
      return false
    }
  }

  // MARK: - Connect

  enum RegistrationResult {
    case connected
    case openedInstaller  // deeplink clients finish in their own UI
    case failed(String)
  }

  static func connect(_ client: AgentClient) -> RegistrationResult {
    switch client {
    case .codex:
      switch CodexMCPRegistration(cliPath: cliPath).connect() {
      case .connected: return .connected
      case .notInstalled: return .failed("Codex isn't installed on this Mac.")
      case .disconnected: return .failed("Codex didn't keep the Dayflow connection.")
      case .failed(let message): return .failed(message)
      }
    case .claudeCode:
      return writeDayflowEntry(configAt: claudeCodeConfigURL)
    case .claudeDesktop:
      return writeDayflowEntry(configAt: claudeDesktopConfigURL)
    case .cursor:
      let config = ["command": cliPath, "args": ["mcp"]] as [String: Any]
      guard let data = try? JSONSerialization.data(withJSONObject: config),
        let url = URL(
          string:
            "cursor://anysphere.cursor-deeplink/mcp/install?name=dayflow&config=\(data.base64EncodedString())"
        )
      else { return .failed("Could not build the Cursor install link.") }
      NSWorkspace.shared.open(url)
      return .openedInstaller
    case .vsCode:
      let config: [String: Any] = ["name": "dayflow", "command": cliPath, "args": ["mcp"]]
      guard let data = try? JSONSerialization.data(withJSONObject: config),
        let encoded = String(data: data, encoding: .utf8)?.addingPercentEncoding(
          withAllowedCharacters: .alphanumerics),
        let url = URL(string: "vscode:mcp/install?\(encoded)")
      else { return .failed("Could not build the VS Code install link.") }
      NSWorkspace.shared.open(url)
      return .openedInstaller
    }
  }

  static func disconnect(_ client: AgentClient) {
    switch client {
    case .codex:
      _ = CodexMCPRegistration(cliPath: cliPath).disconnect()
    case .claudeCode: removeDayflowEntry(configAt: claudeCodeConfigURL)
    case .claudeDesktop: removeDayflowEntry(configAt: claudeDesktopConfigURL)
    case .cursor, .vsCode: break  // Their config; removed in their UI.
    }
  }

  // MARK: - Config file editing

  private static func dayflowEntry(inConfigAt url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
      let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let servers = config["mcpServers"] as? [String: Any]
    else { return nil }
    return servers["dayflow"] as? [String: Any]
  }

  /// Adds or updates only the "dayflow" key under mcpServers, preserving
  /// everything else in the file byte-for-byte semantically.
  private static func writeDayflowEntry(configAt url: URL) -> RegistrationResult {
    var config: [String: Any] = [:]
    if let data = try? Data(contentsOf: url) {
      guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failed(
          "\(url.lastPathComponent) exists but isn't valid JSON — not touching it.")
      }
      config = existing
    }

    var servers = config["mcpServers"] as? [String: Any] ?? [:]
    servers["dayflow"] = ["type": "stdio", "command": cliPath, "args": ["mcp"]]
    config["mcpServers"] = servers

    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONSerialization.data(
        withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: url, options: .atomic)
      return .connected
    } catch {
      return .failed("Could not update \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }

  private static func removeDayflowEntry(configAt url: URL) {
    guard let data = try? Data(contentsOf: url),
      var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var servers = config["mcpServers"] as? [String: Any],
      servers["dayflow"] != nil
    else { return }
    servers.removeValue(forKey: "dayflow")
    config["mcpServers"] = servers
    if let updated = try? JSONSerialization.data(
      withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    {
      try? updated.write(to: url, options: .atomic)
    }
  }

  /// If the app moved since a config was written, its recorded path is dead.
  /// Called at launch; rewrites any entry we own whose command doesn't match
  /// the running bundle. Never touches entries the user added themselves
  /// beyond the "dayflow" key.
  static func repairStaleRegistrations() {
    for url in [claudeCodeConfigURL, claudeDesktopConfigURL] {
      guard let entry = dayflowEntry(inConfigAt: url),
        let recorded = entry["command"] as? String,
        recorded != cliPath
      else { continue }
      _ = writeDayflowEntry(configAt: url)
      print("ℹ️ AgentAccess: repaired stale dayflow path in \(url.lastPathComponent)")
    }

    let codexRegistration = CodexMCPRegistration(cliPath: cliPath)
    Task.detached(priority: .utility) {
      codexRegistration.repairStaleRegistration()
    }
  }

  // MARK: - Terminal command

  static var manualTerminalInstallCommand: String {
    "sudo mkdir -p /usr/local/bin && sudo ln -sf \(LoginShellRunner.shellEscape(cliPath)) /usr/local/bin/dayflow"
  }

  static var terminalCommandInstalled: Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: "/usr/local/bin/dayflow"))
      == cliPath
  }

  static func installTerminalCommand() -> String? {
    let linkPath = "/usr/local/bin/dayflow"
    let fileManager = FileManager.default
    do {
      if fileManager.fileExists(atPath: linkPath) {
        try fileManager.removeItem(atPath: linkPath)
      }
      try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: cliPath)
      return nil
    } catch {
      return
        "Automatic install failed because /usr/local/bin requires administrator access on this Mac. Copy the command below and run it in Terminal."
    }
  }
}
