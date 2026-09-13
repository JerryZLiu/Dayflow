import XCTest

@testable import Dayflow

final class DailyRecapAttemptBudgetTests: XCTestCase {
  func testRepeatedSchedulerChecksStopAfterThreeAttempts() throws {
    let suite = "Dayflow.DailyRecapAttemptBudgetTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let budget = DailyRecapAttemptBudget(defaults: defaults)

    XCTAssertEqual(budget.reserveAttempt(forDay: "2026-09-15"), 1)
    XCTAssertEqual(budget.reserveAttempt(forDay: "2026-09-15"), 2)
    XCTAssertEqual(budget.reserveAttempt(forDay: "2026-09-15"), 3)
    for _ in 0..<20 {
      XCTAssertNil(budget.reserveAttempt(forDay: "2026-09-15"))
    }
  }

  func testRecreatingTheBudgetPreservesAttemptsAndExhaustion() throws {
    let suite = "Dayflow.DailyRecapAttemptBudgetTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    for expectedAttempt in 1...3 {
      let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      let budget = DailyRecapAttemptBudget(defaults: reloadedDefaults)
      XCTAssertEqual(budget.reserveAttempt(forDay: "2026-09-15"), expectedAttempt)
    }
    let reloadedBudget = DailyRecapAttemptBudget(
      defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    XCTAssertNil(reloadedBudget.reserveAttempt(forDay: "2026-09-15"))
  }

  func testNextDailyRecapGetsItsOwnAttempts() throws {
    let suite = "Dayflow.DailyRecapAttemptBudgetTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let budget = DailyRecapAttemptBudget(defaults: defaults)

    for _ in 0..<3 { _ = budget.reserveAttempt(forDay: "2026-09-15") }
    XCTAssertNil(budget.reserveAttempt(forDay: "2026-09-15"))
    XCTAssertEqual(budget.reserveAttempt(forDay: "2026-09-16"), 1)
    XCTAssertEqual(budget.reserveAttempt(forDay: "2026-09-16"), 2)
    XCTAssertEqual(budget.reserveAttempt(forDay: "2026-09-16"), 3)
    XCTAssertNil(budget.reserveAttempt(forDay: "2026-09-16"))
  }
}
