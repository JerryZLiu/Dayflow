import Foundation

struct TimelineClipboardFormatter {
  static func makeClipboardText(for date: Date, cards: [TimelineCard], now: Date = Date()) -> String
  {
    let timelineDate = timelineDisplayDate(from: date, now: now)
    let header = "Dayflow timeline · \(formattedTimelineDay(timelineDate, now: now))"

    guard !cards.isEmpty else {
      return """
        \(header)

        No timeline activities were recorded for this day.
        """
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
    let header = "Dayflow timeline · \(weekRange.title)"

    guard !cards.isEmpty else {
      return """
        \(header)

        No timeline activities were recorded for this week.
        """
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
    let header = "## Dayflow timeline · \(formattedTimelineDay(timelineDate, now: now))"

    guard !cards.isEmpty else {
      return """
        \(header)

        _No timeline activities were recorded for this day._
        """
    }

    let entries = cards.enumerated().map { index, card -> String in
      var lines: [String] = []

      let timeRange = formattedRange(start: card.startTimestamp, end: card.endTimestamp)
      let titleText = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let bulletTitle = timeRange.isEmpty ? titleText : "\(timeRange) — \(titleText)"
      lines.append("\(index + 1). **\(bulletTitle)**")

      let metaParts = metadataParts(for: card)
      if !metaParts.isEmpty {
        lines.append("   - _\(metaParts.joined(separator: " • "))_")
      }

      if let summary = cleanedParagraph(card.summary) {
        let summaryLines = normalizedLines(summary)
        if summaryLines.count == 1 {
          lines.append("   - Summary: \(summaryLines[0])")
        } else {
          lines.append("   - Summary:")
          summaryLines.forEach { lines.append("      \($0)") }
        }
      }

      if let details = cleanedParagraph(card.detailedSummary),
        details != cleanedParagraph(card.summary)
      {
        let detailLines = normalizedLines(details)
        if detailLines.count == 1 {
          lines.append("   - Details: \(detailLines[0])")
        } else {
          lines.append("   - Details:")
          detailLines.forEach { lines.append("      \($0)") }
        }
      }

      return lines.joined(separator: "\n")
    }

    return ([header, ""] + entries).joined(separator: "\n\n")
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

  private static func formattedTimelineDay(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    let timelineToday = timelineDisplayDate(from: now, now: now)
    let formatter = DateFormatter()

    if calendar.isDate(date, inSameDayAs: timelineToday) {
      formatter.dateFormat = "'Today,' MMM d"
    } else {
      formatter.dateFormat = "EEEE, MMM d"
    }

    return formatter.string(from: date)
  }

  private static func textEntry(for card: TimelineCard, index: Int) -> String {
    var lines: [String] = []

    let timeRange = formattedRange(start: card.startTimestamp, end: card.endTimestamp)
    let titleText = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let bullet = "\(index + 1). \(timeRange.isEmpty ? "" : "\(timeRange) — ")\(titleText)"
    lines.append(bullet.trimmingCharacters(in: .whitespaces))

    let metaParts = metadataParts(for: card)
    if !metaParts.isEmpty {
      lines.append("   " + metaParts.joined(separator: " • "))
    }

    if let summary = cleanedParagraph(card.summary) {
      lines.append(block(label: "Summary", text: summary))
    }

    if let details = cleanedParagraph(card.detailedSummary),
      details != cleanedParagraph(card.summary)
    {
      lines.append(block(label: "Details", text: details))
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

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()
}
