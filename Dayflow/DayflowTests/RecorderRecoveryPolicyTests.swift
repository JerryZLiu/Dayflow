import XCTest

@testable import Dayflow

final class RecorderRecoveryPolicyTests: XCTestCase {
  func testOldSetupCompletionCannotCommitAfterSleepAndNewStart() {
    let oldSetupGeneration = 1
    let generationAfterSleep = 2
    let newSetupGeneration = 3

    XCTAssertFalse(
      RecorderRecoveryPolicy.canCommitSetup(
        setupGeneration: oldSetupGeneration,
        currentGeneration: generationAfterSleep,
        isStarting: false
      )
    )
    XCTAssertFalse(
      RecorderRecoveryPolicy.canCommitSetup(
        setupGeneration: oldSetupGeneration,
        currentGeneration: newSetupGeneration,
        isStarting: true
      )
    )
    XCTAssertTrue(
      RecorderRecoveryPolicy.canCommitSetup(
        setupGeneration: newSetupGeneration,
        currentGeneration: newSetupGeneration,
        isStarting: true
      )
    )
  }

  func testMissingDisplayRestartsRecorderEvenWhenStateClaimsCapturing() {
    XCTAssertTrue(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: true,
        hasDisplay: false,
        lastSuccessfulCaptureAt: Date(),
        now: Date(),
        staleAfter: 30
      )
    )
  }

  func testStaleCaptureRestartsRecorderAfterWake() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertTrue(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: true,
        hasDisplay: true,
        lastSuccessfulCaptureAt: now.addingTimeInterval(-31),
        now: now,
        staleAfter: 30
      )
    )
  }

  func testNonCapturingRecorderRestartsAfterWake() {
    XCTAssertTrue(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: false,
        hasDisplay: true,
        lastSuccessfulCaptureAt: Date(),
        now: Date(),
        staleAfter: 30
      )
    )
  }

  func testMissingSuccessfulCaptureRestartsRecorderAfterWake() {
    XCTAssertTrue(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: true,
        hasDisplay: true,
        lastSuccessfulCaptureAt: nil,
        now: Date(),
        staleAfter: 30
      )
    )
  }

  func testRecentCaptureWithDisplayDoesNotRestartRecorder() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertFalse(
      RecorderRecoveryPolicy.shouldRestartAfterWake(
        isCapturing: true,
        hasDisplay: true,
        lastSuccessfulCaptureAt: now.addingTimeInterval(-29),
        now: now,
        staleAfter: 30
      )
    )
  }

  func testDisplayRetriesUseBoundedExponentialBackoff() {
    XCTAssertEqual(RecorderRecoveryPolicy.retryDelay(forNoDisplayAttempt: 1, maxAttempts: 4), 1)
    XCTAssertEqual(RecorderRecoveryPolicy.retryDelay(forNoDisplayAttempt: 2, maxAttempts: 4), 2)
    XCTAssertEqual(RecorderRecoveryPolicy.retryDelay(forNoDisplayAttempt: 3, maxAttempts: 4), 4)
    XCTAssertNil(RecorderRecoveryPolicy.retryDelay(forNoDisplayAttempt: 4, maxAttempts: 4))
  }
}
