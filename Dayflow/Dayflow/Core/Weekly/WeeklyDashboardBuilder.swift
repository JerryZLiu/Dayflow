import AppKit
import Foundation
import SwiftUI

enum WeeklyDashboardBuilder {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }()

  static let otherKey = "other"
  static let otherColorHex = "BFB6AE"

  static func build(
    cards: [TimelineCard],
    previousWeekCards: [TimelineCard],
    categories: [TimelineCategory],
    weekRange: WeeklyDateRange
  ) -> WeeklyDashboardSnapshot {
    let categoryLookup = firstCategoryLookup(
      from: categories.sorted { $0.order < $1.order },
      normalizedKey: normalizedKey
    )
    let facts = cardFacts(from: cards, categories: categoryLookup, weekRange: weekRange)
    let previousFacts = cardFacts(
      from: previousWeekCards,
      categories: categoryLookup,
      weekRange: weekRange.shifted(byWeeks: -1)
    )

    return WeeklyDashboardSnapshot(
      donut: WeeklyDonutBuilder.build(cards: cards, categories: categories, weekRange: weekRange),
      overview: WeeklyOverviewBuilder.build(
        cards: cards, categories: categories, weekRange: weekRange),
      treemap: buildTreemap(from: facts, previousFacts: previousFacts),
      sankey: buildSankey(from: facts, weekRange: weekRange),
      workflow: buildWorkflow(from: facts, weekRange: weekRange),
      heatmap: buildHeatmap(from: facts, weekRange: weekRange),
      contextCharts: buildContextCharts(from: facts, weekRange: weekRange),
      applicationInteractions: buildApplicationInteractions(from: facts)
    )
  }

  private static func cardFacts(
    from cards: [TimelineCard],
    categories: [String: TimelineCategory],
    weekRange: WeeklyDateRange
  ) -> [WeeklyCardFact] {
    let dayLookup = Dictionary(
      uniqueKeysWithValues: dayDescriptors(for: weekRange, offsets: Array(0..<7))
        .map { ($0.dayString, $0) }
    )

    return cards.compactMap { card -> WeeklyCardFact? in
      guard let startMinute = parseCardMinute(card.startTimestamp),
        let endMinute = parseCardMinute(card.endTimestamp)
      else {
        return nil
      }

      let normalizedRange = normalizedMinuteRange(start: startMinute, end: endMinute)
      let durationMinutes = max(Int((normalizedRange.end - normalizedRange.start).rounded()), 0)
      guard durationMinutes > 0 else { return nil }

      let categoryName = displayName(card.category, fallback: "Uncategorized")
      let categoryKey = normalizedKey(categoryName)
      let category = categories[categoryKey]
      let app = appIdentity(for: card)
      let faviconPrimaryRaw = card.appSites?.primary
      let faviconSecondaryRaw = card.appSites?.secondary
      let day = dayLookup[card.day]
      let isSystem = category?.isSystem == true || categoryKey == "system"
      let isIdle = category?.isIdle == true || categoryKey == "idle"
      let isDistraction = isDistractionCard(card, categoryName: categoryName)

      return WeeklyCardFact(
        id: stableCardID(card),
        card: card,
        dayString: card.day,
        dayLabel: day?.label ?? "",
        dayOrder: day?.order ?? Int.max,
        startMinute: normalizedRange.start,
        endMinute: normalizedRange.end,
        durationMinutes: durationMinutes,
        categoryKey: categoryKey,
        categoryName: category?.name ?? categoryName,
        categoryColorHex: normalizedColorHex(
          category?.colorHex ?? fallbackColorHex(for: categoryKey)),
        isSystem: isSystem,
        isIdle: isIdle,
        isDistraction: isDistraction,
        appKey: app.key,
        appName: app.name,
        appColorHex: app.colorHex,
        faviconPrimaryRaw: faviconPrimaryRaw,
        faviconSecondaryRaw: faviconSecondaryRaw,
        faviconPrimaryHost: FaviconService.normalizedHost(from: faviconPrimaryRaw),
        faviconSecondaryHost: FaviconService.normalizedHost(from: faviconSecondaryRaw),
        appKind: appKind(for: app.name, categoryName: categoryName, isDistraction: isDistraction)
      )
    }
    .sorted {
      if $0.dayOrder == $1.dayOrder {
        return $0.startMinute < $1.startMinute
      }
      return $0.dayOrder < $1.dayOrder
    }
  }

  private static func buildHighlights(from facts: [WeeklyCardFact]) -> WeeklyHighlightsSnapshot {
    let highlights =
      facts
      .filter { !$0.isSystem && !$0.isIdle }
      .sorted(by: factDurationSort)
      .prefix(3)
      .map { fact in
        WeeklyHighlight(
          id: "highlight-\(fact.id)",
          tag: shortened(fact.categoryName.uppercased(), maxLength: 18),
          text: cardNarrative(for: fact.card, maxLength: 170)
        )
      }

    return WeeklyHighlightsSnapshot(highlights: Array(highlights))
  }

  private static func buildSuggestions(from facts: [WeeklyCardFact]) -> WeeklySuggestionsSnapshot {
    let workFacts = facts.filter { !$0.isSystem && !$0.isIdle }
    let groupedByCategory = Dictionary(grouping: workFacts, by: \.categoryKey)

    let topLevelUpdates = groupedByCategory.values
      .map { facts in
        let minutes = facts.reduce(0) { $0 + $1.durationMinutes }
        let representative = facts.sorted(by: factDurationSort).first
        return WeeklyCategoryAggregate(
          key: facts.first?.categoryKey ?? otherKey,
          name: facts.first?.categoryName ?? "Work",
          minutes: minutes,
          count: facts.count,
          representative: representative
        )
      }
      .sorted {
        if $0.minutes == $1.minutes {
          return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return $0.minutes > $1.minutes
      }
      .prefix(4)
      .map { aggregate in
        WeeklySuggestionEntry(
          id: "top-level-\(aggregate.key)",
          label: aggregate.name,
          detail: topLevelDetail(for: aggregate)
        )
      }

    let nextSteps =
      workFacts
      .sorted(by: factDurationSort)
      .prefix(3)
      .map { fact in
        WeeklySuggestionEntry(
          id: "next-step-\(fact.id)",
          label: fact.categoryName,
          detail:
            "Pick up from \(shortTitle(fact.card.title)): \(cardNarrative(for: fact.card, maxLength: 120))"
        )
      }

    return WeeklySuggestionsSnapshot(
      title: "1:1 suggestions",
      topLevelUpdatesTitle: "Top level updates",
      topLevelUpdates: Array(topLevelUpdates),
      nextStepsTitle: "Next steps",
      nextSteps: Array(nextSteps)
    )
  }

  private static func appKind(
    for appName: String,
    categoryName: String,
    isDistraction: Bool
  ) -> WeeklyApplicationKind {
    if isDistraction {
      return .distraction
    }

    let text = "\(appName) \(categoryName)".lowercased()
    if ["youtube", "reddit", "x", "twitter", "tiktok", "netflix", "game"].contains(
      where: text.contains)
    {
      return .distraction
    }
    if ["personal", "shopping", "maps", "messages", "photos", "music"].contains(
      where: text.contains)
    {
      return .personal
    }
    return .work
  }

  private static func appIdentity(for card: TimelineCard) -> WeeklyAppIdentity {
    let rawApp = [card.appSites?.primary, card.appSites?.secondary]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }

    let name = prettyAppName(from: rawApp, fallbackText: "\(card.title) \(card.summary)")
    let key = normalizedKey(name)
    return WeeklyAppIdentity(
      key: key.isEmpty ? otherKey : key,
      name: name,
      colorHex: appColorHex(for: name)
    )
  }

  private static func prettyAppName(from rawValue: String?, fallbackText: String) -> String {
    let source =
      rawValue.flatMap { value -> String? in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      } ?? fallbackAppName(from: fallbackText)

    let lowercased = source.lowercased()
    let mappings: [(needle: String, name: String)] = [
      ("chatgpt", "ChatGPT"),
      ("claude", "Claude"),
      ("codex", "Codex"),
      ("cursor", "Cursor"),
      ("xcode", "Xcode"),
      ("dayflow", "Dayflow"),
      ("figma", "Figma"),
      ("slack", "Slack"),
      ("zoom", "Zoom"),
      ("meet.google", "Meet"),
      ("google meet", "Meet"),
      ("youtube", "YouTube"),
      ("reddit", "Reddit"),
      ("twitter", "X"),
      ("x.com", "X"),
      ("substack", "Substack"),
      ("notion", "Notion"),
      ("linear", "Linear"),
      ("github", "GitHub"),
      ("safari", "Safari"),
      ("chrome", "Chrome"),
      ("calendar", "Calendar"),
      ("mail", "Mail"),
      ("messages", "Messages"),
      ("maps", "Maps"),
      ("clickup", "ClickUp"),
      ("runway", "Runway"),
      ("flora", "Flora"),
    ]

    if let match = mappings.first(where: { lowercased.contains($0.needle) }) {
      return match.name
    }

    let firstPart =
      source
      .split(whereSeparator: { [",", ";", "|", "\n"].contains(String($0)) })
      .first
      .map(String.init) ?? source
    let cleaned =
      firstPart
      .replacingOccurrences(of: "https://", with: "")
      .replacingOccurrences(of: "http://", with: "")
      .replacingOccurrences(of: "www.", with: "")
      .replacingOccurrences(of: "com.apple.", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if cleaned.contains("."), !cleaned.contains(" ") {
      let domainParts = cleaned.split(separator: ".")
      if let first = domainParts.first {
        return titleCase(String(first))
      }
    }

    return titleCase(cleaned.isEmpty ? "Other" : cleaned)
  }

  private static func fallbackAppName(from text: String) -> String {
    let lowercased = text.lowercased()
    let candidates = [
      "ChatGPT", "Claude", "Codex", "Cursor", "Xcode", "Dayflow", "Figma", "Slack", "Zoom",
      "YouTube", "Reddit", "Substack", "Notion", "Linear", "GitHub", "Safari", "Chrome",
      "Calendar", "Mail", "Messages",
    ]
    return candidates.first { lowercased.contains($0.lowercased()) } ?? "Other"
  }

  private static func appColorHex(for appName: String) -> String {
    let lowercased = appName.lowercased()
    let mappings: [(needle: String, color: String)] = [
      ("chatgpt", "333333"),
      ("claude", "D97757"),
      ("codex", "111111"),
      ("cursor", "111111"),
      ("xcode", "4085FD"),
      ("dayflow", "FF7A2F"),
      ("figma", "FF7262"),
      ("slack", "36C5F0"),
      ("zoom", "4085FD"),
      ("meet", "34A853"),
      ("youtube", "FF0000"),
      ("reddit", "FF613C"),
      ("x", "111111"),
      ("substack", "FF6E3E"),
      ("notion", "111111"),
      ("linear", "5E6AD2"),
      ("github", "24292F"),
      ("safari", "2E8BFF"),
      ("chrome", "4285F4"),
      ("calendar", "A29993"),
      ("mail", "4F8EF7"),
      ("messages", "38D06E"),
      ("other", "D9D9D9"),
    ]

    if let match = mappings.first(where: { lowercased.contains($0.needle) }) {
      return match.color
    }

    return fallbackColorHex(for: appName)
  }

  static func dayDescriptors(
    for weekRange: WeeklyDateRange,
    offsets: [Int]
  ) -> [WeeklyDayDescriptor] {
    offsets.compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: weekRange.weekStart) else {
        return nil
      }
      return WeeklyDayDescriptor(
        id: dayID(for: offset),
        label: dayLabel(for: offset),
        dayString: DateFormatter.yyyyMMdd.string(from: date),
        order: offset
      )
    }
  }

  private static func dayID(for offset: Int) -> String {
    switch offset {
    case 0: return "mon"
    case 1: return "tue"
    case 2: return "wed"
    case 3: return "thu"
    case 4: return "fri"
    case 5: return "sat"
    case 6: return "sun"
    default: return "day-\(offset)"
    }
  }

  private static func dayLabel(for offset: Int) -> String {
    switch offset {
    case 0: return "Mon"
    case 1: return "Tue"
    case 2: return "Wed"
    case 3: return "Thur"
    case 4: return "Fri"
    case 5: return "Sat"
    case 6: return "Sun"
    default: return "Day"
    }
  }

  private static func topLevelDetail(for aggregate: WeeklyCategoryAggregate) -> String {
    let duration = durationText(aggregate.minutes)
    let sessionLabel = aggregate.count == 1 ? "session" : "sessions"
    let summary =
      aggregate.representative.map { cardNarrative(for: $0.card, maxLength: 105) }
      ?? "No summary available."
    return "Spent \(duration) across \(aggregate.count) \(sessionLabel). \(summary)"
  }

  static func durationText(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if hours > 0, remainingMinutes > 0 {
      return "\(hours)h \(remainingMinutes)m"
    }
    if hours > 0 {
      return "\(hours)h"
    }
    return "\(minutes)m"
  }

  private static func cardNarrative(for card: TimelineCard, maxLength: Int) -> String {
    let title = shortTitle(card.title)
    let body = firstUsefulSentence(from: [card.detailedSummary, card.summary, card.title])

    if body.localizedCaseInsensitiveContains(title) || title == "Untitled" {
      return shortened(body, maxLength: maxLength)
    }

    return shortened("\(title): \(body)", maxLength: maxLength)
  }

  private static func shortTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return shortened(trimmed.isEmpty ? "Untitled" : trimmed, maxLength: 54)
  }

  private static func firstUsefulSentence(from values: [String]) -> String {
    let text =
      values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? "No summary available."
    let collapsed =
      text
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "  ", with: " ")

    if let sentence = collapsed.split(separator: ".").first, !sentence.isEmpty {
      return String(sentence) + "."
    }

    return collapsed
  }

  private static func shortened(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(max(maxLength - 3, 1))).trimmingCharacters(
      in: .whitespacesAndNewlines) + "..."
  }

  private static func stableCardID(_ card: TimelineCard) -> String {
    if let recordId = card.recordId {
      return "card-\(recordId)"
    }
    return "\(card.day)-\(card.startTimestamp)-\(card.endTimestamp)-\(normalizedKey(card.title))"
  }

  private static func displayName(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func factDurationSort(_ lhs: WeeklyCardFact, _ rhs: WeeklyCardFact) -> Bool {
    if lhs.durationMinutes == rhs.durationMinutes {
      return lhs.startMinute < rhs.startMinute
    }
    return lhs.durationMinutes > rhs.durationMinutes
  }

  private static func isDistractionCard(_ card: TimelineCard, categoryName: String) -> Bool {
    if card.distractions?.isEmpty == false {
      return true
    }

    let text = "\(categoryName) \(card.subcategory) \(card.title) \(card.summary)".lowercased()
    return text.contains("distraction") || text.contains("distracted")
  }

  static func parseCardMinute(_ value: String) -> Double? {
    guard let parsed = parseTimeHMMA(timeString: value) else { return nil }
    return Double(parsed)
  }

  static func normalizedMinuteRange(start: Double, end: Double) -> (
    start: Double, end: Double
  ) {
    let adjustedStart = start < Double(DayBoundaryPreferences.boundaryMinutes) ? start + 1440 : start
    var adjustedEnd = end < Double(DayBoundaryPreferences.boundaryMinutes) ? end + 1440 : end
    if adjustedEnd <= adjustedStart {
      adjustedEnd += 1440
    }
    return (adjustedStart, adjustedEnd)
  }

  private static func normalizedKey(_ value: String) -> String {
    let folded =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
    let parts = folded.map { character -> String in
      character.isLetter || character.isNumber ? String(character) : "-"
    }
    return parts.joined().split(separator: "-").joined(separator: "_")
  }

  private static func normalizedColorHex(_ value: String) -> String {
    let cleaned =
      value
      .replacingOccurrences(of: "#", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    return cleaned.isEmpty ? otherColorHex : cleaned
  }

  private static func fallbackColorHex(for key: String) -> String {
    let palette = ["93BCFF", "DE9DFC", "6CDACD", "FFA189", "FFC6B7", otherColorHex]
    let hash = key.utf8.reduce(5381) { current, byte in
      ((current << 5) &+ current) &+ Int(byte)
    }
    return palette[abs(hash) % palette.count]
  }

  private static func titleCase(_ value: String) -> String {
    value
      .split(separator: " ")
      .map { word in
        guard let first = word.first else { return "" }
        return String(first).uppercased() + String(word.dropFirst())
      }
      .joined(separator: " ")
  }
}

private struct WeeklyCategoryAggregate {
  let key: String
  let name: String
  let minutes: Int
  let count: Int
  let representative: WeeklyCardFact?
}

private struct WeeklyAppIdentity {
  let key: String
  let name: String
  let colorHex: String
}
