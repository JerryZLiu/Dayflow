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
  let isAggregate: Bool
  let isPlaceholder: Bool

  init(
    id: String,
    name: String,
    duration: TimeInterval,
    change: WeeklyTreemapChange?,
    isAggregate: Bool = false,
    isPlaceholder: Bool = false
  ) {
    self.id = id
    self.name = name
    self.duration = duration
    self.change = change
    self.isAggregate = isAggregate
    self.isPlaceholder = isPlaceholder
  }

  var weight: CGFloat {
    max(CGFloat(duration), 1)
  }

  var formattedDuration: String {
    duration.weeklyTreemapDurationString
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
  let text: String
  let color: Color

  static func positive(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "+ \(minutes)m", color: Color(hex: "3AA34C"))
  }

  static func negative(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "- \(minutes)m", color: Color(hex: "DE2121"))
  }

  static func neutral(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "\(minutes)m", color: Color(hex: "8D8C8A"))
  }
}

struct WeeklyTreemapPalette {
  let shellFill: Color
  let shellBorder: Color
  let tileFill: Color
  let tileBorder: Color
  let headerText: Color

  static let design = WeeklyTreemapPalette(
    shellFill: Color(hex: "DE9DFC").opacity(0.25),
    shellBorder: Color(hex: "E2A3FF"),
    tileFill: Color(hex: "FAF3FF"),
    tileBorder: Color(hex: "E6B0FF"),
    headerText: Color(hex: "B922FF")
  )

  static let communication = WeeklyTreemapPalette(
    shellFill: Color(hex: "2DBFAE").opacity(0.25),
    shellBorder: Color(hex: "76CCC2"),
    tileFill: Color(hex: "E4F9F7"),
    tileBorder: Color(hex: "B4D2CE"),
    headerText: Color(hex: "00907F")
  )

  static let testing = WeeklyTreemapPalette(
    shellFill: Color(hex: "FC7645").opacity(0.25),
    shellBorder: Color(hex: "F7936F"),
    tileFill: Color(hex: "FFEDE7"),
    tileBorder: Color(hex: "FFB9A1"),
    headerText: Color(hex: "F04407")
  )

  static let research = WeeklyTreemapPalette(
    shellFill: Color(hex: "93BCFF").opacity(0.25),
    shellBorder: Color(hex: "91AEF1"),
    tileFill: Color(hex: "EEF4FF"),
    tileBorder: Color(hex: "B9D4FF"),
    headerText: Color(hex: "2061F5")
  )
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
