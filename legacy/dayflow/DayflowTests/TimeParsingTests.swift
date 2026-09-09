import XCTest
@testable import Dayflow

final class TimeParsingTests: XCTestCase {
    func testValidTimes() {
        XCTAssertEqual(parseTimeHMMA(timeString: "9:30 AM"), 9 * 60 + 30)
        XCTAssertEqual(parseTimeHMMA(timeString: "11:59 PM"), 23 * 60 + 59)
    }

    func testInvalidTimes() {
        XCTAssertNil(parseTimeHMMA(timeString: ""))
        XCTAssertNil(parseTimeHMMA(timeString: "invalid"))
    }
}
