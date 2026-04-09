import Foundation

struct WeeklyDonutItem: Identifiable, Sendable {
  let id: String
  let name: String
  let colorHex: String
  let minutes: Int
}

struct WeeklyDonutSnapshot: Sendable {
  let items: [WeeklyDonutItem]
  let totalMinutes: Int
  let footerLabel: String

  static let empty = WeeklyDonutSnapshot(
    items: [],
    totalMinutes: 0,
    footerLabel: "Heart"
  )

  static let figmaPreview = WeeklyDonutSnapshot(
    items: [
      WeeklyDonutItem(id: "research", name: "Research", colorHex: "93BCFF", minutes: 618),
      WeeklyDonutItem(id: "design", name: "Design", colorHex: "DE9DFC", minutes: 618),
      WeeklyDonutItem(id: "alignment", name: "Alignment", colorHex: "6CDACD", minutes: 618),
      WeeklyDonutItem(id: "testing", name: "Testing", colorHex: "FFA189", minutes: 618),
      WeeklyDonutItem(id: "general", name: "General", colorHex: "BFB6AE", minutes: 621),
    ],
    totalMinutes: 2573,
    footerLabel: "Heart"
  )
}

enum WeeklyDonutBuilder {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }()

  private static let systemCategoryKey = "system"
  private static let otherCategoryKey = "other"
  private static let otherColorHex = "BFB6AE"
  private static let maxVisibleItems = 5

  static func build(
    cards: [TimelineCard],
    categories: [TimelineCategory],
    weekRange: WeeklyDateRange
  ) -> WeeklyDonutSnapshot {
    let orderedCategories =
      categories
      .sorted { $0.order < $1.order }
      .filter { !$0.isSystem }

    let categoryLookup = firstCategoryLookup(
      from: orderedCategories,
      normalizedKey: normalizedCategoryKey
    )

    let visibleWorkdays = Set(workdayStrings(for: weekRange.weekStart))
    let workweekCards = cards.filter { visibleWorkdays.contains($0.day) }

    var minutesByCategory: [String: Int] = [:]
    var namesByCategory: [String: String] = [:]
    var colorsByCategory: [String: String] = [:]
    var ordersByCategory: [String: Int] = [:]

    for card in workweekCards {
      let key = normalizedCategoryKey(displayName(for: card.category))
      guard key != systemCategoryKey else { continue }

      let minutes = totalMinutes(for: card)
      guard minutes > 0 else { continue }

      minutesByCategory[key, default: 0] += minutes
      namesByCategory[key] =
        namesByCategory[key]
        ?? resolvedName(
          for: key,
          card: card,
          categories: categoryLookup
        )
      colorsByCategory[key] =
        colorsByCategory[key]
        ?? resolvedColorHex(
          for: key,
          categories: categoryLookup
        )
      ordersByCategory[key] = ordersByCategory[key] ?? categoryLookup[key]?.order ?? Int.max
    }

    let rawItems = minutesByCategory.map { key, minutes in
      RawWeeklyDonutItem(
        key: key,
        name: namesByCategory[key] ?? "Uncategorized",
        colorHex: colorsByCategory[key] ?? fallbackColorHex(for: key),
        order: ordersByCategory[key] ?? Int.max,
        minutes: minutes
      )
    }
    .sorted(by: rawItemSort)

    guard !rawItems.isEmpty else {
      return .empty
    }

    let visibleItems = collapsedItems(from: rawItems).map {
      WeeklyDonutItem(
        id: $0.key,
        name: $0.name,
        colorHex: $0.colorHex,
        minutes: $0.minutes
      )
    }

    return WeeklyDonutSnapshot(
      items: visibleItems,
      totalMinutes: visibleItems.reduce(0) { $0 + $1.minutes },
      footerLabel: "Heart"
    )
  }

  private static func collapsedItems(from items: [RawWeeklyDonutItem]) -> [RawWeeklyDonutItem] {
    guard items.count > maxVisibleItems else { return items }

    let visibleItems = Array(items.prefix(maxVisibleItems - 1))
    let otherMinutes = items.dropFirst(maxVisibleItems - 1).reduce(0) { $0 + $1.minutes }

    return visibleItems + [
      RawWeeklyDonutItem(
        key: otherCategoryKey,
        name: "Other",
        colorHex: otherColorHex,
        order: Int.max,
        minutes: otherMinutes
      )
    ]
  }

  private static func workdayStrings(for weekStart: Date) -> [String] {
    (0..<5).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
        return nil
      }
      return DateFormatter.yyyyMMdd.string(from: date)
    }
  }

  private static func totalMinutes(for card: TimelineCard) -> Int {
    guard let startMinute = parseCardMinute(card.startTimestamp),
      let endMinute = parseCardMinute(card.endTimestamp)
    else {
      return 0
    }

    let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
    return max(Int((normalized.end - normalized.start).rounded()), 0)
  }

  private static func normalizedMinuteRange(start: Double, end: Double) -> (
    start: Double, end: Double
  ) {
    let adjustedStart = start < 240 ? start + 1440 : start
    var adjustedEnd = end < 240 ? end + 1440 : end

    if adjustedEnd <= adjustedStart {
      adjustedEnd += 1440
    }

    return (adjustedStart, adjustedEnd)
  }

  private static func parseCardMinute(_ value: String) -> Double? {
    guard let parsed = parseTimeHMMA(timeString: value) else { return nil }
    return Double(parsed)
  }

  private static func displayName(for value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Uncategorized" : trimmed
  }

  private static func normalizedCategoryKey(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private static func resolvedName(
    for key: String,
    card: TimelineCard,
    categories: [String: TimelineCategory]
  ) -> String {
    if let category = categories[key] {
      return category.name
    }

    return displayName(for: card.category)
  }

  private static func resolvedColorHex(
    for key: String,
    categories: [String: TimelineCategory]
  ) -> String {
    let colorHex = categories[key]?.colorHex ?? fallbackColorHex(for: key)
    return colorHex.replacingOccurrences(of: "#", with: "")
  }

  private static func fallbackColorHex(for key: String) -> String {
    let palette = ["93BCFF", "DE9DFC", "6CDACD", "FFA189", otherColorHex]
    let hash = key.utf8.reduce(5381) { current, byte in
      ((current << 5) &+ current) &+ Int(byte)
    }
    let index = abs(hash) % palette.count
    return palette[index]
  }

  private static func rawItemSort(lhs: RawWeeklyDonutItem, rhs: RawWeeklyDonutItem) -> Bool {
    if lhs.minutes == rhs.minutes {
      if lhs.order == rhs.order {
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
      return lhs.order < rhs.order
    }

    return lhs.minutes > rhs.minutes
  }
}

private struct RawWeeklyDonutItem: Sendable {
  let key: String
  let name: String
  let colorHex: String
  let order: Int
  let minutes: Int
}
