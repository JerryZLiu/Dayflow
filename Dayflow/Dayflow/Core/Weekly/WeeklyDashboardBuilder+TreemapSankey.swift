//
//  WeeklyDashboardBuilder+TreemapSankey.swift
//  Dayflow
//

import AppKit
import Foundation
import SwiftUI

extension WeeklyDashboardBuilder {
  static func buildTreemap(
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

  static func buildSankey(
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

    var visible = Array(sortedBuckets.prefix(maxVisible - 1))
    var otherMinutes = sortedBuckets.dropFirst(maxVisible - 1).reduce(0) { $0 + $1.minutes }
    // Coalesce any pre-existing "other" bucket so the synthesised overflow doesn't duplicate its key.
    if let collidingIndex = visible.firstIndex(where: { $0.key == otherKey }) {
      otherMinutes += visible.remove(at: collidingIndex).minutes
    }
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

  private static func sankeySourceName(for weekRange: WeeklyDateRange) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    let start = formatter.string(from: weekRange.weekStart)
    let endDate =
      calendar.date(byAdding: .day, value: 6, to: weekRange.weekStart) ?? weekRange.weekEnd
    let end = formatter.string(from: endDate)
    return "\(start)-\(end)"
  }
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
