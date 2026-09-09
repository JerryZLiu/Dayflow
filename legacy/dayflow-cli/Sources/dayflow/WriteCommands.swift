//
//  WriteCommands.swift
//  dayflow-cli
//
//  Write commands travel to the running app over the bridge. Reversible
//  edits just happen; destructive ones (category remove, activity delete)
//  confirm interactively first, because activity deletion also removes the
//  underlying observations and cannot be fully undone.
//
//  Exit codes here: 4 edits disabled · 5 app not running.
//

import Foundation

func collectFlagValues(_ name: String, in arguments: [String]) -> [String] {
  var values: [String] = []
  var index = 0
  while index < arguments.count - 1 {
    if arguments[index] == name { values.append(arguments[index + 1]) }
    index += 1
  }
  return values
}

private func requireEditsEnabled() {
  guard AgentBridge.editsEnabled else {
    let message = "Editing is off. Turn on \"Allow edits\" in Dayflow → Settings → AI Tools."
    wantsJSON ? failJSON("edits_disabled", message, exitCode: 4) : fail(message, code: 4)
  }
}

private func sendOrFail(operation: String, arguments: [String: Any]) -> [String: Any] {
  requireEditsEnabled()
  do {
    return try AgentBridge.send(operation: operation, arguments: arguments)
  } catch let error as AgentBridge.BridgeError {
    let exitCode: Int32 = error.code == "app_not_running" ? 5 : 1
    wantsJSON
      ? failJSON(error.code, error.message, exitCode: exitCode)
      : fail(error.message, code: exitCode)
  } catch {
    fail("Write failed: \(error)", code: 1)
  }
}

/// Ask before a destructive operation. Non-interactive callers must pass --yes.
private func confirmDestructive(_ prompt: String) {
  guard !flags.contains("--yes") else { return }
  guard isatty(0) == 1 else {
    fail("This is destructive. Re-run with --yes to confirm.", code: 2)
  }
  print("\(prompt) [y/N] ", terminator: "")
  let answer = readLine()?.lowercased() ?? ""
  guard answer == "y" || answer == "yes" else {
    AgentUsageTelemetry.finishCLI(outcome: "cancelled")
    print("Cancelled.")
    exit(0)
  }
}

// MARK: - Categories

func runCategoriesWrite(subcommand: String, rest: [String]) {
  switch subcommand {
  case "add":
    guard let name = rest.first else {
      fail("Usage: dayflow categories add <name> [--color <hex>]", code: 2)
    }
    var arguments: [String: Any] = ["name": name]
    if let color = flagValue("--color") { arguments["color"] = color }
    let data = sendOrFail(operation: "category_add", arguments: arguments)
    reportWrite(data, fallback: "Created \(name)")

  case "rename":
    guard rest.count >= 2 else {
      fail("Usage: dayflow categories rename <old-name> <new-name>", code: 2)
    }
    let data = sendOrFail(
      operation: "category_update", arguments: ["name": rest[0], "new_name": rest[1]])
    reportWrite(data, fallback: "Renamed \(rest[0]) to \(rest[1])")

  case "color":
    guard rest.count >= 2 else {
      fail("Usage: dayflow categories color <name> <hex>", code: 2)
    }
    let data = sendOrFail(
      operation: "category_update", arguments: ["name": rest[0], "color": rest[1]])
    reportWrite(data, fallback: "\(rest[0]) is now \(rest[1])")

  case "describe":
    guard rest.count >= 2 else {
      fail("Usage: dayflow categories describe <name> <text>", code: 2)
    }
    let description = rest.dropFirst().joined(separator: " ")
    let data = sendOrFail(
      operation: "category_update", arguments: ["name": rest[0], "description": description])
    reportWrite(data, fallback: "Updated description for \(rest[0])")

  case "remove":
    guard let name = rest.first else {
      fail("Usage: dayflow categories remove <name>", code: 2)
    }
    requireEditsEnabled()
    confirmDestructive(
      "Delete the category \"\(name)\"? Past activities keep the label but lose the color.")
    let data = sendOrFail(operation: "category_remove", arguments: ["name": name])
    reportWrite(data, fallback: "Removed \(name)")

  default:
    fail(
      "Unknown subcommand \"\(subcommand)\". Use add, rename, color, describe, or remove.",
      code: 2)
  }
}

// MARK: - Timeline edits

func runTimelineWrite(subcommand: String, rest: [String]) {
  guard let idText = rest.first, let recordId = Int(idText) else {
    fail("Usage: dayflow timeline \(subcommand) <record-id>", code: 2)
  }

  switch subcommand {
  case "update":
    var arguments: [String: Any] = ["record_id": recordId]
    if let title = flagValue("--title") { arguments["title"] = title }
    if let category = flagValue("--category") { arguments["category"] = category }
    guard arguments.count > 1 else {
      fail("Nothing to change. Pass --title and/or --category.", code: 2)
    }
    let data = sendOrFail(operation: "activity_update", arguments: arguments)
    reportWrite(data, fallback: "Updated \(recordId)")

  case "delete":
    requireEditsEnabled()
    confirmDestructive(
      "Delete activity \(recordId)? Its underlying observations are removed too — this cannot be fully undone."
    )
    let data = sendOrFail(operation: "activity_delete", arguments: ["record_id": recordId])
    reportWrite(data, fallback: "Deleted \(recordId)")

  default:
    fail("Unknown subcommand \"\(subcommand)\". Use update or delete.", code: 2)
  }
}

// MARK: - Goals

func runGoalSet(dayKey: String?) {
  guard let focusText = flagValue("--focus-minutes"), let focusMinutes = Int(focusText) else {
    fail(
      "Usage: dayflow goal set [YYYY-MM-DD] --focus-minutes <n> "
        + "[--distraction-limit-minutes <n>] [--focus-category <name>]... "
        + "[--distraction-category <name>]...",
      code: 2)
  }

  var arguments: [String: Any] = [
    "date": dayKey ?? dayWindow(containing: Date()).dayKey,
    "focus_minutes": focusMinutes,
  ]
  if let limitText = flagValue("--distraction-limit-minutes"), let limit = Int(limitText) {
    arguments["distraction_limit_minutes"] = limit
  }
  let focusCategories = collectFlagValues("--focus-category", in: arguments0)
  let distractionCategories = collectFlagValues("--distraction-category", in: arguments0)
  if !focusCategories.isEmpty { arguments["focus_categories"] = focusCategories }
  if !distractionCategories.isEmpty {
    arguments["distraction_categories"] = distractionCategories
  }

  let data = sendOrFail(operation: "goal_set", arguments: arguments)
  reportWrite(data, fallback: "Goal saved")
}

// The raw argument list, for repeated-flag collection.
let arguments0 = Array(CommandLine.arguments.dropFirst())

// MARK: - Output

private func reportWrite(_ data: [String: Any], fallback: String) {
  if wantsJSON {
    printJSON(data.isEmpty ? ["ok": true] : data)
  } else {
    let message = data["message"] as? String ?? fallback
    print("✓ \(message)")
  }
}
