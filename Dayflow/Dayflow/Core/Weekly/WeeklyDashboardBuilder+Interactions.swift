//
//  WeeklyDashboardBuilder+Interactions.swift
//  Dayflow
//

import Foundation
import SwiftUI

extension WeeklyDashboardBuilder {
  static func buildContextCharts(
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

  static func buildApplicationInteractions(
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

  private static func clockTime(from minute: Double) -> String {
    let normalized = Int(minute) % 1440
    let hour = normalized / 60
    let minutes = normalized % 60
    return String(format: "%02d:%02d", hour, minutes)
  }

  private static func appInitial(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map { String($0).uppercased() } ?? "-"
  }
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

extension Sequence {
  fileprivate func prefixArray(_ maxLength: Int) -> [Element] {
    Array(prefix(maxLength))
  }
}
