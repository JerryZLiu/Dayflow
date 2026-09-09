//
//  JSONOut.swift
//  dayflow-cli
//
//  Stable JSON output. Keys are sorted so diffs and golden tests are
//  deterministic; every top-level object carries schema_version. This is the
//  same payload a future `dayflow mcp` returns as structuredContent.
//

import Foundation

let schemaVersion = 1

let isoFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
  formatter.locale = Locale(identifier: "en_US_POSIX")
  return formatter
}()

func printJSON(_ object: [String: Any]) {
  var payload = object
  payload["schema_version"] = schemaVersion
  guard
    let data = try? JSONSerialization.data(
      withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
    let text = String(data: data, encoding: .utf8)
  else {
    fail("could not encode response as JSON", code: 1)
  }
  print(text)
}

func failJSON(_ code: String, _ message: String, exitCode: Int32) -> Never {
  AgentUsageTelemetry.finishCLI(
    outcome: "failure",
    failureCategory: AgentUsageTelemetry.failureCategory(forExitCode: exitCode)
  )
  let error: [String: Any] = [
    "schema_version": schemaVersion,
    "error": ["code": code, "message": message],
  ]
  if let data = try? JSONSerialization.data(withJSONObject: error, options: [.sortedKeys]),
    let text = String(data: data, encoding: .utf8)
  {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }
  exit(exitCode)
}

func json(for activity: Activity, detailed: Bool) -> [String: Any] {
  var object: [String: Any] = [
    "record_id": activity.recordId,
    "start": isoFormatter.string(from: activity.start),
    "end": isoFormatter.string(from: activity.end),
    "duration_minutes": activity.durationMinutes,
    "title": activity.title,
    "summary": activity.summary,
    "category": activity.category,
  ]
  if !activity.subcategory.isEmpty { object["subcategory"] = activity.subcategory }
  if !activity.apps.isEmpty { object["apps"] = activity.apps }
  if activity.distractionCount > 0 { object["distraction_count"] = activity.distractionCount }
  if detailed && !activity.detailedSummary.isEmpty {
    object["detailed_summary"] = activity.detailedSummary
  }
  return object
}

func timelineEnvelope(
  _ activities: [Activity], dayKey: String, detailed: Bool
) -> [String: Any] {
  [
    "date": dayKey,
    "time_zone": TimeZone.current.identifier,
    "day_boundary_hour": 4,
    "cards": activities.map { json(for: $0, detailed: detailed) },
    "detail_available": !detailed,
    "hint": detailed
      ? ""
      : "Summaries are abbreviated. Use `dayflow card <record_id>` for the full write-up of a specific activity."
      ,
  ]
}
