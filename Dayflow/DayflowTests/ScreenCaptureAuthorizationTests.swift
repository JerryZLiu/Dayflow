import XCTest
@testable import Dayflow

final class ScreenCaptureAuthorizationTests: XCTestCase {
  func testFirstUseDenialUsesOnboardingPath() {
    var model = ScreenCaptureAuthorizationModel(wasGranted: false)

    model.observePreflight(granted: false)

    XCTAssertEqual(model.state, .needsUserReview)
    XCTAssertTrue(model.shouldRequestPermissionDuringOnboarding)
  }

  func testKnownGrantFalsePreflightBecomesTemporary() {
    var model = ScreenCaptureAuthorizationModel(wasGranted: true)

    model.observePreflight(granted: false)

    XCTAssertEqual(model.state, .temporarilyUnavailable)
    XCTAssertFalse(model.shouldRequestPermissionDuringOnboarding)
  }

  func testUserDeclinedErrorWithGrantedPreflightStaysTemporary() {
    var model = ScreenCaptureAuthorizationModel(wasGranted: true)

    model.observeCaptureFailure(.userDeclined, preflightGranted: true)

    XCTAssertEqual(model.state, .temporarilyUnavailable)
  }

  func testThreeFailedChecksEnterNeedsUserReview() {
    var model = ScreenCaptureAuthorizationModel(wasGranted: true)

    model.observeConfirmationPreflight(granted: false)
    model.observeConfirmationPreflight(granted: false)
    model.observeConfirmationPreflight(granted: false)

    XCTAssertEqual(model.state, .needsUserReview)
  }

  func testSuccessfulConfirmationRestoresGrantedState() {
    var model = ScreenCaptureAuthorizationModel(wasGranted: true)
    model.observePreflight(granted: false)

    model.observeConfirmationPreflight(granted: true)

    XCTAssertEqual(model.state, .granted)
  }

  func testBackgroundConfirmationDoesNotRequestPermission() async {
    let access = ScreenCaptureAccessSpy(preflightResults: [false, false, false])
    let clock = ScreenCaptureConfirmationClockSpy()
    let coordinator = ScreenCaptureAuthorizationCoordinator(
      wasGranted: true,
      access: access,
      sleep: { delay in await clock.sleep(for: delay) }
    )

    await coordinator.confirmWithoutPrompting()

    XCTAssertEqual(access.preflightCallCount, 3)
    XCTAssertEqual(access.requestCallCount, 0)
    let delays = await clock.delays
    let state = await coordinator.state
    XCTAssertEqual(delays, [0, 10, 20])
    XCTAssertEqual(state, .needsUserReview)
  }

  func testExplicitReviewCanRequestPermission() {
    let access = ScreenCaptureAccessSpy(
      preflightResults: [false],
      requestResult: true
    )

    let granted = ScreenCapturePermissionReview.requestAfterUserAction(access: access)

    XCTAssertTrue(granted)
    XCTAssertEqual(access.preflightCallCount, 1)
    XCTAssertEqual(access.requestCallCount, 1)
  }

  func testPermissionHistoryPersistsFirstSuccess() throws {
    let suite = "ScreenCaptureAuthorizationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = ScreenCapturePermissionHistory(defaults: defaults)

    history.markGranted()

    XCTAssertTrue(defaults.bool(forKey: ScreenCapturePermissionHistory.grantedKey))
  }

  func testCompletedOnboardingSeedsPermissionHistory() throws {
    let suite = "ScreenCaptureAuthorizationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let history = ScreenCapturePermissionHistory(defaults: defaults, didCompleteOnboarding: true)

    XCTAssertTrue(history.wasGranted)
  }
}

private final class ScreenCaptureAccessSpy: ScreenCaptureAuthorizationAccess, @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Bool]
  private let requestResult: Bool
  private(set) var preflightCallCount = 0
  private(set) var requestCallCount = 0

  init(preflightResults: [Bool], requestResult: Bool = false) {
    results = preflightResults
    self.requestResult = requestResult
  }

  func preflight() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    preflightCallCount += 1
    return results.isEmpty ? false : results.removeFirst()
  }

  func request() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    requestCallCount += 1
    return requestResult
  }
}

private actor ScreenCaptureConfirmationClockSpy {
  private(set) var delays: [TimeInterval] = []

  func sleep(for delay: TimeInterval) async {
    delays.append(delay)
  }
}
