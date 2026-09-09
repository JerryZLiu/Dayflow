import XCTest

@testable import Dayflow

@MainActor
final class AgentPlaybackUsageTests: XCTestCase {
  func testUsageExcludesLoadingAndBackgroundTime() {
    var clock: TimeInterval = 0
    var events: [(String, [String: Any])] = []
    let usage = AgentPlaybackUsage(
      now: { clock }, enabled: { true }, capture: { events.append(($0, $1)) })
    usage.appear(foreground: true)
    clock = 20
    usage.setReady(true)
    clock = 25
    usage.setForeground(false)
    clock = 100
    usage.setForeground(true)
    clock = 103
    usage.disappear()
    let sessions = events.filter { $0.0 == "agentplayback_session_ended" }
    XCTAssertEqual(sessions.count, 2)
    XCTAssertEqual(sessions[0].1["duration_seconds"] as? Double, 5)
    XCTAssertEqual(sessions[1].1["duration_seconds"] as? Double, 3)
    XCTAssertEqual(sessions[0].1["reason"] as? String, "background")
    XCTAssertEqual(sessions[1].1["reason"] as? String, "tab_closed")
  }

  func testDuplicateCallbacksDoNotDoubleCountAndReopeningIsRecorded() {
    var clock: TimeInterval = 0
    var events: [(String, [String: Any])] = []
    let usage = AgentPlaybackUsage(
      now: { clock }, enabled: { true }, capture: { events.append(($0, $1)) })
    usage.setReady(true)
    usage.appear(foreground: true)
    usage.appear(foreground: true)
    clock = 2
    usage.setReady(true)
    usage.setForeground(true)
    clock = 5
    usage.disappear()
    usage.disappear()
    usage.appear(foreground: true)
    let sessions = events.filter { $0.0 == "agentplayback_session_ended" }
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions[0].1["duration_seconds"] as? Double, 5)
    XCTAssertEqual(events.filter { $0.0 == "agentplayback_opened" }.count, 2)
    XCTAssertEqual(events.last?.1["already_loaded"] as? Bool, true)
  }

  func testOptOutDiscardsIntervalAndOptInStartsFresh() {
    var clock: TimeInterval = 0
    var enabled = false
    var events: [(String, [String: Any])] = []
    let usage = AgentPlaybackUsage(
      now: { clock }, enabled: { enabled }, capture: { events.append(($0, $1)) })
    usage.appear(foreground: true)
    usage.setReady(true)
    XCTAssertTrue(events.isEmpty)
    clock = 10
    enabled = true
    usage.consentChanged()
    clock = 20
    enabled = false
    usage.consentChanged()
    clock = 100
    enabled = true
    usage.consentChanged()
    clock = 104
    usage.terminate()
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].1["duration_seconds"] as? Double, 4)
    XCTAssertEqual(Set(events[0].1.keys), ["duration_seconds", "reason"])
  }

  func testFailedDashboardStopsUsageUntilRecovered() {
    var clock: TimeInterval = 0
    var events: [(String, [String: Any])] = []
    let usage = AgentPlaybackUsage(
      now: { clock }, enabled: { true }, capture: { events.append(($0, $1)) })
    usage.appear(foreground: true)
    usage.setReady(true)
    clock = 3
    usage.setReady(false)
    clock = 100
    usage.setReady(true)
    clock = 102
    usage.terminate()
    usage.setReady(false)
    let sessions = events.filter { $0.0 == "agentplayback_session_ended" }
    XCTAssertEqual(sessions.count, 2)
    XCTAssertEqual(sessions[0].1["duration_seconds"] as? Double, 3)
    XCTAssertEqual(sessions[0].1["reason"] as? String, "unavailable")
    XCTAssertEqual(sessions[1].1["duration_seconds"] as? Double, 2)
  }
}
