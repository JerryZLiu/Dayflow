//
//  ClaudeInstaller.swift
//  Dayflow
//
//  Installs Claude Code for the user during onboarding, so they don't have to leave for
//  Terminal. It runs Anthropic's own installer script, the same one their docs tell people to
//  paste into Terminal, which puts `claude` in ~/.local/bin without needing an admin password.
//

import Foundation

@MainActor
final class ClaudeInstaller: ObservableObject {
  enum State: Equatable {
    case idle
    case installing
    case installed
    case failed
  }

  static let shared = ClaudeInstaller()

  @Published private(set) var state: State = .idle

  private static let scriptURL = URL(string: "https://claude.ai/install.sh")!
  /// The script downloads a ~100 MB binary, which can take a while on a slow connection.
  private static let timeout: TimeInterval = 10 * 60

  private init() {}

  func install(source: String) {
    guard state != .installing else { return }
    state = .installing
    let startedAt = Date()
    AnalyticsService.shared.capture("claude_install_started", ["source": source])

    Task {
      let result = await Self.runInstaller()

      var properties: [String: Any] = [
        "source": source,
        "succeeded": result.succeeded,
        "duration_s": Int(Date().timeIntervalSince(startedAt)),
      ]
      if let reason = result.reason { properties["reason"] = reason }
      AnalyticsService.shared.capture("claude_install_finished", properties)

      state = result.succeeded ? .installed : .failed
    }
  }

  func reset() {
    if state != .installing { state = .idle }
  }

  private struct Result {
    let succeeded: Bool
    let reason: String?
  }

  private nonisolated static func runInstaller() async -> Result {
    let script: Data
    do {
      let (data, response) = try await URLSession.shared.data(from: scriptURL)
      guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
        return Result(succeeded: false, reason: "script_download_failed")
      }
      script = data
    } catch {
      return Result(succeeded: false, reason: "script_download_failed")
    }

    let scriptFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-claude-install-\(UUID().uuidString).sh")
    do {
      try script.write(to: scriptFile)
    } catch {
      return Result(succeeded: false, reason: "script_write_failed")
    }
    defer { try? FileManager.default.removeItem(at: scriptFile) }

    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = ShellEnvironment.shared.makeProcess(
          command: "/bin/bash \(LoginShellRunner.shellEscape(scriptFile.path))")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
          try process.run()
        } catch {
          continuation.resume(returning: Result(succeeded: false, reason: "launch_failed"))
          return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
          Thread.sleep(forTimeInterval: 0.5)
        }
        if process.isRunning {
          process.terminate()
          continuation.resume(returning: Result(succeeded: false, reason: "timed_out"))
          return
        }

        // Pick up ~/.local/bin and the new binary before anything checks for Claude again.
        // Reading the shell can take a few seconds, so it happens here, off the main thread.
        _ = ShellEnvironment.shared.refresh(trigger: "claude_install")

        let binary = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".local/bin/claude").path
        if process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: binary) {
          continuation.resume(returning: Result(succeeded: true, reason: nil))
        } else {
          continuation.resume(
            returning: Result(
              succeeded: false, reason: "exit_\(process.terminationStatus)"))
        }
      }
    }
  }
}
