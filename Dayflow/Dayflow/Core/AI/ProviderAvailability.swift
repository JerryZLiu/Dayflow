//
//  ProviderAvailability.swift
//  Dayflow
//
//  Keeps batches away from a provider that is known to be down, and from the network while the
//  Mac is offline or asleep. A batch that is kept back is waiting, not failed: it is retried on
//  its own once the provider, the network or the Mac is back.
//

import AppKit
import Foundation
import Network

// MARK: - Waiting batches

enum BatchWaitReason: String {
  /// The provider's account or setup is broken, so the batch was not sent.
  case providerDown = "provider_down"
  /// The Mac has no internet connection.
  case offline
  /// The Mac went to sleep or lost its connection while the batch was being worked on.
  case interrupted
}

/// Thrown instead of a provider's error when a batch is waiting rather than failed.
struct BatchHeldError: LocalizedError {
  let reason: BatchWaitReason
  /// What is wrong with the provider, for `.providerDown`.
  let providerFailureKind: TimelineFailureKind?
  let providerLabel: String
  /// The provider the original error named ("AWS" for an expired Bedrock session), when it
  /// isn't simply the configured one.
  var providerName: String? = nil

  var errorDescription: String? {
    switch reason {
    case .providerDown:
      let kind = providerFailureKind?.rawValue ?? "unknown"
      return "Waiting: \(providerLabel) is not working (\(kind)), so this batch was not sent."
    case .offline:
      return "Waiting: this Mac is offline, so this batch was not sent."
    case .interrupted:
      return "Waiting: this Mac went to sleep or lost its connection while the batch was running."
    }
  }

  /// Shown as the timeline card's title.
  func cardTitle(providerDisplayName: String) -> String {
    switch reason {
    case .providerDown: return "Waiting for \(providerDisplayName)"
    case .offline: return "Waiting for internet"
    case .interrupted: return "Waiting to retry"
    }
  }

  /// Shown under the title for `.offline` and `.interrupted`. A provider that is down uses the
  /// failure classifier's sentence instead, which says how to fix it.
  var cardSummary: String {
    switch reason {
    case .providerDown:
      return "Recorded and saved. Cards appear here as soon as the problem is fixed."
    case .offline:
      return
        "Recorded and saved. This Mac was offline, so Dayflow will make these cards when the internet is back."
    case .interrupted:
      return
        "Recorded and saved. This Mac went to sleep or lost its connection while Dayflow was working on this, so it will try again shortly."
    }
  }
}

// MARK: - Provider holds

enum ProviderHealth: String {
  case ok
  case broken
  case unknown
}

/// Remembers which providers failed with an account or setup problem, so later batches are not
/// sent to them until the problem looks fixed or enough time has passed. Kept in memory only: a
/// relaunch starts fresh.
final class ProviderHoldStore: @unchecked Sendable {
  struct Hold {
    let kind: TimelineFailureKind
    let since: Date
    var failedAttempts: Int
    /// When the next real request to the provider is allowed, whatever the health check says.
    var nextAttemptAt: Date
    /// What the quick health check said when the provider failed. Only a check that could see
    /// the problem then can be trusted to see it fixed later.
    var healthWhenHeld: ProviderHealth
    /// The provider's setup when it failed. A change means the user did something about it.
    let setupSignature: String
    /// The provider the error itself named, e.g. "AWS" when Claude runs through Bedrock.
    let providerName: String?
  }

  static let shared = ProviderHoldStore()

  private static let retryDelays: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]

  private let lock = NSLock()
  private var holds: [LLMProviderID: Hold] = [:]

  func hold(for provider: LLMProviderID) -> Hold? {
    lock.lock()
    defer { lock.unlock() }
    return holds[provider]
  }

  var hasHolds: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !holds.isEmpty
  }

  /// Starts a hold, or pushes the next attempt further out when the provider failed again.
  /// Returns true when the hold is new.
  @discardableResult
  func recordFailure(
    provider: LLMProviderID,
    kind: TimelineFailureKind,
    health: ProviderHealth,
    setupSignature: String,
    providerName: String? = nil,
    now: Date = Date()
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let previous = holds[provider]
    let failedAttempts = (previous?.failedAttempts ?? 0) + 1
    let delay = Self.retryDelays[min(failedAttempts, Self.retryDelays.count) - 1]
    holds[provider] = Hold(
      kind: kind,
      since: previous?.since ?? now,
      failedAttempts: failedAttempts,
      nextAttemptAt: now.addingTimeInterval(delay),
      healthWhenHeld: health,
      setupSignature: setupSignature,
      providerName: providerName
    )
    return previous == nil
  }

  /// Returns true when there was a hold to lift.
  @discardableResult
  func clear(_ provider: LLMProviderID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return holds.removeValue(forKey: provider) != nil
  }

  /// Returns true when there was any hold to lift.
  @discardableResult
  func clearAll() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let hadHolds = !holds.isEmpty
    holds.removeAll()
    return hadHolds
  }

  /// Lets the next batch try every held provider for real, e.g. after the user comes back to
  /// Dayflow and may have fixed the problem somewhere else.
  func allowNextAttemptNow(now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    for provider in holds.keys {
      holds[provider]?.nextAttemptAt = now
    }
  }

  /// True when a batch should be sent to `provider` for real: there is no hold, the user
  /// changed the provider's setup, the wait is over, or the health check that saw the problem
  /// now sees it fixed.
  func isReadyForAttempt(
    _ provider: LLMProviderID, setupSignature: String, now: Date = Date()
  ) async -> Bool {
    guard let hold = hold(for: provider) else { return true }
    if hold.setupSignature != setupSignature {
      clear(provider)
      return true
    }
    if now >= hold.nextAttemptAt { return true }
    guard hold.healthWhenHeld == .broken else { return false }
    return await ProviderHealthCheck.check(provider, failureKind: hold.kind) == .ok
  }
}

// MARK: - Quick health checks

/// Cheap checks that answer "is the thing that broke still broken?" without sending a batch.
/// Only sign-in, a missing command-line tool and a closed local model app can be checked this
/// way; everything else is `.unknown` and waits out the hold instead.
enum ProviderHealthCheck {
  static func check(_ provider: LLMProviderID, failureKind: TimelineFailureKind) async
    -> ProviderHealth
  {
    switch failureKind {
    case .providerLoginExpired:
      return await runOffMainThread { signInHealth(provider) }
    case .cliNotInstalled:
      return await runOffMainThread { installHealth(provider) }
    case .localEngineOffline:
      guard provider == .local else { return .unknown }
      return await localEngineHealth()
    default:
      return .unknown
    }
  }

  /// Whether the provider's command-line tool says it is signed in. nil when it can't tell.
  /// Blocks while the tool runs, so call it off the main thread.
  static func isSignedIn(_ provider: LLMProviderID) -> Bool? {
    switch signInHealth(provider) {
    case .ok: return true
    case .broken: return false
    case .unknown: return nil
    }
  }

  /// True when the provider's command-line tool is installed and signed in.
  static func isReadyToUse(_ provider: LLMProviderID) async -> Bool {
    await runOffMainThread {
      guard installHealth(provider) == .ok else { return .broken }
      return signInHealth(provider)
    } == .ok
  }

  private static func runOffMainThread(_ work: @escaping @Sendable () -> ProviderHealth) async
    -> ProviderHealth
  {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: work())
      }
    }
  }

  private static func signInHealth(_ provider: LLMProviderID) -> ProviderHealth {
    switch provider {
    case .claude:
      // Prints JSON such as {"loggedIn": true, ...}. Anything else (an old version without
      // this command, a timeout) says nothing either way.
      let result = LoginShellRunner.run("claude auth status", timeout: 15)
      guard
        let data = result.stdout.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let loggedIn = json["loggedIn"] as? Bool
      else { return .unknown }
      return loggedIn ? .ok : .broken

    case .chatGPT:
      guard let executable = CodexExecutableResolver.shared.resolve()?.executableURL else {
        return .unknown
      }
      let command = "\(LoginShellRunner.shellEscape(executable.path)) login status"
      let result = LoginShellRunner.run(command, timeout: 15)
      let output = (result.stdout + "\n" + result.stderr).lowercased()
      if output.contains("not logged in") { return .broken }
      if result.exitCode == 0, output.contains("logged in") { return .ok }
      return .unknown

    default:
      return .unknown
    }
  }

  private static func installHealth(_ provider: LLMProviderID) -> ProviderHealth {
    switch provider {
    case .claude:
      ShellEnvironment.shared.refreshIfOlder(than: 60, trigger: "provider_health_check")
      return ShellEnvironment.shared.executablePath(named: "claude") == nil ? .broken : .ok
    case .chatGPT:
      return CodexExecutableResolver.shared.resolve() == nil ? .broken : .ok
    default:
      return .unknown
    }
  }

  private static func localEngineHealth() async -> ProviderHealth {
    let saved =
      UserDefaults.standard.string(forKey: "llmLocalBaseURL")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let url = URL(string: saved.isEmpty ? "http://localhost:11434" : saved) else {
      return .unknown
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    do {
      // Any answer at all, even an error page, means the app is open.
      _ = try await URLSession.shared.data(for: request)
      return .ok
    } catch {
      let nsError = error as NSError
      let refused =
        nsError.domain == NSURLErrorDomain
        && [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost].contains(nsError.code)
      return refused ? .broken : .unknown
    }
  }
}

// MARK: - Network and sleep

/// Watches the internet connection and the Mac's sleep and wake, so batches wait instead of
/// failing while there is no way to reach a provider.
final class ConnectivityMonitor: @unchecked Sendable {
  static let shared = ConnectivityMonitor()

  private let lock = NSLock()
  private let pathMonitor = NWPathMonitor()
  private let monitorQueue = DispatchQueue(label: "com.dayflow.connectivityMonitor")
  private var isStarted = false
  private var online = true
  private var lastSleepAt: Date?
  private var lastWakeAt: Date?
  private var observers: [NSObjectProtocol] = []

  /// True unless macOS says there is no usable network. Stays true until the first report.
  var isOnline: Bool {
    lock.lock()
    defer { lock.unlock() }
    return online
  }

  /// True when the Mac went to sleep or woke up at or after `date`.
  func wasAsleep(since date: Date) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if let lastSleepAt, lastSleepAt >= date { return true }
    if let lastWakeAt, lastWakeAt >= date { return true }
    return false
  }

  /// Starts watching; later calls do nothing.
  /// - Parameters:
  ///   - onWillSleep: called as the Mac is about to sleep.
  ///   - onResume: called a few seconds after the Mac wakes ("wake") or the internet comes
  ///     back ("online"), when waiting batches are worth retrying.
  func start(
    onWillSleep: @escaping @Sendable () -> Void,
    onResume: @escaping @Sendable (_ reason: String) -> Void
  ) {
    lock.lock()
    guard !isStarted else {
      lock.unlock()
      return
    }
    isStarted = true
    lock.unlock()

    pathMonitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let isNowOnline = path.status == .satisfied
      self.lock.lock()
      let wasOnline = self.online
      self.online = isNowOnline
      self.lock.unlock()

      guard isNowOnline, !wasOnline else { return }
      // Give Wi-Fi a moment to settle, and skip the retry if it dropped again meanwhile.
      self.monitorQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard let self, self.isOnline else { return }
        onResume("online")
      }
    }
    pathMonitor.start(queue: monitorQueue)

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    let sleepObserver = workspaceCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.setLastSleep(Date())
      onWillSleep()
    }
    let wakeObserver = workspaceCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      self.setLastWake(Date())
      // The network takes a few seconds to come back after a wake. Retry even if it isn't
      // back: a local model doesn't need it, and other batches just keep waiting.
      self.monitorQueue.asyncAfter(deadline: .now() + 10) {
        onResume("wake")
      }
    }

    lock.lock()
    observers = [sleepObserver, wakeObserver]
    lock.unlock()
  }

  private func setLastSleep(_ date: Date) {
    lock.lock()
    lastSleepAt = date
    lock.unlock()
  }

  private func setLastWake(_ date: Date) {
    lock.lock()
    lastWakeAt = date
    lock.unlock()
  }
}
