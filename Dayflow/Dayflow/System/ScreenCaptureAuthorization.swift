import CoreGraphics
import Foundation

enum ScreenCaptureAuthorizationState: Equatable, Sendable {
  case unknown
  case granted
  case temporarilyUnavailable
  case needsUserReview
}

enum ScreenCapturePermissionFailure: Equatable, Sendable {
  case userDeclined
  case screenCaptureKit(domain: String, code: Int)
}

struct ScreenCaptureAuthorizationModel: Equatable, Sendable {
  private(set) var state: ScreenCaptureAuthorizationState
  private(set) var wasGranted: Bool
  private var failedConfirmationCount = 0

  init(wasGranted: Bool) {
    self.wasGranted = wasGranted
    state = wasGranted ? .granted : .unknown
  }

  var shouldRequestPermissionDuringOnboarding: Bool {
    !wasGranted && state == .needsUserReview
  }

  mutating func observePreflight(granted: Bool) {
    guard granted else {
      state = wasGranted ? .temporarilyUnavailable : .needsUserReview
      return
    }

    markGranted()
  }

  mutating func observeCaptureFailure(
    _ failure: ScreenCapturePermissionFailure,
    preflightGranted: Bool
  ) {
    _ = failure
    _ = preflightGranted
    state = wasGranted ? .temporarilyUnavailable : .needsUserReview
    failedConfirmationCount = 0
  }

  mutating func observeConfirmationPreflight(granted: Bool) {
    guard granted else {
      failedConfirmationCount += 1
      state = failedConfirmationCount >= 3 ? .needsUserReview : .temporarilyUnavailable
      return
    }

    markGranted()
  }

  mutating func markGranted() {
    wasGranted = true
    failedConfirmationCount = 0
    state = .granted
  }
}

final class ScreenCapturePermissionHistory: @unchecked Sendable {
  static let grantedKey = "screenCapturePermissionWasGranted"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard, didCompleteOnboarding: Bool = false) {
    self.defaults = defaults
    if didCompleteOnboarding && defaults.object(forKey: Self.grantedKey) == nil {
      defaults.set(true, forKey: Self.grantedKey)
    }
  }

  var wasGranted: Bool {
    defaults.bool(forKey: Self.grantedKey)
  }

  func markGranted() {
    defaults.set(true, forKey: Self.grantedKey)
  }
}

protocol ScreenCaptureAuthorizationAccess: Sendable {
  func preflight() -> Bool
  func request() -> Bool
}

struct SystemScreenCaptureAuthorizationAccess: ScreenCaptureAuthorizationAccess {
  func preflight() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  func request() -> Bool {
    CGRequestScreenCaptureAccess()
  }
}

actor ScreenCaptureAuthorizationCoordinator {
  typealias Sleep = @Sendable (TimeInterval) async -> Void

  private var model: ScreenCaptureAuthorizationModel
  private let access: ScreenCaptureAuthorizationAccess
  private let history: ScreenCapturePermissionHistory?
  private let sleep: Sleep
  private var confirmationTask: Task<Void, Never>?

  init(
    wasGranted: Bool,
    access: ScreenCaptureAuthorizationAccess = SystemScreenCaptureAuthorizationAccess(),
    history: ScreenCapturePermissionHistory? = nil,
    sleep: @escaping Sleep = { delay in
      guard delay > 0 else { return }
      try? await Task.sleep(for: .seconds(delay))
    }
  ) {
    model = ScreenCaptureAuthorizationModel(wasGranted: wasGranted)
    self.access = access
    self.history = history
    self.sleep = sleep
  }

  var state: ScreenCaptureAuthorizationState {
    model.state
  }

  func checkBeforeCapture() -> Bool {
    let granted = access.preflight()
    model.observePreflight(granted: granted)
    return granted
  }

  func recordCaptureSuccess() {
    model.markGranted()
    history?.markGranted()
    confirmationTask?.cancel()
    confirmationTask = nil
  }

  func recordCaptureFailure(_ error: NSError) {
    let failure: ScreenCapturePermissionFailure
    if error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", error.code == -3801 {
      failure = .userDeclined
    } else {
      failure = .screenCaptureKit(domain: error.domain, code: error.code)
    }
    model.observeCaptureFailure(failure, preflightGranted: access.preflight())
  }

  func preflightIsGranted() -> Bool {
    access.preflight()
  }

  func beginConfirmationIfNeeded() {
    guard confirmationTask == nil else { return }
    confirmationTask = Task { [weak self] in
      await self?.confirmWithoutPrompting()
      await self?.clearConfirmationTask()
    }
  }

  func confirmWithoutPrompting() async {
    for delay in [0.0, 10.0, 20.0] {
      guard !Task.isCancelled else { return }
      await sleep(delay)
      guard !Task.isCancelled else { return }
      let granted = access.preflight()
      model.observeConfirmationPreflight(granted: granted)
      if granted {
        history?.markGranted()
        return
      }
    }
  }

  func cancelConfirmation() {
    confirmationTask?.cancel()
    confirmationTask = nil
  }

  private func clearConfirmationTask() {
    confirmationTask = nil
  }
}
