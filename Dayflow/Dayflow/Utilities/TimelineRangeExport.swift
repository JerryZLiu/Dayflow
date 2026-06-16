import Foundation

/// Builds the Markdown export for an inclusive range of timeline days.
///
/// Shared by the Settings UI export (`OtherSettingsViewModel.exportTimelineRange`)
/// and the `dayflow://export-timeline` deep link so both surfaces produce identical
/// output from a single source of truth.
enum TimelineRangeExport {
  /// Divider inserted between per-day Markdown sections.
  static let dayDivider = "\n\n---\n\n"

  struct Output {
    let markdown: String
    let dayCount: Int
    let activityCount: Int
  }

  /// Builds the combined Markdown for every day in `startDay...endDay` (inclusive).
  ///
  /// - Parameters:
  ///   - startDay: First timeline day to include. Caller guarantees `startDay <= endDay`.
  ///   - endDay: Last timeline day to include.
  ///   - now: Reference date used by the formatter for relative day labels (e.g. "Today").
  ///   - fetch: Returns the timeline cards for a `yyyy-MM-dd` day string. Defaults to
  ///     `StorageManager.shared`; injectable so the day-iteration logic is unit-testable.
  static func build(
    startDay: Date,
    endDay: Date,
    now: Date = Date(),
    fetch: (String) -> [TimelineCard] = { StorageManager.shared.fetchTimelineCards(forDay: $0) }
  ) -> Output {
    let calendar = Calendar.current

    var cursor = startDay
    var sections: [String] = []
    var totalActivities = 0
    var dayCount = 0

    while cursor <= endDay {
      let dayString = DateFormatter.yyyyMMdd.string(from: cursor)
      let cards = fetch(dayString)
      totalActivities += cards.count
      sections.append(TimelineClipboardFormatter.makeMarkdown(for: cursor, cards: cards, now: now))
      dayCount += 1

      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
      cursor = next
    }

    return Output(
      markdown: sections.joined(separator: dayDivider),
      dayCount: dayCount,
      activityCount: totalActivities
    )
  }
}
