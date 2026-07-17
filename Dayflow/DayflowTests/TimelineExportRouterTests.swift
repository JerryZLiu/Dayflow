import XCTest

@testable import Dayflow

@MainActor
final class TimelineExportRouterTests: XCTestCase {
  func testExportTimelineActionResolvesFromIdentifierAndAlias() {
    XCTAssertEqual(AppDeepLinkRouter.Action(identifier: "export-timeline"), .exportTimeline)
    XCTAssertEqual(AppDeepLinkRouter.Action(identifier: "export"), .exportTimeline)
    XCTAssertEqual(AppDeepLinkRouter.Action(identifier: "EXPORT-TIMELINE"), .exportTimeline)
  }

  func testUnknownActionDoesNotResolve() {
    XCTAssertNil(AppDeepLinkRouter.Action(identifier: "bogus"))
  }

  func testExistingActionsStillResolve() {
    XCTAssertEqual(AppDeepLinkRouter.Action(identifier: "start-recording"), .startRecording)
    XCTAssertEqual(AppDeepLinkRouter.Action(identifier: "stop"), .stopRecording)
  }
}
