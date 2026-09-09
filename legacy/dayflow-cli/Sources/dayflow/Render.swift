//
//  Render.swift
//  dayflow-cli
//
//  Human output. Data goes to stdout, diagnostics to stderr. ANSI styling only
//  when stdout is a real terminal, so piped output stays clean.
//

import Foundation

let stdoutIsTTY = isatty(1) == 1

enum Style {
  static var bold: String { stdoutIsTTY ? "\u{1B}[1m" : "" }
  static var dim: String { stdoutIsTTY ? "\u{1B}[2m" : "" }
  static var reset: String { stdoutIsTTY ? "\u{1B}[0m" : "" }
}

let clockFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  formatter.locale = Locale(identifier: "en_US_POSIX")
  return formatter
}()

let headerDayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "EEEE, MMMM d"
  return formatter
}()

func fail(_ message: String, code: Int32) -> Never {
  AgentUsageTelemetry.finishCLI(
    outcome: "failure",
    failureCategory: AgentUsageTelemetry.failureCategory(forExitCode: code)
  )
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

// MARK: - Timeline

func renderTimeline(_ activities: [Activity], window: DayWindow, detail: TimelineDetail) {
  guard !activities.isEmpty else {
    print("No activities recorded for \(window.dayKey).")
    return
  }

  let tracked = activities.reduce(0) { $0 + $1.durationMinutes }
  let title = headerDayFormatter.string(from: window.start)
  print(
    "\(Style.bold)\(title)\(Style.reset)  \(Style.dim)\(formatDuration(minutes: tracked)) tracked\(Style.reset)"
  )
  print("")

  let idWidth = activities.map { String($0.recordId).count }.max() ?? 4
  for activity in activities {
    let id = String(activity.recordId).padding(toLength: idWidth, withPad: " ", startingAt: 0)
    let start = clockFormatter.string(from: activity.start)
    let end = clockFormatter.string(from: activity.end)
    let time = "\(start) – \(end)".padding(toLength: 20, withPad: " ", startingAt: 0)

    switch detail {
    case .compact:
      let name = activity.title.padded(to: 44)
      print("  \(Style.dim)\(id)\(Style.reset)  \(time)  \(name)  \(activity.category)")
    case .summary, .detailed:
      print(
        "  \(Style.dim)\(id)\(Style.reset)  \(time)  \(Style.bold)\(activity.title)\(Style.reset)  \(Style.dim)\(activity.category)\(Style.reset)"
      )
      let body =
        detail == .detailed && !activity.detailedSummary.isEmpty
        ? activity.detailedSummary
        : activity.summary
      for line in wrap(body, width: 68) {
        print("  \(String(repeating: " ", count: idWidth))  \(line)")
      }
      print("")
    }
  }

  if detail == .compact {
    print("")
    printCategoryTotals(activities)
    print("")
    print(
      "  \(Style.dim)\(activities.count) activities · dayflow timeline --summary for descriptions\(Style.reset)"
    )
  }
}

enum TimelineDetail {
  case compact, summary, detailed
}

func printCategoryTotals(_ activities: [Activity]) {
  var totals: [String: Int] = [:]
  for activity in activities {
    totals[activity.category, default: 0] += activity.durationMinutes
  }
  let parts = totals.sorted { $0.value > $1.value }
    .map { "\($0.key) \(formatDuration(minutes: $0.value))" }
  print("  " + parts.joined(separator: " · "))
}

// MARK: - Single card

func renderCard(_ activity: Activity) {
  let day = headerDayFormatter.string(from: activity.start)
  let start = clockFormatter.string(from: activity.start)
  let end = clockFormatter.string(from: activity.end)

  print("\(Style.bold)\(activity.title)\(Style.reset)")
  var context = "\(day) · \(start) – \(end) · \(formatDuration(minutes: activity.durationMinutes))"
  print("\(Style.dim)\(context)\(Style.reset)")

  context = activity.category
  if !activity.subcategory.isEmpty { context += " › \(activity.subcategory)" }
  if !activity.apps.isEmpty { context += " · " + activity.apps.joined(separator: ", ") }
  print("\(Style.dim)\(context)\(Style.reset)")
  print("")

  if !activity.summary.isEmpty {
    for line in wrap(activity.summary, width: 72) { print(line) }
    print("")
  }
  if !activity.detailedSummary.isEmpty {
    for line in wrap(activity.detailedSummary, width: 72) { print(line) }
  }
}

// MARK: - Weekly

func renderWeekly(_ activities: [Activity], window: WeekWindow) {
  let rangeFormatter = DateFormatter()
  rangeFormatter.dateFormat = "EEE MMM d"
  let displayEnd = Calendar.current.date(byAdding: .day, value: 6, to: window.start)!
  let header =
    "\(rangeFormatter.string(from: window.start)) – \(rangeFormatter.string(from: displayEnd))"

  var totals: [String: Int] = [:]
  for activity in activities where activity.category != "System" {
    totals[activity.category, default: 0] += activity.durationMinutes
  }
  let tracked = totals.values.reduce(0, +)
  let focus = totals.filter { $0.key != "Idle" }.values.reduce(0, +)

  print(
    "\(Style.bold)\(header)\(Style.reset)  \(Style.dim)Tracked \(formatDuration(minutes: tracked)) · Focus \(formatDuration(minutes: focus))\(Style.reset)"
  )
  print("")

  guard tracked > 0 else {
    print("  Nothing recorded this week.")
    return
  }

  let sorted = totals.sorted { $0.value > $1.value }
  let nameWidth = sorted.map { $0.key.count }.max() ?? 10
  let maxMinutes = sorted.first?.value ?? 1
  for (name, minutes) in sorted {
    let bar = String(repeating: "█", count: max(1, minutes * 20 / maxMinutes))
    let percent = minutes * 100 / tracked
    let paddedName = name.padded(to: nameWidth)
    let duration = formatDuration(minutes: minutes).padded(to: 8)
    print("  \(paddedName)  \(duration)  \(Style.dim)\(bar)\(Style.reset)  \(percent)%")
  }
}

// MARK: - Helpers

extension String {
  func padded(to width: Int) -> String {
    count >= width ? self : self + String(repeating: " ", count: width - count)
  }
}

func wrap(_ text: String, width: Int) -> [String] {
  var lines: [String] = []
  for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
    var current = ""
    for word in paragraph.split(separator: " ") {
      if current.isEmpty {
        current = String(word)
      } else if current.count + 1 + word.count <= width {
        current += " \(word)"
      } else {
        lines.append(current)
        current = String(word)
      }
    }
    lines.append(current)
  }
  return lines
}
