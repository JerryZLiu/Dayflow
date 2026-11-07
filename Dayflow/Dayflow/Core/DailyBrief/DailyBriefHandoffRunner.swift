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

  /// For ChatGPT, the current app (which has Codex and owns codex:// links) when it's
  /// installed, otherwise ChatGPT Classic.
  var bundleIdentifier: String {
    switch self {
    case .claude: return "com.anthropic.claudefordesktop"
    case .chatgpt:
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleIdentifier)
        != nil
        ? Self.codexBundleIdentifier : "com.openai.chat"
    }
  }

  private static let codexBundleIdentifier = "com.openai.codex"

  /// The agent a thread id belongs to, from its shape: Claude Code's desktop sessions are
  /// `local_<uuid>`, Codex threads are bare UUIDs. Nil for anything else.
  init?(threadID id: String) {
    if id.hasPrefix("local_") {
      let rest = id.dropFirst("local_".count)
      guard !rest.isEmpty, rest.count <= 64,
        rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
      else { return nil }
      self = .claude
    } else if UUID(uuidString: id) != nil {
      self = .chatgpt
    } else {
      return nil
    }
  }

  /// The agent behind an app name the brief uses for new threads: "claude" or "codex".
  init?(appName: String) {
    switch appName {
    case "claude": self = .claude
    case "codex": self = .chatgpt
    default: return nil
    }
  }

  /// Whether the app this agent opens is installed.
  var isInstalled: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
  }

  /// The deep link that opens the thread the task goes to: `thread` when the brief picked
  /// one, otherwise a new thread (in `folder`, when the task has one). It never carries the
  /// prompt, which still gets typed in. Nil when the installed app can't take the link.
  func threadLink(thread: String?, folder: String?) -> URL? {
    var components = URLComponents()
    switch self {
    case .claude:
      components.scheme = "claude"
      components.host = "code"
      if let thread {
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: thread)]
      } else {
        components.path = "/new"
        if let folder { components.queryItems = [URLQueryItem(name: "folder", value: folder)] }
      }
    case .chatgpt:
      guard bundleIdentifier == Self.codexBundleIdentifier else { return nil }
      components.scheme = "codex"
      components.host = "threads"
      if let thread {
        components.path = "/\(thread)"
      } else {
        components.path = "/new"
        if let folder { components.queryItems = [URLQueryItem(name: "path", value: folder)] }
      }
    }
    return components.url
  }

  /// Opens the app at `link` (or just opens it when there's no link), bringing it forward.
  func open(link: URL?, completion: (@Sendable (Error?) -> Void)? = nil) {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else {
      completion?(CocoaError(.fileNoSuchFile))
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    if let link {
      NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration) {
        _, error in
        completion?(error)
      }
    } else {
      NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
        completion?(error)
      }
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

  /// `link` opens the thread to paste into (see DailyBriefAgent.threadLink); nil just opens the app.
  static func paste(prompt: String, agent: DailyBriefAgent, link: URL?) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(prompt, forType: .string)

    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleIdentifier) != nil
    else {
      if let url = agent.webURL(prompt: prompt) { NSWorkspace.shared.open(url) }
      return
    }

    agent.open(link: link) { error in
      guard error == nil else { return }
      // Give the app a moment to come forward (and switch threads) and focus its message box.
      DispatchQueue.main.asyncAfter(deadline: .now() + (link == nil ? 1.2 : 1.8)) {
        MainActor.assumeIsolated { pressCommandV() }
      }
    }
  }

  static func openApp(_ agent: DailyBriefAgent) {
    agent.open(link: nil)
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
