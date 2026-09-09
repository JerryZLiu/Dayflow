//
//  main.swift
//  dayflow-cli
//
//  Command dispatch. Reads work with Dayflow closed; they go straight to the
//  database. Write commands arrive in a later phase and will require the app.
//
//  Exit codes: 0 success · 1 unexpected · 2 bad arguments · 3 not found ·
//  5 no Dayflow data. (4 and 6 are reserved for the write phase.)
//

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let valueTakingFlags: Set<String> = [
  "--category", "--from", "--to", "--color", "--title",
  "--focus-minutes", "--distraction-limit-minutes",
  "--focus-category", "--distraction-category",
]
let positional: [String] = {
  var result: [String] = []
  var index = 0
  let all = arguments
  while index < all.count {
    let argument = all[index]
    if argument.hasPrefix("--") {
      // Skip the flag, and its value if it takes one.
      if valueTakingFlags.contains(argument) { index += 1 }
    } else {
      result.append(argument)
    }
    index += 1
  }
  return result
}()
let wantsJSON = flags.contains("--json")

func flagValue(_ name: String) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
    return nil
  }
  return arguments[index + 1]
}

func openDatabase() -> (Database, String) {
  let path = Database.defaultPath()
  do {
    return (try Database(path: path), path)
  } catch DatabaseError.notFound {
    let message = "No Dayflow data found. Open Dayflow and let it record for a bit."
    wantsJSON ? failJSON("no_data", message, exitCode: 5) : fail(message, code: 5)
  } catch {
    let message = "Could not open Dayflow's database: \(error)"
    wantsJSON ? failJSON("database_error", message, exitCode: 1) : fail(message, code: 1)
  }
}

/// Resolve an optional YYYY-MM-DD argument to a Dayflow day, defaulting to now.
func resolveDay(_ key: String?) -> DayWindow {
  guard let key else { return dayWindow(containing: Date()) }
  guard let window = dayWindow(forKey: key) else {
    let message = "\"\(key)\" is not a date. Use YYYY-MM-DD, e.g. 2026-03-11."
    wantsJSON ? failJSON("invalid_date", message, exitCode: 2) : fail(message, code: 2)
  }
  return window
}

func timelineDetail() -> TimelineDetail {
  if flags.contains("--detailed") { return .detailed }
  if flags.contains("--summary") { return .summary }
  return .compact
}

// MARK: - Commands

func runTimeline(dayKey: String?) {
  let (db, _) = openDatabase()

  if flagValue("--from") != nil || flagValue("--to") != nil {
    runTimelineRange(db: db)
    return
  }

  let window = resolveDay(dayKey)
  do {
    var activities = try fetchActivities(db: db, window: window)
    if let category = flagValue("--category") {
      activities = activities.filter {
        $0.category.caseInsensitiveCompare(category) == .orderedSame
      }
    }
    if wantsJSON {
      printJSON(
        timelineEnvelope(
          activities, dayKey: window.dayKey, detailed: flags.contains("--detailed")))
    } else {
      renderTimeline(activities, window: window, detail: timelineDetail())
    }
  } catch {
    fail("Query failed: \(error)", code: 1)
  }
}

let maxRangeDaysForActivities = 7

func runTimelineRange(db: Database) {
  guard let fromKey = flagValue("--from"), let toKey = flagValue("--to"),
    let fromWindow = dayWindow(forKey: fromKey), let toWindow = dayWindow(forKey: toKey),
    fromWindow.start <= toWindow.start
  else {
    fail("Ranges need --from and --to as YYYY-MM-DD, with --from first.", code: 2)
  }

  let days =
    (Calendar.current.dateComponents([.day], from: fromWindow.start, to: toWindow.end).day ?? 0)

  do {
    let activities = try fetchActivities(db: db, from: fromWindow.start, to: toWindow.end)

    // Long ranges aggregate instead of listing; --force overrides for humans.
    if days > maxRangeDaysForActivities && !flags.contains("--force") {
      renderRangeAggregate(
        activities, fromKey: fromKey, toKey: toKey, days: days, asJSON: wantsJSON)
      return
    }

    if wantsJSON {
      printJSON(
        [
          "from": fromKey, "to": toKey,
          "cards": activities.map { json(for: $0, detailed: flags.contains("--detailed")) },
        ])
    } else {
      print("\(Style.bold)\(activities.count) activities · \(fromKey) → \(toKey)\(Style.reset)")
      print("")
      for activity in activities {
        let day = dayWindow(containing: activity.start).dayKey
        let start = clockFormatter.string(from: activity.start)
        print(
          "  \(Style.dim)\(day) \(start.padded(to: 9))\(Style.reset) \(activity.title.padded(to: 44))  \(activity.category)"
        )
      }
    }
  } catch {
    fail("Query failed: \(error)", code: 1)
  }
}

func renderRangeAggregate(
  _ activities: [Activity], fromKey: String, toKey: String, days: Int, asJSON: Bool
) {
  var totals: [String: Int] = [:]
  for activity in activities where activity.category != "System" {
    totals[activity.category, default: 0] += activity.durationMinutes
  }
  let tracked = totals.values.reduce(0, +)
  let sorted = totals.sorted { $0.value > $1.value }

  if asJSON {
    printJSON(
      [
        "range": ["from": fromKey, "to": toKey, "days": days],
        "granularity": "aggregate",
        "cards_omitted": activities.count,
        "reason":
          "Range exceeds \(maxRangeDaysForActivities) days. Returning totals instead of individual activities.",
        "tracked_minutes": tracked,
        "categories": sorted.map {
          [
            "name": $0.key, "minutes": $0.value,
            "share": tracked > 0 ? Double($0.value) / Double(tracked) : 0,
          ] as [String: Any]
        },
        "hint":
          "Request \(maxRangeDaysForActivities) days or fewer to get individual activities.",
      ])
    return
  }

  print(
    "\(Style.bold)\(fromKey) → \(toKey)\(Style.reset)  \(Style.dim)\(days) days · \(activities.count) activities · \(formatDuration(minutes: tracked)) tracked\(Style.reset)"
  )
  print("")
  let nameWidth = sorted.map { $0.key.count }.max() ?? 10
  let maxMinutes = sorted.first?.value ?? 1
  for (name, minutes) in sorted {
    let bar = String(repeating: "█", count: max(1, minutes * 20 / maxMinutes))
    let percent = tracked > 0 ? minutes * 100 / tracked : 0
    print(
      "  \(name.padded(to: nameWidth))  \(formatDuration(minutes: minutes).padded(to: 9))  \(Style.dim)\(bar)\(Style.reset)  \(percent)%"
    )
  }
  print("")
  print("  \(Style.dim)Showing totals — \(days) days is too many to list.\(Style.reset)")
  print(
    "  \(Style.dim)Use a range of \(maxRangeDaysForActivities) days or fewer, or --force to list all \(activities.count).\(Style.reset)"
  )
}

func runCard(idText: String?) {
  guard let idText, let recordId = Int(idText) else {
    fail("Usage: dayflow card <record-id>   (IDs come from `dayflow timeline`)", code: 2)
  }
  let (db, _) = openDatabase()
  do {
    guard let activity = try fetchActivity(db: db, recordId: recordId) else {
      let message = "No activity with ID \(recordId)."
      wantsJSON ? failJSON("not_found", message, exitCode: 3) : fail(message, code: 3)
    }
    if wantsJSON {
      printJSON(json(for: activity, detailed: true))
    } else {
      renderCard(activity)
    }
  } catch {
    fail("Query failed: \(error)", code: 1)
  }
}

func runDaily(dayKey: String?) {
  // Standups are keyed by plain calendar date, not the 4 AM boundary —
  // this mirrors dailyStandupDayKey in the app.
  let calendarToday: String = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }()
  let key = dayKey ?? calendarToday

  let (db, _) = openDatabase()
  do {
    guard let standup = try fetchStandup(db: db, day: key) else {
      let message = "No Daily for \(key). Dayflow generates one after a day with enough activity."
      wantsJSON ? failJSON("not_found", message, exitCode: 3) : fail(message, code: 3)
    }
    if wantsJSON {
      printJSON(
        [
          "date": standup.day,
          "highlights": standup.highlights,
          "tasks": standup.tasks,
          "blockers": standup.blockersBody,
        ])
    } else {
      print("\(Style.bold)\(standup.highlightsTitle)\(Style.reset)")
      for item in standup.highlights { print("- \(item)") }
      print("")
      print("\(Style.bold)\(standup.tasksTitle)\(Style.reset)")
      for item in standup.tasks { print("- \(item)") }
      print("")
      print("\(Style.bold)\(standup.blockersTitle)\(Style.reset)")
      print("- \(standup.blockersBody.isEmpty ? "None" : standup.blockersBody)")
    }
  } catch {
    fail("Query failed: \(error)", code: 1)
  }
}

func runWeekly(dayKey: String?) {
  let anchor: Date
  if let dayKey {
    guard let window = dayWindow(forKey: dayKey) else {
      fail("\"\(dayKey)\" is not a date. Use YYYY-MM-DD.", code: 2)
    }
    anchor = window.start
  } else {
    anchor = Date()
  }
  let window = weekWindow(containing: anchor)

  let (db, _) = openDatabase()
  do {
    let activities = try fetchActivities(db: db, from: window.start, to: window.end)
    if wantsJSON {
      var totals: [String: Int] = [:]
      for activity in activities where activity.category != "System" {
        totals[activity.category, default: 0] += activity.durationMinutes
      }
      let tracked = totals.values.reduce(0, +)
      printJSON(
        [
          "week_start": isoFormatter.string(from: window.start),
          "week_end": isoFormatter.string(from: window.end),
          "tracked_minutes": tracked,
          "focus_minutes": totals.filter { $0.key != "Idle" }.values.reduce(0, +),
          "categories": totals.sorted { $0.value > $1.value }.map {
            [
              "name": $0.key, "minutes": $0.value,
              "share": tracked > 0 ? Double($0.value) / Double(tracked) : 0,
            ] as [String: Any]
          },
        ])
    } else {
      renderWeekly(activities, window: window)
    }
  } catch {
    fail("Query failed: \(error)", code: 1)
  }
}

func runCategories() {
  let categories = loadCategories()
  if wantsJSON {
    printJSON(
      [
        "categories": categories.map {
          [
            "name": $0.name, "color_hex": $0.colorHex,
            "is_system": $0.isSystem, "is_idle": $0.isIdle,
          ] as [String: Any]
        }
      ])
  } else {
    let nameWidth = categories.map { $0.name.count }.max() ?? 10
    for category in categories {
      var line =
        "  ■ \(category.name.padded(to: nameWidth))  \(Style.dim)\(category.colorHex)\(Style.reset)"
      if category.isSystem { line += "  \(Style.dim)system\(Style.reset)" }
      print(line)
    }
  }
}

func runSearch(text: String?) {
  guard let text, !text.isEmpty else {
    fail("Usage: dayflow search <text>", code: 2)
  }
  let (db, _) = openDatabase()
  do {
    let matches = try searchActivities(db: db, text: text)
    if wantsJSON {
      printJSON(
        [
          "query": text,
          "matches": matches.map { json(for: $0, detailed: false) },
        ])
      return
    }
    guard !matches.isEmpty else {
      print("No activities matching \"\(text)\".")
      return
    }
    print("\(matches.count) match\(matches.count == 1 ? "" : "es")")
    print("")
    for activity in matches {
      let day = dayWindow(containing: activity.start).dayKey
      let start = clockFormatter.string(from: activity.start)
      print(
        "  \(Style.dim)\(day)  \(start.padded(to: 9))\(Style.reset) \(activity.title.padded(to: 44))  \(activity.category)"
      )
    }
  } catch {
    fail("Query failed: \(error)", code: 1)
  }
}

func runStatus() {
  let (db, path) = openDatabase()
  _ = path
  do {
    let status = try fetchStatus(db: db, path: path)
    if wantsJSON {
      var object: [String: Any] = [
        "today": status.today,
        "time_zone": TimeZone.current.identifier,
        "day_boundary_hour": 4,
        "pending_batches": status.pendingBatches,
        "failed_batches": status.failedBatches,
        "edits_enabled": false,
      ]
      if let lastCapture = status.lastCaptureAt {
        object["last_capture_at"] = isoFormatter.string(from: lastCapture)
      }
      printJSON(object)
    } else {
      var captureLine = "no captures found"
      if let lastCapture = status.lastCaptureAt {
        let minutes = Int(Date().timeIntervalSince(lastCapture) / 60)
        captureLine =
          minutes < 2
          ? "last capture just now" : "last capture \(formatDuration(minutes: minutes)) ago"
      }
      print("  Dayflow · \(captureLine)")
      print("  Today: \(status.today) (day starts 4:00 AM, \(TimeZone.current.identifier))")
      if status.pendingBatches > 0 {
        print(
          "  Analysis backlog: \(status.pendingBatches) batch\(status.pendingBatches == 1 ? "" : "es")"
        )
      }
      print("  Edits: off \(Style.dim)(reads only in this version)\(Style.reset)")
    }
  } catch {
    fail("Query failed: \(error)", code: 1)
  }
}

func runLink(remove: Bool) {
  let binaryPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
  let linkPath = "/usr/local/bin/dayflow"
  let fileManager = FileManager.default

  if remove {
    guard (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) != nil else {
      fail("Nothing to remove — \(linkPath) is not a dayflow link.", code: 3)
    }
    do {
      try fileManager.removeItem(atPath: linkPath)
      print("Removed \(linkPath)")
    } catch {
      fail("Could not remove \(linkPath): \(error.localizedDescription)", code: 1)
    }
    return
  }

  print("This links `dayflow` into /usr/local/bin so you can run it from anywhere:")
  print("")
  print("  \(linkPath) → \(binaryPath)")
  print("")
  print("Nothing is downloaded and your shell configuration is not touched.")

  do {
    if fileManager.fileExists(atPath: linkPath) {
      try fileManager.removeItem(atPath: linkPath)
    }
    try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: binaryPath)
    print("✓ Linked. Try: dayflow timeline")
  } catch {
    fail(
      "Could not write to /usr/local/bin (\(error.localizedDescription)). "
        + "Run with sudo, or create the link yourself:\n"
        + "  sudo ln -sf \"\(binaryPath)\" \(linkPath)",
      code: 1)
  }
}

let helpText = """
  dayflow — your Dayflow timeline, in the terminal

  Usage
    dayflow <command> [arguments] [--json]

  Reading (works even when Dayflow is closed)
    status                     Recording state and today's date
    timeline [YYYY-MM-DD]      A day's activities (aliases: today, yesterday)
      --summary                Include one-line descriptions
      --detailed               Include full write-ups
      --category <name>        Only one category
      --from/--to <date>       A range; over 7 days returns totals
    card <id>                  One activity in full detail
    daily [YYYY-MM-DD]         The Daily standup document
    weekly [YYYY-MM-DD]        The week containing that date
    categories                 Category names and colors
    search <text>              Find activities by title or summary

  Editing (needs Dayflow running, with edits enabled in Settings → AI Tools)
    timeline update <id> --title <text> | --category <name>
    timeline delete <id>       Asks first; also removes its observations
    categories add <name> [--color <hex>]
    categories rename <old> <new>
    categories color <name> <hex>
    categories describe <name> <text>
    categories remove <name>   Asks first; past activities keep the label
    goal set [YYYY-MM-DD] --focus-minutes <n> [--distraction-limit-minutes <n>]
             [--focus-category <name>]... [--distraction-category <name>]...

  Setup
    link                       Add `dayflow` to /usr/local/bin
    unlink                     Remove it
    mcp                        Run the MCP server (stdio)

  All commands accept --json for stable, scriptable output.
  """

// MARK: - Dispatch

AgentUsageTelemetry.beginCLI(operation: AgentUsageTelemetry.operation(for: positional))

switch positional.first {
case nil, "help":
  print(helpText)
case "status":
  runStatus()
case "timeline":
  let sub = positional.count > 1 ? positional[1] : nil
  if sub == "update" || sub == "delete" {
    runTimelineWrite(subcommand: sub!, rest: Array(positional.dropFirst(2)))
  } else {
    runTimeline(dayKey: sub)
  }
case "today":
  runTimeline(dayKey: nil)
case "yesterday":
  let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
  runTimeline(dayKey: dayWindow(containing: yesterday).dayKey)
case "card":
  runCard(idText: positional.count > 1 ? positional[1] : nil)
case "daily":
  runDaily(dayKey: positional.count > 1 ? positional[1] : nil)
case "weekly":
  runWeekly(dayKey: positional.count > 1 ? positional[1] : nil)
case "categories":
  if positional.count > 1 {
    runCategoriesWrite(subcommand: positional[1], rest: Array(positional.dropFirst(2)))
  } else {
    runCategories()
  }
case "goal":
  guard positional.count > 1, positional[1] == "set" else {
    fail("Usage: dayflow goal set [YYYY-MM-DD] --focus-minutes <n> ...", code: 2)
  }
  runGoalSet(dayKey: positional.count > 2 ? positional[2] : nil)
case "search":
  runSearch(text: positional.count > 1 ? positional[1...].joined(separator: " ") : nil)
case "link":
  runLink(remove: false)
case "unlink":
  runLink(remove: true)
case "mcp":
  runMCPServer()
case let command?:
  fail("Unknown command \"\(command)\". Run `dayflow help`.", code: 2)
}

AgentUsageTelemetry.finishCLI(outcome: "success")
