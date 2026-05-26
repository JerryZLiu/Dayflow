import XCTest

@testable import Dayflow

final class DailyStandupMarkdownCleanerTests: XCTestCase {
  func testCleansMarkdownFromGeneratedBulletText() {
    XCTAssertEqual(
      DailyStandupMarkdownCleaner.clean("## **Yesterday's highlights**"),
      "Yesterday's highlights"
    )
    XCTAssertEqual(
      DailyStandupMarkdownCleaner.clean("- Fixed `ChatService` markdown rendering"),
      "Fixed ChatService markdown rendering"
    )
    XCTAssertEqual(
      DailyStandupMarkdownCleaner.clean("[Reviewed PR](https://example.com) with **Claude**"),
      "Reviewed PR with Claude"
    )
  }

  func testReturnsNilForEmptyMarkdownAfterCleaning() {
    XCTAssertNil(DailyStandupMarkdownCleaner.clean("- "))
    XCTAssertNil(DailyStandupMarkdownCleaner.clean("###"))
  }
}
