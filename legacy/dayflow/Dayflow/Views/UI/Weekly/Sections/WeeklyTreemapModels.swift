import SwiftUI

struct WeeklyTreemapCategory: Identifiable {
  let id: String
  let name: String
  let palette: WeeklyTreemapPalette
  let apps: [WeeklyTreemapApp]

  var totalDuration: TimeInterval {
    apps.reduce(0) { partial, app in
      partial + app.duration
    }
  }

  var weight: CGFloat {
    max(CGFloat(totalDuration), 1)
  }

  var formattedDuration: String {
    totalDuration.weeklyTreemapDurationString
  }

  static func displayOrder(_ lhs: WeeklyTreemapCategory, _ rhs: WeeklyTreemapCategory) -> Bool {
    if lhs.weight != rhs.weight {
      return lhs.weight > rhs.weight
    }

    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
  }
}

struct WeeklyTreemapApp: Identifiable {
  let id: String
  let name: String
  let duration: TimeInterval
  let change: WeeklyTreemapChange?
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
  let isAggregate: Bool
  let isPlaceholder: Bool

  init(
    id: String,
    name: String,
    duration: TimeInterval,
    change: WeeklyTreemapChange?,
    faviconPrimaryRaw: String? = nil,
    faviconSecondaryRaw: String? = nil,
    faviconPrimaryHost: String? = nil,
    faviconSecondaryHost: String? = nil,
    isAggregate: Bool = false,
    isPlaceholder: Bool = false
  ) {
    self.id = id
    self.name = name
    self.duration = duration
    self.change = change
    self.faviconPrimaryRaw = faviconPrimaryRaw
    self.faviconSecondaryRaw = faviconSecondaryRaw
    self.faviconPrimaryHost = faviconPrimaryHost
    self.faviconSecondaryHost = faviconSecondaryHost
    self.isAggregate = isAggregate
    self.isPlaceholder = isPlaceholder
  }

  var weight: CGFloat {
    max(CGFloat(duration), 1)
  }

  var formattedDuration: String {
    duration.weeklyTreemapDurationString
  }

  var hasFaviconSource: Bool {
    guard !isAggregate, !isPlaceholder else { return false }
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

  static func displayOrder(_ lhs: WeeklyTreemapApp, _ rhs: WeeklyTreemapApp) -> Bool {
    if lhs.weight != rhs.weight {
      return lhs.weight > rhs.weight
    }

    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
  }

  func merging(_ other: WeeklyTreemapApp) -> WeeklyTreemapApp {
    WeeklyTreemapApp(
      id: id,
      name: name,
      duration: duration + other.duration,
      change: nil,
      isAggregate: true,
      isPlaceholder: false
    )
  }

  static func aggregate(containing apps: [WeeklyTreemapApp]) -> WeeklyTreemapApp {
    WeeklyTreemapApp(
      id: "other",
      name: "Other",
      duration: apps.reduce(0) { $0 + $1.duration },
      change: nil,
      isAggregate: true,
      isPlaceholder: false
    )
  }
}

struct WeeklyTreemapChange {
  enum Kind {
    case positive
    case negative
    case neutral
  }

  let text: String
  let kind: Kind

  var color: Color {
    switch kind {
    case .positive:
      return Color.dayflowAdaptive(
        light: NSColor(hex: "089041") ?? .black, dark: NSColor(hex: "E0FBEE") ?? .white)
    case .negative:
      return Color.dayflowAdaptive(
        light: NSColor(hex: "E25922") ?? .black, dark: NSColor(hex: "FCE3E1") ?? .white)
    case .neutral:
      return Color(hex: "8D8C8A")
    }
  }

  var badgeFill: Color {
    switch kind {
    case .positive:
      return Color.dayflowAdaptive(
        light: NSColor(hex: "D1EAE4") ?? .white, dark: NSColor(hex: "58927F") ?? .black)
    case .negative:
      return Color.dayflowAdaptive(
        light: NSColor(hex: "FAE0D8") ?? .white, dark: NSColor(hex: "CA6D59") ?? .black)
    case .neutral:
      return .clear
    }
  }

  static func positive(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "+ \(minutes)m", kind: .positive)
  }

  static func negative(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "- \(minutes)m", kind: .negative)
  }

  static func neutral(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "\(minutes)m", kind: .neutral)
  }
}

struct WeeklyTreemapPalette {
  let shellFill: Color
  let shellBorder: Color
  let tileFill: Color
  let tileBorder: Color
  let headerText: Color

  // Figma "Edits after first implementation": the treemap layers the raw
  // category color at fixed opacities over the themed card background, so a
  // single formula holds for both light and dark mode.
  static func category(hex: String) -> WeeklyTreemapPalette {
    let base = Color(hex: hex)
    return WeeklyTreemapPalette(
      shellFill: base.opacity(0.25),
      shellBorder: base.opacity(0.75),
      tileFill: base.opacity(0.42),
      tileBorder: base,
      headerText: Color.dayflowAdaptive(
        light: NSColor(hex: "6D6D6D") ?? .darkGray, dark: NSColor(hex: "DFDFDF") ?? .lightGray)
    )
  }

  static let design = WeeklyTreemapPalette.category(hex: "DE9DFC")
  static let communication = WeeklyTreemapPalette.category(hex: "2DBFAE")
  static let testing = WeeklyTreemapPalette.category(hex: "FC7645")
  static let research = WeeklyTreemapPalette.category(hex: "93BCFF")
  static let general = WeeklyTreemapPalette.category(hex: "727272")
}

extension TimeInterval {
  var weeklyTreemapDurationString: String {
    let totalMinutes = Int(self / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0, minutes > 0 {
      return "\(hours)hr \(minutes)m"
    }

    if hours > 0 {
      return "\(hours)hr"
    }

    return "\(minutes)m"
  }
}

extension CGRect {
  var area: CGFloat {
    width * height
  }
}
