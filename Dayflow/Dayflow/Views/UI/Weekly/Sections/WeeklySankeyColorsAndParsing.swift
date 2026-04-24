import SwiftUI

extension WeeklySankeyFixture {
  static func categoryRibbonColor(for id: String) -> Color {
    softenedColor(
      hex: categoryBarHex(for: id),
      by: categoryRibbonSofteningAmount(for: id)
    )
  }

  static func appRibbonColor(for id: String) -> Color {
    softenedColor(
      hex: appBarHex(for: id),
      by: appRibbonSofteningAmount(for: id)
    )
  }

  static func categoryBarHex(for id: String) -> String {
    switch id {
    case "research":
      return "73A7FF"
    case "communication":
      return "6CDACD"
    case "design":
      return "DE9DFC"
    case "general":
      return "BFB6AE"
    case "testing":
      return "FFA189"
    case "distractions":
      return "FF5950"
    case "personal":
      return "FFC6B7"
    default:
      return "D9CBC0"
    }
  }

  static func appBarHex(for id: String) -> String {
    switch id {
    case "chatgpt":
      return "333333"
    case "zoom":
      return "4085FD"
    case "clickup":
      return "FD1BB9"
    case "slack":
      return "36C5F0"
    case "youtube":
      return "FF0000"
    case "claude":
      return "D97757"
    case "figma":
      return "FF7262"
    case "x", "medium":
      return "000000"
    case "other":
      return "D9D9D9"
    default:
      return "D9D9D9"
    }
  }

  static func categoryRibbonSofteningAmount(for id: String) -> CGFloat {
    switch id {
    case "research":
      return 0.78
    case "communication":
      return 0.8
    case "design":
      return 0.8
    case "general":
      return 0.45
    case "testing":
      return 0.72
    case "distractions":
      return 0.76
    case "personal":
      return 0.18
    default:
      return 0.7
    }
  }

  static func appRibbonSofteningAmount(for id: String) -> CGFloat {
    switch id {
    case "chatgpt":
      return 0.8
    case "zoom":
      return 0.78
    case "clickup":
      return 0.82
    case "slack":
      return 0.8
    case "youtube":
      return 0.8
    case "claude":
      return 0.72
    case "figma":
      return 0.72
    case "x", "medium":
      return 0.84
    case "other":
      return 0.18
    default:
      return 0.75
    }
  }

  static func liveColumns(
    totalMinutes: Int,
    geometry: WeeklySankeyFixture
  ) -> (columns: [SankeyColumnSpec], categoryPointsPerMinute: CGFloat, appPointsPerMinute: CGFloat)
  {
    let total = max(CGFloat(totalMinutes), 1)
    let sourcePointsPerMinute = 300 / total
    let categoryPointsPerMinute = sourcePointsPerMinute * 0.86
    let appPointsPerMinute = sourcePointsPerMinute * 0.58

    let columns = geometry.columns.map { column in
      switch column.id {
      case "source":
        return column.updating(pointsPerUnit: sourcePointsPerMinute)
      case "categories":
        return column.updating(pointsPerUnit: categoryPointsPerMinute)
      case "apps":
        return column.updating(pointsPerUnit: appPointsPerMinute)
      default:
        return column
      }
    }

    return (columns, categoryPointsPerMinute, appPointsPerMinute)
  }

  static func dynamicSourceLink(
    id: String,
    sourceNodeID: String,
    targetNodeID: String,
    value: CGFloat,
    sourceOrder: Int,
    opacity: Double,
    targetColorHex: String
  ) -> SankeyLinkSpec {
    let center = CGFloat(3)
    let spread = CGFloat(sourceOrder) - center

    return SankeyLinkSpec(
      id: id,
      sourceNodeID: sourceNodeID,
      targetNodeID: targetNodeID,
      value: value,
      sourceOrder: sourceOrder,
      targetOrder: 0,
      style: SankeyRibbonStyle(
        leadingColor: sourceBlendNeutral,
        trailingColor: softenedColor(
          hex: targetColorHex,
          by: categoryRibbonSofteningAmount(for: targetNodeID)
        ),
        opacity: opacity,
        zIndex: Double(sourceOrder),
        leadingControlFactor: 0.26,
        trailingControlFactor: 0.34,
        topStartBend: spread * 6,
        topEndBend: spread * 2,
        bottomStartBend: spread * 6,
        bottomEndBend: spread * 2
      )
    )
  }

  static func dynamicAppLink(
    id: String,
    source: String,
    target: String,
    value: CGFloat,
    sourceOrder: Int,
    targetOrder: Int,
    opacity: Double,
    contentsByID: [String: WeeklySankeyNodeContent]
  ) -> SankeyLinkSpec {
    let slope = CGFloat(targetOrder - sourceOrder)
    let sourceColorHex = contentsByID[source]?.barColorHex ?? categoryBarHex(for: source)
    let targetColorHex = contentsByID[target]?.barColorHex ?? appBarHex(for: target)

    return SankeyLinkSpec(
      id: id,
      sourceNodeID: source,
      targetNodeID: target,
      value: value,
      sourceOrder: sourceOrder,
      targetOrder: targetOrder,
      style: SankeyRibbonStyle(
        leadingColor: softenedColor(
          hex: sourceColorHex,
          by: categoryRibbonSofteningAmount(for: source)
        ),
        trailingColor: softenedColor(
          hex: targetColorHex,
          by: appRibbonSofteningAmount(for: target)
        ),
        opacity: opacity,
        zIndex: 100 + Double(targetOrder * 10 + sourceOrder),
        leadingControlFactor: 0.3,
        trailingControlFactor: 0.3,
        topStartBend: slope * 1.5,
        topEndBend: slope * 4,
        bottomStartBend: slope * 1.5,
        bottomEndBend: slope * 4
      )
    )
  }

  static func sourceOpacity(for minutes: Int, totalMinutes: Int) -> Double {
    let share = Double(minutes) / Double(max(totalMinutes, 1))
    return min(max(0.72 + (share * 0.4), 0.76), 0.9)
  }

  static func appOpacity(minutes: Int, totalMinutes: Int) -> Double {
    let share = Double(minutes) / Double(max(totalMinutes, 1))
    return min(max(0.7 + (share * 0.55), 0.76), 0.9)
  }

  static func shareText(minutes: Int, totalMinutes: Int) -> String {
    let share = Double(minutes) / Double(max(totalMinutes, 1))
    return "\(Int((share * 100).rounded()))%"
  }

  static func resolvedCategoryBucket(
    id: String,
    card: TimelineCard,
    categories: [String: TimelineCategory]
  ) -> WeeklySankeyCategoryBucket {
    let category = categories[id]
    return WeeklySankeyCategoryBucket(
      id: id,
      title: category?.name ?? displayName(for: card.category),
      colorHex: sanitizedHex(category?.colorHex) ?? fallbackCategoryHex(for: id),
      totalMinutes: 0,
      order: category?.order ?? Int.max
    )
  }

  static func resolvedAppBucket(
    primaryRaw: String?,
    secondaryRaw: String?
  ) -> WeeklySankeyAppBucket? {
    let raw = preferredRawAppValue(primaryRaw: primaryRaw, secondaryRaw: secondaryRaw)
    let host = normalizedHost(raw) ?? normalizedHost(secondaryRaw)

    guard raw != nil || host != nil else {
      return nil
    }

    let id = canonicalAppID(raw: raw, host: host)
    let resolvedHost = faviconHost(for: id, host: host)

    return WeeklySankeyAppBucket(
      id: id,
      title: appTitle(for: id, raw: raw, host: resolvedHost),
      colorHex: appColorHex(for: id, host: resolvedHost),
      iconSource: appIconSource(for: id, raw: raw, host: resolvedHost),
      raw: raw ?? resolvedHost,
      host: resolvedHost,
      totalMinutes: 0
    )
  }

  static func otherAppBucket() -> WeeklySankeyAppBucket {
    WeeklySankeyAppBucket(
      id: "other",
      title: "Other",
      colorHex: "D9D9D9",
      iconSource: .none,
      raw: nil,
      host: nil,
      totalMinutes: 0
    )
  }

  static func preferredRawAppValue(
    primaryRaw: String?,
    secondaryRaw: String?
  ) -> String? {
    let trimmedPrimary = trimmed(primaryRaw)
    if let trimmedPrimary {
      return trimmedPrimary
    }

    return trimmed(secondaryRaw)
  }

  static func canonicalAppID(raw: String?, host: String?) -> String {
    let token = [raw, host]
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")

    if token.contains("chatgpt") || token.contains("openai") || token.contains("codex") {
      return "chatgpt"
    }
    if token.contains("zoom") {
      return "zoom"
    }
    if token.contains("clickup") {
      return "clickup"
    }
    if token.contains("slack") {
      return "slack"
    }
    if token.contains("youtube") || token.contains("youtu.be") {
      return "youtube"
    }
    if token.contains("claude") {
      return "claude"
    }
    if token.contains("figma") {
      return "figma"
    }
    if token.contains("twitter") || token.contains("x.com") || token == "x" {
      return "x"
    }
    if token.contains("medium") {
      return "medium"
    }

    if let host {
      return sanitizedNodeID(host.replacingOccurrences(of: "www.", with: ""))
    }

    return sanitizedNodeID(raw ?? "other")
  }

  static func faviconHost(for id: String, host: String?) -> String? {
    switch id {
    case "chatgpt":
      return "chatgpt.com"
    case "claude":
      return host ?? "claude.ai"
    case "x":
      return "x.com"
    case "medium":
      return "medium.com"
    default:
      return host
    }
  }

  static func appTitle(for id: String, raw: String?, host: String?) -> String {
    switch id {
    case "chatgpt":
      return "ChatGPT"
    case "zoom":
      return "Zoom"
    case "clickup":
      return "ClickUp"
    case "slack":
      return "Slack"
    case "youtube":
      return "YouTube"
    case "claude":
      return "Claude"
    case "figma":
      return "Figma"
    case "x":
      return "X"
    case "medium":
      return "Medium"
    case "other":
      return "Other"
    default:
      if let host {
        return displayTitle(fromHost: host)
      }
      return displayName(for: raw ?? "Other")
    }
  }

  static func appColorHex(for id: String, host: String?) -> String {
    switch id {
    case "other":
      return "D9D9D9"
    case "chatgpt", "zoom", "clickup", "slack", "youtube", "claude", "figma", "x", "medium":
      return appBarHex(for: id)
    default:
      return fallbackAppHex(for: host ?? id)
    }
  }

  static func appIconSource(for id: String, raw: String?, host: String?)
    -> WeeklySankeyIconSource
  {
    switch id {
    case "chatgpt":
      return .asset("ChatGPTLogo")
    case "claude":
      return .asset("ClaudeLogo")
    case "x":
      return .monogram(text: "X", background: .black, foreground: .white)
    case "medium":
      return .monogram(text: "M", background: .black, foreground: .white)
    case "other":
      return .none
    default:
      return .favicon(raw: raw ?? host ?? id, host: host ?? raw ?? id)
    }
  }

  static func displayTitle(fromHost host: String) -> String {
    let cleanedHost =
      host
      .replacingOccurrences(of: "www.", with: "")
      .components(separatedBy: ".")
      .first ?? host

    return
      cleanedHost
      .split(separator: "-")
      .map { segment in
        segment.prefix(1).uppercased() + segment.dropFirst()
      }
      .joined(separator: " ")
  }

  static func fallbackCategoryHex(for seed: String) -> String {
    fallbackHex(
      for: seed,
      palette: ["73A7FF", "6CDACD", "DE9DFC", "BFB6AE", "FFA189", "FF5950", "FFC6B7"]
    )
  }

  static func fallbackAppHex(for seed: String) -> String {
    fallbackHex(
      for: seed,
      palette: ["4085FD", "36C5F0", "FD1BB9", "FF7262", "D97757", "7C8CF8", "6BBFA9", "7A7A7A"]
    )
  }

  static func fallbackHex(for seed: String, palette: [String]) -> String {
    let hash = seed.utf8.reduce(5381) { partial, byte in
      ((partial << 5) &+ partial) &+ Int(byte)
    }
    let index = abs(hash) % max(palette.count, 1)
    return palette[index]
  }

  static func sanitizedNodeID(_ raw: String) -> String {
    raw
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "www.", with: "")
      .replacingOccurrences(of: "://", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ".", with: "-")
      .replacingOccurrences(of: " ", with: "-")
  }

  static func sanitizedHex(_ raw: String?) -> String? {
    guard let raw = trimmed(raw), !raw.isEmpty else {
      return nil
    }

    return raw.replacingOccurrences(of: "#", with: "")
  }

  static func trimmed(_ raw: String?) -> String? {
    guard let raw else {
      return nil
    }

    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func displayName(for value: String) -> String {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedValue.isEmpty ? "Uncategorized" : trimmedValue
  }

  static func normalizedCategoryKey(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  static func normalizedHost(_ site: String?) -> String? {
    guard var site = trimmed(site) else {
      return nil
    }

    site = site.lowercased()
    if let url = URL(string: site), let host = url.host {
      return host
    }
    if site.contains("://"), let url = URL(string: site), let host = url.host {
      return host
    }
    if site.contains("/"), let url = URL(string: "https://" + site), let host = url.host {
      return host
    }
    if !site.contains(".") {
      return site + ".com"
    }
    return site
  }

  static func workdayStrings(for weekStart: Date) -> [String] {
    let calendar = sankeyCalendar
    return (0..<5).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
        return nil
      }
      return DateFormatter.yyyyMMdd.string(from: date)
    }
  }

  static func totalMinutes(for card: TimelineCard) -> Int {
    guard let startMinute = parseCardMinute(card.startTimestamp),
      let endMinute = parseCardMinute(card.endTimestamp)
    else {
      return 0
    }

    let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
    return max(Int((normalized.end - normalized.start).rounded()), 0)
  }

  static func normalizedMinuteRange(start: Double, end: Double) -> (
    start: Double, end: Double
  ) {
    let adjustedStart = start < 240 ? start + 1440 : start
    var adjustedEnd = end < 240 ? end + 1440 : end

    if adjustedEnd <= adjustedStart {
      adjustedEnd += 1440
    }

    return (adjustedStart, adjustedEnd)
  }

  static func parseCardMinute(_ value: String) -> Double? {
    guard let parsed = parseTimeHMMA(timeString: value) else {
      return nil
    }

    return Double(parsed)
  }

  static let sankeyCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }()

  static func softenedColor(
    hex: String,
    towards mixHex: String = "FFFFFF",
    by amount: CGFloat
  ) -> Color {
    let base = rgbComponents(from: hex)
    let mix = rgbComponents(from: mixHex)
    let clampedAmount = min(max(amount, 0), 1)

    let red = base.red + (mix.red - base.red) * clampedAmount
    let green = base.green + (mix.green - base.green) * clampedAmount
    let blue = base.blue + (mix.blue - base.blue) * clampedAmount

    return Color(
      red: red,
      green: green,
      blue: blue
    )
  }

  static func rgbComponents(from hex: String) -> (red: Double, green: Double, blue: Double) {
    let sanitized = hex.replacingOccurrences(of: "#", with: "")
    let value = UInt64(sanitized, radix: 16) ?? 0

    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255

    return (red, green, blue)
  }

}
