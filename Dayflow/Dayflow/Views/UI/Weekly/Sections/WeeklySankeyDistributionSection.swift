import AppKit
import SwiftUI

struct WeeklySankeyAppFilterPolicy {
  let minAppSharePercent: Int
  let maxVisibleApps: Int?

  init(minAppSharePercent: Int = 2, maxVisibleApps: Int? = nil) {
    self.minAppSharePercent = min(max(minAppSharePercent, 1), 10)
    if let maxVisibleApps {
      self.maxVisibleApps = max(maxVisibleApps, 1)
    } else {
      self.maxVisibleApps = nil
    }
  }

  static let `default` = WeeklySankeyAppFilterPolicy(minAppSharePercent: 2, maxVisibleApps: nil)

  var summary: String {
    if let maxVisibleApps {
      return
        "Collapses apps below \(minAppSharePercent)% of total flow, then keeps the top \(maxVisibleApps) right-rail buckets."
    }

    return "Collapses apps below \(minAppSharePercent)% of total flow into Other."
  }
}

struct WeeklySankeyLiveInput {
  let cards: [TimelineCard]
  let categories: [TimelineCategory]
  let weekRange: WeeklyDateRange
}

struct WeeklySankeyDistributionSection: View {
  let variant: WeeklySankeyPreviewVariant
  let appFilterPolicy: WeeklySankeyAppFilterPolicy
  let liveInput: WeeklySankeyLiveInput?

  init(appFilterPolicy: WeeklySankeyAppFilterPolicy = .default) {
    self.variant = .balanced
    self.appFilterPolicy = appFilterPolicy
    self.liveInput = nil
  }

  init(
    cards: [TimelineCard],
    categories: [TimelineCategory],
    weekRange: WeeklyDateRange,
    appFilterPolicy: WeeklySankeyAppFilterPolicy = .default
  ) {
    self.variant = .airierOptimized
    self.appFilterPolicy = appFilterPolicy
    self.liveInput = WeeklySankeyLiveInput(
      cards: cards,
      categories: categories,
      weekRange: weekRange
    )
  }

  init(
    variant: WeeklySankeyPreviewVariant,
    appFilterPolicy: WeeklySankeyAppFilterPolicy = .default
  ) {
    self.variant = variant
    self.appFilterPolicy = appFilterPolicy
    self.liveInput = nil
  }

  var baseFixture: WeeklySankeyFixture {
    if let liveInput {
      return WeeklySankeyFixture.live(
        cards: liveInput.cards,
        categories: liveInput.categories,
        weekRange: liveInput.weekRange,
        geometry: variant.fixture
      )
    }

    return variant.fixture
  }

  var fixture: WeeklySankeyFixture {
    baseFixture.filteringRightRail(using: appFilterPolicy)
  }

  var layoutOptions: SankeyLayoutOptions {
    variant.layoutOptions
  }

  var layout: SankeyLayoutResult {
    SankeyLayoutEngine.layout(
      columns: fixture.columns,
      nodes: fixture.nodes,
      links: fixture.links,
      options: layoutOptions
    )
  }

  var body: some View {
    if showsEmptyState {
      emptyState
    } else {
      chartBody
    }
  }

  var chartBody: some View {
    WeeklySankeyWebCard(model: webModel)
  }

  var showsEmptyState: Bool {
    guard liveInput != nil else {
      return false
    }

    return webModel.categories.isEmpty || webModel.apps.isEmpty || webModel.flows.isEmpty
  }

  private var webModel: WeeklySankeyWebModel {
    if let liveInput {
      return WeeklySankeyWebModel.live(
        cards: liveInput.cards,
        categories: liveInput.categories,
        weekRange: liveInput.weekRange,
        appFilterPolicy: appFilterPolicy
      )
    }

    return WeeklySankeyWebModel.figmaBaseline()
  }

  var emptyState: some View {
    RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
      .fill(Design.background)
      .frame(width: Design.sectionSize.width, height: Design.sectionSize.height)
      .overlay {
        VStack(spacing: 8) {
          Text("Not enough weekly activity yet")
            .font(.custom("Nunito-Bold", size: 16))
            .foregroundStyle(Color(hex: "3B2418"))

          Text(
            "Once Dayflow has a bit more app and category data for the selected week, the Sankey will appear here."
          )
          .font(.custom("Nunito-Regular", size: 13))
          .foregroundStyle(Color(hex: "6E584B"))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 380)
        }
        .padding(24)
      }
  }

  @ViewBuilder
  func labelView(for content: WeeklySankeyNodeContent) -> some View {
    switch content.labelKind {
    case .plain:
      WeeklySankeyPlainLabel(content: content)
    case .app(let iconSource):
      WeeklySankeyAppLabel(content: content, iconSource: iconSource)
    }
  }

  func ribbonSort(lhs: SankeyRibbonLayout, rhs: SankeyRibbonLayout) -> Bool {
    if lhs.zIndex == rhs.zIndex {
      return lhs.id < rhs.id
    }
    return lhs.zIndex < rhs.zIndex
  }

  func labelPlacements(for layout: SankeyLayoutResult) -> [String:
    WeeklySankeyLabelPlacement]
  {
    let candidates = fixture.contents.compactMap { content -> WeeklySankeyLabelCandidate? in
      guard let node = layout.nodeLayoutsByID[content.id] else {
        return nil
      }

      return WeeklySankeyLabelCandidate(
        id: content.id,
        columnID: node.columnID,
        preferredTopY: node.frame.midY - content.labelAnchorY,
        originX: labelOriginX(for: node),
        size: content.labelSize
      )
    }

    let candidatesByColumn = Dictionary(grouping: candidates, by: \.columnID)
    var placements: [String: WeeklySankeyLabelPlacement] = [:]

    for (columnID, columnCandidates) in candidatesByColumn {
      let orderedCandidates = columnCandidates.sorted { lhs, rhs in
        if abs(lhs.preferredTopY - rhs.preferredTopY) > 0.5 {
          return lhs.preferredTopY < rhs.preferredTopY
        }
        return lhs.id < rhs.id
      }

      let bounds = labelVerticalBounds(for: columnID)
      let spacing = labelSpacing(for: columnID)
      let frames = resolvedLabelFrames(
        for: orderedCandidates,
        within: bounds,
        preferredSpacing: spacing
      )

      for (candidate, frame) in zip(orderedCandidates, frames) {
        placements[candidate.id] = WeeklySankeyLabelPlacement(
          origin: CGPoint(x: candidate.originX, y: frame.minY)
        )
      }
    }

    return placements
  }

  func resolvedLabelFrames(
    for candidates: [WeeklySankeyLabelCandidate],
    within verticalBounds: ClosedRange<CGFloat>,
    preferredSpacing: CGFloat
  ) -> [CGRect] {
    guard !candidates.isEmpty else {
      return []
    }

    let totalLabelHeight = candidates.reduce(CGFloat(0)) { partial, candidate in
      partial + candidate.size.height
    }
    let availableHeight = max(
      verticalBounds.upperBound - verticalBounds.lowerBound, totalLabelHeight)
    let effectiveSpacing: CGFloat

    if candidates.count > 1 {
      let maxSpacing = max(
        0,
        (availableHeight - totalLabelHeight) / CGFloat(candidates.count - 1)
      )
      effectiveSpacing = min(preferredSpacing, maxSpacing)
    } else {
      effectiveSpacing = 0
    }

    var topOrigins: [CGFloat] = []
    var cursorY = verticalBounds.lowerBound

    for candidate in candidates {
      let preferredTop = candidate.preferredTopY
      let top = max(preferredTop, cursorY)
      topOrigins.append(top)
      cursorY = top + candidate.size.height + effectiveSpacing
    }

    if let lastIndex = topOrigins.indices.last,
      (topOrigins[lastIndex] + candidates[lastIndex].size.height) > verticalBounds.upperBound
    {
      topOrigins[lastIndex] = verticalBounds.upperBound - candidates[lastIndex].size.height

      if lastIndex > 0 {
        for index in stride(from: lastIndex - 1, through: 0, by: -1) {
          let maximumTop =
            topOrigins[index + 1]
            - effectiveSpacing
            - candidates[index].size.height
          topOrigins[index] = min(topOrigins[index], maximumTop)
        }
      }

      if let firstTop = topOrigins.first, firstTop < verticalBounds.lowerBound {
        topOrigins[0] = verticalBounds.lowerBound

        if lastIndex > 0 {
          for index in 1...lastIndex {
            let minimumTop =
              topOrigins[index - 1]
              + candidates[index - 1].size.height
              + effectiveSpacing
            topOrigins[index] = max(topOrigins[index], minimumTop)
          }
        }
      }
    }

    return zip(candidates, topOrigins).map { candidate, top in
      CGRect(origin: CGPoint(x: candidate.originX, y: top), size: candidate.size)
    }
  }

  func labelOriginX(for node: SankeyNodeLayout) -> CGFloat {
    switch node.columnID {
    case "source":
      return node.frame.maxX + 18
    case "categories":
      return node.frame.maxX + 18
    case "apps":
      return node.frame.maxX + 12
    default:
      return node.frame.maxX + 14
    }
  }

  func labelVerticalBounds(for columnID: String) -> ClosedRange<CGFloat> {
    switch columnID {
    case "apps":
      return Design.appLabelTopPadding...(Design.sectionSize.height - Design.appLabelBottomPadding)
    case "categories":
      return Design
        .categoryLabelTopPadding...(Design.sectionSize.height - Design.categoryLabelBottomPadding)
    default:
      return Design
        .sourceLabelTopPadding...(Design.sectionSize.height - Design.sourceLabelBottomPadding)
    }
  }

  func labelSpacing(for columnID: String) -> CGFloat {
    switch columnID {
    case "apps":
      return Design.appLabelSpacing
    case "categories":
      return Design.categoryLabelSpacing
    default:
      return 0
    }
  }
}

extension WeeklySankeyDistributionSection {
  enum Design {
    static let sectionSize = CGSize(width: 959, height: 512)
    static let cornerRadius: CGFloat = 4
    static let borderColor = Color(hex: "EBE6E3")
    static let background = Color.white.opacity(0.6)
    static let ribbonOpacityScale = 0.62
    static let ribbonHighlightOpacity = 0.06
    static let ribbonHighlightWidth: CGFloat = 0.24
    static let sourceLabelTopPadding: CGFloat = 28
    static let sourceLabelBottomPadding: CGFloat = 28
    static let categoryLabelTopPadding: CGFloat = 28
    static let categoryLabelBottomPadding: CGFloat = 26
    static let appLabelTopPadding: CGFloat = 16
    static let appLabelBottomPadding: CGFloat = 10
    static let categoryLabelSpacing: CGFloat = 8
    static let appLabelSpacing: CGFloat = 8
  }
}

private enum WeeklySankeyWebDesign {
  static let virtualSize = CGSize(width: 1748, height: 933)
  static let sourceCurveTension: CGFloat = 0.15
  static let rightCurveTension: CGFloat = 0.42

  static let source = WeeklySankeyWebColumnLayout(
    x: 72,
    width: 12,
    top: 273,
    bottom: 706,
    gap: 0,
    minHeight: 0,
    labelX: 105,
    labelTop: 0,
    labelBottom: 0,
    labelWidth: 170,
    labelHeight: 52,
    labelSpacing: 0
  )

  static let categories = WeeklySankeyWebColumnLayout(
    x: 834,
    width: 12,
    top: 126,
    bottom: 828,
    gap: 20,
    minHeight: 40,
    labelX: 868,
    labelTop: 64,
    labelBottom: 874,
    labelWidth: 178,
    labelHeight: 54,
    labelSpacing: 12
  )

  static let apps = WeeklySankeyWebColumnLayout(
    x: 1485,
    width: 12,
    top: 54,
    bottom: 928,
    gap: 20,
    minHeight: 28,
    labelX: 1518,
    labelTop: 38,
    labelBottom: 923,
    labelWidth: 220,
    labelHeight: 56,
    labelSpacing: 10
  )
}

private struct WeeklySankeyWebColumnLayout {
  let x: CGFloat
  let width: CGFloat
  let top: CGFloat
  let bottom: CGFloat
  let gap: CGFloat
  let minHeight: CGFloat
  let labelX: CGFloat
  let labelTop: CGFloat
  let labelBottom: CGFloat
  let labelWidth: CGFloat
  let labelHeight: CGFloat
  let labelSpacing: CGFloat
}

private struct WeeklySankeyWebBox {
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat
  let height: CGFloat

  func scaled(by scale: CGSize) -> CGRect {
    CGRect(
      x: x * scale.width,
      y: y * scale.height,
      width: width * scale.width,
      height: height * scale.height
    )
  }
}

private struct WeeklySankeyWebLabel {
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat

  func scaledOrigin(by scale: CGSize) -> CGPoint {
    CGPoint(x: x * scale.width, y: y * scale.height)
  }

  func scaledWidth(by scale: CGSize) -> CGFloat {
    width * scale.width
  }
}

private struct WeeklySankeyWebNode: Identifiable {
  let id: String
  let name: String
  let metric: String
  let percent: String
  let minutes: Int
  let barColorHex: String
  let iconSource: WeeklySankeyIconSource?
  let bar: WeeklySankeyWebBox
  let label: WeeklySankeyWebLabel
}

private struct WeeklySankeyWebFlow: Identifiable {
  let id: String
  let from: String
  let to: String
  let fromColorHex: String
  let toColorHex: String
  let x0: CGFloat
  let y0Top: CGFloat
  let y0Bottom: CGFloat
  let x1: CGFloat
  let y1Top: CGFloat
  let y1Bottom: CGFloat
  let curveTension: CGFloat
  let opacity: Double
}

private struct WeeklySankeyWebInputCategory {
  let id: String
  let name: String
  let minutes: Int
  let barColorHex: String
  let order: Int
}

private struct WeeklySankeyWebInputApp {
  let id: String
  let name: String
  let minutes: Int
  let barColorHex: String
  let iconSource: WeeklySankeyIconSource?
}

private struct WeeklySankeyWebInputLink: Identifiable {
  let id: String
  let from: String
  let to: String
  let minutes: Int
}

private struct WeeklySankeyWebModel {
  let id: String
  let source: WeeklySankeyWebNode
  let categories: [WeeklySankeyWebNode]
  let apps: [WeeklySankeyWebNode]
  let flows: [WeeklySankeyWebFlow]

  var nodes: [WeeklySankeyWebNode] {
    [source] + categories + apps
  }

  static func live(
    cards: [TimelineCard],
    categories timelineCategories: [TimelineCategory],
    weekRange: WeeklyDateRange,
    appFilterPolicy: WeeklySankeyAppFilterPolicy
  ) -> WeeklySankeyWebModel {
    let input = liveInput(
      cards: cards,
      timelineCategories: timelineCategories,
      weekRange: weekRange,
      appFilterPolicy: appFilterPolicy
    )

    return build(
      id: "live-\(weekRange.weekStart.timeIntervalSince1970)-\(cards.count)",
      sourceName: weekRange == WeeklyDateRange.containing(Date()) ? "This Week" : "Week Total",
      categories: input.categories,
      apps: input.apps,
      links: input.links
    )
  }

  static func figmaBaseline() -> WeeklySankeyWebModel {
    let categoryMinutes = [
      "research": 409,
      "communication": 447,
      "design": 842,
      "general": 342,
      "testing": 326,
      "distractions": 341,
      "personal": 215,
    ]
    let categories = [
      WeeklySankeyWebInputCategory(
        id: "research", name: "Research", minutes: categoryMinutes["research"] ?? 0,
        barColorHex: "93BCFF", order: 0),
      WeeklySankeyWebInputCategory(
        id: "communication", name: "Communication",
        minutes: categoryMinutes["communication"] ?? 0, barColorHex: "6CDACD", order: 1),
      WeeklySankeyWebInputCategory(
        id: "design", name: "Design", minutes: categoryMinutes["design"] ?? 0,
        barColorHex: "DE9DFC", order: 2),
      WeeklySankeyWebInputCategory(
        id: "general", name: "General", minutes: categoryMinutes["general"] ?? 0,
        barColorHex: "BFB6AE", order: 3),
      WeeklySankeyWebInputCategory(
        id: "testing", name: "Testing", minutes: categoryMinutes["testing"] ?? 0,
        barColorHex: "FFA189", order: 4),
      WeeklySankeyWebInputCategory(
        id: "distractions", name: "Distractions",
        minutes: categoryMinutes["distractions"] ?? 0, barColorHex: "FF5950", order: 5),
      WeeklySankeyWebInputCategory(
        id: "personal", name: "Personal", minutes: categoryMinutes["personal"] ?? 0,
        barColorHex: "FFC6B7", order: 6),
    ]
    let links = [
      WeeklySankeyWebInputLink(
        id: "research-chatgpt", from: "research", to: "chatgpt", minutes: 196),
      WeeklySankeyWebInputLink(id: "research-zoom", from: "research", to: "zoom", minutes: 126),
      WeeklySankeyWebInputLink(id: "research-claude", from: "research", to: "claude", minutes: 87),
      WeeklySankeyWebInputLink(
        id: "communication-zoom", from: "communication", to: "zoom", minutes: 111),
      WeeklySankeyWebInputLink(
        id: "communication-clickup", from: "communication", to: "clickup", minutes: 94),
      WeeklySankeyWebInputLink(
        id: "communication-slack", from: "communication", to: "slack", minutes: 242),
      WeeklySankeyWebInputLink(id: "design-figma", from: "design", to: "figma", minutes: 537),
      WeeklySankeyWebInputLink(id: "design-claude", from: "design", to: "claude", minutes: 182),
      WeeklySankeyWebInputLink(id: "design-medium", from: "design", to: "medium", minutes: 123),
      WeeklySankeyWebInputLink(id: "general-x", from: "general", to: "x", minutes: 190),
      WeeklySankeyWebInputLink(id: "general-other", from: "general", to: "other", minutes: 152),
      WeeklySankeyWebInputLink(id: "testing-youtube", from: "testing", to: "youtube", minutes: 178),
      WeeklySankeyWebInputLink(id: "testing-figma", from: "testing", to: "figma", minutes: 148),
      WeeklySankeyWebInputLink(
        id: "distractions-youtube", from: "distractions", to: "youtube", minutes: 183),
      WeeklySankeyWebInputLink(id: "distractions-x", from: "distractions", to: "x", minutes: 91),
      WeeklySankeyWebInputLink(
        id: "distractions-other", from: "distractions", to: "other", minutes: 67),
      WeeklySankeyWebInputLink(id: "personal-medium", from: "personal", to: "medium", minutes: 105),
      WeeklySankeyWebInputLink(id: "personal-other", from: "personal", to: "other", minutes: 110),
    ]
    let appIDs = Set(links.map(\.to))
    let apps = appTemplates().filter { appIDs.contains($0.id) }

    return build(
      id: "figma-baseline",
      sourceName: "Communication",
      categories: categories,
      apps: apps,
      links: links,
      preserveAppOrder: true
    )
  }

  private static func liveInput(
    cards: [TimelineCard],
    timelineCategories: [TimelineCategory],
    weekRange: WeeklyDateRange,
    appFilterPolicy: WeeklySankeyAppFilterPolicy
  ) -> (
    categories: [WeeklySankeyWebInputCategory],
    apps: [WeeklySankeyWebInputApp],
    links: [WeeklySankeyWebInputLink]
  ) {
    let orderedCategories =
      timelineCategories
      .sorted { $0.order < $1.order }
      .filter { !$0.isSystem }
    let categoryLookup = firstCategoryLookup(
      from: orderedCategories,
      normalizedKey: WeeklySankeyFixture.normalizedCategoryKey
    )
    let visibleWorkdays = Set(WeeklySankeyFixture.workdayStrings(for: weekRange.weekStart))
    let workweekCards = cards.filter { visibleWorkdays.contains($0.day) }

    var minutesByCategoryID: [String: Int] = [:]
    var categoryByID: [String: WeeklySankeyCategoryBucket] = [:]
    var minutesByAppID: [String: Int] = [:]
    var appByID: [String: WeeklySankeyAppBucket] = [:]
    var minutesByCategoryAppKey: [String: Int] = [:]

    for card in workweekCards {
      let categoryID = WeeklySankeyFixture.normalizedCategoryKey(
        WeeklySankeyFixture.displayName(for: card.category)
      )
      guard categoryID != "system" else {
        continue
      }

      let minutes = WeeklySankeyFixture.totalMinutes(for: card)
      guard minutes > 0 else {
        continue
      }

      let categoryBucket = WeeklySankeyFixture.resolvedCategoryBucket(
        id: categoryID,
        card: card,
        categories: categoryLookup
      )
      minutesByCategoryID[categoryID, default: 0] += minutes
      categoryByID[categoryID] = categoryBucket

      let appBucket =
        WeeklySankeyFixture.resolvedAppBucket(
          primaryRaw: card.appSites?.primary,
          secondaryRaw: card.appSites?.secondary
        )
        ?? WeeklySankeyFixture.otherAppBucket()

      minutesByAppID[appBucket.id, default: 0] += minutes
      if appByID[appBucket.id] == nil {
        appByID[appBucket.id] = appBucket
      }

      let categoryAppKey = "\(categoryID)->\(appBucket.id)"
      minutesByCategoryAppKey[categoryAppKey, default: 0] += minutes
    }

    let totalMinutes = minutesByCategoryID.values.reduce(0, +)
    guard totalMinutes > 0 else {
      return ([], [], [])
    }

    let categoryInputs =
      minutesByCategoryID.compactMap { entry -> WeeklySankeyWebInputCategory? in
        let (categoryID, minutes) = entry
        guard let bucket = categoryByID[categoryID] else {
          return nil
        }

        return WeeklySankeyWebInputCategory(
          id: bucket.id,
          name: bucket.title,
          minutes: minutes,
          barColorHex: bucket.colorHex,
          order: bucket.order
        )
      }
      .sorted { lhs, rhs in
        if lhs.order != rhs.order {
          return lhs.order < rhs.order
        }
        if lhs.minutes != rhs.minutes {
          return lhs.minutes > rhs.minutes
        }
        return lhs.name < rhs.name
      }

    let minimumVisibleMinutes =
      totalMinutes * max(appFilterPolicy.minAppSharePercent, 0) / 100
    let candidateAppIDs = Set(minutesByAppID.keys.filter { $0 != "other" })
    let keptAppIDs = Set(
      candidateAppIDs.filter { appID in
        minutesByAppID[appID, default: 0] >= minimumVisibleMinutes
      }
    )
    let collapsedAppIDs = candidateAppIDs.subtracting(keptAppIDs)
    let shouldShowOther = minutesByAppID["other", default: 0] > 0 || !collapsedAppIDs.isEmpty

    var visibleAppIDs = keptAppIDs
    if shouldShowOther {
      visibleAppIDs.insert("other")
    }

    var aggregatedValueBySourceTarget: [String: Int] = [:]
    for (key, minutes) in minutesByCategoryAppKey {
      let parts = key.components(separatedBy: "->")
      guard parts.count == 2 else { continue }
      let sourceID = parts[0]
      let targetID = visibleAppIDs.contains(parts[1]) ? parts[1] : "other"
      guard visibleAppIDs.contains(targetID) else {
        continue
      }
      aggregatedValueBySourceTarget["\(sourceID)->\(targetID)", default: 0] += minutes
    }

    let links =
      categoryInputs.flatMap { category in
        visibleAppIDs.compactMap { appID -> WeeklySankeyWebInputLink? in
          let key = "\(category.id)->\(appID)"
          let minutes = aggregatedValueBySourceTarget[key, default: 0]
          guard minutes > 0 else {
            return nil
          }
          return WeeklySankeyWebInputLink(
            id: "\(category.id)-\(appID)",
            from: category.id,
            to: appID,
            minutes: minutes
          )
        }
      }

    let appTotals = Dictionary(grouping: links, by: \.to)
      .mapValues { groupedLinks in
        groupedLinks.reduce(0) { partial, link in
          partial + link.minutes
        }
      }

    let appInputs =
      visibleAppIDs.compactMap { appID -> WeeklySankeyWebInputApp? in
        let minutes = appTotals[appID, default: 0]
        guard minutes > 0 else {
          return nil
        }

        let bucket = appByID[appID] ?? WeeklySankeyFixture.otherAppBucket()
        return WeeklySankeyWebInputApp(
          id: bucket.id,
          name: bucket.title,
          minutes: minutes,
          barColorHex: bucket.colorHex,
          iconSource: bucket.iconSource
        )
      }

    return (categoryInputs, appInputs, links)
  }

  private static func appTemplates() -> [WeeklySankeyWebInputApp] {
    [
      WeeklySankeyWebInputApp(
        id: "chatgpt", name: "Chat GPT", minutes: 0, barColorHex: "333333",
        iconSource: .asset("ChatGPTLogo")),
      WeeklySankeyWebInputApp(
        id: "zoom", name: "Zoom", minutes: 0, barColorHex: "4085FD",
        iconSource: WeeklySankeyIconSource.none),
      WeeklySankeyWebInputApp(
        id: "clickup", name: "ClickUp", minutes: 0, barColorHex: "FD1BB9",
        iconSource: WeeklySankeyIconSource.none),
      WeeklySankeyWebInputApp(
        id: "slack", name: "Slack", minutes: 0, barColorHex: "36C5F0",
        iconSource: WeeklySankeyIconSource.none),
      WeeklySankeyWebInputApp(
        id: "youtube", name: "YouTube", minutes: 0, barColorHex: "FF0000",
        iconSource: WeeklySankeyIconSource.none),
      WeeklySankeyWebInputApp(
        id: "claude", name: "Claude", minutes: 0, barColorHex: "D97757",
        iconSource: .asset("ClaudeLogo")),
      WeeklySankeyWebInputApp(
        id: "figma", name: "Figma", minutes: 0, barColorHex: "FF7262",
        iconSource: WeeklySankeyIconSource.none),
      WeeklySankeyWebInputApp(
        id: "x", name: "X", minutes: 0, barColorHex: "000000",
        iconSource: .monogram(text: "X", background: .black, foreground: .white)),
      WeeklySankeyWebInputApp(
        id: "medium", name: "Medium", minutes: 0, barColorHex: "000000",
        iconSource: .monogram(text: "M", background: .black, foreground: .white)),
      WeeklySankeyWebInputApp(
        id: "other", name: "Other", minutes: 0, barColorHex: "D9D9D9",
        iconSource: WeeklySankeyIconSource.none),
    ]
  }

  private static func build(
    id: String,
    sourceName: String,
    categories rawCategories: [WeeklySankeyWebInputCategory],
    apps rawApps: [WeeklySankeyWebInputApp],
    links rawLinks: [WeeklySankeyWebInputLink],
    preserveAppOrder: Bool = false
  ) -> WeeklySankeyWebModel {
    let categories = rawCategories.filter { $0.minutes > 0 }.sorted { lhs, rhs in
      if lhs.order != rhs.order {
        return lhs.order < rhs.order
      }
      return lhs.name < rhs.name
    }
    let totalMinutes = categories.reduce(0) { partial, category in
      partial + category.minutes
    }
    let links = rawLinks.filter { $0.minutes > 0 }

    let appsWithTotals = rawApps.map { app in
      let linkedMinutes =
        links
        .filter { $0.to == app.id }
        .reduce(0) { partial, link in
          partial + link.minutes
        }
      return WeeklySankeyWebInputApp(
        id: app.id,
        name: app.name,
        minutes: app.minutes > 0 ? app.minutes : linkedMinutes,
        barColorHex: app.barColorHex,
        iconSource: app.iconSource
      )
    }
    .filter { $0.minutes > 0 }

    let categoryBands = allocateBands(
      items: categories,
      layout: WeeklySankeyWebDesign.categories
    )
    let categoryBandByID = Dictionary(uniqueKeysWithValues: categoryBands.map { ($0.id, $0) })

    let appBarycenters = Dictionary(
      uniqueKeysWithValues: appsWithTotals.map { app -> (String, CGFloat) in
        let incomingLinks = links.filter { $0.to == app.id }
        let weightedCenter = incomingLinks.reduce(CGFloat.zero) { partial, link in
          guard let category = categoryBandByID[link.from] else {
            return partial
          }

          return partial + ((category.bar.y + category.bar.height / 2) * CGFloat(link.minutes))
        }
        let total = incomingLinks.reduce(0) { partial, link in
          partial + link.minutes
        }

        return (app.id, total > 0 ? weightedCenter / CGFloat(total) : 999)
      }
    )

    let orderedApps =
      preserveAppOrder
      ? appsWithTotals
      : appsWithTotals.sorted { lhs, rhs in
        if lhs.id == "other" {
          return false
        }
        if rhs.id == "other" {
          return true
        }

        let lhsCenter = appBarycenters[lhs.id, default: 999]
        let rhsCenter = appBarycenters[rhs.id, default: 999]
        if abs(lhsCenter - rhsCenter) > 0.001 {
          return lhsCenter < rhsCenter
        }
        return lhs.name < rhs.name
      }

    let appBands = allocateBands(
      items: orderedApps,
      layout: WeeklySankeyWebDesign.apps
    )
    let appBandByID = Dictionary(uniqueKeysWithValues: appBands.map { ($0.id, $0) })
    let sourceBar = WeeklySankeyWebBox(
      x: WeeklySankeyWebDesign.source.x,
      y: WeeklySankeyWebDesign.source.top,
      width: WeeklySankeyWebDesign.source.width,
      height: WeeklySankeyWebDesign.source.bottom - WeeklySankeyWebDesign.source.top
    )
    let sourceNode = WeeklySankeyWebNode(
      id: "source-weekly-activity",
      name: sourceName,
      metric: formatDuration(minutes: totalMinutes),
      percent: "100%",
      minutes: totalMinutes,
      barColorHex: "D9CBC0",
      iconSource: nil,
      bar: sourceBar,
      label: WeeklySankeyWebLabel(
        x: WeeklySankeyWebDesign.source.labelX,
        y: sourceBar.y + sourceBar.height / 2 - WeeklySankeyWebDesign.source.labelHeight / 2,
        width: WeeklySankeyWebDesign.source.labelWidth
      )
    )

    let sourceSegments = allocateStackSegments(
      items: categoryBands.map { WeeklySankeyWebSegmentInput(id: $0.id, minutes: $0.minutes) },
      top: sourceNode.bar.y,
      height: sourceNode.bar.height
    )
    let sourceSegmentByID = Dictionary(uniqueKeysWithValues: sourceSegments.map { ($0.id, $0) })
    let leftFlows = categoryBands.compactMap { category -> WeeklySankeyWebFlow? in
      guard let segment = sourceSegmentByID[category.id] else {
        return nil
      }

      return WeeklySankeyWebFlow(
        id: "source-\(category.id)",
        from: sourceNode.id,
        to: category.id,
        fromColorHex: sourceNode.barColorHex,
        toColorHex: category.barColorHex,
        x0: sourceNode.bar.x + sourceNode.bar.width,
        y0Top: segment.top,
        y0Bottom: segment.bottom,
        x1: category.bar.x,
        y1Top: category.bar.y,
        y1Bottom: category.bar.y + category.bar.height,
        curveTension: WeeklySankeyWebDesign.sourceCurveTension,
        opacity: 0.18 + 0.11 * sqrt(Double(category.minutes) / Double(max(totalMinutes, 1)))
      )
    }

    let maxLinkMinutes = max(links.map(\.minutes).max() ?? 1, 1)
    var categorySegments: [String: WeeklySankeyWebSegment] = [:]
    var appSegments: [String: WeeklySankeyWebSegment] = [:]

    for category in categoryBands {
      let outgoing =
        links
        .filter { $0.from == category.id }
        .sorted { lhs, rhs in
          let lhsY = appBandByID[lhs.to]?.bar.y ?? 0
          let rhsY = appBandByID[rhs.to]?.bar.y ?? 0
          return lhsY < rhsY
        }
      let segments = allocateStackSegments(
        items: outgoing.map {
          WeeklySankeyWebSegmentInput(id: $0.id, from: $0.from, minutes: $0.minutes)
        },
        top: category.bar.y,
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
        .sorted { lhs, rhs in
          let lhsY = categoryBandByID[lhs.from]?.bar.y ?? 0
          let rhsY = categoryBandByID[rhs.from]?.bar.y ?? 0
          return lhsY < rhsY
        }
      let segments = allocateStackSegments(
        items: incoming.map {
          WeeklySankeyWebSegmentInput(id: $0.to, from: $0.from, minutes: $0.minutes)
        },
        top: app.bar.y,
        height: app.bar.height
      )
      for segment in segments {
        if let from = segment.from {
          appSegments["\(from)-\(app.id)"] = segment
        }
      }
    }

    let rightFlows = links.compactMap { link -> WeeklySankeyWebFlow? in
      guard let category = categoryBandByID[link.from],
        let app = appBandByID[link.to],
        let categorySegment = categorySegments["\(link.from)-\(link.id)"],
        let appSegment = appSegments["\(link.from)-\(link.to)"]
      else {
        return nil
      }

      return WeeklySankeyWebFlow(
        id: link.id,
        from: link.from,
        to: link.to,
        fromColorHex: category.barColorHex,
        toColorHex: app.barColorHex,
        x0: category.bar.x + category.bar.width,
        y0Top: categorySegment.top,
        y0Bottom: categorySegment.bottom,
        x1: app.bar.x,
        y1Top: appSegment.top,
        y1Bottom: appSegment.bottom,
        curveTension: WeeklySankeyWebDesign.rightCurveTension,
        opacity: 0.11 + 0.25 * sqrt(Double(link.minutes) / Double(maxLinkMinutes))
      )
    }

    let categoryLabels = placeLabels(
      nodes: categoryBands,
      layout: WeeklySankeyWebDesign.categories
    )
    let appLabels = placeLabels(
      nodes: appBands,
      layout: WeeklySankeyWebDesign.apps
    )

    return WeeklySankeyWebModel(
      id: id,
      source: sourceNode,
      categories: categoryLabels.map { band in
        WeeklySankeyWebNode(
          id: band.id,
          name: band.name,
          metric: formatDuration(minutes: band.minutes),
          percent: formatPercent(minutes: band.minutes, totalMinutes: totalMinutes),
          minutes: band.minutes,
          barColorHex: band.barColorHex,
          iconSource: nil,
          bar: band.bar,
          label: band.label
        )
      },
      apps: appLabels.map { band in
        WeeklySankeyWebNode(
          id: band.id,
          name: band.name,
          metric: formatDuration(minutes: band.minutes),
          percent: formatPercent(minutes: band.minutes, totalMinutes: totalMinutes),
          minutes: band.minutes,
          barColorHex: band.barColorHex,
          iconSource: band.iconSource,
          bar: band.bar,
          label: band.label
        )
      },
      flows: leftFlows + rightFlows
    )
  }

  private static func allocateBands<T: WeeklySankeyWebBandInput>(
    items: [T],
    layout: WeeklySankeyWebColumnLayout
  ) -> [WeeklySankeyWebBand] {
    guard !items.isEmpty else {
      return []
    }

    let gapTotal = layout.gap * CGFloat(max(items.count - 1, 0))
    let available = max(
      CGFloat(items.count) * layout.minHeight, layout.bottom - layout.top - gapTotal)
    let total = items.reduce(0) { partial, item in
      partial + item.minutes
    }
    let flexible = max(0, available - layout.minHeight * CGFloat(items.count))
    var cursor = layout.top

    return items.map { item in
      let proportionalHeight =
        total > 0
        ? flexible * CGFloat(item.minutes) / CGFloat(total)
        : flexible / CGFloat(max(items.count, 1))
      let band = WeeklySankeyWebBand(
        id: item.id,
        name: item.name,
        minutes: item.minutes,
        barColorHex: item.barColorHex,
        iconSource: item.iconSource,
        bar: WeeklySankeyWebBox(
          x: layout.x,
          y: cursor,
          width: layout.width,
          height: layout.minHeight + proportionalHeight
        ),
        label: WeeklySankeyWebLabel(x: 0, y: 0, width: 0)
      )
      cursor += band.bar.height + layout.gap
      return band
    }
  }

  private static func allocateStackSegments(
    items: [WeeklySankeyWebSegmentInput],
    top: CGFloat,
    height: CGFloat
  ) -> [WeeklySankeyWebSegment] {
    guard !items.isEmpty else {
      return []
    }

    let total = items.reduce(0) { partial, item in
      partial + item.minutes
    }
    var cursor = top

    return items.map { item in
      let segmentHeight =
        total > 0
        ? CGFloat(item.minutes) / CGFloat(total) * height
        : height / CGFloat(max(items.count, 1))
      let segment = WeeklySankeyWebSegment(
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
    nodes: [WeeklySankeyWebBand],
    layout: WeeklySankeyWebColumnLayout
  ) -> [WeeklySankeyWebBand] {
    let sorted = nodes.sorted {
      let lhsTop = $0.bar.y + $0.bar.height / 2 - layout.labelHeight / 2
      let rhsTop = $1.bar.y + $1.bar.height / 2 - layout.labelHeight / 2
      return lhsTop < rhsTop
    }
    var placed: [WeeklySankeyWebBand] = []
    var cursor = layout.labelTop

    for node in sorted {
      let preferredTop = node.bar.y + node.bar.height / 2 - layout.labelHeight / 2
      let y = max(preferredTop, cursor)
      placed.append(
        node.updatingLabel(
          WeeklySankeyWebLabel(x: layout.labelX, y: y, width: layout.labelWidth)
        )
      )
      cursor = y + layout.labelHeight + layout.labelSpacing
    }

    if let lastIndex = placed.indices.last {
      let overflow = placed[lastIndex].label.y + layout.labelHeight - layout.labelBottom
      if overflow > 0 {
        placed[lastIndex] = placed[lastIndex].updatingLabel(
          WeeklySankeyWebLabel(
            x: placed[lastIndex].label.x,
            y: placed[lastIndex].label.y - overflow,
            width: placed[lastIndex].label.width
          )
        )

        if lastIndex > 0 {
          for index in stride(from: lastIndex - 1, through: 0, by: -1) {
            let maximumTop = placed[index + 1].label.y - layout.labelHeight - layout.labelSpacing
            placed[index] = placed[index].updatingLabel(
              WeeklySankeyWebLabel(
                x: placed[index].label.x,
                y: min(placed[index].label.y, maximumTop),
                width: placed[index].label.width
              )
            )
          }
        }

        if let first = placed.first, first.label.y < layout.labelTop {
          placed[0] = first.updatingLabel(
            WeeklySankeyWebLabel(
              x: first.label.x,
              y: layout.labelTop,
              width: first.label.width
            )
          )

          if lastIndex > 0 {
            for index in 1...lastIndex {
              let minimumTop = placed[index - 1].label.y + layout.labelHeight + layout.labelSpacing
              placed[index] = placed[index].updatingLabel(
                WeeklySankeyWebLabel(
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

  private static func formatDuration(minutes: Int) -> String {
    let roundedMinutes = max(1, minutes)
    let hours = roundedMinutes / 60
    let remainingMinutes = roundedMinutes % 60
    if hours <= 0 {
      return "\(remainingMinutes)min"
    }
    return "\(hours)hr \(remainingMinutes)min"
  }

  private static func formatPercent(minutes: Int, totalMinutes: Int) -> String {
    guard totalMinutes > 0 else {
      return "0%"
    }

    let percent = Double(minutes) / Double(totalMinutes) * 100
    return "\(max(1, Int(percent.rounded())))%"
  }
}

private protocol WeeklySankeyWebBandInput {
  var id: String { get }
  var name: String { get }
  var minutes: Int { get }
  var barColorHex: String { get }
  var iconSource: WeeklySankeyIconSource? { get }
}

extension WeeklySankeyWebInputCategory: WeeklySankeyWebBandInput {
  var iconSource: WeeklySankeyIconSource? { nil }
}

extension WeeklySankeyWebInputApp: WeeklySankeyWebBandInput {}

private struct WeeklySankeyWebBand: WeeklySankeyWebBandInput {
  let id: String
  let name: String
  let minutes: Int
  let barColorHex: String
  let iconSource: WeeklySankeyIconSource?
  let bar: WeeklySankeyWebBox
  let label: WeeklySankeyWebLabel

  func updatingLabel(_ label: WeeklySankeyWebLabel) -> WeeklySankeyWebBand {
    WeeklySankeyWebBand(
      id: id,
      name: name,
      minutes: minutes,
      barColorHex: barColorHex,
      iconSource: iconSource,
      bar: bar,
      label: label
    )
  }
}

private struct WeeklySankeyWebSegmentInput {
  let id: String
  let from: String?
  let minutes: Int

  init(id: String, from: String? = nil, minutes: Int) {
    self.id = id
    self.from = from
    self.minutes = minutes
  }
}

private struct WeeklySankeyWebSegment {
  let id: String
  let from: String?
  let top: CGFloat
  let bottom: CGFloat
}

private struct WeeklySankeyWebCard: View {
  let model: WeeklySankeyWebModel

  @State private var hoveredNodeID: String?
  @State private var pinnedNodeID: String?

  private var activeNodeID: String? {
    pinnedNodeID ?? hoveredNodeID
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(
        cornerRadius: WeeklySankeyDistributionSection.Design.cornerRadius, style: .continuous
      )
      .fill(WeeklySankeyDistributionSection.Design.background)

      Canvas { context, size in
        let scale = renderScale(for: size)
        drawUnderlays(in: &context, scale: scale)
        drawFlows(in: &context, scale: scale)
      }

      ForEach(model.nodes) { node in
        let scale = displayScale
        let frame = node.bar.scaled(by: scale)

        Rectangle()
          .fill(Color(hex: node.barColorHex))
          .frame(width: frame.width, height: frame.height)
          .offset(x: frame.minX, y: frame.minY)
          .opacity(nodeOpacity(node.id))
          .contentShape(Rectangle())
          .onHover { isHovering in
            handleHover(isHovering: isHovering, nodeID: node.id)
          }
          .onTapGesture {
            togglePinnedNode(node.id)
          }
          .accessibilityLabel("\(node.name): \(node.metric), \(node.percent)")
      }

      WeeklySankeyWebPlainLabel(
        node: model.source,
        scale: displayScale,
        opacity: nodeOpacity(model.source.id),
        onHover: { isHovering in
          handleHover(isHovering: isHovering, nodeID: model.source.id)
        },
        onTap: { togglePinnedNode(model.source.id) }
      )

      ForEach(model.categories) { category in
        WeeklySankeyWebPlainLabel(
          node: category,
          scale: displayScale,
          opacity: nodeOpacity(category.id),
          onHover: { isHovering in
            handleHover(isHovering: isHovering, nodeID: category.id)
          },
          onTap: { togglePinnedNode(category.id) }
        )
      }

      ForEach(model.apps) { app in
        WeeklySankeyWebAppLabel(
          node: app,
          scale: displayScale,
          opacity: nodeOpacity(app.id),
          onHover: { isHovering in
            handleHover(isHovering: isHovering, nodeID: app.id)
          },
          onTap: { togglePinnedNode(app.id) }
        )
      }
    }
    .frame(
      width: WeeklySankeyDistributionSection.Design.sectionSize.width,
      height: WeeklySankeyDistributionSection.Design.sectionSize.height
    )
    .clipShape(
      RoundedRectangle(
        cornerRadius: WeeklySankeyDistributionSection.Design.cornerRadius,
        style: .continuous
      )
    )
    .overlay(
      RoundedRectangle(
        cornerRadius: WeeklySankeyDistributionSection.Design.cornerRadius,
        style: .continuous
      )
      .stroke(WeeklySankeyDistributionSection.Design.borderColor, lineWidth: 1)
    )
    .onTapGesture {
      pinnedNodeID = nil
    }
    .onHover { isHovering in
      if !isHovering {
        hoveredNodeID = nil
      }
    }
    .onChange(of: model.id) { _, _ in
      hoveredNodeID = nil
      pinnedNodeID = nil
    }
  }

  private var displayScale: CGSize {
    CGSize(
      width: WeeklySankeyDistributionSection.Design.sectionSize.width
        / WeeklySankeyWebDesign.virtualSize.width,
      height: WeeklySankeyDistributionSection.Design.sectionSize.height
        / WeeklySankeyWebDesign.virtualSize.height
    )
  }

  private func renderScale(for size: CGSize) -> CGSize {
    CGSize(
      width: size.width / WeeklySankeyWebDesign.virtualSize.width,
      height: size.height / WeeklySankeyWebDesign.virtualSize.height
    )
  }

  private func drawUnderlays(in context: inout GraphicsContext, scale: CGSize) {
    guard let firstCategory = model.categories.first,
      let firstApp = model.apps.first
    else {
      return
    }

    let sourceUnderlay = columnUnderlayPath(
      x0: model.source.bar.x + model.source.bar.width,
      y0Top: model.source.bar.y,
      y0Bottom: model.source.bar.y + model.source.bar.height,
      x1: firstCategory.bar.x,
      y1Top: model.categories.map(\.bar.y).min() ?? firstCategory.bar.y,
      y1Bottom: model.categories.map { $0.bar.y + $0.bar.height }.max()
        ?? firstCategory.bar.y + firstCategory.bar.height,
      tension: WeeklySankeyWebDesign.sourceCurveTension,
      scale: scale
    )
    context.fill(
      sourceUnderlay,
      with: .linearGradient(
        Gradient(stops: [
          .init(color: Color(hex: "E6DBD1").opacity(0.48), location: 0),
          .init(color: Color(hex: "EFE9E3").opacity(0.34), location: 0.42),
          .init(color: Color(hex: "F4EEE9").opacity(0.2), location: 0.76),
          .init(color: Color(hex: "F7F2ED").opacity(0.08), location: 1),
        ]),
        startPoint: CGPoint(x: (model.source.bar.x + model.source.bar.width) * scale.width, y: 0),
        endPoint: CGPoint(x: firstCategory.bar.x * scale.width, y: 0)
      )
    )

    let rightUnderlay = columnUnderlayPath(
      x0: firstCategory.bar.x + firstCategory.bar.width,
      y0Top: model.categories.map(\.bar.y).min() ?? firstCategory.bar.y,
      y0Bottom: model.categories.map { $0.bar.y + $0.bar.height }.max()
        ?? firstCategory.bar.y + firstCategory.bar.height,
      x1: firstApp.bar.x,
      y1Top: model.apps.map(\.bar.y).min() ?? firstApp.bar.y,
      y1Bottom: model.apps.map { $0.bar.y + $0.bar.height }.max()
        ?? firstApp.bar.y + firstApp.bar.height,
      tension: 0.22,
      scale: scale
    )
    context.fill(
      rightUnderlay,
      with: .linearGradient(
        Gradient(stops: [
          .init(color: Color(hex: "EFE7E0").opacity(0.08 * 0.72), location: 0),
          .init(color: Color(hex: "F4EEE9").opacity(0.11 * 0.72), location: 0.46),
          .init(color: Color(hex: "EFE7E0").opacity(0.07 * 0.72), location: 1),
        ]),
        startPoint: CGPoint(
          x: (firstCategory.bar.x + firstCategory.bar.width) * scale.width,
          y: 0
        ),
        endPoint: CGPoint(x: firstApp.bar.x * scale.width, y: 0)
      )
    )
  }

  private func drawFlows(in context: inout GraphicsContext, scale: CGSize) {
    for flow in model.flows {
      let related = flowIsRelated(flow)
      var flowContext = context
      flowContext.opacity = activeNodeID == nil || related ? 1 : 0.12

      flowContext.fill(
        ribbonPath(for: flow, scale: scale),
        with: .linearGradient(
          Gradient(stops: gradientStops(for: flow)),
          startPoint: CGPoint(x: flow.x0 * scale.width, y: 0),
          endPoint: CGPoint(x: flow.x1 * scale.width, y: 0)
        )
      )
      flowContext.stroke(
        ribbonPath(for: flow, scale: scale),
        with: .color(Color.white.opacity(0.08)),
        lineWidth: 0.12
      )
    }
  }

  private func gradientStops(for flow: WeeklySankeyWebFlow) -> [Gradient.Stop] {
    let sourceFlow = flow.from == model.source.id
    let strength = max(0.08, min(flow.opacity, 0.36))
    let fromColor = ribbonTint(flow.fromColorHex)
    let toColor = ribbonTint(flow.toColorHex)

    if sourceFlow {
      return [
        .init(color: Color(hex: "E3D8CF").opacity(0.18), location: 0),
        .init(color: Color(hex: "ECE3DC").opacity(0.16), location: 0.24),
        .init(color: Color(hex: toColor).opacity(min(0.12, strength * 0.42)), location: 0.58),
        .init(color: Color(hex: toColor).opacity(min(0.2, strength * 0.72)), location: 0.82),
        .init(color: Color(hex: toColor).opacity(min(0.32, strength * 1.08)), location: 1),
      ]
    }

    return [
      .init(color: Color(hex: fromColor).opacity(min(0.2, strength * 0.68)), location: 0),
      .init(color: Color(hex: fromColor).opacity(min(0.11, strength * 0.4)), location: 0.24),
      .init(color: Color(hex: toColor).opacity(min(0.05, strength * 0.2)), location: 0.54),
      .init(color: Color(hex: toColor).opacity(min(0.12, strength * 0.42)), location: 0.78),
      .init(color: Color(hex: toColor).opacity(min(0.27, strength * 0.9)), location: 1),
    ]
  }

  private func ribbonTint(_ colorHex: String) -> String {
    let normalized = colorHex.replacingOccurrences(of: "#", with: "").uppercased()
    if normalized == "000000" || normalized == "333333" {
      return "CAC2BA"
    }
    if normalized == "D9D9D9" || normalized == "BFB6AE" {
      return "CFC8C1"
    }
    return normalized
  }

  private func ribbonPath(for flow: WeeklySankeyWebFlow, scale: CGSize) -> Path {
    let curve = max(90, (flow.x1 - flow.x0) * flow.curveTension)
    var path = Path()
    path.move(to: scaledPoint(x: flow.x0, y: flow.y0Top, scale: scale))
    path.addCurve(
      to: scaledPoint(x: flow.x1, y: flow.y1Top, scale: scale),
      control1: scaledPoint(x: flow.x0 + curve, y: flow.y0Top, scale: scale),
      control2: scaledPoint(x: flow.x1 - curve, y: flow.y1Top, scale: scale)
    )
    path.addLine(to: scaledPoint(x: flow.x1, y: flow.y1Bottom, scale: scale))
    path.addCurve(
      to: scaledPoint(x: flow.x0, y: flow.y0Bottom, scale: scale),
      control1: scaledPoint(x: flow.x1 - curve, y: flow.y1Bottom, scale: scale),
      control2: scaledPoint(x: flow.x0 + curve, y: flow.y0Bottom, scale: scale)
    )
    path.closeSubpath()
    return path
  }

  private func columnUnderlayPath(
    x0: CGFloat,
    y0Top: CGFloat,
    y0Bottom: CGFloat,
    x1: CGFloat,
    y1Top: CGFloat,
    y1Bottom: CGFloat,
    tension: CGFloat,
    scale: CGSize
  ) -> Path {
    let curve = max(90, (x1 - x0) * tension)
    var path = Path()
    path.move(to: scaledPoint(x: x0, y: y0Top, scale: scale))
    path.addCurve(
      to: scaledPoint(x: x1, y: y1Top, scale: scale),
      control1: scaledPoint(x: x0 + curve, y: y0Top, scale: scale),
      control2: scaledPoint(x: x1 - curve, y: y1Top, scale: scale)
    )
    path.addLine(to: scaledPoint(x: x1, y: y1Bottom, scale: scale))
    path.addCurve(
      to: scaledPoint(x: x0, y: y0Bottom, scale: scale),
      control1: scaledPoint(x: x1 - curve, y: y1Bottom, scale: scale),
      control2: scaledPoint(x: x0 + curve, y: y0Bottom, scale: scale)
    )
    path.closeSubpath()
    return path
  }

  private func scaledPoint(x: CGFloat, y: CGFloat, scale: CGSize) -> CGPoint {
    CGPoint(x: x * scale.width, y: y * scale.height)
  }

  private func nodeOpacity(_ nodeID: String) -> Double {
    guard let activeNodeID else {
      return 1
    }

    return nodeIsRelated(nodeID, activeNodeID: activeNodeID) ? 1 : 0.25
  }

  private func flowIsRelated(_ flow: WeeklySankeyWebFlow) -> Bool {
    guard let activeNodeID else {
      return true
    }
    if activeNodeID == model.source.id {
      return true
    }
    return flow.from == activeNodeID || flow.to == activeNodeID
  }

  private func nodeIsRelated(_ nodeID: String, activeNodeID: String) -> Bool {
    if nodeID == activeNodeID || activeNodeID == model.source.id {
      return true
    }

    return model.flows.contains { flow in
      (flow.from == activeNodeID && flow.to == nodeID)
        || (flow.to == activeNodeID && flow.from == nodeID)
        || (flow.from == model.source.id && flow.to == activeNodeID
          && nodeID == model.source.id)
    }
  }

  private func handleHover(isHovering: Bool, nodeID: String) {
    if isHovering {
      hoveredNodeID = nodeID
    } else if hoveredNodeID == nodeID {
      hoveredNodeID = nil
    }
  }

  private func togglePinnedNode(_ nodeID: String) {
    pinnedNodeID = pinnedNodeID == nodeID ? nil : nodeID
  }
}

private struct WeeklySankeyWebPlainLabel: View {
  let node: WeeklySankeyWebNode
  let scale: CGSize
  let opacity: Double
  let onHover: (Bool) -> Void
  let onTap: () -> Void

  var body: some View {
    let origin = node.label.scaledOrigin(by: scale)

    VStack(alignment: .leading, spacing: 2) {
      Text(node.name)
        .font(.custom("Nunito-Regular", size: 10))
        .foregroundStyle(.black)
        .lineLimit(1)

      WeeklySankeyWebMetaLine(metric: node.metric, percent: node.percent)
    }
    .frame(width: node.label.scaledWidth(by: scale), alignment: .topLeading)
    .offset(x: origin.x, y: origin.y)
    .opacity(opacity)
    .contentShape(Rectangle())
    .onHover(perform: onHover)
    .onTapGesture(perform: onTap)
    .accessibilityLabel("\(node.name): \(node.metric), \(node.percent)")
  }
}

private struct WeeklySankeyWebAppLabel: View {
  let node: WeeklySankeyWebNode
  let scale: CGSize
  let opacity: Double
  let onHover: (Bool) -> Void
  let onTap: () -> Void

  var body: some View {
    let origin = node.label.scaledOrigin(by: scale)

    HStack(alignment: .top, spacing: 4) {
      if let iconSource = node.iconSource {
        WeeklySankeyWebIconView(source: iconSource)
          .frame(width: 14, height: 14)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(node.name)
          .font(.custom("Nunito-Regular", size: 10))
          .foregroundStyle(.black)
          .lineLimit(1)

        WeeklySankeyWebMetaLine(metric: node.metric, percent: node.percent, fontSize: 9)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: node.label.scaledWidth(by: scale), alignment: .topLeading)
    .offset(x: origin.x, y: origin.y)
    .opacity(opacity)
    .contentShape(Rectangle())
    .onHover(perform: onHover)
    .onTapGesture(perform: onTap)
    .accessibilityLabel("\(node.name): \(node.metric), \(node.percent)")
  }
}

private struct WeeklySankeyWebMetaLine: View {
  let metric: String
  let percent: String
  var fontSize: CGFloat = 10

  var body: some View {
    HStack(alignment: .top, spacing: fontSize == 9 ? 3 : 4) {
      Text(metric)
      Rectangle()
        .fill(Color(hex: "CFC7C1"))
        .frame(width: 0.5, height: fontSize == 9 ? 10 : 11)
      Text(percent)
    }
    .font(.custom("Nunito-Regular", size: fontSize))
    .foregroundStyle(Color(hex: "717171"))
    .lineLimit(1)
  }
}

private struct WeeklySankeyWebIconView: View {
  let source: WeeklySankeyIconSource

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: 13, height: 13)
      } else {
        fallbackView
      }
    }
    .frame(width: 14, height: 14)
    .task(id: source.cacheKey) {
      image = await source.resolveImage()
    }
  }

  @ViewBuilder
  private var fallbackView: some View {
    switch source {
    case .monogram(let text, let background, let foreground):
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(background)
        .overlay {
          Text(text)
            .font(.custom("Nunito-Bold", size: 8))
            .foregroundStyle(foreground)
        }
    case .none:
      Color.clear
    default:
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(Color.black.opacity(0.05))
    }
  }
}
