import AppKit
import Foundation
import SwiftUI

struct WeeklyDashboardSnapshot {
  let donut: WeeklyDonutSnapshot
  let overview: WeeklyOverviewSnapshot
  let treemap: WeeklyTreemapSnapshot
  let sankey: WeeklySankeySnapshot
  let workflow: WeeklyWorkflowSnapshot
  let heatmap: WeeklyFocusHeatmapSnapshot
  let contextCharts: WeeklyContextChartsSnapshot
  let applicationInteractions: WeeklyApplicationInteractionsSnapshot
}

struct WeeklySankeySnapshot {
  let id: String
  let seedLabel: String
  let sourceName: String
  let categories: [WeeklySankeySnapshotCategory]
  let apps: [WeeklySankeySnapshotApp]
  let links: [WeeklySankeySnapshotLink]

  static func empty(sourceName: String) -> WeeklySankeySnapshot {
    WeeklySankeySnapshot(
      id: "empty-weekly-sankey",
      seedLabel: "Timeline data",
      sourceName: sourceName,
      categories: [],
      apps: [],
      links: []
    )
  }
}

struct WeeklySankeySnapshotCategory {
  let id: String
  let name: String
  let minutes: Int
  let colorHex: String
}

struct WeeklySankeySnapshotApp {
  let id: String
  let name: String
  let minutes: Int
  let colorHex: String
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?

  init(
    id: String,
    name: String,
    minutes: Int,
    colorHex: String,
    faviconPrimaryRaw: String? = nil,
    faviconSecondaryRaw: String? = nil,
    faviconPrimaryHost: String? = nil,
    faviconSecondaryHost: String? = nil
  ) {
    self.id = id
    self.name = name
    self.minutes = minutes
    self.colorHex = colorHex
    self.faviconPrimaryRaw = faviconPrimaryRaw
    self.faviconSecondaryRaw = faviconSecondaryRaw
    self.faviconPrimaryHost = faviconPrimaryHost
    self.faviconSecondaryHost = faviconSecondaryHost
  }

  var hasFaviconSource: Bool {
    guard id != "other" && name != "Other" else { return false }
    if hasNonEmpty(faviconPrimaryRaw) || hasNonEmpty(faviconSecondaryRaw)
      || hasNonEmpty(faviconPrimaryHost) || hasNonEmpty(faviconSecondaryHost)
    {
      return true
    }

    return FaviconService.shared.hasRawFaviconOverride(name)
  }

  var fallbackFaviconRaw: String? {
    FaviconService.shared.hasRawFaviconOverride(name) ? name : nil
  }

  private func hasNonEmpty(_ value: String?) -> Bool {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
}

struct WeeklySankeySnapshotLink {
  let id: String
  let from: String
  let to: String
  let minutes: Int
}

struct WeeklyWorkflowSnapshot: Sendable {
  let title: String
  let startMinute: Double
  let endMinute: Double
  let slotMinutes: Double
  let timeLabels: [WeeklyWorkflowTimeLabel]
  let rows: [WeeklyWorkflowRow]
  let totals: [WeeklyWorkflowTotalItem]
}

struct WeeklyWorkflowTimeLabel: Identifiable, Sendable {
  let id: String
  let label: String
  let minute: Double
}

struct WeeklyWorkflowRow: Identifiable, Sendable {
  let id: String
  let label: String
  let cells: [WeeklyWorkflowCell]
}

struct WeeklyWorkflowCell: Identifiable, Sendable {
  let id: String
  let categoryName: String?
  let colorHex: String?
  let minutes: Int
  let occupancy: Double
}

struct WeeklyWorkflowTotalItem: Identifiable, Sendable {
  let id: String
  let name: String
  let minutes: Int
  let duration: String
  let colorHex: String
}

enum WeeklyDashboardBuilder {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }()

  private static let otherKey = "other"
  private static let otherColorHex = "BFB6AE"

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

  private static func buildTreemap(
    from facts: [WeeklyCardFact],
    previousFacts: [WeeklyCardFact]
  ) -> WeeklyTreemapSnapshot {
    let currentFacts = facts.filter { !$0.isSystem && !$0.isIdle }
    let previousLookup = appMinutesByCategory(
      from: previousFacts.filter { !$0.isSystem && !$0.isIdle })
    let groupedByCategory = Dictionary(grouping: currentFacts, by: \.categoryKey)

    let categories = groupedByCategory.values
      .compactMap { categoryFacts -> WeeklyTreemapCategory? in
        guard let first = categoryFacts.first else { return nil }
        let appGroups = Dictionary(grouping: categoryFacts, by: \.appKey)
        let apps = appGroups.values
          .map { appFacts -> WeeklyTreemapApp in
            let appFirst = appFacts[0]
            let faviconSource =
              appFacts.first { $0.hasFaviconLookupSource } ?? appFirst
            let minutes = appFacts.reduce(0) { $0 + $1.durationMinutes }
            let previousMinutes = previousLookup[
              "\(first.categoryKey)|\(appFirst.appKey)", default: 0]
            return WeeklyTreemapApp(
              id: "\(first.categoryKey)-\(appFirst.appKey)",
              name: appFirst.appName,
              duration: TimeInterval(minutes * 60),
              change: treemapChange(currentMinutes: minutes, previousMinutes: previousMinutes),
              faviconPrimaryRaw: faviconSource.faviconPrimaryRaw,
              faviconSecondaryRaw: faviconSource.faviconSecondaryRaw,
              faviconPrimaryHost: faviconSource.faviconPrimaryHost,
              faviconSecondaryHost: faviconSource.faviconSecondaryHost,
              isAggregate: false,
              isPlaceholder: false
            )
          }
          .sorted(by: WeeklyTreemapApp.displayOrder)

        guard !apps.isEmpty else { return nil }
        return WeeklyTreemapCategory(
          id: first.categoryKey,
          name: first.categoryName,
          palette: treemapPalette(for: first.categoryColorHex),
          apps: Array(apps.prefix(8))
        )
      }
      .sorted(by: WeeklyTreemapCategory.displayOrder)

    return WeeklyTreemapSnapshot(
      title: "Most used per category",
      categories: Array(categories.prefix(5))
    )
  }

  private static func buildSankey(
    from facts: [WeeklyCardFact],
    weekRange: WeeklyDateRange
  ) -> WeeklySankeySnapshot {
    let sankeyFacts = facts.filter { !$0.isSystem && !$0.isIdle }
    guard !sankeyFacts.isEmpty else {
      return .empty(sourceName: sankeySourceName(for: weekRange))
    }

    let categoryBuckets = visibleBuckets(
      items: sankeyFacts,
      key: \.categoryKey,
      name: \.categoryName,
      colorHex: \.categoryColorHex,
      maxVisible: 6
    )
    let appBuckets = visibleBuckets(
      items: sankeyFacts,
      key: \.appKey,
      name: \.appName,
      colorHex: \.appColorHex,
      maxVisible: 10
    )
    let appFaviconSources = faviconSourcesByAppKey(from: sankeyFacts)

    var linkMinutes: [String: Int] = [:]
    for fact in sankeyFacts {
      let categoryKey = categoryBuckets.bucketKey(for: fact.categoryKey)
      let appKey = appBuckets.bucketKey(for: fact.appKey)
      linkMinutes["\(categoryKey)|\(appKey)", default: 0] += fact.durationMinutes
    }

    let links = linkMinutes.compactMap { key, minutes -> WeeklySankeySnapshotLink? in
      let parts = key.split(separator: "|", omittingEmptySubsequences: false)
      guard parts.count == 2, minutes > 0 else { return nil }
      let from = String(parts[0])
      let to = String(parts[1])
      return WeeklySankeySnapshotLink(
        id: "\(from)-\(to)",
        from: from,
        to: to,
        minutes: minutes
      )
    }
    .sorted {
      if $0.from == $1.from {
        return $0.minutes > $1.minutes
      }
      return $0.from < $1.from
    }

    return WeeklySankeySnapshot(
      id: "weekly-sankey-\(DateFormatter.yyyyMMdd.string(from: weekRange.weekStart))",
      seedLabel: "Timeline data",
      sourceName: sankeySourceName(for: weekRange),
      categories: categoryBuckets.categories.map {
        WeeklySankeySnapshotCategory(
          id: $0.key,
          name: $0.name,
          minutes: $0.minutes,
          colorHex: $0.colorHex
        )
      },
      apps: appBuckets.categories.map {
        let faviconSource = appFaviconSources[$0.key]
        return WeeklySankeySnapshotApp(
          id: $0.key,
          name: $0.name,
          minutes: $0.minutes,
          colorHex: $0.colorHex,
          faviconPrimaryRaw: faviconSource?.faviconPrimaryRaw,
          faviconSecondaryRaw: faviconSource?.faviconSecondaryRaw,
          faviconPrimaryHost: faviconSource?.faviconPrimaryHost,
          faviconSecondaryHost: faviconSource?.faviconSecondaryHost
        )
      },
      links: links
    )
  }

  private static func faviconSourcesByAppKey(
    from facts: [WeeklyCardFact]
  ) -> [String: WeeklyCardFact] {
    let groupedByApp = Dictionary(grouping: facts, by: \.appKey)
    return groupedByApp.reduce(into: [:]) { result, entry in
      guard
        let source = entry.value.first(where: { $0.hasFaviconLookupSource }) ?? entry.value.first
      else {
        return
      }
      result[entry.key] = source
    }
  }

  private static func buildHeatmap(
    from facts: [WeeklyCardFact],
    weekRange: WeeklyDateRange
  ) -> WeeklyFocusHeatmapSnapshot {
    let visibleFacts = facts.filter { !$0.isSystem && !$0.isIdle }
    let visibleWindow = weeklyActivityWindow(from: visibleFacts)
    let bucketMinutes = 5.0
    let bucketCount = max(1, Int(ceil((visibleWindow.end - visibleWindow.start) / bucketMinutes)))
    let descriptors = heatmapDayDescriptors(for: weekRange)
    let rows = descriptors.map { descriptor in
      let dayFacts = visibleFacts.filter {
        $0.dayString == descriptor.dayString
      }

      return WeeklyFocusHeatmapRow(
        id: descriptor.id,
        label: descriptor.label,
        values: heatmapValues(
          for: dayFacts,
          visibleStart: visibleWindow.start,
          bucketMinutes: bucketMinutes,
          bucketCount: bucketCount
        )
      )
    }

    return WeeklyFocusHeatmapSnapshot(
      title: "Focus and distraction heat map",
      focusedLabel: "Focused work",
      distractedLabel: "Distracted",
      startMinute: visibleWindow.start,
      endMinute: visibleWindow.start + (Double(bucketCount) * bucketMinutes),
      bucketMinutes: bucketMinutes,
      timeLabels: weeklyTimeLabels(
        startMinute: visibleWindow.start,
        endMinute: visibleWindow.start + (Double(bucketCount) * bucketMinutes)
      ),
      rows: rows
    )
  }

  private static func buildWorkflow(
    from facts: [WeeklyCardFact],
    weekRange: WeeklyDateRange
  ) -> WeeklyWorkflowSnapshot {
    let visibleFacts = facts.filter { !$0.isSystem && !$0.isIdle }
    let visibleWindow = weeklyActivityWindow(from: visibleFacts)
    let visibleStart = visibleWindow.start
    let visibleEnd = visibleWindow.end
    let slotMinutes = 15.0
    let slotCount = max(1, Int((visibleEnd - visibleStart) / slotMinutes))
    let descriptors = dayDescriptors(for: weekRange, offsets: Array(0..<7))

    let rows = descriptors.map { descriptor in
      let dayFacts = visibleFacts.filter { $0.dayString == descriptor.dayString }
      let cells = (0..<slotCount).map { slotIndex in
        workflowCell(
          slotIndex: slotIndex,
          dayFacts: dayFacts,
          visibleStart: visibleStart,
          slotMinutes: slotMinutes
        )
      }

      return WeeklyWorkflowRow(
        id: descriptor.id,
        label: descriptor.label,
        cells: cells
      )
    }

    return WeeklyWorkflowSnapshot(
      title: "Your workflow this week",
      startMinute: visibleStart,
      endMinute: visibleEnd,
      slotMinutes: slotMinutes,
      timeLabels: weeklyTimeLabels(startMinute: visibleStart, endMinute: visibleEnd),
      rows: rows,
      totals: workflowTotals(from: visibleFacts)
    )
  }

  private static func buildContextCharts(
    from facts: [WeeklyCardFact],
    weekRange: WeeklyDateRange
  ) -> WeeklyContextChartsSnapshot {
    let descriptors = dayDescriptors(for: weekRange, offsets: Array(0..<7))
    var distributionEvents: [WeeklyContextDistributionEvent] = []
    var comparisonDays: [WeeklyContextComparisonDay] = []

    for descriptor in descriptors {
      let dayFacts =
        facts
        .filter { $0.dayString == descriptor.dayString && !$0.isSystem && !$0.isIdle }
        .sorted { $0.startMinute < $1.startMinute }

      var shifts = 0
      var previousCategory: String?
      for fact in dayFacts {
        if let previousCategory, previousCategory != fact.categoryKey {
          shifts += 1
          if isDistributionMinute(fact.startMinute) {
            distributionEvents.append(
              WeeklyContextDistributionEvent(
                day: descriptor.label,
                kind: .context,
                time: clockTime(from: fact.startMinute)
              )
            )
          }
        }
        previousCategory = fact.categoryKey
      }

      let distractionTimes = dayFacts.flatMap(distractionStartMinutes)
      for minute in distractionTimes where isDistributionMinute(minute) {
        distributionEvents.append(
          WeeklyContextDistributionEvent(
            day: descriptor.label,
            kind: .distraction,
            time: clockTime(from: minute)
          )
        )
      }

      comparisonDays.append(
        WeeklyContextComparisonDay(
          day: descriptor.label,
          distracted: distractionTimes.count,
          shifts: shifts
        )
      )
    }

    return WeeklyContextChartsSnapshot(
      distribution: WeeklyContextDistributionSnapshot(
        days: descriptors.map(\.label),
        start: "10:00",
        end: "18:00",
        events: Array(distributionEvents.prefix(80))
      ),
      comparison: WeeklyContextComparisonSnapshot(
        days: comparisonDays,
        insight: contextInsight(from: comparisonDays)
      )
    )
  }

  private static func buildApplicationInteractions(
    from facts: [WeeklyCardFact]
  ) -> WeeklyApplicationInteractionsSnapshot {
    let appFacts = facts.filter { !$0.isSystem && !$0.isIdle && $0.appKey != otherKey }
    guard !appFacts.isEmpty else {
      return emptyApplicationInteractionsSnapshot()
    }

    let aggregates = appAggregates(from: appFacts)
    let visibleApps = Array(aggregates.prefix(14))
    let visibleKeys = Set(visibleApps.map(\.key))
    let nodeByKey = Dictionary(uniqueKeysWithValues: visibleApps.map { ($0.key, $0) })
    let nodes = applicationNodes(from: visibleApps)
    let transitions = appTransitions(from: appFacts, visibleKeys: visibleKeys)
    let maxTransitionCount = max(transitions.map(\.count).max() ?? 1, 1)
    let curveOffsets: [CGFloat] = [-42, 24, -55, -22, 52, -14, 30, -30, 18, -62]

    let edges = transitions.prefix(18).enumerated().compactMap {
      index, transition -> WeeklyApplicationEdge? in
      guard let from = nodeByKey[transition.from], let to = nodeByKey[transition.to] else {
        return nil
      }
      return WeeklyApplicationEdge(
        from: from.key,
        to: to.key,
        kind: edgeKind(from: from.kind, to: to.kind),
        weight: Double(transition.count) / Double(maxTransitionCount),
        curveOffset: curveOffsets[index % curveOffsets.count]
      )
    }

    let patterns = workPatterns(
      from: transitions,
      aggregates: nodeByKey,
      activeDayCount: max(Set(appFacts.map(\.dayString)).count, 1)
    )
    let rabbitHole = rabbitHoleSnapshot(
      from: transitions, aggregates: nodeByKey, visibleApps: visibleApps)
    let totalMinutes = appFacts.reduce(0) { $0 + $1.durationMinutes }
    let visibleMinutes = visibleApps.reduce(0) { $0 + $1.minutes }
    let coverage = Int((Double(visibleMinutes) / Double(max(totalMinutes, 1)) * 100).rounded())

    return WeeklyApplicationInteractionsSnapshot(
      subtitle: "About \(coverage)% of recorded app time was spent using these applications.",
      nodes: nodes,
      edges: Array(edges),
      patterns: patterns,
      rabbitHole: rabbitHole
    )
  }

  private static func appAggregates(from facts: [WeeklyCardFact]) -> [WeeklyAppAggregate] {
    Dictionary(grouping: facts, by: \.appKey).values.map { appFacts in
      let first = appFacts[0]
      let minutes = appFacts.reduce(0) { $0 + $1.durationMinutes }
      let visits = appFacts.count
      let kind = resolvedAppKind(from: appFacts)
      return WeeklyAppAggregate(
        key: first.appKey,
        name: first.appName,
        colorHex: first.appColorHex,
        kind: kind,
        minutes: minutes,
        visits: visits
      )
    }
    .sorted {
      if $0.minutes == $1.minutes {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return $0.minutes > $1.minutes
    }
  }

  private static func applicationNodes(from apps: [WeeklyAppAggregate]) -> [WeeklyApplicationNode] {
    let positions: [(x: CGFloat, y: CGFloat)] = [
      (256.5, 253.3),
      (106.5, 411.3),
      (134, 154.3),
      (220, 136.8),
      (308.5, 167.8),
      (342.5, 108.8),
      (436.1, 142.8),
      (501.5, 255.8),
      (391.1, 310.8),
      (391.5, 415.8),
      (296, 380.3),
      (62, 304.8),
      (111, 233.8),
      (179.5, 343.3),
    ]
    let maxMinutes = max(apps.map(\.minutes).max() ?? 1, 1)

    return apps.enumerated().map { index, app in
      let position = positions[index % positions.count]
      let size =
        index == 0
        ? CGFloat(76)
        : CGFloat(30) + CGFloat(sqrt(Double(app.minutes) / Double(maxMinutes))) * 28
      return WeeklyApplicationNode(
        id: app.key,
        name: app.name,
        x: position.x,
        y: position.y,
        size: size,
        kind: app.kind,
        mark: appInitial(app.name),
        isPrimary: index == 0,
        isMuted: index > 5
      )
    }
  }

  private static func appTransitions(
    from facts: [WeeklyCardFact],
    visibleKeys: Set<String>
  ) -> [WeeklyAppTransition] {
    let byDay = Dictionary(grouping: facts, by: \.dayString)
    var counts: [String: Int] = [:]

    for dayFacts in byDay.values {
      var previous: WeeklyCardFact?
      for fact in dayFacts.sorted(by: { $0.startMinute < $1.startMinute }) {
        guard visibleKeys.contains(fact.appKey) else { continue }
        if let previous, previous.appKey != fact.appKey, visibleKeys.contains(previous.appKey) {
          counts["\(previous.appKey)|\(fact.appKey)", default: 0] += 1
        }
        previous = fact
      }
    }

    return counts.compactMap { key, count -> WeeklyAppTransition? in
      let parts = key.split(separator: "|", omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      return WeeklyAppTransition(from: String(parts[0]), to: String(parts[1]), count: count)
    }
    .sorted {
      if $0.count == $1.count {
        return "\($0.from)-\($0.to)" < "\($1.from)-\($1.to)"
      }
      return $0.count > $1.count
    }
  }

  private static func workPatterns(
    from transitions: [WeeklyAppTransition],
    aggregates: [String: WeeklyAppAggregate],
    activeDayCount: Int
  ) -> [WeeklyWorkPattern] {
    transitions.compactMap { transition -> WeeklyWorkPattern? in
      guard let from = aggregates[transition.from],
        let to = aggregates[transition.to],
        from.kind != .distraction,
        to.kind != .distraction
      else {
        return nil
      }

      let averageCount = max(1, Int((Double(transition.count) / Double(activeDayCount)).rounded()))
      return WeeklyWorkPattern(
        id: "\(from.key)-\(to.key)",
        from: patternApp(from),
        via: nil,
        to: patternApp(to),
        count: averageCount,
        description:
          "Moves from \(from.name) to \(to.name) an average of \(averageCount) times per active day."
      )
    }
    .prefixArray(2)
  }

  private static func rabbitHoleSnapshot(
    from transitions: [WeeklyAppTransition],
    aggregates: [String: WeeklyAppAggregate],
    visibleApps: [WeeklyAppAggregate]
  ) -> WeeklyRabbitHoleSnapshot {
    let distractionTransitions = transitions.filter { transition in
      guard let from = aggregates[transition.from], let to = aggregates[transition.to] else {
        return false
      }
      return from.kind != .distraction && to.kind == .distraction
    }

    if let first = distractionTransitions.first,
      let from = aggregates[first.from]
    {
      let targets =
        distractionTransitions
        .filter { $0.from == first.from }
        .compactMap { aggregates[$0.to] }
        .prefixArray(4)

      return WeeklyRabbitHoleSnapshot(
        from: patternApp(from),
        targets: targets.map(patternApp),
        avg: averageDurationText(for: targets)
      )
    }

    let from =
      visibleApps.first
      ?? WeeklyAppAggregate(
        key: "none",
        name: "No app",
        colorHex: "D9D9D9",
        kind: .work,
        minutes: 0,
        visits: 1
      )
    let targets = visibleApps.filter { $0.kind == .distraction }.prefixArray(4)
    return WeeklyRabbitHoleSnapshot(
      from: patternApp(from),
      targets: targets.map(patternApp),
      avg: averageDurationText(for: targets)
    )
  }

  private static func emptyApplicationInteractionsSnapshot()
    -> WeeklyApplicationInteractionsSnapshot
  {
    WeeklyApplicationInteractionsSnapshot(
      subtitle: "No recorded app interactions for this week yet.",
      nodes: [],
      edges: [],
      patterns: [],
      rabbitHole: WeeklyRabbitHoleSnapshot(
        from: WeeklyPatternApp(
          id: "none",
          name: "No app",
          initial: "-",
          color: Color(hex: "D9D9D9"),
          avg: "0m avg"
        ),
        targets: [],
        avg: "0m avg"
      )
    )
  }

  private static func visibleBuckets(
    items: [WeeklyCardFact],
    key: KeyPath<WeeklyCardFact, String>,
    name: KeyPath<WeeklyCardFact, String>,
    colorHex: KeyPath<WeeklyCardFact, String>,
    maxVisible: Int
  ) -> WeeklyVisibleBuckets {
    let grouped = Dictionary(grouping: items, by: { $0[keyPath: key] })
    let sortedBuckets = grouped.values.map { facts in
      WeeklyBucket(
        key: facts[0][keyPath: key],
        name: facts[0][keyPath: name],
        colorHex: facts[0][keyPath: colorHex],
        minutes: facts.reduce(0) { $0 + $1.durationMinutes }
      )
    }
    .sorted {
      if $0.minutes == $1.minutes {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return $0.minutes > $1.minutes
    }

    guard sortedBuckets.count > maxVisible else {
      return WeeklyVisibleBuckets(
        categories: sortedBuckets, visibleKeys: Set(sortedBuckets.map(\.key)))
    }

    let visible = Array(sortedBuckets.prefix(maxVisible - 1))
    let otherMinutes = sortedBuckets.dropFirst(maxVisible - 1).reduce(0) { $0 + $1.minutes }
    let categories =
      visible + [
        WeeklyBucket(key: otherKey, name: "Other", colorHex: otherColorHex, minutes: otherMinutes)
      ]
    return WeeklyVisibleBuckets(categories: categories, visibleKeys: Set(visible.map(\.key)))
  }

  private static func appMinutesByCategory(from facts: [WeeklyCardFact]) -> [String: Int] {
    var result: [String: Int] = [:]
    for fact in facts {
      result["\(fact.categoryKey)|\(fact.appKey)", default: 0] += fact.durationMinutes
    }
    return result
  }

  private static func treemapChange(currentMinutes: Int, previousMinutes: Int)
    -> WeeklyTreemapChange?
  {
    guard previousMinutes > 0 else { return nil }
    let delta = currentMinutes - previousMinutes
    if delta > 0 {
      return .positive(delta)
    }
    if delta < 0 {
      return .negative(abs(delta))
    }
    return .neutral(0)
  }

  private static func treemapPalette(for colorHex: String) -> WeeklyTreemapPalette {
    let accent = NSColor(hex: colorHex) ?? .systemBlue
    let color = Color(nsColor: accent)
    let tileFill = accent.blended(with: 0.86, of: .white) ?? .white
    let tileBorder = accent.blended(with: 0.36, of: .white) ?? accent

    return WeeklyTreemapPalette(
      shellFill: color.opacity(0.25),
      shellBorder: color.opacity(0.62),
      tileFill: Color(nsColor: tileFill),
      tileBorder: Color(nsColor: tileBorder),
      headerText: color
    )
  }

  private static func heatmapValues(
    for facts: [WeeklyCardFact],
    visibleStart: Double,
    bucketMinutes: Double,
    bucketCount: Int
  ) -> [Double] {
    var focusMinutes = Array(repeating: 0.0, count: bucketCount)
    var distractionMinutes = Array(repeating: 0.0, count: bucketCount)
    var switchPressure = Array(repeating: 0.0, count: bucketCount)
    var previousFact: WeeklyCardFact?

    for fact in facts.sorted(by: { $0.startMinute < $1.startMinute }) {
      if let previousFact,
        fact.startMinute - previousFact.endMinute <= 20,
        heatmapSignature(for: fact) != heatmapSignature(for: previousFact)
      {
        addHeatmapSwitch(
          at: fact.startMinute,
          to: &switchPressure,
          visibleStart: visibleStart,
          bucketMinutes: bucketMinutes
        )
      }

      addHeatmapFact(
        fact,
        focusMinutes: &focusMinutes,
        distractionMinutes: &distractionMinutes,
        visibleStart: visibleStart,
        bucketMinutes: bucketMinutes
      )
      previousFact = fact
    }

    return heatmapScores(
      focusMinutes: focusMinutes,
      distractionMinutes: distractionMinutes,
      switchPressure: switchPressure,
      bucketMinutes: bucketMinutes
    )
  }

  private static func addHeatmapFact(
    _ fact: WeeklyCardFact,
    focusMinutes: inout [Double],
    distractionMinutes: inout [Double],
    visibleStart: Double,
    bucketMinutes: Double
  ) {
    if isFullDistractionFact(fact) {
      addHeatmapInterval(
        start: fact.startMinute,
        end: fact.endMinute,
        to: &distractionMinutes,
        visibleStart: visibleStart,
        bucketMinutes: bucketMinutes
      )
      return
    }

    addHeatmapInterval(
      start: fact.startMinute,
      end: fact.endMinute,
      to: &focusMinutes,
      visibleStart: visibleStart,
      bucketMinutes: bucketMinutes
    )

    for interval in embeddedDistractionIntervals(for: fact) {
      addHeatmapInterval(
        start: interval.start,
        end: interval.end,
        to: &distractionMinutes,
        visibleStart: visibleStart,
        bucketMinutes: bucketMinutes
      )
      addHeatmapInterval(
        start: interval.start,
        end: interval.end,
        to: &focusMinutes,
        visibleStart: visibleStart,
        bucketMinutes: bucketMinutes,
        weight: -1
      )
    }
  }

  private static func addHeatmapInterval(
    start rawStart: Double,
    end rawEnd: Double,
    to values: inout [Double],
    visibleStart: Double,
    bucketMinutes: Double,
    weight: Double = 1
  ) {
    let visibleEnd = visibleStart + Double(values.count) * bucketMinutes
    let start = max(rawStart, visibleStart)
    let end = min(rawEnd, visibleEnd)
    guard end > start else { return }

    let firstIndex = max(0, Int(floor((start - visibleStart) / bucketMinutes)))
    let lastIndex = min(values.count - 1, Int(ceil((end - visibleStart) / bucketMinutes)) - 1)
    guard firstIndex <= lastIndex else { return }

    for index in firstIndex...lastIndex where values.indices.contains(index) {
      let bucketStart = visibleStart + (Double(index) * bucketMinutes)
      let bucketEnd = bucketStart + bucketMinutes
      let overlap = max(0, min(end, bucketEnd) - max(start, bucketStart))
      values[index] += overlap * weight
    }
  }

  private static func addHeatmapSwitch(
    at minute: Double,
    to values: inout [Double],
    visibleStart: Double,
    bucketMinutes: Double
  ) {
    let visibleEnd = visibleStart + Double(values.count) * bucketMinutes
    guard minute >= visibleStart && minute < visibleEnd else { return }

    let index = Int((minute - visibleStart) / bucketMinutes)
    guard values.indices.contains(index) else { return }
    values[index] += 1
  }

  private static func heatmapScores(
    focusMinutes: [Double],
    distractionMinutes: [Double],
    switchPressure: [Double],
    bucketMinutes: Double
  ) -> [Double] {
    let cleanFocus = focusMinutes.indices.map { index in
      focusMinutes[index] >= bucketMinutes * 0.6 && distractionMinutes[index] < 1
    }
    let focusRunLengths = heatmapRunLengths(from: cleanFocus)

    let rawScores = focusMinutes.indices.map { index -> Double in
      let focusRatio = max(0, min(1, focusMinutes[index] / bucketMinutes))
      let distractionRatio = max(0, min(1, distractionMinutes[index] / bucketMinutes))
      let sustainedFocusBoost = min(1, Double(focusRunLengths[index]) / 6)
      let focusStrength = focusRatio * (0.35 + (0.65 * sustainedFocusBoost))
      let distractionStrength = min(1, distractionRatio * 1.25)
      let switchStrength = min(1, switchPressure[index] / 2) * 0.22

      return max(-1, min(1, distractionStrength + switchStrength - focusStrength))
    }

    return smoothFocusedHeatmapScores(rawScores)
  }

  private static func heatmapRunLengths(from values: [Bool]) -> [Int] {
    var lengths = Array(repeating: 0, count: values.count)
    var index = 0

    while index < values.count {
      guard values[index] else {
        index += 1
        continue
      }

      let startIndex = index
      while index < values.count && values[index] {
        index += 1
      }

      let runLength = index - startIndex
      for runIndex in startIndex..<index {
        lengths[runIndex] = runLength
      }
    }

    return lengths
  }

  private static func smoothFocusedHeatmapScores(_ scores: [Double]) -> [Double] {
    guard scores.count > 2 else { return scores }

    return scores.indices.map { index in
      let value = scores[index]
      guard value < 0 else { return value }

      let lowerBound = max(scores.startIndex, index - 1)
      let upperBound = min(scores.index(before: scores.endIndex), index + 1)
      let focusedNeighbors = scores[lowerBound...upperBound].filter { $0 < 0 }
      guard focusedNeighbors.count > 1 else { return value }

      let average = focusedNeighbors.reduce(0, +) / Double(focusedNeighbors.count)
      return max(-1, min(1, (value * 0.55) + (average * 0.45)))
    }
  }

  private static func embeddedDistractionIntervals(for fact: WeeklyCardFact) -> [(
    start: Double, end: Double
  )] {
    guard let distractions = fact.card.distractions, !distractions.isEmpty else { return [] }

    return distractions.compactMap { distraction in
      guard let startMinute = parseCardMinute(distraction.startTime),
        let endMinute = parseCardMinute(distraction.endTime)
      else {
        return nil
      }

      return alignedDistractionRange(
        start: startMinute,
        end: endMinute,
        parentStart: fact.startMinute,
        parentEnd: fact.endMinute
      )
    }
  }

  private static func alignedDistractionRange(
    start: Double,
    end: Double,
    parentStart: Double,
    parentEnd: Double
  ) -> (start: Double, end: Double)? {
    let normalized = normalizedMinuteRange(start: start, end: end)
    let candidates = [
      normalized,
      (start: normalized.start - 1440, end: normalized.end - 1440),
      (start: normalized.start + 1440, end: normalized.end + 1440),
    ]

    return
      candidates
      .filter { candidate in
        candidate.start >= parentStart - 2
          && candidate.end <= parentEnd + 2
          && candidate.end > candidate.start
      }
      .min { lhs, rhs in
        let lhsDistance = abs(lhs.start - parentStart) + abs(parentEnd - lhs.end) * 0.1
        let rhsDistance = abs(rhs.start - parentStart) + abs(parentEnd - rhs.end) * 0.1
        return lhsDistance < rhsDistance
      }
  }

  private static func isFullDistractionFact(_ fact: WeeklyCardFact) -> Bool {
    let categoryText = "\(fact.categoryName) \(fact.card.subcategory)".lowercased()
    if categoryText.contains("distraction") || categoryText.contains("distracted") {
      return true
    }

    if fact.card.distractions?.isEmpty == false {
      return false
    }

    return fact.isDistraction
  }

  private static func heatmapSignature(for fact: WeeklyCardFact) -> String {
    "\(fact.categoryKey)|\(fact.appKey)"
  }

  private static func workflowCell(
    slotIndex: Int,
    dayFacts: [WeeklyCardFact],
    visibleStart: Double,
    slotMinutes: Double
  ) -> WeeklyWorkflowCell {
    let slotStart = visibleStart + (Double(slotIndex) * slotMinutes)
    let slotEnd = slotStart + slotMinutes
    var buckets: [String: WeeklyWorkflowBucket] = [:]

    for fact in dayFacts {
      let overlap = max(0, min(fact.endMinute, slotEnd) - max(fact.startMinute, slotStart))
      guard overlap > 0 else { continue }

      let bucket = workflowBucket(for: fact)
      var updatedBucket = buckets[bucket.id] ?? bucket
      updatedBucket.minutes += overlap
      buckets[bucket.id] = updatedBucket
    }

    let totalMinutes = buckets.values.reduce(0) { $0 + $1.minutes }
    guard let dominant = buckets.values.sorted(by: workflowBucketSort).first else {
      return WeeklyWorkflowCell(
        id: "slot-\(slotIndex)",
        categoryName: nil,
        colorHex: nil,
        minutes: 0,
        occupancy: 0
      )
    }

    return WeeklyWorkflowCell(
      id: "slot-\(slotIndex)",
      categoryName: dominant.name,
      colorHex: dominant.colorHex,
      minutes: Int(totalMinutes.rounded()),
      occupancy: min(1, totalMinutes / slotMinutes)
    )
  }

  private static func workflowTotals(from facts: [WeeklyCardFact]) -> [WeeklyWorkflowTotalItem] {
    let grouped = Dictionary(grouping: facts) { fact in
      workflowBucket(for: fact).id
    }

    let totals = grouped.values.compactMap { categoryFacts -> WeeklyWorkflowTotalItem? in
      guard let first = categoryFacts.first else { return nil }
      let minutes = categoryFacts.reduce(0) { $0 + $1.durationMinutes }
      guard minutes > 0 else { return nil }
      let bucket = workflowBucket(for: first)

      return WeeklyWorkflowTotalItem(
        id: bucket.id,
        name: bucket.name,
        minutes: minutes,
        duration: durationText(minutes),
        colorHex: bucket.colorHex
      )
    }

    return totals.sorted {
      if $0.minutes == $1.minutes {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return $0.minutes > $1.minutes
    }
    .prefix(7)
    .map { $0 }
  }

  private static func weeklyActivityWindow(from facts: [WeeklyCardFact]) -> (
    start: Double, end: Double
  ) {
    let fallbackStart = 9.0 * 60.0
    let fallbackEnd = 22.0 * 60.0
    let dayStart = 4.0 * 60.0
    let dayEnd = 28.0 * 60.0
    let padding = 30.0
    let snapMinutes = 15.0

    guard let earliest = facts.map(\.startMinute).min(),
      let latest = facts.map(\.endMinute).max()
    else {
      return (fallbackStart, fallbackEnd)
    }

    let paddedStart = max(dayStart, earliest - padding)
    let paddedEnd = min(dayEnd, latest + padding)
    let snappedStart = floor(paddedStart / snapMinutes) * snapMinutes
    var snappedEnd = ceil(paddedEnd / snapMinutes) * snapMinutes

    if snappedEnd == 24.0 * 60.0 {
      snappedEnd = dayEnd
    }

    guard snappedEnd > snappedStart else {
      return (fallbackStart, fallbackEnd)
    }

    return (snappedStart, snappedEnd)
  }

  private static func weeklyTimeLabels(
    startMinute: Double,
    endMinute: Double
  ) -> [WeeklyWorkflowTimeLabel] {
    let firstHour = ceil(startMinute / 60.0) * 60.0
    let lastHour = floor(endMinute / 60.0) * 60.0

    guard firstHour <= lastHour else {
      return []
    }

    return stride(from: firstHour, through: lastHour, by: 60.0).map { minute in
      WeeklyWorkflowTimeLabel(
        id: "time-\(Int(minute))",
        label: workflowClockLabel(from: minute),
        minute: minute
      )
    }
  }

  private static func workflowClockLabel(from minute: Double) -> String {
    let totalMinutes = Int(minute.rounded())
    let hour24 = (totalMinutes / 60) % 24
    let minutePart = totalMinutes % 60
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    let suffix = hour24 < 12 ? "am" : "pm"
    if minutePart > 0 {
      return String(format: "%d:%02d%@", hour12, minutePart, suffix)
    }
    return "\(hour12)\(suffix)"
  }

  private static func workflowBucket(for fact: WeeklyCardFact) -> WeeklyWorkflowBucket {
    if isDistractionCategory(fact) {
      return WeeklyWorkflowBucket(
        id: "distraction",
        name: "Distraction",
        colorHex: "FF5950",
        minutes: 0
      )
    }

    return WeeklyWorkflowBucket(
      id: fact.categoryKey,
      name: fact.categoryName,
      colorHex: fact.categoryColorHex,
      minutes: 0
    )
  }

  private static func isDistractionCategory(_ fact: WeeklyCardFact) -> Bool {
    fact.categoryKey.contains("distraction")
      || fact.categoryName.localizedCaseInsensitiveContains("distraction")
  }

  private static func workflowBucketSort(
    lhs: WeeklyWorkflowBucket,
    rhs: WeeklyWorkflowBucket
  ) -> Bool {
    if lhs.minutes == rhs.minutes {
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    return lhs.minutes > rhs.minutes
  }

  private static func distractionStartMinutes(for fact: WeeklyCardFact) -> [Double] {
    if let distractions = fact.card.distractions, !distractions.isEmpty {
      return distractions.compactMap { parseCardMinute($0.startTime) }
    }

    return fact.isDistraction ? [fact.startMinute] : []
  }

  private static func isDistributionMinute(_ minute: Double) -> Bool {
    minute >= 10 * 60 && minute <= 18 * 60
  }

  private static func contextInsight(from days: [WeeklyContextComparisonDay]) -> String {
    guard
      let busiest = days.max(by: { lhs, rhs in
        (lhs.distracted + lhs.shifts) < (rhs.distracted + rhs.shifts)
      }), busiest.distracted + busiest.shifts > 0
    else {
      return "No context shift or distraction pattern was detected in this week."
    }

    return
      "\(busiest.day) had the most interruptions, with \(busiest.shifts) context shifts and \(busiest.distracted) distractions."
  }

  private static func edgeKind(
    from: WeeklyApplicationKind,
    to: WeeklyApplicationKind
  ) -> WeeklyApplicationKind {
    if from == .distraction || to == .distraction {
      return .distraction
    }
    if from == .personal || to == .personal {
      return .personal
    }
    return .work
  }

  private static func resolvedAppKind(from facts: [WeeklyCardFact]) -> WeeklyApplicationKind {
    if facts.contains(where: { $0.appKind == .distraction }) {
      return .distraction
    }
    if facts.contains(where: { $0.appKind == .personal }) {
      return .personal
    }
    return .work
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

  private static func dayDescriptors(
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

  private static func heatmapDayDescriptors(for weekRange: WeeklyDateRange) -> [WeeklyDayDescriptor]
  {
    dayDescriptors(for: weekRange, offsets: [6, 0, 1, 2, 3, 4, 5])
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

  private static func sankeySourceName(for weekRange: WeeklyDateRange) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    let start = formatter.string(from: weekRange.weekStart)
    let endDate =
      calendar.date(byAdding: .day, value: 6, to: weekRange.weekStart) ?? weekRange.weekEnd
    let end = formatter.string(from: endDate)
    return "\(start)-\(end)"
  }

  private static func topLevelDetail(for aggregate: WeeklyCategoryAggregate) -> String {
    let duration = durationText(aggregate.minutes)
    let sessionLabel = aggregate.count == 1 ? "session" : "sessions"
    let summary =
      aggregate.representative.map { cardNarrative(for: $0.card, maxLength: 105) }
      ?? "No summary available."
    return "Spent \(duration) across \(aggregate.count) \(sessionLabel). \(summary)"
  }

  private static func patternApp(_ aggregate: WeeklyAppAggregate) -> WeeklyPatternApp {
    WeeklyPatternApp(
      id: aggregate.key,
      name: aggregate.name,
      initial: appInitial(aggregate.name),
      color: Color(hex: aggregate.colorHex),
      avg: averageDurationText(minutes: aggregate.minutes, visits: aggregate.visits)
    )
  }

  private static func averageDurationText(for aggregates: [WeeklyAppAggregate]) -> String {
    let minutes = aggregates.reduce(0) { $0 + $1.minutes }
    let visits = max(aggregates.reduce(0) { $0 + $1.visits }, 1)
    return averageDurationText(minutes: minutes, visits: visits)
  }

  private static func averageDurationText(minutes: Int, visits: Int) -> String {
    let averageMinutes = max(1, Int((Double(minutes) / Double(max(visits, 1))).rounded()))
    return "\(durationText(averageMinutes)) avg"
  }

  private static func durationText(_ minutes: Int) -> String {
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

  private static func parseCardMinute(_ value: String) -> Double? {
    guard let parsed = parseTimeHMMA(timeString: value) else { return nil }
    return Double(parsed)
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

  private static func clockTime(from minute: Double) -> String {
    let normalized = Int(minute) % 1440
    let hour = normalized / 60
    let minutes = normalized % 60
    return String(format: "%02d:%02d", hour, minutes)
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

  private static func appInitial(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map { String($0).uppercased() } ?? "-"
  }
}

private struct WeeklyCardFact {
  let id: String
  let card: TimelineCard
  let dayString: String
  let dayLabel: String
  let dayOrder: Int
  let startMinute: Double
  let endMinute: Double
  let durationMinutes: Int
  let categoryKey: String
  let categoryName: String
  let categoryColorHex: String
  let isSystem: Bool
  let isIdle: Bool
  let isDistraction: Bool
  let appKey: String
  let appName: String
  let appColorHex: String
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
  let appKind: WeeklyApplicationKind

  var hasFaviconLookupSource: Bool {
    hasNonEmpty(faviconPrimaryRaw) || hasNonEmpty(faviconSecondaryRaw)
      || hasNonEmpty(faviconPrimaryHost) || hasNonEmpty(faviconSecondaryHost)
  }

  private func hasNonEmpty(_ value: String?) -> Bool {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
}

private struct WeeklyWorkflowBucket {
  let id: String
  let name: String
  let colorHex: String
  var minutes: Double
}

private struct WeeklyDayDescriptor {
  let id: String
  let label: String
  let dayString: String
  let order: Int
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

private struct WeeklyAppAggregate {
  let key: String
  let name: String
  let colorHex: String
  let kind: WeeklyApplicationKind
  let minutes: Int
  let visits: Int
}

private struct WeeklyAppTransition {
  let from: String
  let to: String
  let count: Int
}

private struct WeeklyBucket {
  let key: String
  let name: String
  let colorHex: String
  let minutes: Int
}

private struct WeeklyVisibleBuckets {
  let categories: [WeeklyBucket]
  let visibleKeys: Set<String>

  func bucketKey(for key: String) -> String {
    visibleKeys.contains(key) ? key : "other"
  }
}

extension Sequence {
  fileprivate func prefixArray(_ maxLength: Int) -> [Element] {
    Array(prefix(maxLength))
  }
}
