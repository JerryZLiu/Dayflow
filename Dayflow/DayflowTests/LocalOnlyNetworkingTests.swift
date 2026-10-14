import XCTest

@testable import Dayflow

final class LocalOnlyNetworkingTests: XCTestCase {
  func testLoopbackHostsAreAllowed() {
    XCTAssertTrue(LocalOnlyNetworking.allows(URL(string: "http://127.0.0.1:11434/v1/chat/completions")))
    XCTAssertTrue(LocalOnlyNetworking.allows(URL(string: "http://localhost:1234/v1/chat/completions")))
    XCTAssertTrue(LocalOnlyNetworking.allows(URL(string: "http://[::1]:11434/api/chat")))
  }

  func testRemoteHostsAreBlocked() {
    XCTAssertFalse(LocalOnlyNetworking.allows(URL(string: "https://generativelanguage.googleapis.com/v1beta/models")))
    XCTAssertFalse(LocalOnlyNetworking.allows(URL(string: "https://www.dayflow.so/v1/transcribe")))
    XCTAssertFalse(LocalOnlyNetworking.allows(URL(string: "https://openrouter.ai/api/v1/chat/completions")))
    XCTAssertFalse(LocalOnlyNetworking.allows(URL(string: "https://us.i.posthog.com/capture")))
  }
}
