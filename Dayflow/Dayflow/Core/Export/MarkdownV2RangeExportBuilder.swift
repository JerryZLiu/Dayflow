import Foundation

enum MarkdownV2RangeExportBuilder {
  static func makeMarkdown(start: Date, end: Date, cardsByDay: [(day: Date, cards: [TimelineCard])])
    -> String
  {
    let allCards = cardsByDay.flatMap(\.cards)
    let startDay = DateFormatter.yyyyMMdd.string(from: start)
    let endDay = DateFormatter.yyyyMMdd.string(from: end)

    var lines: [String] = []
    appendFrontmatter(
      startDay: startDay,
      endDay: endDay,
      cardCount: allCards.count,
      to: &lines
    )

    lines.append("# Dayflow timeline")
    lines.append("")
    lines.append("Range: \(startDay) to \(endDay)")
    lines.append("Activities: \(allCards.count)")
    lines.append("")

    appendRangeSummary(cards: allCards, to: &lines)
    appendWeeklyRollupIfNeeded(cardsByDay: cardsByDay, to: &lines)

    lines.append("## Daily timeline")
    lines.append("")
    for entry in cardsByDay {
      appendDay(entry.day, cards: entry.cards, to: &lines)
    }

    return normalizedMarkdown(lines)
  }

  private static func appendFrontmatter(
    startDay: String,
    endDay: String,
    cardCount: Int,
    to lines: inout [String]
  ) {
    lines.append("---")
    lines.append("title: \"Dayflow timeline \(startDay) to \(endDay)\"")
    lines.append("source: dayflow")
    lines.append("export_kind: timeline_range")
    lines.append("export_version: 2")
    lines.append("start_date: \(startDay)")
    lines.append("end_date: \(endDay)")
    lines.append("card_count: \(cardCount)")
    lines.append("suggested_folder: dayflow/\(startDay)-to-\(endDay)")
    lines.append("---")
    lines.append("")
  }

  private static func appendRangeSummary(cards: [TimelineCard], to lines: inout [String]) {
    lines.append("## Range summary")
    lines.append("")

    guard !cards.isEmpty else {
      lines.append("- No timeline activities were recorded for this range.")
      lines.append("")
      return
    }

    lines.append("- Total activity cards: \(cards.count)")
    lines.append("- Estimated tracked time: \(durationText(totalMinutes(cards)))")

    let categoryTotals = groupedMinutes(cards) { clean($0.category, fallback: "Uncategorized") }
    if let topCategory = categoryTotals.first {
      lines.append("- Top category: \(topCategory.name) (\(durationText(topCategory.minutes)))")
    }

    let appTotals = groupedMinutes(cards) { appSitesText($0.appSites) ?? "Unknown app/site" }
    if let topApp = appTotals.first {
      lines.append("- Top app/site: \(topApp.name) (\(durationText(topApp.minutes)))")
    }
    lines.append("")

    appendGroupedSection(title: "Category rollup", totals: categoryTotals, to: &lines)
    appendGroupedSection(title: "App/site rollup", totals: appTotals, to: &lines)
  }

  private static func appendWeeklyRollupIfNeeded(
    cardsByDay: [(day: Date, cards: [TimelineCard])],
    to lines: inout [String]
  ) {
    guard cardsByDay.count >= 5 else { return }

    lines.append("## Weekly rollup")
    lines.append("")

    for entry in cardsByDay {
      let dayString = DateFormatter.yyyyMMdd.string(from: entry.day)
      let minutes = totalMinutes(entry.cards)
      lines.append("- \(dayString): \(durationText(minutes)) across \(entry.cards.count) card\(entry.cards.count == 1 ? "" : "s")")
    }
    lines.append("")
  }

  private static func appendGroupedSection(
    title: String,
    totals: [(name: String, minutes: Int, cardCount: Int)],
    to lines: inout [String]
  ) {
    lines.append("## \(title)")
    lines.append("")

    guard !totals.isEmpty else {
      lines.append("- No data found.")
      lines.append("")
      return
    }

    for total in totals.prefix(12) {
      lines.append("- #\(tagSlug(total.name)) \(total.name): \(durationText(total.minutes)) across \(total.cardCount) card\(total.cardCount == 1 ? "" : "s")")
    }
    lines.append("")
  }

  private static func appendDay(_ day: Date, cards: [TimelineCard], to lines: inout [String]) {
    let dayString = DateFormatter.yyyyMMdd.string(from: day)
    lines.append("### \(dayString)")
    lines.append("")

    guard !cards.isEmpty else {
      lines.append("_No timeline activities were recorded for this day._")
      lines.append("")
      return
    }

    for card in cards.sorted(by: cardSort) {
      let title = clean(card.title, fallback: "Untitled activity")
      let timeRange = [card.startTimestamp, card.endTimestamp]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " - ")
      lines.append("#### \(timeRange.isEmpty ? title : "\(timeRange) - \(title)")")
      lines.append("")

      let tags = tags(for: card)
      if !tags.isEmpty {
        lines.append("Tags: \(tags.map { "#\(tagSlug($0))" }.joined(separator: " "))")
      }
      lines.append("- Category: \(clean(card.category, fallback: "Uncategorized"))")
      if let subcategory = optional(card.subcategory) {
        lines.append("- Subcategory: \(subcategory)")
      }
      if let appSites = appSitesText(card.appSites) {
        lines.append("- Apps/sites: \(appSites)")
      }
      if let video = optional(card.videoSummaryURL) {
        lines.append("- Timelapse: `\(video)`")
      }
      if let otherVideos = card.otherVideoSummaryURLs?.compactMap(optional), !otherVideos.isEmpty {
        lines.append("- Additional timelapses: \(otherVideos.map { "`\($0)`" }.joined(separator: ", "))")
      }
      lines.append("")

      if let summary = optional(card.summary) {
        lines.append(summary)
        lines.append("")
      }
      if let details = optional(card.detailedSummary), details != optional(card.summary) {
        lines.append(details)
        lines.append("")
      }
    }
  }

  private static func groupedMinutes(
    _ cards: [TimelineCard],
    by key: (TimelineCard) -> String
  ) -> [(name: String, minutes: Int, cardCount: Int)] {
    var totals: [String: (minutes: Int, cardCount: Int)] = [:]
    for card in cards {
      let name = clean(key(card), fallback: "Unknown")
      let current = totals[name] ?? (minutes: 0, cardCount: 0)
      totals[name] = (
        minutes: current.minutes + estimatedMinutes(for: card),
        cardCount: current.cardCount + 1
      )
    }

    return totals
      .map { (name: $0.key, minutes: $0.value.minutes, cardCount: $0.value.cardCount) }
      .sorted {
        if $0.minutes == $1.minutes { return $0.name < $1.name }
        return $0.minutes > $1.minutes
      }
  }

  private static func totalMinutes(_ cards: [TimelineCard]) -> Int {
    cards.map(estimatedMinutes).reduce(0, +)
  }

  private static func estimatedMinutes(for card: TimelineCard) -> Int {
    guard
      let start = timelineTimeDate(card.startTimestamp, day: card.day),
      let end = timelineTimeDate(card.endTimestamp, day: card.day)
    else {
      return 0
    }

    let adjustedEnd = end >= start ? end : end.addingTimeInterval(24 * 60 * 60)
    return Int(max(1, (adjustedEnd.timeIntervalSince(start) / 60).rounded()))
  }

  private static func timelineTimeDate(_ time: String, day: String) -> Date? {
    let cleaned = time.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }

    for formatter in timelineTimeFormatters {
      if let timeDate = formatter.date(from: cleaned),
        let dayDate = DateFormatter.yyyyMMdd.date(from: day)
      {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: timeDate)
        return calendar.date(
          bySettingHour: timeComponents.hour ?? 0,
          minute: timeComponents.minute ?? 0,
          second: timeComponents.second ?? 0,
          of: dayDate
        )
      }
    }

    return nil
  }

  private static let timelineTimeFormatters: [DateFormatter] = {
    ["HH:mm:ss", "HH:mm", "h:mm a", "h:mm:ss a"].map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = format
      return formatter
    }
  }()

  private static func tags(for card: TimelineCard) -> [String] {
    var tags: [String] = []
    if let category = optional(card.category) {
      tags.append(category)
    }
    if let subcategory = optional(card.subcategory) {
      tags.append(subcategory)
    }
    if let primary = optional(card.appSites?.primary) {
      tags.append(primary)
    }
    return Array(Set(tags)).sorted()
  }

  private static func appSitesText(_ appSites: AppSites?) -> String? {
    guard let appSites else { return nil }
    return [appSites.primary, appSites.secondary]
      .compactMap(optional)
      .joined(separator: ", ")
      .nilIfEmpty
  }

  private static func cardSort(_ lhs: TimelineCard, _ rhs: TimelineCard) -> Bool {
    if lhs.day != rhs.day { return lhs.day < rhs.day }
    return lhs.startTimestamp < rhs.startTimestamp
  }

  private static func optional(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func clean(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func tagSlug(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
  }

  private static func normalizedMarkdown(_ lines: [String]) -> String {
    lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  private static func durationText(_ minutes: Int) -> String {
    let safeMinutes = max(0, minutes)
    if safeMinutes < 60 { return "\(safeMinutes)m" }
    let hours = safeMinutes / 60
    let remainder = safeMinutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
