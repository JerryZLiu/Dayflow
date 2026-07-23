import Foundation

enum RecorderRecoveryPolicy {
  static func canCommitSetup(
    setupGeneration: Int,
    currentGeneration: Int,
    isStarting: Bool
  ) -> Bool {
    isStarting && setupGeneration == currentGeneration
  }

  static func retryDelay(forNoDisplayAttempt attempt: Int, maxAttempts: Int) -> TimeInterval? {
    guard attempt > 0, attempt < maxAttempts else { return nil }
    return pow(2, Double(attempt - 1))
  }

  static func shouldRestartAfterWake(
    isCapturing: Bool,
    hasDisplay: Bool,
    lastSuccessfulCaptureAt: Date?,
    now: Date,
    staleAfter: TimeInterval
  ) -> Bool {
    guard isCapturing, hasDisplay, let lastSuccessfulCaptureAt else { return true }
    return now.timeIntervalSince(lastSuccessfulCaptureAt) > staleAfter
  }
}
