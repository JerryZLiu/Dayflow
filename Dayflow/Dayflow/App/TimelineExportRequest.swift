import Foundation

/// Parsed, validated parameters for a `dayflow://export-timeline` deep link.
///
/// This is a pure value type: parsing performs no file or database I/O, so it can be
/// unit tested in isolation. The side effects (fetching cards, writing the file) live in
/// `TimelineExportService`.
struct TimelineExportRequest: Equatable {
  /// First timeline day to export (inclusive), normalized to the timeline-day representation (noon).
  let startDay: Date
  /// Last timeline day to export (inclusive).
  let endDay: Date
  /// Raw destination from the URL (`path`/`to`/`destination`), or `nil` for the default location.
  /// Kept verbatim (including a leading `~`); resolved to a concrete URL by `TimelineExportService`.
  let destinationPath: String?
  /// Whether to reveal the exported file in Finder once written.
  let reveal: Bool

  enum ParseError: Error, Equatable {
    case invalidDate(String)
    case startAfterEnd
    case rangeTooLarge
  }

  /// Maximum number of days an export may span (inclusive). Bounds the work a single deep link
  /// can trigger — without it, `start=2000-01-01&end=2030-01-01` would force thousands of
  /// database reads on a background thread.
  static let maxRangeDays = 366

  /// Parses a `dayflow://export-timeline?...` URL into a validated request.
  ///
  /// Recognized query items (keys matched case-insensitively):
  /// - `date`: `today` | `yesterday` | `YYYY-MM-DD` — exports a single day.
  /// - `start` / `end`: same token grammar — inclusive range. Presence of either selects range mode.
  /// - `path` (aliases `to`, `destination`): output file or directory path.
  /// - `reveal`: `true` | `1` | `yes` reveals the file in Finder afterward.
  ///
  /// Precedence: range mode (when `start`/`end` present) > `date` > default (today).
  static func parse(url: URL, now: Date = Date()) -> Result<TimelineExportRequest, ParseError> {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    // Resolve in preference order: the first name with a non-empty value wins, regardless of
    // where it appears in the query string (so `path` beats its `to`/`destination` aliases).
    func value(forAny names: [String]) -> String? {
      for name in names {
        for item in items where item.name.lowercased() == name {
          if let trimmed = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
          {
            return trimmed
          }
        }
      }
      return nil
    }

    let startToken = value(forAny: ["start"])
    let endToken = value(forAny: ["end"])
    let dateToken = value(forAny: ["date"])

    let startDay: Date
    let endDay: Date

    if startToken != nil || endToken != nil {
      // Range mode. A missing side falls back to the other (a single-ended range still works).
      let resolvedStartToken = startToken ?? endToken ?? "today"
      let resolvedEndToken = endToken ?? startToken ?? "today"
      guard let resolvedStart = resolveDay(resolvedStartToken, now: now) else {
        return .failure(.invalidDate(resolvedStartToken))
      }
      guard let resolvedEnd = resolveDay(resolvedEndToken, now: now) else {
        return .failure(.invalidDate(resolvedEndToken))
      }
      startDay = resolvedStart
      endDay = resolvedEnd
    } else if let dateToken {
      guard let resolved = resolveDay(dateToken, now: now) else {
        return .failure(.invalidDate(dateToken))
      }
      startDay = resolved
      endDay = resolved
    } else {
      let today = timelineDisplayDate(from: now, now: now)
      startDay = today
      endDay = today
    }

    guard startDay <= endDay else { return .failure(.startAfterEnd) }

    let span = Calendar.current.dateComponents([.day], from: startDay, to: endDay).day ?? 0
    guard span < maxRangeDays else { return .failure(.rangeTooLarge) }

    return .success(
      TimelineExportRequest(
        startDay: startDay,
        endDay: endDay,
        destinationPath: value(forAny: ["path", "to", "destination"]),
        reveal: parseBool(value(forAny: ["reveal"]))
      ))
  }

  /// Resolves a date token (`today`, `yesterday`, or `YYYY-MM-DD`) to a normalized timeline day.
  /// Returns `nil` for unrecognized or malformed tokens.
  static func resolveDay(_ token: String, now: Date = Date()) -> Date? {
    switch token.lowercased() {
    case "today":
      return timelineDisplayDate(from: now, now: now)
    case "yesterday":
      let today = timelineDisplayDate(from: now, now: now)
      return Calendar.current.date(byAdding: .day, value: -1, to: today)
    default:
      guard let parsed = DateFormatter.yyyyMMdd.date(from: token) else { return nil }
      return normalizedTimelineDate(parsed)
    }
  }

  private static func parseBool(_ value: String?) -> Bool {
    guard let value = value?.lowercased() else { return false }
    return ["true", "1", "yes"].contains(value)
  }
}
