import AppKit
import Darwin
import Foundation

// MARK: - Login Shell Runner

struct LoginShellResult {
  let stdout: String
  let stderr: String
  let exitCode: Int32
}

/// Invokes commands via the user's login shell to replicate Terminal.app behavior.
/// This ensures CLIs installed via nvm, homebrew, cargo, etc. are found.
struct LoginShellRunner {

  /// Detects the user's configured login shell (e.g., /bin/bash or /bin/zsh)
  static var userLoginShell: URL {
    if let entry = getpwuid(getuid()),
      let shellPath = String(validatingUTF8: entry.pointee.pw_shell)
    {
      return URL(fileURLWithPath: shellPath)
    }
    return URL(fileURLWithPath: "/bin/zsh")
  }

  /// Get names of all MCP servers configured in Codex CLI.
  /// Used to generate `--config mcp_servers.<name>.enabled=false` flags.
  static func getCodexMCPServerNames() -> [String] {
    let result = run("codex mcp list --json", timeout: 10)
    guard result.exitCode == 0,
      let data = result.stdout.data(using: .utf8)
    else {
      return []
    }

    struct MCPServer: Codable {
      let name: String
    }

    guard let servers = try? JSONDecoder().decode([MCPServer].self, from: data) else {
      return []
    }

    return servers.map { $0.name }
  }

  /// Run a command via login shell and wait for completion.
  static func run(
    _ command: String,
    environment: [String: String] = [:],
    timeout: TimeInterval = 30
  ) -> LoginShellResult {
    let envExports = environment.map { key, value in
      "\(key)=\(shellEscape(value))"
    }.joined(separator: " ")

    let fullCommand = envExports.isEmpty ? command : "\(envExports) \(command)"

    let process = Process()
    process.executableURL = userLoginShell
    process.arguments = ["-l", "-i", "-c", fullCommand]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return LoginShellResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
    }

    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      process.waitUntilExit()
      semaphore.signal()
    }

    let result = semaphore.wait(timeout: .now() + timeout)
    if result == .timedOut {
      process.terminate()
      return LoginShellResult(
        stdout: "", stderr: "Command timed out after \(Int(timeout))s", exitCode: -2)
    }

    let stdout =
      String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr =
      String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    return LoginShellResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
  }

  /// Check if a CLI tool is installed by running `tool --version`
  static func isInstalled(_ toolName: String) -> Bool {
    let result = run("\(toolName) --version", timeout: 10)
    return result.exitCode == 0
  }

  /// Get version string of a CLI tool, or nil if not installed
  static func version(of toolName: String) -> String? {
    let result = run("\(toolName) --version", timeout: 10)
    guard result.exitCode == 0 else { return nil }
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.components(separatedBy: .newlines).first ?? trimmed
  }

  /// Escape a string for safe inclusion in a shell command (single-quote escaping)
  static func shellEscape(_ string: String) -> String {
    let sanitized = string.replacingOccurrences(of: "\0", with: "")
    let escaped = sanitized.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
  }
}
