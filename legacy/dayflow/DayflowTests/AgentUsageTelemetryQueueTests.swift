import XCTest

@testable import Dayflow

@MainActor
final class AgentUsageTelemetryQueueTests: XCTestCase {
  func testValidRecordProducesOnlyAllowlistedProperties() throws {
    let data = Data(
      """
      {
        "schema_version": 1,
        "interface": "mcp",
        "operation": "get_timeline",
        "outcome": "success",
        "duration_bucket": "under_100ms",
        "cli_version": "1.0.0",
        "arguments": {"query": "private text", "record_id": 42},
        "result": "private result"
      }
      """.utf8)

    let properties = try XCTUnwrap(AgentUsageTelemetryQueue.analyticsProperties(from: data))

    XCTAssertEqual(properties.count, 6)
    XCTAssertEqual(properties["interface"] as? String, "mcp")
    XCTAssertEqual(properties["operation"] as? String, "get_timeline")
    XCTAssertNil(properties["arguments"])
    XCTAssertNil(properties["result"])
  }

  func testFailureCategoryIsIncludedWhenAllowlisted() throws {
    let data = Data(
      """
      {
        "schema_version": 1,
        "interface": "cli",
        "operation": "update_activity",
        "outcome": "failure",
        "failure_category": "edits_disabled",
        "duration_bucket": "100_to_499ms",
        "cli_version": "1.0.0"
      }
      """.utf8)

    let properties = try XCTUnwrap(AgentUsageTelemetryQueue.analyticsProperties(from: data))
    XCTAssertEqual(properties["failure_category"] as? String, "edits_disabled")
  }

  func testUnknownOperationIsRejected() {
    let data = Data(
      """
      {
        "schema_version": 1,
        "interface": "cli",
        "operation": "read_arbitrary_file",
        "outcome": "success",
        "duration_bucket": "under_100ms",
        "cli_version": "1.0.0"
      }
      """.utf8)

    XCTAssertNil(AgentUsageTelemetryQueue.analyticsProperties(from: data))
  }
}
