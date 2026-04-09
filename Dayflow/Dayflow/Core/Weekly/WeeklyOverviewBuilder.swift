import Foundation

struct WeeklyOverviewSegment: Identifiable, Sendable {
  let id: String
  let categoryKey: String
  let colorHex: String
  let startMinute: Double
  let endMinute: Double
}

struct WeeklyOverviewRow: Identifiable, Sendable {
  let id: String
  let label: String
  let weekdayName: String
  let segments: [WeeklyOverviewSegment]

  static let placeholder: [WeeklyOverviewRow] = [
    WeeklyOverviewRow(id: "mon", label: "Mon", weekdayName: "Monday", segments: []),
    WeeklyOverviewRow(id: "tue", label: "Tue", weekdayName: "Tuesday", segments: []),
    WeeklyOverviewRow(id: "wed", label: "Wed", weekdayName: "Wednesday", segments: []),
    WeeklyOverviewRow(id: "thu", label: "Thu", weekdayName: "Thursday", segments: []),
    WeeklyOverviewRow(id: "fri", label: "Fri", weekdayName: "Friday", segments: []),
  ]
}

struct WeeklyOverviewLegendItem: Identifiable, Sendable {
  let id: String
  let name: String
  let colorHex: String
}

struct WeeklyOverviewFocusSummary: Sendable {
  let weekdayName: String
  let minutes: Int
}

struct WeeklyOverviewCategorySummary: Sendable {
  let name: String
  let minutes: Int
  let colorHex: String
}

struct WeeklyOverviewSnapshot: Sendable {
  let rows: [WeeklyOverviewRow]
  let legendItems: [WeeklyOverviewLegendItem]
  let contextSwitchTotal: Int
  let contextSwitchAverage: Int
  let totalFocusMinutes: Int
  let longestFocus: WeeklyOverviewFocusSummary?
  let primaryFocus: WeeklyOverviewCategorySummary?

  static let empty = WeeklyOverviewSnapshot(
    rows: WeeklyOverviewRow.placeholder,
    legendItems: [],
    contextSwitchTotal: 0,
    contextSwitchAverage: 0,
    totalFocusMinutes: 0,
    longestFocus: nil,
    primaryFocus: nil
  )
}

enum WeeklyOverviewBuilder {
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
  private static let maxLegendItems = 5
  private static let focusMergeGapMinutes = 5.0
  private static let visibleStartMinute = 9.0 * 60.0
  private static let visibleEndMinute = 18.0 * 60.0
  private static let weekdayTemplates: [(short: String, full: String)] = [
    ("Mon", "Monday"),
    ("Tue", "Tuesday"),
    ("Wed", "Wednesday"),
    ("Thu", "Thursday"),
    ("Fri", "Friday"),
  ]

  static func build(
    cards: [TimelineCard],
    categories: [TimelineCategory],
    weekRange: WeeklyDateRange
  ) -> WeeklyOverviewSnapshot {
    let orderedCategories =
      categories
      .sorted { $0.order < $1.order }
      .filter { normalizedCategoryKey($0.name) != systemCategoryKey }

    let categoryLookup = firstCategoryLookup(
      from: orderedCategories,
      normalizedKey: normalizedCategoryKey
    )

    let workdays = workdays(for: weekRange.weekStart)
    let workdayLookup = Dictionary(uniqueKeysWithValues: workdays.map { ($0.dayString, $0) })

    let workweekCards = cards.filter { workdayLookup[$0.day] != nil }

    var minutesByCategory: [String: Double] = [:]
    var displayNameByCategory: [String: String] = [:]
    var colorHexByCategory: [String: String] = [:]

    for card in workweekCards {
      let key = normalizedCategoryKey(displayName(for: card.category))
      guard key != systemCategoryKey else { continue }

      let durationMinutes = totalMinutes(for: card)
      guard durationMinutes > 0 else { continue }

      minutesByCategory[key, default: 0] += durationMinutes
      displayNameByCategory[key] =
        displayNameByCategory[key] ?? resolvedName(for: key, card: card, categories: categoryLookup)
      colorHexByCategory[key] =
        colorHexByCategory[key] ?? resolvedColorHex(for: key, categories: categoryLookup)
    }

    let categorySummaries = minutesByCategory.map { key, minutes in
      RawCategorySummary(
        key: key,
        name: displayNameByCategory[key] ?? "Uncategorized",
        colorHex: colorHexByCategory[key] ?? fallbackColorHex(for: key),
        order: categoryLookup[key]?.order ?? Int.max,
        minutes: minutes,
        isIdle: categoryLookup[key]?.isIdle ?? false
      )
    }

    let visibleCategoryKeys = visibleCategoryKeys(from: categorySummaries)
    let rows = workdays.map { workday in
      WeeklyOverviewRow(
        id: workday.dayString,
        label: workday.label,
        weekdayName: workday.weekdayName,
        segments: rowSegments(
          for: workweekCards.filter { $0.day == workday.dayString },
          visibleCategoryKeys: visibleCategoryKeys,
          categories: categoryLookup
        )
      )
    }

    let legendItems = legendItems(from: categorySummaries, visibleCategoryKeys: visibleCategoryKeys)
    let contextSwitchTotal = workdays.reduce(0) { partial, workday in
      partial
        + contextSwitchCount(
          for: workweekCards.filter { $0.day == workday.dayString }
        )
    }

    let focusSummaries = categorySummaries.filter { !$0.isIdle }
    let totalFocusMinutes = Int(focusSummaries.reduce(0) { $0 + $1.minutes }.rounded())
    let longestFocus = longestFocusSummary(
      cardsByDay: workdays.map { workday in
        (workday: workday, cards: workweekCards.filter { $0.day == workday.dayString })
      },
      categories: categoryLookup
    )
    let primaryFocus =
      focusSummaries
      .sorted(by: focusCategorySort)
      .first
      .map {
        WeeklyOverviewCategorySummary(
          name: $0.name,
          minutes: Int($0.minutes.rounded()),
          colorHex: $0.colorHex
        )
      }

    let contextSwitchAverage =
      workdays.isEmpty
      ? 0
      : Int((Double(contextSwitchTotal) / Double(workdays.count)).rounded())

    return WeeklyOverviewSnapshot(
      rows: rows,
      legendItems: legendItems,
      contextSwitchTotal: contextSwitchTotal,
      contextSwitchAverage: contextSwitchAverage,
      totalFocusMinutes: totalFocusMinutes,
      longestFocus: longestFocus,
      primaryFocus: primaryFocus
    )
  }

  private static func rowSegments(
    for cards: [TimelineCard],
    visibleCategoryKeys: Set<String>,
    categories: [String: TimelineCategory]
  ) -> [WeeklyOverviewSegment] {
    let segments = cards.compactMap { card -> WeeklyOverviewSegment? in
      guard var startMinute = parseCardMinute(card.startTimestamp),
        var endMinute = parseCardMinute(card.endTimestamp)
      else {
        return nil
      }

      let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
      startMinute = max(normalized.start, visibleStartMinute)
      endMinute = min(normalized.end, visibleEndMinute)
      guard endMinute > startMinute else { return nil }

      let rawKey = normalizedCategoryKey(displayName(for: card.category))
      guard rawKey != systemCategoryKey else { return nil }

      let bucketKey =
        visibleCategoryKeys.isEmpty || visibleCategoryKeys.contains(rawKey)
        ? rawKey
        : otherCategoryKey

      let colorHex =
        bucketKey == otherCategoryKey
        ? otherColorHex
        : resolvedColorHex(for: rawKey, categories: categories)

      return WeeklyOverviewSegment(
        id: "\(card.recordId ?? -1)-\(bucketKey)-\(Int(startMinute))-\(Int(endMinute))",
        categoryKey: bucketKey,
        colorHex: colorHex,
        startMinute: startMinute,
        endMinute: endMinute
      )
    }
    .sorted {
      if $0.startMinute == $1.startMinute {
        return $0.endMinute < $1.endMinute
      }
      return $0.startMinute < $1.startMinute
    }

    return mergeAdjacentSegments(segments)
  }

  private static func contextSwitchCount(for cards: [TimelineCard]) -> Int {
    let segments = cards.compactMap { card -> SortableSegment? in
      guard var startMinute = parseCardMinute(card.startTimestamp),
        var endMinute = parseCardMinute(card.endTimestamp)
      else {
        return nil
      }

      let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
      startMinute = normalized.start
      endMinute = normalized.end
      guard endMinute > startMinute else { return nil }

      let key = normalizedCategoryKey(displayName(for: card.category))
      guard key != systemCategoryKey else { return nil }

      return SortableSegment(categoryKey: key, startMinute: startMinute, endMinute: endMinute)
    }
    .sorted {
      if $0.startMinute == $1.startMinute {
        return $0.endMinute < $1.endMinute
      }
      return $0.startMinute < $1.startMinute
    }

    var previousCategory: String? = nil
    var switches = 0

    for segment in segments {
      if let previousCategory, previousCategory != segment.categoryKey {
        switches += 1
      }
      previousCategory = segment.categoryKey
    }

    return switches
  }

  private static func longestFocusSummary(
    cardsByDay: [(workday: Workday, cards: [TimelineCard])],
    categories: [String: TimelineCategory]
  ) -> WeeklyOverviewFocusSummary? {
    var bestSummary: WeeklyOverviewFocusSummary? = nil

    for entry in cardsByDay {
      let ranges = entry.cards.compactMap { card -> MinuteRange? in
        let key = normalizedCategoryKey(displayName(for: card.category))
        if key == systemCategoryKey { return nil }
        if categories[key]?.isIdle == true { return nil }

        guard var startMinute = parseCardMinute(card.startTimestamp),
          var endMinute = parseCardMinute(card.endTimestamp)
        else {
          return nil
        }

        let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
        startMinute = normalized.start
        endMinute = normalized.end
        guard endMinute > startMinute else { return nil }

        return MinuteRange(start: startMinute, end: endMinute)
      }
      .sorted { $0.start < $1.start }

      let mergedRanges = mergeFocusRanges(ranges)

      for range in mergedRanges {
        let minutes = Int((range.end - range.start).rounded())
        guard minutes > 0 else { continue }

        if let currentBest = bestSummary, minutes <= currentBest.minutes {
          continue
        } else {
          bestSummary = WeeklyOverviewFocusSummary(
            weekdayName: entry.workday.weekdayName,
            minutes: minutes
          )
        }
      }
    }

    return bestSummary
  }

  private static func mergeFocusRanges(_ ranges: [MinuteRange]) -> [MinuteRange] {
    guard var current = ranges.first else { return [] }

    var merged: [MinuteRange] = []

    for next in ranges.dropFirst() {
      let gap = next.start - current.end
      if gap < focusMergeGapMinutes {
        current.end = max(current.end, next.end)
      } else {
        merged.append(current)
        current = next
      }
    }

    merged.append(current)
    return merged
  }

  private static func visibleCategoryKeys(from summaries: [RawCategorySummary]) -> Set<String> {
    let sortedByUsage = summaries.sorted(by: usageSort)

    if sortedByUsage.count <= maxLegendItems {
      return Set(sortedByUsage.map(\.key))
    }

    return Set(sortedByUsage.prefix(maxLegendItems - 1).map(\.key))
  }

  private static func legendItems(
    from summaries: [RawCategorySummary],
    visibleCategoryKeys: Set<String>
  ) -> [WeeklyOverviewLegendItem] {
    guard !summaries.isEmpty else { return [] }

    let visibleItems =
      summaries
      .filter { visibleCategoryKeys.contains($0.key) }
      .sorted(by: legendSort)
      .map {
        WeeklyOverviewLegendItem(id: $0.key, name: $0.name, colorHex: $0.colorHex)
      }

    guard summaries.count > maxLegendItems else {
      return visibleItems
    }

    return visibleItems + [
      WeeklyOverviewLegendItem(id: otherCategoryKey, name: "Other", colorHex: otherColorHex)
    ]
  }

  private static func mergeAdjacentSegments(
    _ segments: [WeeklyOverviewSegment]
  ) -> [WeeklyOverviewSegment] {
    guard var current = segments.first else { return [] }

    var merged: [WeeklyOverviewSegment] = []

    for next in segments.dropFirst() {
      let gap = next.startMinute - current.endMinute
      if current.categoryKey == next.categoryKey && gap <= 1 {
        current = WeeklyOverviewSegment(
          id: current.id,
          categoryKey: current.categoryKey,
          colorHex: current.colorHex,
          startMinute: current.startMinute,
          endMinute: max(current.endMinute, next.endMinute)
        )
      } else {
        merged.append(current)
        current = next
      }
    }

    merged.append(current)
    return merged
  }

  private static func resolvedName(
    for key: String,
    card: TimelineCard,
    categories: [String: TimelineCategory]
  ) -> String {
    let trimmed = card.category.trimmingCharacters(in: .whitespacesAndNewlines)
    if let category = categories[key] {
      return category.name
    }
    return trimmed.isEmpty ? "Uncategorized" : trimmed
  }

  private static func resolvedColorHex(
    for key: String,
    categories: [String: TimelineCategory]
  ) -> String {
    let colorHex = categories[key]?.colorHex ?? fallbackColorHex(for: key)
    return colorHex.replacingOccurrences(of: "#", with: "")
  }

  private static func totalMinutes(for card: TimelineCard) -> Double {
    guard let startMinute = parseCardMinute(card.startTimestamp),
      let endMinute = parseCardMinute(card.endTimestamp)
    else {
      return 0
    }

    let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
    return max(0, normalized.end - normalized.start)
  }

  private static func workdays(for weekStart: Date) -> [Workday] {
    weekdayTemplates.enumerated().compactMap { offset, labels in
      guard let dayDate = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
        return nil
      }

      return Workday(
        label: labels.short,
        weekdayName: labels.full,
        dayString: DateFormatter.yyyyMMdd.string(from: dayDate)
      )
    }
  }

  private static func displayName(for value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Uncategorized" : trimmed
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

  private static func normalizedCategoryKey(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private static func fallbackColorHex(for key: String) -> String {
    let palette = ["93BCFF", "DE9DFC", "6CDACD", "FFA189", otherColorHex]
    let hash = key.utf8.reduce(5381) { current, byte in
      ((current << 5) &+ current) &+ Int(byte)
    }
    let index = abs(hash) % palette.count
    return palette[index]
  }

  private static func usageSort(lhs: RawCategorySummary, rhs: RawCategorySummary) -> Bool {
    if lhs.minutes == rhs.minutes {
      return legendSort(lhs: lhs, rhs: rhs)
    }
    return lhs.minutes > rhs.minutes
  }

  private static func legendSort(lhs: RawCategorySummary, rhs: RawCategorySummary) -> Bool {
    if lhs.order == rhs.order {
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    return lhs.order < rhs.order
  }

  private static func focusCategorySort(lhs: RawCategorySummary, rhs: RawCategorySummary) -> Bool {
    if lhs.minutes == rhs.minutes {
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    return lhs.minutes > rhs.minutes
  }
}

private struct Workday: Sendable {
  let label: String
  let weekdayName: String
  let dayString: String
}

private struct RawCategorySummary: Sendable {
  let key: String
  let name: String
  let colorHex: String
  let order: Int
  let minutes: Double
  let isIdle: Bool
}

private struct SortableSegment: Sendable {
  let categoryKey: String
  let startMinute: Double
  let endMinute: Double
}

private struct MinuteRange: Sendable {
  var start: Double
  var end: Double
}
