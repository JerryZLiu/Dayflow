import XCTest

@testable import Dayflow

final class DaySummaryLoadTokenTests: XCTestCase {
  func testCurrentRequestMatchesLatestToken() {
    let token = DaySummaryLoadToken(dayString: "2026-07-16")

    XCTAssertTrue(token.matches(latest: token))
  }

  func testSupersededRequestDoesNotMatch() {
    let staleToken = DaySummaryLoadToken(dayString: "2026-07-16")
    let latestToken = DaySummaryLoadToken(dayString: "2026-07-16")

    XCTAssertFalse(staleToken.matches(latest: latestToken))
  }

  func testRequestIdentityCannotBeReusedAcrossDays() {
    let id = UUID()
    let previousDayToken = DaySummaryLoadToken(id: id, dayString: "2026-07-15")
    let currentDayToken = DaySummaryLoadToken(id: id, dayString: "2026-07-16")

    XCTAssertFalse(previousDayToken.matches(latest: currentDayToken))
  }
}
