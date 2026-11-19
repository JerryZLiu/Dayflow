//
//  FlowWatchOutage.swift
//  Dayflow
//
//  What happens when Flow's screen checks keep failing mid-session. The agent
//  used to stop for good after a few failed checks, which left the rest of the
//  session "Not watched" with no explanation. Now it waits and tries again
//  (until the provider's usage limit resets, when that was the problem), and
//  remembers each stretch it couldn't watch so the session summary can say why.
//

import Foundation

/// A stretch of a Flow session the agent couldn't watch because its checks failed.
struct FlowWatchOutage: Equatable {
  let kind: TimelineFailureKind
  /// The provider in user-facing words: "ChatGPT", "Claude", "Dayflow Pro".
  let providerName: String
  /// When the first of the failed checks ran.
  let startedAt: Date
  /// When the provider said its usage limit resets, if it said.
  var resetsAt: Date?
  /// When a check worked again. Nil while the outage lasts.
  var endedAt: Date?
}

enum FlowWatchRetry {
  /// Waits before trying again after a run of failed checks, growing with each
  /// run in the same outage. Short at first, since most failures are brief.
  static let failureDelays: [TimeInterval] = [60, 120, 300, 600]
  /// Waits for a usage limit whose reset time the provider didn't give.
  static let usageLimitDelays: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]
  /// Checked a minute after the stated reset, so the provider's clock has passed it too.
  static let afterResetMargin: TimeInterval = 60

  /// When to try the next check, after `round` runs of failures in a row (1 for the first).
  static func nextAttempt(
    kind: TimelineFailureKind, resetsAt: Date?, round: Int, now: Date
  ) -> Date {
    let index = max(0, round - 1)
    if kind == .usageLimitHit {
      if let resetsAt, resetsAt > now { return resetsAt.addingTimeInterval(afterResetMargin) }
      return now.addingTimeInterval(usageLimitDelays[min(index, usageLimitDelays.count - 1)])
    }
    return now.addingTimeInterval(failureDelays[min(index, failureDelays.count - 1)])
  }

  /// Reads the reset time out of an error like Codex's "…or try again at 2:11 PM."
  /// The message gives only a time of day, so one that has already passed today
  /// means tomorrow.
  static func resetTime(in errorText: String, now: Date, calendar: Calendar = .current) -> Date? {
    let pattern = #"(?i)try again at (\d{1,2}):(\d{2})\s*([ap])\.?\s*m"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: errorText, range: NSRange(errorText.startIndex..., in: errorText)),
      let hourRange = Range(match.range(at: 1), in: errorText),
      let minuteRange = Range(match.range(at: 2), in: errorText),
      let meridiemRange = Range(match.range(at: 3), in: errorText),
      var hour = Int(errorText[hourRange]), let minute = Int(errorText[minuteRange]),
      (1...12).contains(hour), (0..<60).contains(minute)
    else { return nil }
    let isPM = errorText[meridiemRange].lowercased() == "p"
    if hour == 12 { hour = 0 }
    if isPM { hour += 12 }
    guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
    else { return nil }
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
  }

  /// The longest outage, which is the one worth explaining.
  static func mainOutage(_ outages: [FlowWatchOutage], sessionEnd: Date) -> FlowWatchOutage? {
    outages.max { length($0, sessionEnd) < length($1, sessionEnd) }
  }

  /// One sentence for the session summary on why Flow couldn't watch part of it.
  static func problemSentence(
    _ outage: FlowWatchOutage, formatter: DateFormatter = timeFormatter()
  ) -> String {
    let from = formatter.string(from: outage.startedAt)
    let until = outage.endedAt.map { "until \(formatter.string(from: $0))" }
    if outage.kind == .usageLimitHit {
      let rest =
        until ?? outage.resetsAt.map { "after that. It resets at \(formatter.string(from: $0))" }
        ?? "after that"
      return
        "You ran out of \(outage.providerName) usage at \(from), so Flow couldn't watch \(rest)."
    }
    return
      "Flow couldn't reach \(outage.providerName) at \(from), so it couldn't watch \(until ?? "after that")."
  }

  /// A few words for the "Not watched" row in the session's timeline.
  static func awayReason(_ outage: FlowWatchOutage) -> String {
    outage.kind == .usageLimitHit
      ? "\(outage.providerName) usage limit reached"
      : "couldn't reach \(outage.providerName)"
  }

  static func timeFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }

  private static func length(_ outage: FlowWatchOutage, _ sessionEnd: Date) -> TimeInterval {
    (outage.endedAt ?? sessionEnd).timeIntervalSince(outage.startedAt)
  }
}
