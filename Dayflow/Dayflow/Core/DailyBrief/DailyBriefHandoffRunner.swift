//
//  DailyBriefHandoffRunner.swift
//  Dayflow
//
//  Sends a docket task's prompt to an agent, the two ways the gear menu offers:
//    paste  copy the prompt, open the Claude or ChatGPT app, and press ⌘V for the user
//           (only when Dayflow has Accessibility access; otherwise they paste themselves)
//    run    run `claude -p` or `codex exec` in the background, in the task's folder,
//           writing everything it prints to a file in the brief folder. When it ends,
//           its exit code goes to "<output>.exit", so a later launch can still tell
//           whether it finished.
//

import AppKit
import ApplicationServices

enum DailyBriefAgent: String, Codable, CaseIterable, Sendable {
  case claude
  case chatgpt

  var displayName: String {
    switch self {
    case .claude: return "Claude"
    case .chatgpt: return "ChatGPT"
    }
  }

  /// The asset catalog icon shown in the gear menu and the list's status tags.
  var iconAsset: String {
    switch self {
    case .claude: return "DocketAgentClaude"
    case .chatgpt: return "DocketAgentChatGPT"
    }
  }

  var bundleIdentifier: String {
    switch self {
    case .claude: return "com.anthropic.claudefordesktop"
    case .chatgpt: return "com.openai.chat"
    }
  }

  /// Opens a new chat on the web with the prompt filled in, for when the app isn't installed.
  fileprivate func webURL(prompt: String) -> URL? {
    var components: URLComponents
    switch self {
    case .claude: components = URLComponents(string: "https://claude.ai/new")!
    case .chatgpt: components = URLComponents(string: "https://chatgpt.com/")!
    }
    components.queryItems = [URLQueryItem(name: "q", value: prompt)]
    return components.url
  }

  /// The shell command that runs the prompt (read from stdin) without asking questions.
  fileprivate var runCommand: String {
    switch self {
    case .claude: return "claude -p --permission-mode acceptEdits"
    case .chatgpt: return "codex exec --full-auto --skip-git-repo-check -"
    }
  }
}

@MainActor
enum DailyBriefHandoffRunner {
  /// Background runs still going, by output file path.
  private static var running: [String: Process] = [:]

  static func isRunning(outputURL: URL) -> Bool {
    running[outputURL.path]?.isRunning ?? false
  }

  // MARK: - Paste

  static func paste(prompt: String, agent: DailyBriefAgent, folder: String?) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(prompt, forType: .string)

    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleIdentifier)
    else {
      if let url = agent.webURL(prompt: prompt) { NSWorkspace.shared.open(url) }
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
      guard error == nil else { return }
      // Give the app a moment to come forward and focus its message box.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        MainActor.assumeIsolated { pressCommandV() }
      }
    }
  }

  static func openApp(_ agent: DailyBriefAgent) {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleIdentifier)
    else { return }
    NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
  }

  /// Posts ⌘V to the frontmost app. Needs Accessibility access; without it nothing happens
  /// and the prompt just waits on the clipboard.
  static func pressCommandV() {
    guard AXIsProcessTrusted() else { return }
    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey: CGKeyCode = 9
    let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  // MARK: - Run

  /// Starts the agent in the background. `finished` gets the exit code on the main actor.
  static func run(
    prompt: String, agent: DailyBriefAgent, folder: String?, outputURL: URL,
    finished: @escaping @MainActor (Int32) -> Void
  ) {
    let promptURL = outputURL.appendingPathExtension("prompt")
    let exitURL = outputURL.appendingPathExtension("exit")
    do {
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
    } catch {
      finished(1)
      return
    }

    let workingFolder = folder ?? outputURL.deletingLastPathComponent().path
    let escape = LoginShellRunner.shellEscape
    // The whole run goes through /bin/sh so it works whatever the user's shell is (fish
    // too), and a failed `cd` still lands in the output file.
    let inner = "cd \(escape(workingFolder)) && \(agent.runCommand) < \(escape(promptURL.path))"
    let script = "{ \(inner); } > \(escape(outputURL.path)) 2>&1; echo $? > \(escape(exitURL.path))"
    // A login, interactive shell so PATH includes what .zshrc adds (npm, nvm, ~/.local/bin).
    let command = "/bin/sh -c \(escape(script))"

    let process = Process()
    process.executableURL = LoginShellRunner.userLoginShell
    process.arguments = ["-l", "-i", "-c", command]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    let key = outputURL.path
    process.terminationHandler = { _ in
      let text = (try? String(contentsOf: exitURL, encoding: .utf8)) ?? "1"
      let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
      Task { @MainActor in
        running[key] = nil
        finished(code)
      }
    }

    do {
      try process.run()
      running[key] = process
    } catch {
      finished(1)
    }
  }
}
