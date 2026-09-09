//
//  AgentUsageTelemetryQueue.swift
//  Dayflow
//
//  Drains content-free CLI/MCP usage records into the app's existing,
//  consent-gated analytics client. Command arguments and results never enter
//  this queue or the PostHog payload.
//

import Darwin
import Foundation

private struct QueuedAgentUsageRecord: Decodable {
  let schemaVersion: Int
  let interface: String
  let operation: String
  let outcome: String
  let failureCategory: String?
  let durationBucket: String
  let cliVersion: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case interface
    case operation
    case outcome
    case failureCategory = "failure_category"
    case durationBucket = "duration_bucket"
    case cliVersion = "cli_version"
  }
}

@MainActor
enum AgentUsageTelemetryQueue {
  private static let allowedInterfaces: Set<String> = ["cli", "mcp"]
  private static let allowedOperations: Set<String> = [
    "get_status",
    "get_timeline",
    "get_activity_detail",
    "get_daily",
    "get_weekly",
    "list_categories",
    "search_activities",
    "create_category",
    "update_category",
    "delete_category",
    "update_activity",
    "delete_activity",
    "set_day_goal",
  ]
  private static let allowedOutcomes: Set<String> = ["success", "failure", "cancelled"]
  private static let allowedFailureCategories: Set<String> = [
    "invalid_input",
    "not_found",
    "edits_disabled",
    "unavailable",
    "execution_error",
    "tool_error",
  ]
  private static let allowedDurationBuckets: Set<String> = [
    "under_100ms",
    "100_to_499ms",
    "500_to_1999ms",
    "2_to_9s",
    "10s_plus",
  ]

  private static var appSupportDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dayflow", isDirectory: true)
  }

  private static var queueURL: URL {
    appSupportDirectory.appendingPathComponent("agent-telemetry.ndjson")
  }

  private static var pendingURL: URL {
    appSupportDirectory.appendingPathComponent("agent-telemetry.pending.ndjson")
  }

  private static var lockURL: URL {
    appSupportDirectory.appendingPathComponent("agent-telemetry.lock")
  }

  static func drain() {
    guard AnalyticsService.shared.isOptedIn else {
      discard()
      return
    }

    var capturedAny = false
    for _ in 0..<10 {
      guard let claimedURL = claimQueue() else { break }
      guard let data = try? Data(contentsOf: claimedURL) else {
        try? FileManager.default.removeItem(at: claimedURL)
        continue
      }

      for line in data.split(separator: 0x0A) {
        guard let properties = analyticsProperties(from: Data(line)) else { continue }
        AnalyticsService.shared.capture("agent_command_executed", properties)
        capturedAny = true
      }
      try? FileManager.default.removeItem(at: claimedURL)
    }

    if capturedAny {
      AnalyticsService.shared.flush()
    }
  }

  static func discard() {
    withExclusiveLock {
      try? FileManager.default.removeItem(at: queueURL)
      try? FileManager.default.removeItem(at: pendingURL)
    }
  }

  static func analyticsProperties(from data: Data) -> [String: Any]? {
    guard let record = try? JSONDecoder().decode(QueuedAgentUsageRecord.self, from: data) else {
      return nil
    }
    guard record.schemaVersion == 1 else { return nil }
    guard allowedInterfaces.contains(record.interface) else { return nil }
    guard allowedOperations.contains(record.operation) else { return nil }
    guard allowedOutcomes.contains(record.outcome) else { return nil }
    guard allowedDurationBuckets.contains(record.durationBucket) else { return nil }
    guard isSafeVersion(record.cliVersion) else { return nil }
    if let failureCategory = record.failureCategory,
      !allowedFailureCategories.contains(failureCategory)
    {
      return nil
    }

    var properties: [String: Any] = [
      "schema_version": record.schemaVersion,
      "interface": record.interface,
      "operation": record.operation,
      "outcome": record.outcome,
      "duration_bucket": record.durationBucket,
      "cli_version": record.cliVersion,
    ]
    if let failureCategory = record.failureCategory {
      properties["failure_category"] = failureCategory
    }
    return properties
  }

  private static func claimQueue() -> URL? {
    var claimedURL: URL?
    withExclusiveLock {
      if FileManager.default.fileExists(atPath: pendingURL.path) {
        claimedURL = pendingURL
        return
      }
      guard FileManager.default.fileExists(atPath: queueURL.path) else { return }
      do {
        try FileManager.default.moveItem(at: queueURL, to: pendingURL)
        claimedURL = pendingURL
      } catch {
        claimedURL = nil
      }
    }
    return claimedURL
  }

  private static func withExclusiveLock(_ body: () -> Void) {
    try? FileManager.default.createDirectory(
      at: appSupportDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else { return }
    fchmod(lockFD, S_IRUSR | S_IWUSR)
    defer {
      flock(lockFD, LOCK_UN)
      close(lockFD)
    }
    guard flock(lockFD, LOCK_EX) == 0 else { return }
    body()
  }

  private static func isSafeVersion(_ version: String) -> Bool {
    guard !version.isEmpty, version.count <= 32 else { return false }
    return version.allSatisfy { character in
      character.isLetter || character.isNumber || character == "." || character == "-"
    }
  }
}
