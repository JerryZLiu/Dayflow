//
//  AgentUsageTelemetry.swift
//  dayflow-cli
//
//  Content-free usage telemetry for CLI commands and MCP tool calls. The helper
//  never sends data itself. It appends a small allowlisted record locally, and
//  the Dayflow app uploads those records later only when analytics is enabled.
//

import Darwin
import Foundation

private struct AgentUsageRecord: Encodable {
  let schemaVersion = 1
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

enum AgentUsageTelemetry {
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

  private static let maximumQueueBytes: Int64 = 1_048_576
  private static var activeCLIOperation: String?
  private static var activeCLIStart: TimeInterval?
  private static var cliFinished = false

  private static var appSupportDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dayflow", isDirectory: true)
  }

  private static var queueURL: URL {
    appSupportDirectory.appendingPathComponent("agent-telemetry.ndjson")
  }

  private static var lockURL: URL {
    appSupportDirectory.appendingPathComponent("agent-telemetry.lock")
  }

  static func operation(for positional: [String]) -> String? {
    guard let command = positional.first else { return nil }
    switch command {
    case "status": return "get_status"
    case "timeline":
      switch positional.dropFirst().first {
      case "update": return "update_activity"
      case "delete": return "delete_activity"
      default: return "get_timeline"
      }
    case "today", "yesterday": return "get_timeline"
    case "card": return "get_activity_detail"
    case "daily": return "get_daily"
    case "weekly": return "get_weekly"
    case "categories":
      switch positional.dropFirst().first {
      case "add": return "create_category"
      case "rename", "color", "describe": return "update_category"
      case "remove": return "delete_category"
      case nil: return "list_categories"
      default: return nil
      }
    case "goal": return positional.dropFirst().first == "set" ? "set_day_goal" : nil
    case "search": return "search_activities"
    default: return nil
    }
  }

  static func beginCLI(operation: String?) {
    guard let operation, allowedOperations.contains(operation) else { return }
    activeCLIOperation = operation
    activeCLIStart = ProcessInfo.processInfo.systemUptime
    cliFinished = false
  }

  static func finishCLI(outcome: String, failureCategory: String? = nil) {
    guard !cliFinished, let operation = activeCLIOperation else { return }
    cliFinished = true
    let start = activeCLIStart ?? ProcessInfo.processInfo.systemUptime
    record(
      interface: "cli",
      operation: operation,
      outcome: outcome,
      failureCategory: failureCategory,
      duration: ProcessInfo.processInfo.systemUptime - start
    )
  }

  static func recordMCP(
    operation: String,
    outcome: String,
    failureCategory: String? = nil,
    duration: TimeInterval
  ) {
    record(
      interface: "mcp",
      operation: operation,
      outcome: outcome,
      failureCategory: failureCategory,
      duration: duration
    )
  }

  static func failureCategory(forExitCode code: Int32) -> String {
    switch code {
    case 2: return "invalid_input"
    case 3: return "not_found"
    case 4: return "edits_disabled"
    case 5: return "unavailable"
    default: return "execution_error"
    }
  }

  private static func record(
    interface: String,
    operation: String,
    outcome: String,
    failureCategory: String?,
    duration: TimeInterval
  ) {
    guard analyticsEnabled, allowedOperations.contains(operation) else { return }
    guard interface == "cli" || interface == "mcp" else { return }
    guard outcome == "success" || outcome == "failure" || outcome == "cancelled" else { return }

    let record = AgentUsageRecord(
      interface: interface,
      operation: operation,
      outcome: outcome,
      failureCategory: sanitizedFailureCategory(failureCategory),
      durationBucket: durationBucket(duration),
      cliVersion: cliVersion
    )
    guard var data = try? JSONEncoder().encode(record) else { return }
    data.append(0x0A)
    append(data)
  }

  private static var analyticsEnabled: Bool {
    let defaults = UserDefaults(suiteName: "teleportlabs.com.Dayflow")
    guard defaults?.object(forKey: "analyticsOptIn") != nil else { return true }
    return defaults?.bool(forKey: "analyticsOptIn") == true
  }

  private static func sanitizedFailureCategory(_ value: String?) -> String? {
    let allowed: Set<String> = [
      "invalid_input",
      "not_found",
      "edits_disabled",
      "unavailable",
      "execution_error",
      "tool_error",
    ]
    guard let value, allowed.contains(value) else { return nil }
    return value
  }

  private static func durationBucket(_ duration: TimeInterval) -> String {
    switch duration {
    case ..<0.1: return "under_100ms"
    case ..<0.5: return "100_to_499ms"
    case ..<2: return "500_to_1999ms"
    case ..<10: return "2_to_9s"
    default: return "10s_plus"
    }
  }

  private static func append(_ data: Data) {
    do {
      try FileManager.default.createDirectory(
        at: appSupportDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return
    }

    let lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else { return }
    fchmod(lockFD, S_IRUSR | S_IWUSR)
    defer {
      flock(lockFD, LOCK_UN)
      close(lockFD)
    }
    guard flock(lockFD, LOCK_EX) == 0 else { return }

    let existingSize = (try? queueURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard Int64(existingSize) + Int64(data.count) <= maximumQueueBytes else { return }

    let queueFD = Darwin.open(
      queueURL.path,
      O_CREAT | O_APPEND | O_WRONLY,
      S_IRUSR | S_IWUSR
    )
    guard queueFD >= 0 else { return }
    defer { close(queueFD) }
    fchmod(queueFD, S_IRUSR | S_IWUSR)

    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let result = Darwin.write(
          queueFD,
          baseAddress.advanced(by: written),
          bytes.count - written
        )
        guard result > 0 else { return }
        written += result
      }
    }
  }
}
