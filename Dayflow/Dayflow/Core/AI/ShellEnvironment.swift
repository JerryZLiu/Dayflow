import Foundation

/// The user's shell environment, read once and reused to launch Claude, Codex and other CLIs.
///
/// Ported from T3 Code's shell environment loader (MIT, github.com/pingdotgg/t3code,
/// apps/desktop/src/shell and packages/shared/src/shell.ts): run the login shell once,
/// print the environment between a start and an end marker, and look for the markers
/// anywhere in the output. Shell startup noise, such as iTerm2's shell integration codes,
/// then can't hide a value, and CLIs launch without starting an interactive shell each time.
///
/// Unlike T3, every variable comes from the shell (API keys, proxies, version managers), so
/// CLIs see what they would in Terminal. Only `terminalSessionNames`, which describe the
/// shell session rather than the user's setup, are left out. When the read fails (no PATH
/// within the timeout), commands fall back to running through the login shell.
final class ShellEnvironment: @unchecked Sendable {
  enum Outcome: String, Sendable {
    case ok
    case timedOut = "timed_out"
    case noPath = "no_path"
    case failedToStart = "failed_to_start"
  }

  struct Snapshot: Sendable {
    /// The app's own environment with the shell values merged in, the way T3 does it.
    let launchEnvironment: [String: String]
    /// The values the shell printed, by variable name.
    let shellValues: [String: String]
    let outcome: Outcome
    let shellPath: String
    let exitCode: Int32?
    let readAt: Date
    let durationMs: Int
    /// Where PATH came from: "login_shell", "launchctl" or "app".
    let pathSource: String
    /// Text the shell printed outside the markers, such as iTerm2 codes or shell file output.
    let extraOutput: String

    /// True when commands launch with `launchEnvironment`; false means the login shell fallback.
    var usesCapturedEnvironment: Bool { outcome == .ok }
  }

  static let shared = ShellEnvironment()

  /// Variables printed in the support debug log. Every one is a path, a locale or a socket;
  /// other variables can hold secrets, so the log only counts them.
  static let diagnosticNames = [
    "PATH",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "SSH_AUTH_SOCK",
    "HOMEBREW_PREFIX",
    "HOMEBREW_CELLAR",
    "HOMEBREW_REPOSITORY",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "__MISE_DIFF",
    "CLAUDE_CONFIG_DIR",
    "CODEX_HOME",
  ]

  /// Variables about the shell session or the terminal it ran in, not the user's setup.
  /// Passing them on would make a CLI think it runs inside a terminal (or inside Claude Code).
  private static let terminalSessionNames: Set<String> = [
    "PWD", "OLDPWD", "SHLVL", "_",
    "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "COLORTERM",
    "LC_TERMINAL", "LC_TERMINAL_VERSION", "TMUX", "TMUX_PANE", "STY", "WINDOWID",
    "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "SECURITYSESSIONID",
    "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
  ]
  private static let terminalSessionPrefixes = [
    "ITERM_", "VSCODE_", "KITTY_", "WEZTERM_", "GHOSTTY_", "ALACRITTY_",
  ]

  private static let localeNames = ["LANG", "LC_ALL", "LC_CTYPE"]
  private static let readTimeout: TimeInterval = 5
  private static let launchctlTimeout: TimeInterval = 2

  private let lock = NSLock()
  private var cached: Snapshot?

  /// The saved snapshot, reading the shell first if nothing is saved yet.
  func current(trigger: String = "first_use") -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    if let cached { return cached }
    return readLocked(trigger: trigger)
  }

  /// Reads the shell again, e.g. after the user installs a CLI or edits their shell file.
  @discardableResult
  func refresh(trigger: String) -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return readLocked(trigger: trigger)
  }

  /// Like `refresh`, but keeps the saved snapshot when it is newer than `maxAge` seconds.
  /// Failure paths that can repeat on every batch use this.
  @discardableResult
  func refreshIfOlder(than maxAge: TimeInterval, trigger: String) -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    if let cached, Date().timeIntervalSince(cached.readAt) < maxAge { return cached }
    return readLocked(trigger: trigger)
  }

  /// A process that runs `command`, an already shell-escaped command line.
  ///
  /// With a good snapshot this is `/bin/sh -c`, which only splits the command into arguments
  /// and reads no startup files, so the CLI sees `launchEnvironment` plus `overrides`.
  /// Otherwise it is the login shell with `-l -i -c`, as Dayflow always ran commands.
  func makeProcess(command: String, environment overrides: [String: String] = [:]) -> Process {
    let snapshot = current()
    let process = Process()
    if snapshot.usesCapturedEnvironment {
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.environment = snapshot.launchEnvironment.merging(overrides) { _, override in
        override
      }
    } else {
      process.executableURL = LoginShellRunner.userLoginShell
      process.arguments = ["-l", "-i", "-c", command]
      if !overrides.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(overrides) {
          _, override in override
        }
      }
    }
    return process
  }

  /// Full path of the first executable called `name` on the launch PATH.
  func executablePath(named name: String) -> String? {
    let path = current().launchEnvironment["PATH"] ?? ""
    for directory in path.split(separator: ":") {
      let candidate = (String(directory) as NSString).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  /// A section for the support debug log. Every captured variable is a path, a locale or a
  /// socket, so values are printed (with the home folder shortened to ~), except mise's
  /// internal record, which is long and unreadable.
  func diagnosticsText() -> String {
    let snapshot = current()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func tidy(_ text: String) -> String {
      text.replacingOccurrences(of: home, with: "~")
    }

    let readAt = ISO8601DateFormatter().string(from: snapshot.readAt)
    let exitCode = snapshot.exitCode.map(String.init) ?? "none"
    var lines = ["--- Shell environment (used to launch Claude and Codex) ---"]
    lines.append(
      "Read \(readAt) | \(snapshot.shellPath) | \(snapshot.outcome.rawValue) | "
        + "\(snapshot.durationMs)ms | exit \(exitCode)")
    lines.append(
      "Launch mode: "
        + (snapshot.usesCapturedEnvironment ? "captured environment" : "login shell fallback"))
    lines.append("PATH source: \(snapshot.pathSource)")

    for name in Self.diagnosticNames where name != "PATH" {
      guard let value = snapshot.shellValues[name] else { continue }
      lines.append(name == "__MISE_DIFF" ? "\(name) is set" : "\(name)=\(tidy(value))")
    }
    let otherCount = snapshot.shellValues.keys.filter { !Self.diagnosticNames.contains($0) }.count
    lines.append("Other variables from the shell: \(otherCount)")

    lines.append("PATH used:")
    for entry in (snapshot.launchEnvironment["PATH"] ?? "").split(separator: ":") {
      lines.append("  \(tidy(String(entry)))")
    }

    for cli in ["claude", "codex"] {
      lines.append("\(cli): \(executablePath(named: cli).map(tidy) ?? "not on PATH")")
    }

    if !snapshot.extraOutput.isEmpty {
      let sample = Self.visible(String(snapshot.extraOutput.prefix(300)))
      lines.append("Shell printed outside the markers: \(tidy(sample))")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Reading the shell

  private struct ShellRead {
    let shellPath: String
    let outcome: Outcome
    let exitCode: Int32?
    let values: [String: String]
    let extraOutput: String
  }

  private func readLocked(trigger: String) -> Snapshot {
    let started = Date()
    var read: ShellRead?
    for shell in Self.loginShellCandidates() {
      read = Self.readValues(shell: shell)
      if read?.values["PATH"] != nil { break }
    }

    let shellValues = read?.values ?? [:]
    let launchctlPath = shellValues["PATH"] == nil ? Self.readLaunchctlPath() : nil
    let pathSource =
      shellValues["PATH"] != nil ? "login_shell" : launchctlPath != nil ? "launchctl" : "app"

    let snapshot = Snapshot(
      launchEnvironment: Self.merge(
        shellValues: shellValues,
        launchctlPath: launchctlPath,
        into: ProcessInfo.processInfo.environment
      ),
      shellValues: shellValues,
      outcome: read?.outcome ?? .failedToStart,
      shellPath: read?.shellPath ?? LoginShellRunner.userLoginShell.path,
      exitCode: read?.exitCode,
      readAt: Date(),
      durationMs: Int(Date().timeIntervalSince(started) * 1000),
      pathSource: pathSource,
      extraOutput: read?.extraOutput ?? ""
    )
    cached = snapshot
    Self.report(snapshot, trigger: trigger)
    return snapshot
  }

  /// $SHELL, then the account's login shell, then zsh; T3 tries them in the same order.
  private static func loginShellCandidates() -> [String] {
    var candidates: [String] = []
    let shells: [String?] = [
      ProcessInfo.processInfo.environment["SHELL"],
      LoginShellRunner.userLoginShell.path,
      "/bin/zsh",
    ]
    for shell in shells {
      guard let shell, !shell.isEmpty, !candidates.contains(shell) else { continue }
      candidates.append(shell)
    }
    return candidates
  }

  private static let startMarker = "__DAYFLOW_ENV_START__"
  private static let endMarker = "__DAYFLOW_ENV_END__"

  /// Prints every variable as NAME=value, each ending in a NUL byte, so values that
  /// contain newlines survive.
  private static func captureCommand() -> String {
    "printf '%s\\n' '\(startMarker)'; /usr/bin/env -0; printf '%s\\n' '\(endMarker)'"
  }

  private static func readValues(shell: String) -> ShellRead {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    // Interactive startup is where most people's PATH lines live (.zshrc).
    process.arguments = ["-ilc", captureCommand()]
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    let reader = ChatCLIProcessRunner.BufferedPipeReader(
      handle: stdoutPipe.fileHandleForReading, label: "ShellEnvironment.Stdout")

    do {
      try process.run()
    } catch {
      return ShellRead(
        shellPath: shell, outcome: .failedToStart, exitCode: nil, values: [:], extraOutput: "")
    }
    reader.start()

    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      process.waitUntilExit()
      exited.signal()
    }
    if exited.wait(timeout: .now() + readTimeout) == .timedOut {
      process.terminate()
      return ShellRead(
        shellPath: shell, outcome: .timedOut, exitCode: nil, values: [:], extraOutput: "")
    }

    // A background job started by the shell file can hold stdout open, so don't wait for EOF.
    _ = reader.wait(timeout: .now() + 1)
    // Decoding replaces invalid bytes instead of failing, so one odd value can't lose the rest.
    let output = String(decoding: reader.snapshotData(), as: UTF8.self)
    let values = extractValues(from: output)
    return ShellRead(
      shellPath: shell,
      outcome: values["PATH"] == nil ? .noPath : .ok,
      exitCode: process.terminationStatus,
      values: values,
      extraOutput: textOutsideMarkers(output)
    )
  }

  /// Finds the environment between the markers, wherever they land in the output, and
  /// leaves out empty values and the terminal session variables.
  private static func extractValues(from output: String) -> [String: String] {
    guard
      let start = output.range(of: startMarker + "\n"),
      let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
    else { return [:] }

    var values: [String: String] = [:]
    for entry in output[start.upperBound..<end.lowerBound].split(separator: "\0") {
      guard let equals = entry.firstIndex(of: "=") else { continue }
      let name = String(entry[..<equals])
      let value = String(entry[entry.index(after: equals)...])
      guard !name.isEmpty, !value.isEmpty, !isTerminalSessionName(name) else { continue }
      values[name] = value
    }
    return values
  }

  private static func isTerminalSessionName(_ name: String) -> Bool {
    terminalSessionNames.contains(name)
      || terminalSessionPrefixes.contains { name.hasPrefix($0) }
  }

  private static func textOutsideMarkers(_ output: String) -> String {
    guard
      let firstMarker = output.range(of: startMarker),
      let lastMarker = output.range(of: endMarker, options: .backwards)
    else {
      return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let outside =
      String(output[..<firstMarker.lowerBound]) + String(output[lastMarker.upperBound...])
    return outside.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func readLaunchctlPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["getenv", "PATH"]
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe

    do {
      try process.run()
    } catch {
      return nil
    }

    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      process.waitUntilExit()
      exited.signal()
    }
    if exited.wait(timeout: .now() + launchctlTimeout) == .timedOut {
      process.terminate()
      return nil
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return path?.isEmpty == false ? path : nil
  }

  // MARK: - Merging

  private static func merge(
    shellValues: [String: String],
    launchctlPath: String?,
    into appEnvironment: [String: String]
  ) -> [String: String] {
    // The shell's values win, as they would in Terminal; the app's fill in the rest.
    var environment = appEnvironment.merging(shellValues) { _, shell in shell }

    // Shell PATH first, then the app's own, without duplicates. Claude's old local
    // installer only adds a shell alias (`claude` → ~/.claude/local/claude), which can't
    // be carried over, so that folder goes on the end of PATH instead.
    let claudeLocal = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/local").path
    let claudeLocalEntry =
      FileManager.default.isExecutableFile(atPath: claudeLocal + "/claude") ? claudeLocal : nil
    if let path = mergedPath([
      shellValues["PATH"] ?? launchctlPath, appEnvironment["PATH"], claudeLocalEntry,
    ]) {
      environment["PATH"] = path
    }

    // Locale variables go together, since an inherited LC_ALL overrides LANG and LC_CTYPE.
    if localeNames.allSatisfy({ isMissing($0, in: environment) }) {
      for name in localeNames {
        if let value = shellValues[name] {
          environment[name] = value
        }
      }
      // launchd sets no locale; a UTF-8 LC_CTYPE keeps CLIs from decoding text as MacRoman.
      if localeNames.allSatisfy({ isMissing($0, in: environment) }) {
        environment["LC_CTYPE"] = "en_US.UTF-8"
      }
    }

    return environment
  }

  private static func isMissing(_ name: String, in environment: [String: String]) -> Bool {
    environment[name]?.isEmpty ?? true
  }

  private static func mergedPath(_ values: [String?]) -> String? {
    var seen = Set<String>()
    var entries: [String] = []
    for value in values.compactMap({ $0 }) {
      for rawEntry in value.split(separator: ":") {
        let entry = rawEntry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty, seen.insert(entry).inserted else { continue }
        entries.append(entry)
      }
    }
    return entries.isEmpty ? nil : entries.joined(separator: ":")
  }

  // MARK: - Telemetry

  /// Sends `cli_not_found` when Claude or Codex is missing even after a fresh shell read.
  func reportCLINotFound(_ cli: String) {
    var properties = Self.analyticsProperties(current())
    properties["cli"] = cli
    AnalyticsService.shared.capture("cli_not_found", properties)
  }

  /// Logs every read, but only sends analytics when the read failed.
  private static func report(_ snapshot: Snapshot, trigger: String) {
    print(
      "[ShellEnvironment] Read \(snapshot.shellPath) (\(trigger)): \(snapshot.outcome.rawValue) "
        + "in \(snapshot.durationMs)ms, PATH from \(snapshot.pathSource)")

    guard !snapshot.usesCapturedEnvironment else { return }
    var properties = analyticsProperties(snapshot)
    properties["trigger"] = trigger
    AnalyticsService.shared.capture("shell_environment_read_failed", properties)
  }

  private static func analyticsProperties(_ snapshot: Snapshot) -> [String: Any] {
    let pathEntryCount = (snapshot.launchEnvironment["PATH"] ?? "")
      .split(separator: ":").count
    return [
      "outcome": snapshot.outcome.rawValue,
      "duration_ms": snapshot.durationMs,
      "login_shell": URL(fileURLWithPath: snapshot.shellPath).lastPathComponent,
      "exit_code": Int(snapshot.exitCode ?? -1),
      "path_source": snapshot.pathSource,
      "path_entry_count": pathEntryCount,
      "found_names": diagnosticNames.filter { snapshot.shellValues[$0] != nil }
        .joined(separator: ","),
      "shell_variable_count": snapshot.shellValues.count,
      "extra_output": extraOutputKind(snapshot.extraOutput),
      "launch_mode": snapshot.usesCapturedEnvironment
        ? "captured_environment" : "login_shell_fallback",
    ]
  }

  /// Names the kind of shell noise without sending the text, which can hold host names.
  private static func extraOutputKind(_ text: String) -> String {
    if text.isEmpty { return "none" }
    if text.contains("]1337;") { return "iterm2" }
    return "other"
  }

  /// Makes escape codes readable in the debug log, e.g. ESC becomes \x1B.
  private static func visible(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      if scalar.value < 0x20 && scalar != "\n" && scalar != "\t" {
        result += String(format: "\\x%02X", scalar.value)
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
