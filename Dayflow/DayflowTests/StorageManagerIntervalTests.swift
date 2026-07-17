import XCTest
@testable import Dayflow

final class StorageManagerIntervalTests: XCTestCase {
  func testMergedIntervalDurationUnionsOverlappingDeviceActivity() {
    let duration = StorageManager.mergedIntervalDuration([
      (start: 100, end: 200),
      (start: 150, end: 250),
      (start: 300, end: 360),
    ])

    XCTAssertEqual(duration, 210)
  }

  func testMergedIntervalDurationHandlesNestedAndInvalidIntervals() {
    let duration = StorageManager.mergedIntervalDuration([
      (start: 100, end: 300),
      (start: 150, end: 200),
      (start: 400, end: 390),
    ])

    XCTAssertEqual(duration, 200)
  }
}
