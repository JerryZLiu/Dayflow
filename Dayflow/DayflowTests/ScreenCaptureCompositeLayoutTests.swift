import XCTest

@testable import Dayflow

final class ScreenCaptureCompositeLayoutTests: XCTestCase {
  func testSideBySideDisplaysPreserveNegativeCoordinates() throws {
    let layout = try XCTUnwrap(
      ScreenCaptureCompositeLayout(
        displayFrames: [
          CGRect(x: -1920, y: 0, width: 1920, height: 1080),
          CGRect(x: 0, y: 0, width: 2560, height: 1440),
        ],
        targetDisplayHeight: 1080
      ))

    XCTAssertEqual(layout.canvasSize, CGSize(width: 3360, height: 1080))
    XCTAssertEqual(layout.destinationRects[0], CGRect(x: 0, y: 270, width: 1440, height: 810))
    XCTAssertEqual(layout.destinationRects[1], CGRect(x: 1440, y: 0, width: 1920, height: 1080))
  }

  func testVerticallyStackedDisplaysIncreaseCanvasHeight() throws {
    let layout = try XCTUnwrap(
      ScreenCaptureCompositeLayout(
        displayFrames: [
          CGRect(x: 0, y: -1080, width: 1920, height: 1080),
          CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ],
        targetDisplayHeight: 1080
      ))

    XCTAssertEqual(layout.canvasSize, CGSize(width: 1920, height: 2160))
    XCTAssertEqual(layout.destinationRects[0], CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    XCTAssertEqual(layout.destinationRects[1], CGRect(x: 0, y: 0, width: 1920, height: 1080))
  }
}
