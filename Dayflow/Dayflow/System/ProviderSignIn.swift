//
//  ProviderSignIn.swift
//  Dayflow
//
//  Signs the user back in to Claude or ChatGPT from inside Dayflow. It runs the tool's own
//  login command in the background, which opens the browser, then checks that the sign-in
//  worked and retries the batches that were waiting.
//

import Foundation

@MainActor
final class ProviderSignIn: ObservableObject {
  enum State: Equatable {
    case idle
    case waiting(LLMProviderID)
    case failed(LLMProviderID)
  }

  static let shared = ProviderSignIn()

  @Published private(set) var state: State = .idle

  private var process: Process?
  private var input: Pipe?
  private var watchTask: Task<Void, Never>?

  private static let timeout: TimeInterval = 10 * 60
  private static let checkInterval: Duration = .seconds(3)

  nonisolated static func displayName(for provider: LLMProviderID) -> String {
    provider == .claude ? "Claude" : "ChatGPT"
  }

  /// Opens the browser sign-in for `provider`. Calling it again restarts the sign-in, which is
  /// what "Browser didn't open? Try again" does.
  func start(_ provider: LLMProviderID, source: String) {
    guard let command = Self.loginCommand(for: provider) else {
      state = .failed(provider)
      return
    }
    stopProcess()

    let process = ShellEnvironment.shared.makeProcess(command: command)
    // The tool only needs to open the browser and wait. An open, silent input keeps it from
    // quitting early because it thinks the terminal went away.
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    AnalyticsService.shared.capture(
      "provider_sign_in_started", ["provider_id": provider.rawValue, "source": source])

    do {
      try process.run()
    } catch {
      finish(provider, succeeded: false, reason: "launch_failed")
      return
    }

    self.process = process
    self.input = input
    state = .waiting(provider)
    watchTask = Task { [weak self] in
      await self?.watch(process, provider: provider)
    }
  }

  func cancel() {
    stopProcess()
    state = .idle
  }

  /// Waits until the tool reports it is signed in, the login command ends, or time runs out.
  private func watch(_ process: Process, provider: LLMProviderID) async {
    let deadline = Date().addingTimeInterval(Self.timeout)
    // A login that can no longer be refreshed still reads as signed in, so in that case only
    // the login command finishing cleanly counts as done.
    let lookedSignedInBefore = await Self.isSignedIn(provider) == true

    while !Task.isCancelled, Date() < deadline {
      try? await Task.sleep(for: Self.checkInterval)
      if Task.isCancelled { return }

      let processEnded = !process.isRunning
      let signedIn = await Self.isSignedIn(provider)
      if Task.isCancelled { return }

      if signedIn == true, !lookedSignedInBefore {
        finish(provider, succeeded: true, reason: "signed_in")
        return
      }
      if processEnded {
        // A tool too old to report its sign-in state is trusted on its exit code.
        let succeeded = signedIn != false && process.terminationStatus == 0
        finish(provider, succeeded: succeeded, reason: succeeded ? "command_ok" : "command_ended")
        return
      }
    }

    if !Task.isCancelled {
      finish(provider, succeeded: false, reason: "timed_out")
    }
  }

  private func finish(_ provider: LLMProviderID, succeeded: Bool, reason: String) {
    watchTask = nil
    endProcess()

    AnalyticsService.shared.capture(
      "provider_sign_in_finished",
      ["provider_id": provider.rawValue, "succeeded": succeeded, "reason": reason])

    guard succeeded else {
      state = .failed(provider)
      return
    }

    state = .idle
    ProviderHoldStore.shared.clear(provider)
    ProviderProblemCenter.shared.resolve()
    AnalysisManager.shared.catchUpFailedBatches(reason: "signed_in")
  }

  private func stopProcess() {
    watchTask?.cancel()
    watchTask = nil
    endProcess()
  }

  private func endProcess() {
    try? input?.fileHandleForWriting.close()
    input = nil
    if let process, process.isRunning { process.terminate() }
    process = nil
  }

  /// Forgets a failed attempt, so the next problem's card starts with its Sign in button.
  func clearFailure() {
    if case .failed = state { state = .idle }
  }

  private static func isSignedIn(_ provider: LLMProviderID) async -> Bool? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: ProviderHealthCheck.isSignedIn(provider))
      }
    }
  }

  private static func loginCommand(for provider: LLMProviderID) -> String? {
    switch provider {
    case .claude:
      // `exec` so stopping the process stops the tool itself, not just the shell around it.
      return "exec claude auth login"
    case .chatGPT:
      guard let executable = CodexExecutableResolver.shared.resolve()?.executableURL else {
        return nil
      }
      return "exec \(LoginShellRunner.shellEscape(executable.path)) login"
    default:
      return nil
    }
  }
}
