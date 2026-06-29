import SwiftUI

enum WeeklySankeyModelFactory {
  static func snapshot(_ snapshot: WeeklySankeySnapshot) -> WeeklySankeyModel {
    build(
      id: snapshot.id,
      seedLabel: snapshot.seedLabel,
      sourceName: snapshot.sourceName,
      categories: snapshot.categories.map {
        WeeklySankeyCategoryInput(
          id: $0.id,
          name: $0.name,
          minutes: $0.minutes,
          barColorHex: $0.colorHex
        )
      },
      apps: snapshot.apps.map {
        WeeklySankeyAppInput(
          id: $0.id,
          name: $0.name,
          minutes: $0.minutes,
          barColorHex: $0.colorHex,
          icon: icon(for: $0)
        )
      },
      links: snapshot.links.map {
        WeeklySankeyLinkInput(
          id: $0.id,
          from: $0.from,
          to: $0.to,
          minutes: $0.minutes
        )
      }
    )
  }

  static func timeline() -> WeeklySankeyModel {
    let categories = [
      WeeklySankeyCategoryInput(
        id: "coding", name: "Coding/Debugging", minutes: 686, barColorHex: "93BCFF"),
      WeeklySankeyCategoryInput(
        id: "research", name: "Research", minutes: 581, barColorHex: "6CDACD"),
      WeeklySankeyCategoryInput(
        id: "communication", name: "Communication", minutes: 34, barColorHex: "DE9DFC"),
      WeeklySankeyCategoryInput(
        id: "code_review", name: "Code Review", minutes: 13, barColorHex: "BFB6AE"),
      WeeklySankeyCategoryInput(
        id: "personal", name: "Personal", minutes: 321, barColorHex: "FFC6B7"),
      WeeklySankeyCategoryInput(
        id: "distractions", name: "Distraction", minutes: 466, barColorHex: "FF5950"),
    ]

    let apps = [
      WeeklySankeyAppInput(
        id: "codex", name: "Codex", minutes: 0, barColorHex: "111111",
        icon: .none),
      WeeklySankeyAppInput(
        id: "dayflow", name: "Dayflow", minutes: 0, barColorHex: "FF7A2F",
        icon: .asset("DayflowLogoMainApp")),
      WeeklySankeyAppInput(
        id: "claude", name: "Claude", minutes: 0, barColorHex: "D97757",
        icon: .asset("ClaudeLogo")),
      WeeklySankeyAppInput(
        id: "chatgpt", name: "Chat GPT", minutes: 0, barColorHex: "333333",
        icon: .asset("ChatGPTLogo")),
      WeeklySankeyAppInput(
        id: "figma", name: "Figma", minutes: 0, barColorHex: "FF7262",
        icon: .monogram(text: "F", backgroundHex: "FF7262", foregroundHex: "FFFFFF")),
      WeeklySankeyAppInput(
        id: "browser", name: "Browser / Docs", minutes: 0, barColorHex: "BFB6AE",
        icon: .none),
      WeeklySankeyAppInput(
        id: "messages", name: "Messages / Meet", minutes: 0, barColorHex: "38D06E",
        icon: .none),
      WeeklySankeyAppInput(
        id: "shopping", name: "Shopping / Maps", minutes: 0, barColorHex: "F59E0B",
        icon: .none),
      WeeklySankeyAppInput(
        id: "x", name: "X", minutes: 0, barColorHex: "000000",
        icon: .monogram(text: "X", backgroundHex: "000000", foregroundHex: "FFFFFF")),
      WeeklySankeyAppInput(
        id: "youtube", name: "YouTube", minutes: 0, barColorHex: "FF0000",
        icon: .monogram(text: "Y", backgroundHex: "FF0000", foregroundHex: "FFFFFF")),
      WeeklySankeyAppInput(
        id: "league", name: "League", minutes: 0, barColorHex: "7AA7FF",
        icon: .none),
      WeeklySankeyAppInput(
        id: "other", name: "Other", minutes: 0, barColorHex: "D9D9D9",
        icon: .none),
    ]

    let links = [
      link("coding", "codex", 365),
      link("coding", "dayflow", 145),
      link("coding", "claude", 82),
      link("coding", "figma", 55),
      link("coding", "other", 39),
      link("research", "browser", 170),
      link("research", "claude", 120),
      link("research", "chatgpt", 80),
      link("research", "codex", 76),
      link("research", "x", 55),
      link("research", "dayflow", 50),
      link("research", "figma", 30),
      link("communication", "messages", 24),
      link("communication", "browser", 10),
      link("code_review", "codex", 8),
      link("code_review", "other", 5),
      link("personal", "shopping", 130),
      link("personal", "messages", 80),
      link("personal", "browser", 60),
      link("personal", "chatgpt", 25),
      link("personal", "other", 26),
      link("distractions", "x", 175),
      link("distractions", "youtube", 140),
      link("distractions", "league", 70),
      link("distractions", "browser", 55),
      link("distractions", "other", 26),
    ]

    return build(
      id: "dayflow-timeline-apr20-apr24",
      seedLabel: "Timeline data",
      sourceName: "Apr 20-24",
      categories: categories,
      apps: apps,
      links: links
    )
  }

  static func figmaBaseline() -> WeeklySankeyModel {
    let categoryTemplates = [
      WeeklySankeyCategoryInput(
        id: "research", name: "Research", minutes: 430, barColorHex: "93BCFF"),
      WeeklySankeyCategoryInput(
        id: "communication", name: "Communication", minutes: 360, barColorHex: "6CDACD"),
      WeeklySankeyCategoryInput(
        id: "design", name: "Design", minutes: 720, barColorHex: "DE9DFC"),
      WeeklySankeyCategoryInput(
        id: "testing", name: "Testing", minutes: 240, barColorHex: "FFA189"),
      WeeklySankeyCategoryInput(
        id: "distractions", name: "Distractions", minutes: 150, barColorHex: "FF5950"),
      WeeklySankeyCategoryInput(
        id: "personal", name: "Personal", minutes: 180, barColorHex: "FFC6B7"),
    ]
    let links = [
      link("research", "chatgpt", 180),
      link("research", "claude", 150),
      link("research", "figma", 100),
      link("communication", "slack", 260),
      link("communication", "zoom", 100),
      link("design", "figma", 520),
      link("design", "claude", 100),
      link("design", "chatgpt", 100),
      link("testing", "clickup", 100),
      link("testing", "figma", 100),
      link("testing", "chatgpt", 40),
      link("distractions", "youtube", 110),
      link("distractions", "other", 40),
      link("personal", "other", 180),
    ]
    let usedAppIDs = Set(links.map(\.to))
    let apps = appTemplates().filter { usedAppIDs.contains($0.id) }

    return build(
      id: "figma-baseline",
      seedLabel: "Figma baseline",
      sourceName: "Weekly",
      categories: categoryTemplates,
      apps: apps,
      links: links
    )
  }

  static func random(seed: Int) -> WeeklySankeyModel {
    var random = WeeklySankeyRandom(seed: seed)
    let categoryTemplates = [
      WeeklySankeyCategoryInput(
        id: "research", name: "Research", minutes: 0, barColorHex: "93BCFF"),
      WeeklySankeyCategoryInput(
        id: "communication", name: "Communication", minutes: 0, barColorHex: "6CDACD"),
      WeeklySankeyCategoryInput(
        id: "design", name: "Design", minutes: 0, barColorHex: "DE9DFC"),
      WeeklySankeyCategoryInput(
        id: "general", name: "General", minutes: 0, barColorHex: "BFB6AE"),
      WeeklySankeyCategoryInput(
        id: "testing", name: "Testing", minutes: 0, barColorHex: "FFA189"),
      WeeklySankeyCategoryInput(
        id: "distractions", name: "Distractions", minutes: 0, barColorHex: "FF5950"),
      WeeklySankeyCategoryInput(
        id: "personal", name: "Personal", minutes: 0, barColorHex: "FFC6B7"),
    ]
    let categories = categoryTemplates.enumerated().map { index, category in
      let wave = 0.72 + sin(Double(seed) * 0.37 + Double(index) * 1.21) * 0.22
      let minutes = Int((160 + pow(random.next(), 1.35) * 940 * wave).rounded())
      return WeeklySankeyCategoryInput(
        id: category.id,
        name: category.name,
        minutes: minutes,
        barColorHex: category.barColorHex
      )
    }

    let appTemplates = appTemplates()
    var appMinutes = Dictionary(uniqueKeysWithValues: appTemplates.map { ($0.id, 0) })
    var links: [WeeklySankeyLinkInput] = []

    for (categoryIndex, category) in categories.enumerated() {
      let rankedApps = appTemplates.enumerated().map { appIndex, app in
        let score =
          random.next()
          + 0.42 * cos(Double(categoryIndex + 1) * Double(appIndex + 2) + Double(seed) * 0.09)
          + (app.id == "other" ? -0.22 : 0)
        return (app: app, score: score)
      }
      .sorted { $0.score > $1.score }

      let visibleCount = 2 + Int(floor(random.next() * 4))
      let chosenApps = Array(rankedApps.prefix(visibleCount))
      let shares = chosenApps.map { _ in 0.35 + pow(random.next(), 1.6) * 1.85 }
      let shareTotal = shares.reduce(0, +)
      var assignedMinutes = 0

      for index in chosenApps.indices {
        let app = chosenApps[index].app
        let minutes: Int
        if index == chosenApps.count - 1 {
          minutes = max(10, category.minutes - assignedMinutes)
        } else {
          minutes = max(10, Int((Double(category.minutes) * shares[index] / shareTotal).rounded()))
        }
        assignedMinutes += minutes
        appMinutes[app.id, default: 0] += minutes
        links.append(link(category.id, app.id, minutes))
      }
    }

    let apps = appTemplates.compactMap { app -> WeeklySankeyAppInput? in
      let minutes = appMinutes[app.id, default: 0]
      guard minutes > 0 else { return nil }
      return WeeklySankeyAppInput(
        id: app.id,
        name: app.name,
        minutes: minutes,
        barColorHex: app.barColorHex,
        icon: app.icon
      )
    }

    return build(
      id: "random-\(seed)",
      seedLabel: "Seed \(seed)",
      sourceName: "Weekly",
      categories: categories,
      apps: apps,
      links: links
    )
  }

  private static func build(
    id: String,
    seedLabel: String,
    sourceName: String,
    categories rawCategories: [WeeklySankeyCategoryInput],
    apps rawApps: [WeeklySankeyAppInput],
    links: [WeeklySankeyLinkInput]
  ) -> WeeklySankeyModel {
    let layout = WeeklySankeyLayout.base
    let totalMinutes = rawCategories.reduce(0) { $0 + $1.minutes }
    let appsWithTotals = rawApps.map { app in
      let linkedMinutes =
        links
        .filter { $0.to == app.id }
        .reduce(0) { $0 + $1.minutes }
      return WeeklySankeyAppInput(
        id: app.id,
        name: app.name,
        minutes: app.minutes > 0 ? app.minutes : linkedMinutes,
        barColorHex: app.barColorHex,
        icon: app.icon
      )
    }

    let categoryBands = allocateBands(
      items: rawCategories,
      layout: layout.categories
    )
    let categoryBandByID = Dictionary(uniqueKeysWithValues: categoryBands.map { ($0.id, $0) })
    let appBarycenters = Dictionary(
      uniqueKeysWithValues: appsWithTotals.map { app -> (String, CGFloat) in
        let incomingLinks = links.filter { $0.to == app.id }
        let weightedCenter = incomingLinks.reduce(CGFloat.zero) { partial, link in
          guard let category = categoryBandByID[link.from] else {
            return partial
          }
          return partial + category.bar.midY * CGFloat(link.minutes)
        }
        let total = incomingLinks.reduce(0) { $0 + $1.minutes }
        return (app.id, total > 0 ? weightedCenter / CGFloat(total) : 999)
      }
    )
    let orderedApps = appsWithTotals.sorted { lhs, rhs in
      if lhs.id == "other" { return false }
      if rhs.id == "other" { return true }
      return appBarycenters[lhs.id, default: 999] < appBarycenters[rhs.id, default: 999]
    }
    let appBands = allocateBands(items: orderedApps, layout: layout.apps)
    let appBandByID = Dictionary(uniqueKeysWithValues: appBands.map { ($0.id, $0) })

    let sourceBar = CGRect(
      x: layout.source.x,
      y: layout.source.top,
      width: layout.source.width,
      height: layout.source.bottom - layout.source.top
    )
    let sourceNode = WeeklySankeyNode(
      id: "source-weekly-activity",
      name: sourceName,
      metric: formatDuration(totalMinutes),
      percent: "100%",
      minutes: totalMinutes,
      barColorHex: "D9CBC0",
      icon: .none,
      bar: sourceBar,
      label: WeeklySankeyLabelFrame(
        x: layout.source.labelX,
        y: sourceBar.midY - layout.source.labelHeight / 2,
        width: layout.source.labelWidth
      )
    )

    let sourceSegments = allocateStackSegments(
      items: categoryBands.map {
        WeeklySankeySegmentInput(id: $0.id, from: nil, minutes: $0.minutes)
      },
      top: sourceBar.minY,
      height: sourceBar.height
    )
    let sourceSegmentByID = Dictionary(uniqueKeysWithValues: sourceSegments.map { ($0.id, $0) })
    let leftFlows = categoryBands.compactMap { category -> WeeklySankeyFlow? in
      guard let segment = sourceSegmentByID[category.id] else {
        return nil
      }

      return WeeklySankeyFlow(
        id: "source-\(category.id)",
        from: sourceNode.id,
        to: category.id,
        fromColorHex: sourceNode.barColorHex,
        toColorHex: category.barColorHex,
        x0: sourceBar.maxX,
        y0Top: segment.top,
        y0Bottom: segment.bottom,
        x1: category.bar.minX,
        y1Top: category.bar.minY,
        y1Bottom: category.bar.maxY,
        curveTension: WeeklySankeyDesign.sourceCurveTension,
        opacity: 0.14 + 0.08 * sqrt(Double(category.minutes) / Double(max(totalMinutes, 1)))
      )
    }

    let maxLinkMinutes = max(links.map(\.minutes).max() ?? 1, 1)
    var categorySegments: [String: WeeklySankeySegment] = [:]
    var appSegments: [String: WeeklySankeySegment] = [:]

    for category in categoryBands {
      let outgoing =
        links
        .filter { $0.from == category.id }
        .sorted {
          let leftY = appBandByID[$0.to]?.bar.minY ?? 0
          let rightY = appBandByID[$1.to]?.bar.minY ?? 0
          return leftY < rightY
        }

      let segments = allocateStackSegments(
        items: outgoing.map {
          WeeklySankeySegmentInput(id: $0.id, from: $0.from, minutes: $0.minutes)
        },
        top: category.bar.minY,
        height: category.bar.height
      )
      for segment in segments {
        categorySegments["\(category.id)-\(segment.id)"] = segment
      }
    }

    for app in appBands {
      let incoming =
        links
        .filter { $0.to == app.id }
        .sorted {
          let leftY = categoryBandByID[$0.from]?.bar.minY ?? 0
          let rightY = categoryBandByID[$1.from]?.bar.minY ?? 0
          return leftY < rightY
        }

      let segments = allocateStackSegments(
        items: incoming.map {
          WeeklySankeySegmentInput(id: $0.to, from: $0.from, minutes: $0.minutes)
        },
        top: app.bar.minY,
        height: app.bar.height
      )
      for segment in segments {
        guard let from = segment.from else { continue }
        appSegments["\(from)-\(app.id)"] = segment
      }
    }

    let rightFlows = links.compactMap { link -> WeeklySankeyFlow? in
      guard let category = categoryBandByID[link.from],
        let app = appBandByID[link.to],
        let categorySegment = categorySegments["\(link.from)-\(link.id)"],
        let appSegment = appSegments["\(link.from)-\(link.to)"]
      else {
        return nil
      }

      return WeeklySankeyFlow(
        id: link.id,
        from: link.from,
        to: link.to,
        fromColorHex: category.barColorHex,
        toColorHex: app.barColorHex,
        x0: category.bar.maxX,
        y0Top: categorySegment.top,
        y0Bottom: categorySegment.bottom,
        x1: app.bar.minX,
        y1Top: appSegment.top,
        y1Bottom: appSegment.bottom,
        curveTension: 0.42,
        opacity: 0.08 + 0.18 * sqrt(Double(link.minutes) / Double(maxLinkMinutes))
      )
    }

    let categoryLabels = placeLabels(nodes: categoryBands, layout: layout.categories)
    let appLabels = placeLabels(nodes: appBands, layout: layout.apps)

    return WeeklySankeyModel(
      id: id,
      seedLabel: seedLabel,
      source: sourceNode,
      categories: categoryLabels.map { node in
        sankeyNode(from: node, totalMinutes: totalMinutes)
      },
      apps: appLabels.map { node in
        sankeyNode(from: node, totalMinutes: totalMinutes)
      },
      flows: leftFlows + rightFlows
    )
  }

  private static func sankeyNode(
    from band: WeeklySankeyBand,
    totalMinutes: Int
  ) -> WeeklySankeyNode {
    WeeklySankeyNode(
      id: band.id,
      name: band.name,
      metric: formatDuration(band.minutes),
      percent: formatPercent(minutes: band.minutes, totalMinutes: totalMinutes),
      minutes: band.minutes,
      barColorHex: band.barColorHex,
      icon: band.icon,
      bar: band.bar,
      label: band.label
    )
  }

  private static func allocateBands<T: WeeklySankeyBandInput>(
    items: [T],
    layout: WeeklySankeyColumnSpec
  ) -> [WeeklySankeyBand] {
    guard !items.isEmpty else {
      return []
    }

    let available = max(
      CGFloat(items.count) * layout.minHeight,
      layout.bottom - layout.top - layout.gap * CGFloat(max(0, items.count - 1))
    )
    let total = items.reduce(0) { $0 + $1.minutes }
    let flexible = max(0, available - layout.minHeight * CGFloat(items.count))
    var cursor = layout.top

    return items.map { item in
      let height =
        total > 0
        ? layout.minHeight + flexible * CGFloat(item.minutes) / CGFloat(total)
        : layout.minHeight + flexible / CGFloat(max(items.count, 1))
      let band = WeeklySankeyBand(
        id: item.id,
        name: item.name,
        minutes: item.minutes,
        barColorHex: item.barColorHex,
        icon: item.icon,
        bar: CGRect(x: layout.x, y: cursor, width: layout.width, height: height),
        label: WeeklySankeyLabelFrame(x: 0, y: 0, width: 0)
      )
      cursor += height + layout.gap
      return band
    }
  }

  private static func allocateStackSegments(
    items: [WeeklySankeySegmentInput],
    top: CGFloat,
    height: CGFloat
  ) -> [WeeklySankeySegment] {
    guard !items.isEmpty else {
      return []
    }

    let total = items.reduce(0) { $0 + $1.minutes }
    var cursor = top

    return items.map { item in
      let segmentHeight =
        total > 0
        ? CGFloat(item.minutes) / CGFloat(total) * height
        : height / CGFloat(max(items.count, 1))
      let segment = WeeklySankeySegment(
        id: item.id,
        from: item.from,
        top: cursor,
        bottom: cursor + segmentHeight
      )
      cursor += segmentHeight
      return segment
    }
  }

  private static func placeLabels(
    nodes: [WeeklySankeyBand],
    layout: WeeklySankeyColumnSpec
  ) -> [WeeklySankeyBand] {
    let sorted = nodes.sorted {
      let leftTop = $0.bar.midY - layout.labelHeight / 2
      let rightTop = $1.bar.midY - layout.labelHeight / 2
      return leftTop < rightTop
    }
    var placed: [WeeklySankeyBand] = []
    var cursor = layout.labelTop

    for node in sorted {
      let preferredTop = node.bar.midY - layout.labelHeight / 2
      let y = max(preferredTop, cursor)
      placed.append(
        node.updatingLabel(
          WeeklySankeyLabelFrame(x: layout.labelX, y: y, width: layout.labelWidth)
        )
      )
      cursor = y + layout.labelHeight + layout.labelSpacing
    }

    if let lastIndex = placed.indices.last {
      let overflow = placed[lastIndex].label.y + layout.labelHeight - layout.labelBottom
      if overflow > 0 {
        placed[lastIndex] = placed[lastIndex].updatingLabel(
          WeeklySankeyLabelFrame(
            x: placed[lastIndex].label.x,
            y: placed[lastIndex].label.y - overflow,
            width: placed[lastIndex].label.width
          )
        )

        if lastIndex > 0 {
          for index in stride(from: lastIndex - 1, through: 0, by: -1) {
            let maximumTop = placed[index + 1].label.y - layout.labelHeight - layout.labelSpacing
            placed[index] = placed[index].updatingLabel(
              WeeklySankeyLabelFrame(
                x: placed[index].label.x,
                y: min(placed[index].label.y, maximumTop),
                width: placed[index].label.width
              )
            )
          }
        }

        if let first = placed.first, first.label.y < layout.labelTop {
          placed[0] = first.updatingLabel(
            WeeklySankeyLabelFrame(
              x: first.label.x,
              y: layout.labelTop,
              width: first.label.width
            )
          )

          if lastIndex > 0 {
            for index in 1...lastIndex {
              let minimumTop = placed[index - 1].label.y + layout.labelHeight + layout.labelSpacing
              placed[index] = placed[index].updatingLabel(
                WeeklySankeyLabelFrame(
                  x: placed[index].label.x,
                  y: max(placed[index].label.y, minimumTop),
                  width: placed[index].label.width
                )
              )
            }
          }
        }
      }
    }

    let orderByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
    return placed.sorted {
      orderByID[$0.id, default: 0] < orderByID[$1.id, default: 0]
    }
  }

  private static func appTemplates() -> [WeeklySankeyAppInput] {
    [
      WeeklySankeyAppInput(
        id: "chatgpt", name: "Chat GPT", minutes: 0, barColorHex: "333333",
        icon: .asset("ChatGPTLogo")),
      WeeklySankeyAppInput(
        id: "zoom", name: "Zoom", minutes: 0, barColorHex: "4085FD",
        icon: .none),
      WeeklySankeyAppInput(
        id: "clickup", name: "ClickUp", minutes: 0, barColorHex: "FD1BB9",
        icon: .none),
      WeeklySankeyAppInput(
        id: "slack", name: "Slack", minutes: 0, barColorHex: "36C5F0",
        icon: .none),
      WeeklySankeyAppInput(
        id: "youtube", name: "YouTube", minutes: 0, barColorHex: "FF0000",
        icon: .monogram(text: "Y", backgroundHex: "FF0000", foregroundHex: "FFFFFF")),
      WeeklySankeyAppInput(
        id: "claude", name: "Claude", minutes: 0, barColorHex: "D97757",
        icon: .asset("ClaudeLogo")),
      WeeklySankeyAppInput(
        id: "figma", name: "Figma", minutes: 0, barColorHex: "FF7262",
        icon: .monogram(text: "F", backgroundHex: "FF7262", foregroundHex: "FFFFFF")),
      WeeklySankeyAppInput(
        id: "x", name: "X", minutes: 0, barColorHex: "000000",
        icon: .monogram(text: "X", backgroundHex: "000000", foregroundHex: "FFFFFF")),
      WeeklySankeyAppInput(
        id: "medium", name: "Medium", minutes: 0, barColorHex: "000000",
        icon: .monogram(text: "M", backgroundHex: "000000", foregroundHex: "FFFFFF")),
      WeeklySankeyAppInput(
        id: "other", name: "Other", minutes: 0, barColorHex: "D9D9D9",
        icon: .none),
    ]
  }

  private static func link(
    _ from: String,
    _ to: String,
    _ minutes: Int
  ) -> WeeklySankeyLinkInput {
    WeeklySankeyLinkInput(
      id: "\(from)-\(to)",
      from: from,
      to: to,
      minutes: minutes
    )
  }

  private static func icon(for app: WeeklySankeySnapshotApp) -> WeeklySankeyIcon {
    let lookupText = "\(app.id) \(app.name)".lowercased()
    if app.id == "x" || app.name.lowercased() == "x" || lookupText.contains("twitter") {
      return .asset("XFavicon")
    }

    if app.hasFaviconSource {
      return .favicon(
        primaryRaw: app.faviconPrimaryRaw,
        secondaryRaw: app.faviconSecondaryRaw,
        primaryHost: app.faviconPrimaryHost,
        secondaryHost: app.faviconSecondaryHost,
        fallbackRaw: app.fallbackFaviconRaw
      )
    }

    return .monogram(
      text: app.name.first.map { String($0).uppercased() } ?? "-",
      backgroundHex: app.colorHex,
      foregroundHex: "FFFFFF"
    )
  }

  private static func formatDuration(_ minutes: Int) -> String {
    let roundedMinutes = max(0, minutes)
    let hours = roundedMinutes / 60
    let remainingMinutes = roundedMinutes % 60
    if hours <= 0 {
      return "\(remainingMinutes)min"
    }
    return "\(hours)hr \(remainingMinutes)min"
  }

  private static func formatPercent(minutes: Int, totalMinutes: Int) -> String {
    guard totalMinutes > 0 else { return "0%" }
    return "\(max(1, Int((Double(minutes) / Double(totalMinutes) * 100).rounded())))%"
  }
}

private struct WeeklySankeyCategoryInput: WeeklySankeyBandInput {
  let id: String
  let name: String
  let minutes: Int
  let barColorHex: String
  let icon: WeeklySankeyIcon = .none
}

private struct WeeklySankeyAppInput: WeeklySankeyBandInput {
  let id: String
  let name: String
  let minutes: Int
  let barColorHex: String
  let icon: WeeklySankeyIcon
}

private struct WeeklySankeyLinkInput: Identifiable {
  let id: String
  let from: String
  let to: String
  let minutes: Int
}

private protocol WeeklySankeyBandInput {
  var id: String { get }
  var name: String { get }
  var minutes: Int { get }
  var barColorHex: String { get }
  var icon: WeeklySankeyIcon { get }
}

private struct WeeklySankeyBand: WeeklySankeyBandInput {
  let id: String
  let name: String
  let minutes: Int
  let barColorHex: String
  let icon: WeeklySankeyIcon
  let bar: CGRect
  let label: WeeklySankeyLabelFrame

  func updatingLabel(_ label: WeeklySankeyLabelFrame) -> WeeklySankeyBand {
    WeeklySankeyBand(
      id: id,
      name: name,
      minutes: minutes,
      barColorHex: barColorHex,
      icon: icon,
      bar: bar,
      label: label
    )
  }
}

private struct WeeklySankeySegment {
  let id: String
  let from: String?
  let top: CGFloat
  let bottom: CGFloat
}

private struct WeeklySankeySegmentInput {
  let id: String
  let from: String?
  let minutes: Int
}

private struct WeeklySankeyRandom {
  private var state: UInt32

  init(seed: Int) {
    self.state = UInt32(truncatingIfNeeded: seed)
  }

  mutating func next() -> Double {
    state &+= 0x6d2b_79f5
    var value = state
    value = (value ^ (value >> 15)) &* (value | 1)
    value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
    return Double((value ^ (value >> 14))) / Double(UInt32.max)
  }
}
