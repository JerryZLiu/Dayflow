//
//  LLMProviderSetupView.swift
//  Dayflow
//
//  LLM provider setup flow with step-by-step configuration
//

import AppKit
import Foundation
import SwiftUI

struct CLIResult {
  let stdout: String
  let stderr: String
  let exitCode: Int32
}

/// Run a CLI command via login shell.
/// This replicates Terminal.app behavior - if user can run it in Terminal, it works here.
@discardableResult
func runCLI(
  _ command: String,
  args: [String] = [],
  env: [String: String]? = nil,
  cwd: URL? = nil
) throws -> CLIResult {
  // Build the full command with args
  let cmdParts = [command] + args.map { LoginShellRunner.shellEscape($0) }
  var fullCommand = cmdParts.joined(separator: " ")

  // Add environment variable exports if provided
  if let env = env, !env.isEmpty {
    let envExports = env.map { key, value in
      "\(key)=\(LoginShellRunner.shellEscape(value))"
    }.joined(separator: " ")
    fullCommand = "\(envExports) \(fullCommand)"
  }

  // Add cd if working directory specified
  if let cwd = cwd {
    fullCommand = "cd \(LoginShellRunner.shellEscape(cwd.path)) && \(fullCommand)"
  }

  let result = LoginShellRunner.run(fullCommand, timeout: 60)
  return CLIResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
}

/// Streaming CLI runner that uses login shell for Terminal.app-like behavior.
final class StreamingCLI {
  var process: Process?
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()

  func cancel() {
    process?.terminate()
  }

  /// Run a command via login shell with streaming output.
  /// - Parameters:
  ///   - command: The command name (e.g., "codex", "claude") - no path needed
  ///   - args: Arguments to pass to the command
  ///   - env: Optional environment variable overrides
  ///   - cwd: Optional working directory
  ///   - onStdout: Callback for stdout chunks
  ///   - onStderr: Callback for stderr chunks
  ///   - onFinish: Callback when process exits with exit code
  func run(
    command: String,
    args: [String],
    env: [String: String]? = nil,
    cwd: URL? = nil,
    onStdout: @escaping (String) -> Void,
    onStderr: @escaping (String) -> Void,
    onFinish: @escaping (Int32) -> Void
  ) {
    let proc = Process()
    process = proc

    // Build shell command from command + args
    let cmdParts = [command] + args.map { LoginShellRunner.shellEscape($0) }
    var shellCommand = cmdParts.joined(separator: " ")

    // Add environment exports if provided
    if let env = env, !env.isEmpty {
      let envExports = env.map { key, value in
        "\(key)=\(LoginShellRunner.shellEscape(value))"
      }.joined(separator: " ")
      shellCommand = "\(envExports) \(shellCommand)"
    }

    // Add cd if working directory specified
    if let cwd = cwd {
      shellCommand = "cd \(LoginShellRunner.shellEscape(cwd.path)) && \(shellCommand)"
    }

    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    // -l = login shell (sources .zprofile), -i = interactive (sources .zshrc)
    // Both are needed because PATH setup can be in either file
    proc.arguments = ["-l", "-i", "-c", shellCommand]
    proc.standardInput = FileHandle.nullDevice

    proc.standardOutput = stdoutPipe
    proc.standardError = stderrPipe

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      DispatchQueue.main.async {
        onStdout(chunk)
      }
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      DispatchQueue.main.async {
        onStderr(chunk)
      }
    }

    do {
      try proc.run()
      proc.terminationHandler = { process in
        self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        self.stderrPipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async {
          onFinish(process.terminationStatus)
        }
      }
    } catch {
      DispatchQueue.main.async {
        onStderr("Failed to start \(command): \(error.localizedDescription)")
        onFinish(-1)
      }
    }
  }
}
