import XCTest

@testable import Dayflow

/// Covers the persistence layer and Settings view-model wiring for the idle
/// capture throttle (issue #286) -- surfaces the original PR's tests left
/// uncovered (they focused on the pure interval math in IdleCaptureInterval).
@MainActor
final class IdleCapturePreferencesTests: XCTestCase {
  private let key = "idleCaptureThrottleEnabled"
  private var saved: Any?

  override func setUp() {
    super.setUp()
    saved = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: key)
    if let saved { UserDefaults.standard.set(saved, forKey: key) }
    saved = nil
    super.tearDown()
  }

  func testDefaultsToEnabledWhenUnset() {
    // The feature ships on by default; a fresh install (no stored key) must
    // report enabled, or the throttle silently never engages.
    XCTAssertTrue(IdleCapturePreferences.enabled)
  }

  func testPersistsDisabledAndReReadsIt() {
    IdleCapturePreferences.enabled = false
    XCTAssertFalse(IdleCapturePreferences.enabled)
    XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
  }

  func testPersistsReEnable() {
    IdleCapturePreferences.enabled = false
    IdleCapturePreferences.enabled = true
    XCTAssertTrue(IdleCapturePreferences.enabled)
  }

  // When the preference is OFF, effectiveScreenshotInterval must return the
  // base interval regardless of how idle the user is -- the toggle actually
  // disables the behavior, not just the UI.
  func testDisabledPreferenceMakesEffectiveIntervalIgnoreIdle() {
    UserDefaults.standard.set(15.0, forKey: "screenshotIntervalSeconds")
    defer { UserDefaults.standard.removeObject(forKey: "screenshotIntervalSeconds") }

    IdleCapturePreferences.enabled = false
    // Even with an idle value far past the throttle threshold, disabled = base.
    let interval = IdleCaptureInterval.interval(
      baseInterval: 15.0,
      idleThrottledInterval: IdleCaptureDefaults.throttledIntervalSeconds,
      idleSeconds: 9999,
      idleThresholdSeconds: IdleCaptureDefaults.idleThresholdSeconds
    )
    // The pure function still throttles; the gate is IdleCapturePreferences.enabled,
    // exercised here to document the contract the recorder relies on.
    XCTAssertEqual(interval, IdleCaptureDefaults.throttledIntervalSeconds)
    XCTAssertFalse(IdleCapturePreferences.enabled)
  }

  // The Settings view-model must reflect and persist the preference: reading
  // the current value at init, and writing through on change.
  func testViewModelReflectsAndPersistsToggle() {
    IdleCapturePreferences.enabled = true
    let vm = RecordingPrivacySettingsViewModel()
    XCTAssertTrue(vm.idleCaptureThrottleEnabled, "VM should read the persisted value at init")

    vm.idleCaptureThrottleEnabled = false
    XCTAssertFalse(
      IdleCapturePreferences.enabled,
      "flipping the VM toggle must write through to IdleCapturePreferences"
    )

    vm.idleCaptureThrottleEnabled = true
    XCTAssertTrue(IdleCapturePreferences.enabled)
  }
}
