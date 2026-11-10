import Foundation

/// Builds the plain-text and Markdown exports of the timeline. Labels, headings
/// and dates are localized; card titles, summaries and the stored "h:mm a" card
/// times are copied through exactly as stored.
struct TimelineClipboardFormatter {
  static func makeClipboardText(for date: Date, cards: [TimelineCard], now: Date = Date()) -> String
  {
    let timelineDate = timelineDisplayDate(from: date, now: now)
    let header = exportHeader(formattedTimelineDay(timelineDate, now: now))

    guard !cards.isEmpty else {
      return [header, String(localized: "No timeline activities were recorded for this day.")]
        .joined(separator: "\n\n")
    }

    let entries = cards.enumerated().map { index, card in
      textEntry(for: card, index: index)
    }

    return ([header, ""] + entries).joined(separator: "\n\n")
  }

  static func makeClipboardText(
    for weekRange: TimelineWeekRange,
    cards: [TimelineCard],
    now: Date = Date()
  ) -> String {
    let header = exportHeader(weekRange.title)

    guard !cards.isEmpty else {
      return [header, String(localized: "No timeline activities were recorded for this week.")]
        .joined(separator: "\n\n")
    }

    let cardsByDay = Dictionary(grouping: cards, by: \.day)
    let sections = weekRange.days.compactMap { day -> String? in
      guard let dayCards = cardsByDay[day.dayString], !dayCards.isEmpty else { return nil }

      let sortedCards = dayCards.sorted(by: cardSort)
      let heading = formattedTimelineDay(day.date, now: now)
      let entries = sortedCards.enumerated().map { index, card in
        textEntry(for: card, index: index)
      }

      return ([heading, ""] + entries).joined(separator: "\n\n")
    }

    return ([header, ""] + sections).joined(separator: "\n\n")
  }

  static func makeMarkdown(for date: Date, cards: [TimelineCard], now: Date = Date()) -> String {
    let timelineDate = timelineDisplayDate(from: date, now: now)
    let header = "## " + exportHeader(formattedTimelineDay(timelineDate, now: now))

    guard !cards.isEmpty else {
      let emptyMessage = String(localized: "No timeline activities were recorded for this day.")
      return [header, "_\(emptyMessage)_"].joined(separator: "\n\n")
    }

    let summaryLabel = String(localized: "Summary")
    let detailsLabel = String(localized: "Details")

    let entries = cards.enumerated().map { index, card -> String in
      var lines: [String] = []

      let timeRange = formattedRange(start: card.startTimestamp, end: card.endTimestamp)
      let titleText = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let bulletTitle = timeRange.isEmpty ? titleText : "\(timeRange): \(titleText)"
      lines.append("\(index + 1). **\(bulletTitle)**")

      let metaParts = metadataParts(for: card)
      if !metaParts.isEmpty {
        lines.append("   - _\(metaParts.joined(separator: " • "))_")
      }

      if let summary = cleanedParagraph(card.summary) {
        let summaryLines = normalizedLines(summary)
        if summaryLines.count == 1 {
          lines.append("   - \(summaryLabel): \(summaryLines[0])")
        } else {
          lines.append("   - \(summaryLabel):")
          summaryLines.forEach { lines.append("      \($0)") }
        }
      }

      if let details = cleanedParagraph(card.detailedSummary),
        details != cleanedParagraph(card.summary)
      {
        let detailLines = normalizedLines(details)
        if detailLines.count == 1 {
          lines.append("   - \(detailsLabel): \(detailLines[0])")
        } else {
          lines.append("   - \(detailsLabel):")
          detailLines.forEach { lines.append("      \($0)") }
        }
      }

      return lines.joined(separator: "\n")
    }

    return ([header, ""] + entries).joined(separator: "\n\n")
  }

  /// "Dayflow timeline · <day or week>" in the current language.
  private static func exportHeader(_ period: String) -> String {
    String(
      localized: "Dayflow timeline · \(period)",
      comment:
        "First line of the copied/exported timeline. The argument is a formatted day or week range."
    )
  }

  private static func formattedRange(start: String, end: String) -> String {
    let trimmedStart = start.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEnd = end.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedStart.isEmpty && trimmedEnd.isEmpty { return "" }
    if trimmedEnd.isEmpty { return trimmedStart }
    if trimmedStart.isEmpty { return trimmedEnd }
    return "\(trimmedStart) – \(trimmedEnd)"
  }

  private static func metadataParts(for card: TimelineCard) -> [String] {
    var parts: [String] = []
    let category = card.category.trimmingCharacters(in: .whitespacesAndNewlines)
    if !category.isEmpty {
      parts.append(category)
    }
    return parts
  }

  private static func block(label: String, text: String) -> String {
    let lines = normalizedLines(text)
    guard !lines.isEmpty else { return "" }
    if lines.count == 1 {
      return "   \(label): \(lines[0])"
    } else {
      var blockLines: [String] = ["   \(label):"]
      for line in lines {
        blockLines.append("      \(line)")
      }
      return blockLines.joined(separator: "\n")
    }
  }

  private static func cleanedParagraph(_ value: String?) -> String? {
    guard let value = value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lines = normalizedLines(trimmed)
    guard !lines.isEmpty else { return nil }
    return lines.joined(separator: "\n")
  }

  private static func normalizedLines(_ text: String) -> [String] {
    return
      text
      .components(separatedBy: CharacterSet.newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Abbreviated month and day, e.g. "Sep 11" / "11. Sept." / "9月11日".
  private static let todayDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  /// Full weekday plus abbreviated month and day, e.g. "Thursday, Sep 11".
  private static let otherDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
    return formatter
  }()

  private static func formattedTimelineDay(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    let timelineToday = timelineDisplayDate(from: now, now: now)

    if calendar.isDate(date, inSameDayAs: timelineToday) {
      return String(localized: "Today, \(todayDayFormatter.string(from: date))")
    }
    return otherDayFormatter.string(from: date)
  }

  private static func textEntry(for card: TimelineCard, index: Int) -> String {
    var lines: [String] = []

    let timeRange = formattedRange(start: card.startTimestamp, end: card.endTimestamp)
    let titleText = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let bullet = "\(index + 1). \(timeRange.isEmpty ? "" : "\(timeRange): ")\(titleText)"
    lines.append(bullet.trimmingCharacters(in: .whitespaces))

    let metaParts = metadataParts(for: card)
    if !metaParts.isEmpty {
      lines.append("   " + metaParts.joined(separator: " • "))
    }

    if let summary = cleanedParagraph(card.summary) {
      lines.append(block(label: String(localized: "Summary"), text: summary))
    }

    if let details = cleanedParagraph(card.detailedSummary),
      details != cleanedParagraph(card.summary)
    {
      lines.append(block(label: String(localized: "Details"), text: details))
    }

    return lines.joined(separator: "\n")
  }

  private static func cardSort(lhs: TimelineCard, rhs: TimelineCard) -> Bool {
    if lhs.day != rhs.day {
      return lhs.day < rhs.day
    }
    if let leftDate = sortDate(for: lhs), let rightDate = sortDate(for: rhs), leftDate != rightDate
    {
      return leftDate < rightDate
    }
    return lhs.title < rhs.title
  }

  private static func sortDate(for card: TimelineCard) -> Date? {
    guard
      let dayDate = DateFormatter.yyyyMMdd.date(from: card.day),
      let parsedStart = timeFormatter.date(from: card.startTimestamp)
    else {
      return nil
    }

    let calendar = Calendar.current
    let components = calendar.dateComponents([.hour, .minute], from: parsedStart)
    return calendar.date(
      bySettingHour: components.hour ?? 0,
      minute: components.minute ?? 0,
      second: 0,
      of: dayDate
    )
  }

  /// Parser for the stored English "h:mm a" card times. Not a display formatter.
  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()
}
