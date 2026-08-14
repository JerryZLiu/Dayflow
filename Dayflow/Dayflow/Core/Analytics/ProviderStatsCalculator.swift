//
//  ProviderStatsCalculator.swift
//  Dayflow
//
//  Derives per-provider / per-model / per-day / per-week usage statistics
//  from a list of `TimelineCard`s. Used by the dashboard view to render
//  the GitHub-commit-style heatmap and the provider breakdown.
//

import Foundation

// MARK: - Public models

struct ProviderStatsSummary {
  /// Total number of cards in the input. Cached because every view re-reads it.
  let totalCards: Int

  /// Cards per provider ID ("gemini", "minimax", "ollama", "chatgpt_claude", "dayflow").
  /// Always includes an entry for the 5 known providers, even if zero.
  let byProvider: [String: Int]

  /// Cards per (providerID|modelID) tuple — the per-model breakdown.
  let byModel: [(providerID: String, modelID: String, count: Int)]

  /// Daily buckets covering the most recent `days` days (default 365).
  let daily: [DailyStat]
  /// Weekly buckets covering the most recent `weeks` weeks (default 26).
  let weekly: [WeeklyStat]
  /// Monthly buckets covering the most recent `months` months (default 12).
  let monthly: [MonthlyStat]

  /// Earliest card date in the dataset (or nil if no cards).
  let earliest: Date?
  /// Latest card date in the dataset (or nil if no cards).
  let latest: Date?

  /// A flat (date, count) list for the GitHub-style heatmap (defaults to the
  /// last 365 days). The view is responsible for rendering the grid.
  let heatmapDays: [HeatmapDay]

  /// The most active day in `daily`, useful as a quick callout.
  let peakDay: DailyStat?
}

struct DailyStat: Identifiable, Hashable {
  var id: Date { date }
  let date: Date
  let count: Int
}

struct WeeklyStat: Identifiable, Hashable {
  var id: Date { weekStart }
  let weekStart: Date  // Monday of the week
  let count: Int
}

struct MonthlyStat: Identifiable, Hashable {
  var id: Date { monthStart }
  let monthStart: Date  // First day of the month
  let count: Int
}

struct HeatmapDay: Identifiable, Hashable {
  var id: Date { date }
  let date: Date
  let count: Int
  /// Normalized intensity 0...1, where 1.0 = peak day in the dataset.
  let intensity: Double
}

// MARK: - Calculator

enum ProviderStatsCalculator {
  static let knownProviders: [String] = [
    "gemini", "minimax", "ollama", "chatgpt_claude", "dayflow"
  ]

  /// Compute a summary from a list of cards. The cards may span any time
  /// range; the calculator normalizes to calendar boundaries (Mon-Sun weeks,
  /// 1st-of-month months, …).
  static func summary(
    from cards: [TimelineCard],
    days: Int = 365,
    weeks: Int = 26,
    months: Int = 12,
    calendar: Calendar = .current
  ) -> ProviderStatsSummary {
    let total = cards.count

    // byProvider
    var byProvider: [String: Int] = [:]
    for p in knownProviders { byProvider[p] = 0 }
    for card in cards {
      let key = (card.providerId ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
      let bucket = key.isEmpty ? "unknown" : key
      byProvider[bucket, default: 0] += 1
    }

    // byModel
    var byModelDict: [String: (providerID: String, modelID: String, count: Int)] = [:]
    for card in cards {
      let p = (card.providerId ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
      let m = (card.modelId ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
      let pKey = p.isEmpty ? "unknown" : p
      let mKey = m.isEmpty ? "unknown" : m
      let key = "\(pKey)|\(mKey)"
      if var existing = byModelDict[key] {
        existing.count += 1
        byModelDict[key] = existing
      } else {
        byModelDict[key] = (providerID: pKey, modelID: mKey, count: 1)
      }
    }
    let byModel = byModelDict.values
      .sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        if lhs.providerID != rhs.providerID { return lhs.providerID < rhs.providerID }
        return lhs.modelID < rhs.modelID
      }

    // Date parsing helpers
    func parseDate(_ s: String) -> Date? {
      let formatters: [DateFormatter] = {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        iso.locale = Locale(identifier: "en_US_POSIX")
        let alt = DateFormatter()
        alt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        alt.locale = Locale(identifier: "en_US_POSIX")
        return [iso, alt]
      }()
      for f in formatters { if let d = f.date(from: s) { return d } }
      return nil
    }

    let dates: [Date] = cards.compactMap { parseDate($0.startTimestamp) }
    let earliest = dates.min()
    let latest = dates.max()

    // Daily
    let today = calendar.startOfDay(for: Date())
    var dailyCounts: [Date: Int] = [:]
    for d in dates {
      let day = calendar.startOfDay(for: d)
      dailyCounts[day, default: 0] += 1
    }
    let daily: [DailyStat] = (0..<days).reversed().map { offset in
      let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
      return DailyStat(date: day, count: dailyCounts[day] ?? 0)
    }

    // Weekly
    var weeklyCounts: [Date: Int] = [:]
    for d in dates {
      let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
      if let weekStart = calendar.date(from: comps) {
        weeklyCounts[weekStart, default: 0] += 1
      }
    }
    let weekly: [WeeklyStat] = (0..<weeks).reversed().compactMap { offset in
      guard let weekStart = calendar.date(
        byAdding: .weekOfYear, value: -offset,
        to: calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) ?? today
      ) else { return nil }
      return WeeklyStat(weekStart: weekStart, count: weeklyCounts[weekStart] ?? 0)
    }

    // Monthly
    var monthlyCounts: [Date: Int] = [:]
    for d in dates {
      let comps = calendar.dateComponents([.year, .month], from: d)
      if let monthStart = calendar.date(from: comps) {
        monthlyCounts[monthStart, default: 0] += 1
      }
    }
    let monthly: [MonthlyStat] = (0..<months).reversed().compactMap { offset in
      guard let monthStart = calendar.date(
        byAdding: .month, value: -offset,
        to: calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
      ) else { return nil }
      return MonthlyStat(monthStart: monthStart, count: monthlyCounts[monthStart] ?? 0)
    }

    // Heatmap
    let peak = max(1, daily.map(\.count).max() ?? 1)
    let heatmapDays: [HeatmapDay] = daily.map { day in
      HeatmapDay(
        date: day.date,
        count: day.count,
        intensity: min(1.0, Double(day.count) / Double(peak))
      )
    }

    let peakDay = daily.max(by: { $0.count < $1.count })

    return ProviderStatsSummary(
      totalCards: total,
      byProvider: byProvider,
      byModel: byModel,
      daily: daily,
      weekly: weekly,
      monthly: monthly,
      earliest: earliest,
      latest: latest,
      heatmapDays: heatmapDays,
      peakDay: peakDay
    )
  }
}
