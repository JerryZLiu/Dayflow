import XCTest

@testable import Dayflow

@MainActor
final class AgentWriteHandlersTests: XCTestCase {
  func testActivityUpdateValidatesCategoryBeforeCreatingWriteRequest() {
    var resolvedCategory = false

    XCTAssertThrowsError(
      try AgentWriteHandlers.validatedActivityUpdate(
        ["record_id": 42, "title": "Renamed", "category": "Typo"],
        resolveCategoryName: { _ in
          resolvedCategory = true
          throw AgentWriteError(code: "not_found", message: "Unknown category")
        }
      )
    ) { error in
      XCTAssertEqual((error as? AgentWriteError)?.code, "not_found")
    }
    XCTAssertTrue(resolvedCategory)
  }

  func testActivityUpdateBuildsOneNormalizedRequest() throws {
    let request = try AgentWriteHandlers.validatedActivityUpdate(
      ["record_id": 42, "title": "  Renamed\n", "category": "Deep Work"],
      resolveCategoryName: { _ in "Deep Work" }
    )

    XCTAssertEqual(request.recordId, 42)
    XCTAssertEqual(request.title, "Renamed")
    XCTAssertEqual(request.category, "Deep Work")
    XCTAssertEqual(request.changeDescriptions, ["title", "category → Deep Work"])
  }

  func testActivityUpdateSupportsOneFieldAtATime() throws {
    let titleRequest = try AgentWriteHandlers.validatedActivityUpdate(
      ["record_id": 42, "title": "Renamed"],
      resolveCategoryName: { _ in
        XCTFail("Title-only update should not resolve a category")
        return ""
      }
    )
    let categoryRequest = try AgentWriteHandlers.validatedActivityUpdate(
      ["record_id": 42, "category": "Deep Work"],
      resolveCategoryName: { _ in "Deep Work" }
    )

    XCTAssertEqual(titleRequest.title, "Renamed")
    XCTAssertNil(titleRequest.category)
    XCTAssertNil(categoryRequest.title)
    XCTAssertEqual(categoryRequest.category, "Deep Work")
  }

  func testActivityUpdateRejectsEmptyChanges() {
    XCTAssertThrowsError(
      try AgentWriteHandlers.validatedActivityUpdate(
        ["record_id": 42, "title": " \n"],
        resolveCategoryName: { _ in "Deep Work" }
      )
    ) { error in
      XCTAssertEqual((error as? AgentWriteError)?.code, "invalid_argument")
    }
  }

  func testGoalDayDefaultsToCurrentFourAMDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let beforeFourAM = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 3, minute: 30))
    )

    XCTAssertEqual(
      try AgentWriteHandlers.resolvedGoalDay([:], now: beforeFourAM),
      "2026-08-11"
    )
  }

  func testGoalDayUsesExplicitDate() throws {
    XCTAssertEqual(
      try AgentWriteHandlers.resolvedGoalDay(["date": " 2026-08-12 "]),
      "2026-08-12"
    )
  }
}
