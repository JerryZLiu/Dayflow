//
//  WeeklyDashboardModels.swift
//  Dayflow
//

import Foundation

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

struct WeeklyFlowFocusSnapshot {
  let heatmap: WeeklyFocusHeatmapSnapshot
  let trackedMinutes: Int
  let distractedMinutes: Int

  /// What goes over the Flow bridge. Scores run from -1 (focused) to 1
  /// (distracted), rounded to two places; rows carry the day id ("mon"…).
  var bridgePayload: [String: Any] {
    [
      "available": trackedMinutes > 0,
      "trackedMinutes": trackedMinutes,
      "distractedMinutes": distractedMinutes,
      "startMinute": heatmap.startMinute,
      "bucketMinutes": heatmap.bucketMinutes,
      "rows": heatmap.rows.map { row in
        [
          "day": row.id,
          "values": row.values.map { ($0 * 100).rounded() / 100 },
        ] as [String: Any]
      },
    ]
  }
}

struct WeeklyCardFact {
  let id: String
  let card: TimelineCard
  var dayString: String
  let dayLabel: String
  let dayOrder: Int
  var startMinute: Double
  var endMinute: Double
  var durationMinutes: Int
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

struct WeeklyDayDescriptor {
  let id: String
  let label: String
  let dayString: String
  let order: Int
}
