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

private struct WeeklySankeyLiveInput {
  let cards: [TimelineCard]
  let categories: [TimelineCategory]
  let weekRange: WeeklyDateRange
}

struct WeeklySankeyDistributionSection: View {
  private let variant: WeeklySankeyPreviewVariant
  private let appFilterPolicy: WeeklySankeyAppFilterPolicy
  private let liveInput: WeeklySankeyLiveInput?

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

  fileprivate init(
    variant: WeeklySankeyPreviewVariant,
    appFilterPolicy: WeeklySankeyAppFilterPolicy = .default
  ) {
    self.variant = variant
    self.appFilterPolicy = appFilterPolicy
    self.liveInput = nil
  }

  private var baseFixture: WeeklySankeyFixture {
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

  private var fixture: WeeklySankeyFixture {
    baseFixture.filteringRightRail(using: appFilterPolicy)
  }

  private var layoutOptions: SankeyLayoutOptions {
    variant.layoutOptions
  }

  private var layout: SankeyLayoutResult {
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

  private var chartBody: some View {
    let layout = layout
    let labelPlacements = labelPlacements(for: layout)

    return ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Design.background)

      Canvas { context, _ in
        for ribbon in layout.ribbons.sorted(by: ribbonSort(lhs:rhs:)) {
          let fillOpacity = ribbon.opacity * Design.ribbonOpacityScale
          context.fill(
            ribbon.path,
            with: .linearGradient(
              Gradient(stops: [
                .init(color: ribbon.leadingColor.opacity(fillOpacity), location: 0),
                .init(color: ribbon.trailingColor.opacity(fillOpacity), location: 1),
              ]),
              startPoint: ribbon.gradientStartPoint,
              endPoint: ribbon.gradientEndPoint
            )
          )
          context.stroke(
            ribbon.path,
            with: .color(Color.white.opacity(Design.ribbonHighlightOpacity)),
            lineWidth: Design.ribbonHighlightWidth
          )
        }
      }

      ForEach(layout.nodes) { node in
        if let content = fixture.contentsByID[node.id] {
          Rectangle()
            .fill(content.barColor)
            .frame(width: node.frame.width, height: node.frame.height)
            .offset(x: node.frame.minX, y: node.frame.minY)
        }
      }

      ForEach(fixture.contents) { content in
        if let placement = labelPlacements[content.id] {
          labelView(for: content)
            .frame(
              width: content.labelSize.width,
              height: content.labelSize.height,
              alignment: .topLeading
            )
            .offset(
              x: placement.origin.x,
              y: placement.origin.y
            )
        }
      }
    }
    .frame(width: Design.sectionSize.width, height: Design.sectionSize.height)
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(Design.borderColor, lineWidth: 1)
    )
  }

  private var showsEmptyState: Bool {
    guard liveInput != nil else {
      return false
    }

    return fixture.nodes.isEmpty || fixture.links.isEmpty || fixture.contents.isEmpty
  }

  private var emptyState: some View {
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
  private func labelView(for content: WeeklySankeyNodeContent) -> some View {
    switch content.labelKind {
    case .plain:
      WeeklySankeyPlainLabel(content: content)
    case .app(let iconSource):
      WeeklySankeyAppLabel(content: content, iconSource: iconSource)
    }
  }

  private func ribbonSort(lhs: SankeyRibbonLayout, rhs: SankeyRibbonLayout) -> Bool {
    if lhs.zIndex == rhs.zIndex {
      return lhs.id < rhs.id
    }
    return lhs.zIndex < rhs.zIndex
  }

  private func labelPlacements(for layout: SankeyLayoutResult) -> [String:
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

  private func resolvedLabelFrames(
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

  private func labelOriginX(for node: SankeyNodeLayout) -> CGFloat {
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

  private func labelVerticalBounds(for columnID: String) -> ClosedRange<CGFloat> {
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

  private func labelSpacing(for columnID: String) -> CGFloat {
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
  fileprivate enum Design {
    static let sectionSize = CGSize(width: 958, height: 549)
    static let cornerRadius: CGFloat = 4
    static let borderColor = Color.white.opacity(0)
    static let background = Color.white
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

private struct WeeklySankeyPlainLabel: View {
  let content: WeeklySankeyNodeContent

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(content.title)
        .font(.custom("Nunito-Bold", size: 14))
        .foregroundStyle(.black)
        .lineLimit(1)
        .minimumScaleFactor(0.85)

      WeeklySankeyMetadataLine(
        durationText: content.durationText,
        shareText: content.shareText
      )
    }
  }
}

private struct WeeklySankeyAppLabel: View {
  let content: WeeklySankeyNodeContent
  let iconSource: WeeklySankeyIconSource

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      WeeklySankeyIconView(source: iconSource)
        .frame(width: 18, height: 18)
        .padding(.top, 1.5)

      VStack(alignment: .leading, spacing: 3) {
        Text(content.title)
          .font(.custom("Nunito-Bold", size: 14))
          .foregroundStyle(.black)
          .lineLimit(1)
          .minimumScaleFactor(0.85)

        WeeklySankeyMetadataLine(
          durationText: content.durationText,
          shareText: content.shareText
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct WeeklySankeyMetadataLine: View {
  let durationText: String
  let shareText: String

  var body: some View {
    Text("\(durationText) | \(shareText)")
      .font(.custom("Nunito-Regular", size: 11))
      .foregroundStyle(Color(hex: "717171"))
      .lineLimit(1)
      .minimumScaleFactor(0.85)
  }
}

private struct WeeklySankeyIconView: View {
  let source: WeeklySankeyIconSource

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        fallbackView
      }
    }
    .frame(width: 18, height: 18)
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
            .font(.custom("Nunito-Bold", size: 9))
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

private enum WeeklySankeyIconSource {
  case asset(String)
  case favicon(raw: String, host: String)
  case monogram(text: String, background: Color, foreground: Color)
  case none

  var cacheKey: String {
    switch self {
    case .asset(let name):
      return "asset:\(name)"
    case .favicon(let raw, let host):
      return "favicon:\(raw):\(host)"
    case .monogram(let text, _, _):
      return "monogram:\(text)"
    case .none:
      return "none"
    }
  }

  func resolveImage() async -> NSImage? {
    switch self {
    case .asset(let name):
      return NSImage(named: name)
    case .favicon(let raw, let host):
      return await FaviconService.shared.fetchFavicon(
        primaryRaw: raw,
        secondaryRaw: nil,
        primaryHost: host,
        secondaryHost: nil
      )
    case .monogram, .none:
      return nil
    }
  }
}

private enum WeeklySankeyLabelKind {
  case plain
  case app(WeeklySankeyIconSource)
}

private struct WeeklySankeyNodeContent: Identifiable {
  let id: String
  let title: String
  let durationText: String
  let shareText: String
  let barColorHex: String
  let labelKind: WeeklySankeyLabelKind

  var barColor: Color {
    Color(hex: barColorHex)
  }

  var labelSize: CGSize {
    switch labelKind {
    case .plain:
      return CGSize(width: 152, height: 34)
    case .app:
      return CGSize(width: 136, height: 34)
    }
  }

  var labelAnchorY: CGFloat {
    switch labelKind {
    case .plain:
      return labelSize.height / 2
    case .app:
      // App labels read off the icon first, so align the icon center to the bar.
      return 10.5
    }
  }
}

private struct WeeklySankeyLabelPlacement {
  let origin: CGPoint
}

private struct WeeklySankeyLabelCandidate {
  let id: String
  let columnID: String
  let preferredTopY: CGFloat
  let originX: CGFloat
  let size: CGSize
}

private struct WeeklySankeyCategoryBucket {
  let id: String
  let title: String
  let colorHex: String
  let totalMinutes: Int
  let order: Int
}

private struct WeeklySankeyAppBucket {
  let id: String
  let title: String
  let colorHex: String
  let iconSource: WeeklySankeyIconSource
  let raw: String?
  let host: String?
  let totalMinutes: Int
}

private struct WeeklySankeyFixture {
  let columns: [SankeyColumnSpec]
  let nodes: [SankeyNodeSpec]
  let links: [SankeyLinkSpec]
  let contents: [WeeklySankeyNodeContent]

  var contentsByID: [String: WeeklySankeyNodeContent] {
    Dictionary(uniqueKeysWithValues: contents.map { ($0.id, $0) })
  }
}

extension WeeklySankeyFixture {
  private static let sourceBlendNeutral = Color(hex: "F4F4F4")
  private static let previewTotalMinutes = 80 * 60

  fileprivate static let balanced = WeeklySankeyFixture(
    columns: [
      SankeyColumnSpec(id: "source", x: 52, topY: 151, barWidth: 10, pointsPerUnit: 2.7),
      SankeyColumnSpec(id: "categories", x: 434, topY: 86, barWidth: 10, pointsPerUnit: 2.08),
      SankeyColumnSpec(id: "apps", x: 798, topY: 16, barWidth: 10, pointsPerUnit: 1.42),
    ],
    nodes: [
      SankeyNodeSpec(
        id: "source-communication",
        columnID: "source",
        order: 0,
        visualWeight: 100,
        preferredHeight: 298
      ),

      SankeyNodeSpec(
        id: "research",
        columnID: "categories",
        order: 0,
        visualWeight: 18,
        preferredHeight: 42
      ),
      SankeyNodeSpec(
        id: "communication",
        columnID: "categories",
        order: 1,
        visualWeight: 16,
        preferredHeight: 36,
        gapBefore: 22
      ),
      SankeyNodeSpec(
        id: "design",
        columnID: "categories",
        order: 2,
        visualWeight: 27,
        preferredHeight: 76,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "general",
        columnID: "categories",
        order: 3,
        visualWeight: 13,
        preferredHeight: 34,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "testing",
        columnID: "categories",
        order: 4,
        visualWeight: 10,
        preferredHeight: 26,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "distractions",
        columnID: "categories",
        order: 5,
        visualWeight: 11,
        preferredHeight: 30,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "personal",
        columnID: "categories",
        order: 6,
        visualWeight: 5,
        preferredHeight: 14,
        gapBefore: 24
      ),

      SankeyNodeSpec(
        id: "chatgpt",
        columnID: "apps",
        order: 0,
        visualWeight: 12,
        preferredHeight: 22
      ),
      SankeyNodeSpec(
        id: "zoom",
        columnID: "apps",
        order: 1,
        visualWeight: 6,
        preferredHeight: 12,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "clickup",
        columnID: "apps",
        order: 2,
        visualWeight: 4,
        preferredHeight: 8,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "slack",
        columnID: "apps",
        order: 3,
        visualWeight: 12,
        preferredHeight: 34,
        gapBefore: 62
      ),
      SankeyNodeSpec(
        id: "youtube",
        columnID: "apps",
        order: 4,
        visualWeight: 8,
        preferredHeight: 18,
        gapBefore: 42
      ),
      SankeyNodeSpec(
        id: "claude",
        columnID: "apps",
        order: 5,
        visualWeight: 11,
        preferredHeight: 22,
        gapBefore: 34
      ),
      SankeyNodeSpec(
        id: "figma",
        columnID: "apps",
        order: 6,
        visualWeight: 24,
        preferredHeight: 62,
        gapBefore: 42
      ),
      SankeyNodeSpec(
        id: "x",
        columnID: "apps",
        order: 7,
        visualWeight: 11,
        preferredHeight: 28,
        gapBefore: 18
      ),
      SankeyNodeSpec(
        id: "medium",
        columnID: "apps",
        order: 8,
        visualWeight: 4,
        preferredHeight: 10,
        gapBefore: 20
      ),
      SankeyNodeSpec(
        id: "other",
        columnID: "apps",
        order: 9,
        visualWeight: 8,
        preferredHeight: 22,
        gapBefore: 20
      ),
    ],
    links: [
      sourceLink(
        id: "left-research", target: "research", value: 18, order: 0, opacity: 0.88
      ),
      sourceLink(
        id: "left-communication", target: "communication", value: 16, order: 1, opacity: 0.86),
      sourceLink(
        id: "left-design", target: "design", value: 27, order: 2, opacity: 0.84),
      sourceLink(
        id: "left-general", target: "general", value: 13, order: 3, opacity: 0.86),
      sourceLink(
        id: "left-testing", target: "testing", value: 10, order: 4, opacity: 0.86),
      sourceLink(
        id: "left-distractions", target: "distractions", value: 11, order: 5, opacity: 0.88),
      sourceLink(
        id: "left-personal", target: "personal", value: 5, order: 6, opacity: 0.88),

      appLink(
        id: "research-chatgpt", source: "research", target: "chatgpt", value: 12, sourceOrder: 0,
        targetOrder: 0, opacity: 0.88),
      appLink(
        id: "research-zoom", source: "research", target: "zoom", value: 6, sourceOrder: 1,
        targetOrder: 1, opacity: 0.82),

      appLink(
        id: "communication-clickup", source: "communication", target: "clickup", value: 4,
        sourceOrder: 0, targetOrder: 2, opacity: 0.88),
      appLink(
        id: "communication-slack", source: "communication", target: "slack", value: 12,
        sourceOrder: 1, targetOrder: 3, opacity: 0.84),

      appLink(
        id: "design-youtube", source: "design", target: "youtube", value: 2, sourceOrder: 0,
        targetOrder: 4, opacity: 0.78),
      appLink(
        id: "design-claude", source: "design", target: "claude", value: 5, sourceOrder: 1,
        targetOrder: 5, opacity: 0.80),
      appLink(
        id: "design-figma", source: "design", target: "figma", value: 20, sourceOrder: 2,
        targetOrder: 6, opacity: 0.88),

      appLink(
        id: "general-youtube", source: "general", target: "youtube", value: 3, sourceOrder: 0,
        targetOrder: 4, opacity: 0.82),
      appLink(
        id: "general-other", source: "general", target: "other", value: 5, sourceOrder: 1,
        targetOrder: 9, opacity: 0.80),
      appLink(
        id: "general-x", source: "general", target: "x", value: 5, sourceOrder: 2, targetOrder: 7,
        opacity: 0.80),

      appLink(
        id: "testing-claude", source: "testing", target: "claude", value: 6, sourceOrder: 0,
        targetOrder: 5, opacity: 0.84),
      appLink(
        id: "testing-figma", source: "testing", target: "figma", value: 3, sourceOrder: 1,
        targetOrder: 6, opacity: 0.84),
      appLink(
        id: "testing-x", source: "testing", target: "x", value: 1, sourceOrder: 2, targetOrder: 7,
        opacity: 0.78),

      appLink(
        id: "distractions-youtube", source: "distractions", target: "youtube", value: 3,
        sourceOrder: 0, targetOrder: 4, opacity: 0.82),
      appLink(
        id: "distractions-x", source: "distractions", target: "x", value: 5, sourceOrder: 1,
        targetOrder: 7, opacity: 0.82),
      appLink(
        id: "distractions-medium", source: "distractions", target: "medium", value: 3,
        sourceOrder: 2, targetOrder: 8, opacity: 0.80),

      appLink(
        id: "personal-other", source: "personal", target: "other", value: 3, sourceOrder: 0,
        targetOrder: 9, opacity: 0.78),
      appLink(
        id: "personal-medium", source: "personal", target: "medium", value: 1, sourceOrder: 1,
        targetOrder: 8, opacity: 0.76),
      appLink(
        id: "personal-figma", source: "personal", target: "figma", value: 1, sourceOrder: 2,
        targetOrder: 6, opacity: 0.76),
    ],
    contents: [
      WeeklySankeyNodeContent(
        id: "source-communication",
        title: "Communication",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "D9CBC0",
        labelKind: .plain
      ),

      WeeklySankeyNodeContent(
        id: "research",
        title: "Research",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "93BCFF",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "communication",
        title: "Communication",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "6CDACD",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "design",
        title: "Design",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "DE9DFC",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "general",
        title: "General",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "BFB6AE",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "testing",
        title: "Testing",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "FFA189",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "distractions",
        title: "Distractions",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "FF5950",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "personal",
        title: "Personal",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "FFC6B7",
        labelKind: .plain
      ),

      WeeklySankeyNodeContent(
        id: "chatgpt",
        title: "Chat GPT",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "333333",
        labelKind: .app(.asset("ChatGPTLogo"))
      ),
      WeeklySankeyNodeContent(
        id: "zoom",
        title: "Zoom",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "4085FD",
        labelKind: .app(.favicon(raw: "zoom.us", host: "zoom.us"))
      ),
      WeeklySankeyNodeContent(
        id: "clickup",
        title: "ClickUp",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "FD1BB9",
        labelKind: .app(.favicon(raw: "clickup.com", host: "clickup.com"))
      ),
      WeeklySankeyNodeContent(
        id: "slack",
        title: "Slack",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "36C5F0",
        labelKind: .app(.favicon(raw: "slack.com", host: "slack.com"))
      ),
      WeeklySankeyNodeContent(
        id: "youtube",
        title: "YouTube",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "FF0000",
        labelKind: .app(.favicon(raw: "youtube.com", host: "youtube.com"))
      ),
      WeeklySankeyNodeContent(
        id: "claude",
        title: "Claude",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "D97757",
        labelKind: .app(.asset("ClaudeLogo"))
      ),
      WeeklySankeyNodeContent(
        id: "figma",
        title: "Figma",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "FF7262",
        labelKind: .app(.favicon(raw: "figma.com", host: "figma.com"))
      ),
      WeeklySankeyNodeContent(
        id: "x",
        title: "X",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "000000",
        labelKind: .app(.monogram(text: "X", background: .black, foreground: .white))
      ),
      WeeklySankeyNodeContent(
        id: "medium",
        title: "Medium",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "000000",
        labelKind: .app(.monogram(text: "M", background: .black, foreground: .white))
      ),
      WeeklySankeyNodeContent(
        id: "other",
        title: "Other",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "D9D9D9",
        labelKind: .app(.none)
      ),
    ]
  )

  fileprivate static let airier = makeAirierFixture(from: .balanced)

  fileprivate static func live(
    cards: [TimelineCard],
    categories: [TimelineCategory],
    weekRange: WeeklyDateRange,
    geometry: WeeklySankeyFixture
  ) -> WeeklySankeyFixture {
    let orderedCategories =
      categories
      .sorted { $0.order < $1.order }
      .filter { !$0.isSystem }
    let categoryLookup = firstCategoryLookup(
      from: orderedCategories,
      normalizedKey: normalizedCategoryKey
    )
    let visibleWorkdays = Set(workdayStrings(for: weekRange.weekStart))
    let workweekCards = cards.filter { visibleWorkdays.contains($0.day) }

    var minutesByCategoryID: [String: Int] = [:]
    var categoryByID: [String: WeeklySankeyCategoryBucket] = [:]
    var minutesByAppID: [String: Int] = [:]
    var appByID: [String: WeeklySankeyAppBucket] = [:]
    var minutesByCategoryAppKey: [String: Int] = [:]

    for card in workweekCards {
      let categoryID = normalizedCategoryKey(displayName(for: card.category))
      guard categoryID != "system" else {
        continue
      }

      let minutes = totalMinutes(for: card)
      guard minutes > 0 else {
        continue
      }

      let categoryBucket = resolvedCategoryBucket(
        id: categoryID,
        card: card,
        categories: categoryLookup
      )
      minutesByCategoryID[categoryID, default: 0] += minutes
      categoryByID[categoryID] = categoryBucket

      let appBucket =
        resolvedAppBucket(
          primaryRaw: card.appSites?.primary,
          secondaryRaw: card.appSites?.secondary
        )
        ?? otherAppBucket()

      minutesByAppID[appBucket.id, default: 0] += minutes
      if appByID[appBucket.id] == nil {
        appByID[appBucket.id] = appBucket
      }

      let categoryAppKey = sourceTargetKey(source: categoryID, target: appBucket.id)
      minutesByCategoryAppKey[categoryAppKey, default: 0] += minutes
    }

    let totalMinutes = minutesByCategoryID.values.reduce(0, +)
    guard totalMinutes > 0 else {
      return WeeklySankeyFixture(
        columns: geometry.columns,
        nodes: [],
        links: [],
        contents: []
      )
    }

    let categoryBuckets: [WeeklySankeyCategoryBucket] = minutesByCategoryID.compactMap { entry in
      let (categoryID, minutes) = entry

      guard let bucket = categoryByID[categoryID] else {
        return nil
      }

      return WeeklySankeyCategoryBucket(
        id: bucket.id,
        title: bucket.title,
        colorHex: bucket.colorHex,
        totalMinutes: minutes,
        order: bucket.order
      )
    }
    .sorted { lhs, rhs in
      if lhs.order != rhs.order {
        return lhs.order < rhs.order
      }
      if lhs.totalMinutes != rhs.totalMinutes {
        return lhs.totalMinutes > rhs.totalMinutes
      }
      return lhs.title < rhs.title
    }

    let appBuckets: [WeeklySankeyAppBucket] = minutesByAppID.compactMap { entry in
      let (appID, minutes) = entry

      guard let bucket = appByID[appID] else {
        return nil
      }

      return WeeklySankeyAppBucket(
        id: bucket.id,
        title: bucket.title,
        colorHex: bucket.colorHex,
        iconSource: bucket.iconSource,
        raw: bucket.raw,
        host: bucket.host,
        totalMinutes: minutes
      )
    }
    .sorted { lhs, rhs in
      if lhs.totalMinutes != rhs.totalMinutes {
        return lhs.totalMinutes > rhs.totalMinutes
      }
      return lhs.title < rhs.title
    }

    let sourceID = "source-week"
    let columns = liveColumns(totalMinutes: totalMinutes, geometry: geometry)
    let categoryNodes = categoryBuckets.enumerated().map { index, bucket in
      SankeyNodeSpec(
        id: bucket.id,
        columnID: "categories",
        order: index,
        visualWeight: CGFloat(bucket.totalMinutes),
        preferredHeight: max(CGFloat(bucket.totalMinutes) * columns.categoryPointsPerMinute, 14),
        gapBefore: index == 0 ? 0 : 24
      )
    }
    let appNodes = appBuckets.enumerated().map { index, bucket in
      SankeyNodeSpec(
        id: bucket.id,
        columnID: "apps",
        order: index,
        visualWeight: CGFloat(bucket.totalMinutes),
        preferredHeight: max(CGFloat(bucket.totalMinutes) * columns.appPointsPerMinute, 8),
        gapBefore: index == 0 ? 0 : 20
      )
    }

    let sourceNode = SankeyNodeSpec(
      id: sourceID,
      columnID: "source",
      order: 0,
      visualWeight: CGFloat(totalMinutes),
      preferredHeight: 300
    )

    let appOrderByID: [String: Int] = Dictionary(
      uniqueKeysWithValues: appBuckets.enumerated().map { ($1.id, $0) }
    )
    let sourceContent = WeeklySankeyNodeContent(
      id: sourceID,
      title: weekRange == WeeklyDateRange.containing(Date()) ? "This Week" : "Week Total",
      durationText: formattedDuration(minutes: totalMinutes),
      shareText: "100%",
      barColorHex: "D9CBC0",
      labelKind: .plain
    )
    let categoryContents = categoryBuckets.map { bucket in
      WeeklySankeyNodeContent(
        id: bucket.id,
        title: bucket.title,
        durationText: formattedDuration(minutes: bucket.totalMinutes),
        shareText: shareText(minutes: bucket.totalMinutes, totalMinutes: totalMinutes),
        barColorHex: bucket.colorHex,
        labelKind: .plain
      )
    }
    let appContents = appBuckets.map { bucket in
      WeeklySankeyNodeContent(
        id: bucket.id,
        title: bucket.title,
        durationText: formattedDuration(minutes: bucket.totalMinutes),
        shareText: shareText(minutes: bucket.totalMinutes, totalMinutes: totalMinutes),
        barColorHex: bucket.colorHex,
        labelKind: .app(bucket.iconSource)
      )
    }
    let contents: [WeeklySankeyNodeContent] = [sourceContent] + categoryContents + appContents
    let contentsByID: [String: WeeklySankeyNodeContent] = Dictionary(
      uniqueKeysWithValues: contents.map { ($0.id, $0) }
    )

    let sourceLinks = categoryBuckets.enumerated().map { index, bucket in
      dynamicSourceLink(
        id: "live-left-\(bucket.id)",
        sourceNodeID: sourceID,
        targetNodeID: bucket.id,
        value: CGFloat(bucket.totalMinutes),
        sourceOrder: index,
        opacity: sourceOpacity(for: bucket.totalMinutes, totalMinutes: totalMinutes),
        targetColorHex: bucket.colorHex
      )
    }

    var appLinks: [SankeyLinkSpec] = []
    for categoryBucket in categoryBuckets {
      let categoryTargets =
        appBuckets
        .filter { bucket in
          minutesByCategoryAppKey[
            sourceTargetKey(source: categoryBucket.id, target: bucket.id), default: 0] > 0
        }
        .sorted { lhs, rhs in
          let lhsValue =
            minutesByCategoryAppKey[
              sourceTargetKey(source: categoryBucket.id, target: lhs.id), default: 0]
          let rhsValue =
            minutesByCategoryAppKey[
              sourceTargetKey(source: categoryBucket.id, target: rhs.id), default: 0]

          if lhsValue != rhsValue {
            return lhsValue > rhsValue
          }

          return appOrderByID[lhs.id, default: Int.max] < appOrderByID[rhs.id, default: Int.max]
        }

      for (sourceOrder, appBucket) in categoryTargets.enumerated() {
        let key = sourceTargetKey(source: categoryBucket.id, target: appBucket.id)
        let minutes = minutesByCategoryAppKey[key, default: 0]
        guard minutes > 0 else {
          continue
        }

        appLinks.append(
          dynamicAppLink(
            id: "live-\(categoryBucket.id)-\(appBucket.id)",
            source: categoryBucket.id,
            target: appBucket.id,
            value: CGFloat(minutes),
            sourceOrder: sourceOrder,
            targetOrder: appOrderByID[appBucket.id, default: 0],
            opacity: appOpacity(minutes: minutes, totalMinutes: totalMinutes),
            contentsByID: contentsByID
          )
        )
      }
    }

    return WeeklySankeyFixture(
      columns: columns.columns,
      nodes: [sourceNode] + categoryNodes + appNodes,
      links: sourceLinks + appLinks,
      contents: contents
    )
  }

  fileprivate static func sourceLink(
    id: String,
    target: String,
    value: CGFloat,
    order: Int,
    opacity: Double
  ) -> SankeyLinkSpec {
    let center = CGFloat(3)
    let spread = CGFloat(order) - center

    return SankeyLinkSpec(
      id: id,
      sourceNodeID: "source-communication",
      targetNodeID: target,
      value: value,
      sourceOrder: order,
      targetOrder: 0,
      style: SankeyRibbonStyle(
        leadingColor: sourceBlendNeutral,
        trailingColor: categoryRibbonColor(for: target),
        opacity: opacity,
        zIndex: Double(order),
        leadingControlFactor: 0.26,
        trailingControlFactor: 0.34,
        topStartBend: spread * 6,
        topEndBend: spread * 2,
        bottomStartBend: spread * 6,
        bottomEndBend: spread * 2
      )
    )
  }

  fileprivate static func appLink(
    id: String,
    source: String,
    target: String,
    value: CGFloat,
    sourceOrder: Int,
    targetOrder: Int,
    opacity: Double
  ) -> SankeyLinkSpec {
    let slope = CGFloat(targetOrder - sourceOrder)

    return SankeyLinkSpec(
      id: id,
      sourceNodeID: source,
      targetNodeID: target,
      value: value,
      sourceOrder: sourceOrder,
      targetOrder: targetOrder,
      style: SankeyRibbonStyle(
        leadingColor: categoryRibbonColor(for: source),
        trailingColor: appRibbonColor(for: target),
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

  private static func categoryRibbonColor(for id: String) -> Color {
    softenedColor(
      hex: categoryBarHex(for: id),
      by: categoryRibbonSofteningAmount(for: id)
    )
  }

  private static func appRibbonColor(for id: String) -> Color {
    softenedColor(
      hex: appBarHex(for: id),
      by: appRibbonSofteningAmount(for: id)
    )
  }

  private static func categoryBarHex(for id: String) -> String {
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

  private static func appBarHex(for id: String) -> String {
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

  private static func categoryRibbonSofteningAmount(for id: String) -> CGFloat {
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

  private static func appRibbonSofteningAmount(for id: String) -> CGFloat {
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

  private static func liveColumns(
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

  private static func dynamicSourceLink(
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

  private static func dynamicAppLink(
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

  private static func sourceOpacity(for minutes: Int, totalMinutes: Int) -> Double {
    let share = Double(minutes) / Double(max(totalMinutes, 1))
    return min(max(0.72 + (share * 0.4), 0.76), 0.9)
  }

  private static func appOpacity(minutes: Int, totalMinutes: Int) -> Double {
    let share = Double(minutes) / Double(max(totalMinutes, 1))
    return min(max(0.7 + (share * 0.55), 0.76), 0.9)
  }

  private static func shareText(minutes: Int, totalMinutes: Int) -> String {
    let share = Double(minutes) / Double(max(totalMinutes, 1))
    return "\(Int((share * 100).rounded()))%"
  }

  private static func resolvedCategoryBucket(
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

  private static func resolvedAppBucket(
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

  private static func otherAppBucket() -> WeeklySankeyAppBucket {
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

  private static func preferredRawAppValue(
    primaryRaw: String?,
    secondaryRaw: String?
  ) -> String? {
    let trimmedPrimary = trimmed(primaryRaw)
    if let trimmedPrimary {
      return trimmedPrimary
    }

    return trimmed(secondaryRaw)
  }

  private static func canonicalAppID(raw: String?, host: String?) -> String {
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

  private static func faviconHost(for id: String, host: String?) -> String? {
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

  private static func appTitle(for id: String, raw: String?, host: String?) -> String {
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

  private static func appColorHex(for id: String, host: String?) -> String {
    switch id {
    case "other":
      return "D9D9D9"
    case "chatgpt", "zoom", "clickup", "slack", "youtube", "claude", "figma", "x", "medium":
      return appBarHex(for: id)
    default:
      return fallbackAppHex(for: host ?? id)
    }
  }

  private static func appIconSource(for id: String, raw: String?, host: String?)
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

  private static func displayTitle(fromHost host: String) -> String {
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

  private static func fallbackCategoryHex(for seed: String) -> String {
    fallbackHex(
      for: seed,
      palette: ["73A7FF", "6CDACD", "DE9DFC", "BFB6AE", "FFA189", "FF5950", "FFC6B7"]
    )
  }

  private static func fallbackAppHex(for seed: String) -> String {
    fallbackHex(
      for: seed,
      palette: ["4085FD", "36C5F0", "FD1BB9", "FF7262", "D97757", "7C8CF8", "6BBFA9", "7A7A7A"]
    )
  }

  private static func fallbackHex(for seed: String, palette: [String]) -> String {
    let hash = seed.utf8.reduce(5381) { partial, byte in
      ((partial << 5) &+ partial) &+ Int(byte)
    }
    let index = abs(hash) % max(palette.count, 1)
    return palette[index]
  }

  private static func sanitizedNodeID(_ raw: String) -> String {
    raw
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "www.", with: "")
      .replacingOccurrences(of: "://", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ".", with: "-")
      .replacingOccurrences(of: " ", with: "-")
  }

  private static func sanitizedHex(_ raw: String?) -> String? {
    guard let raw = trimmed(raw), !raw.isEmpty else {
      return nil
    }

    return raw.replacingOccurrences(of: "#", with: "")
  }

  private static func trimmed(_ raw: String?) -> String? {
    guard let raw else {
      return nil
    }

    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func displayName(for value: String) -> String {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedValue.isEmpty ? "Uncategorized" : trimmedValue
  }

  private static func normalizedCategoryKey(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private static func normalizedHost(_ site: String?) -> String? {
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

  private static func workdayStrings(for weekStart: Date) -> [String] {
    let calendar = sankeyCalendar
    return (0..<5).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
        return nil
      }
      return DateFormatter.yyyyMMdd.string(from: date)
    }
  }

  private static func totalMinutes(for card: TimelineCard) -> Int {
    guard let startMinute = parseCardMinute(card.startTimestamp),
      let endMinute = parseCardMinute(card.endTimestamp)
    else {
      return 0
    }

    let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
    return max(Int((normalized.end - normalized.start).rounded()), 0)
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

  private static func parseCardMinute(_ value: String) -> Double? {
    guard let parsed = parseTimeHMMA(timeString: value) else {
      return nil
    }

    return Double(parsed)
  }

  private static let sankeyCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }()

  private static func softenedColor(
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

  private static func rgbComponents(from hex: String) -> (red: Double, green: Double, blue: Double)
  {
    let sanitized = hex.replacingOccurrences(of: "#", with: "")
    let value = UInt64(sanitized, radix: 16) ?? 0

    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255

    return (red, green, blue)
  }

  private static func makeAirierFixture(from base: WeeklySankeyFixture) -> WeeklySankeyFixture {
    WeeklySankeyFixture(
      columns: base.columns.map { column in
        switch column.id {
        case "source":
          return column.updating(topY: 147)
        case "categories":
          return column.updating(topY: 80, pointsPerUnit: 2.14)
        case "apps":
          return column.updating(topY: 18, pointsPerUnit: 1.22)
        default:
          return column
        }
      },
      nodes: base.nodes.map { node in
        switch node.id {
        case "source-communication":
          return node.updating(preferredHeight: 312)
        case "research":
          return node.updating(preferredHeight: 46)
        case "communication":
          return node.updating(preferredHeight: 40, gapBefore: 24)
        case "design":
          return node.updating(preferredHeight: 84, gapBefore: 24)
        case "general":
          return node.updating(preferredHeight: 36, gapBefore: 24)
        case "testing":
          return node.updating(preferredHeight: 28, gapBefore: 24)
        case "distractions":
          return node.updating(preferredHeight: 32, gapBefore: 24)
        case "personal":
          return node.updating(preferredHeight: 16, gapBefore: 24)
        case "chatgpt":
          return node.updating(preferredHeight: 18)
        case "zoom":
          return node.updating(preferredHeight: 10, gapBefore: 24)
        case "clickup":
          return node.updating(preferredHeight: 7, gapBefore: 24)
        case "slack":
          return node.updating(preferredHeight: 30, gapBefore: 68)
        case "youtube":
          return node.updating(preferredHeight: 16, gapBefore: 44)
        case "claude":
          return node.updating(preferredHeight: 18, gapBefore: 36)
        case "figma":
          return node.updating(preferredHeight: 56, gapBefore: 46)
        case "x":
          return node.updating(preferredHeight: 24, gapBefore: 20)
        case "medium":
          return node.updating(preferredHeight: 8, gapBefore: 20)
        case "other":
          return node.updating(preferredHeight: 18, gapBefore: 20)
        default:
          return node
        }
      },
      links: base.links.map { link in
        link.updatingStyle { style in
          if link.sourceNodeID == "source-communication" {
            return style.updating(
              opacity: min(style.opacity * 0.96, 1),
              leadingControlFactor: 0.28,
              trailingControlFactor: 0.38,
              topStartBend: style.topStartBend * 0.9,
              topEndBend: style.topEndBend * 1.1,
              bottomStartBend: style.bottomStartBend * 0.9,
              bottomEndBend: style.bottomEndBend * 1.1
            )
          }

          return style.updating(
            opacity: min(style.opacity * 0.93, 1),
            leadingControlFactor: 0.34,
            trailingControlFactor: 0.32,
            topStartBend: style.topStartBend * 1.1,
            topEndBend: style.topEndBend * 1.18,
            bottomStartBend: style.bottomStartBend * 1.1,
            bottomEndBend: style.bottomEndBend * 1.18
          )
        }
      },
      contents: base.contents
    )
  }

  fileprivate func filteringRightRail(
    using policy: WeeklySankeyAppFilterPolicy
  ) -> WeeklySankeyFixture {
    let orderedAppNodes =
      nodes
      .filter { $0.columnID == "apps" }
      .sorted { $0.order < $1.order }
    guard !orderedAppNodes.isEmpty else {
      return self
    }

    let orderedCategoryNodes =
      nodes
      .filter { $0.columnID == "categories" }
      .sorted { $0.order < $1.order }
    let appNodeIDs = Set(orderedAppNodes.map(\.id))
    let appLinks = links.filter { appNodeIDs.contains($0.targetNodeID) }
    let totalAppValue = appLinks.reduce(CGFloat.zero) { partial, link in
      partial + link.value
    }
    guard totalAppValue > 0 else {
      return self
    }

    let otherNodeID = "other"
    let incomingValueByAppID = Dictionary(grouping: appLinks, by: \.targetNodeID)
      .mapValues { groupedLinks in
        groupedLinks.reduce(CGFloat.zero) { partial, link in
          partial + link.value
        }
      }
    let appIndexByID = Dictionary(
      uniqueKeysWithValues: orderedAppNodes.enumerated().map { ($1.id, $0) }
    )

    let candidateAppIDs = orderedAppNodes.map(\.id).filter { $0 != otherNodeID }
    let minimumVisibleValue = totalAppValue * CGFloat(policy.minAppSharePercent) / 100
    let thresholdVisibleIDs = candidateAppIDs.filter { appID in
      incomingValueByAppID[appID, default: 0] >= minimumVisibleValue
    }

    let keptAppIDs: Set<String>
    if let maxVisibleApps = policy.maxVisibleApps {
      let cappedIDs =
        thresholdVisibleIDs
        .sorted { lhs, rhs in
          let lhsValue = incomingValueByAppID[lhs, default: 0]
          let rhsValue = incomingValueByAppID[rhs, default: 0]

          if abs(lhsValue - rhsValue) > 0.001 {
            return lhsValue > rhsValue
          }

          return appIndexByID[lhs, default: Int.max] < appIndexByID[rhs, default: Int.max]
        }
        .prefix(maxVisibleApps)
      keptAppIDs = Set(cappedIDs)
    } else {
      keptAppIDs = Set(thresholdVisibleIDs)
    }

    let collapsedAppIDs = Set(candidateAppIDs).subtracting(keptAppIDs)
    let shouldShowOther =
      incomingValueByAppID[otherNodeID, default: 0] > 0
      || !collapsedAppIDs.isEmpty

    var visibleAppIDSet = keptAppIDs
    if shouldShowOther {
      visibleAppIDSet.insert(otherNodeID)
    }

    var aggregatedValueBySourceTarget: [String: CGFloat] = [:]
    var aggregatedOpacityNumeratorBySourceTarget: [String: Double] = [:]

    for link in appLinks {
      let targetNodeID: String
      if visibleAppIDSet.contains(link.targetNodeID) {
        targetNodeID = link.targetNodeID
      } else if shouldShowOther {
        targetNodeID = otherNodeID
      } else {
        continue
      }

      let key = Self.sourceTargetKey(source: link.sourceNodeID, target: targetNodeID)
      aggregatedValueBySourceTarget[key, default: 0] += link.value
      aggregatedOpacityNumeratorBySourceTarget[key, default: 0] +=
        link.style.opacity * Double(link.value)
    }

    let visibleAppIDs = Self.orderedFilteredAppIDs(
      visibleAppIDs: visibleAppIDSet,
      orderedCategoryNodes: orderedCategoryNodes,
      aggregatedValueBySourceTarget: aggregatedValueBySourceTarget,
      incomingValueByAppID: incomingValueByAppID
    )
    let targetOrderByID = Dictionary(
      uniqueKeysWithValues: visibleAppIDs.enumerated().map { ($1, $0) })
    var filteredAppLinks: [SankeyLinkSpec] = []

    for categoryNode in orderedCategoryNodes {
      let visibleTargetsForSource = visibleAppIDs.filter { targetNodeID in
        let key = Self.sourceTargetKey(source: categoryNode.id, target: targetNodeID)
        return aggregatedValueBySourceTarget[key, default: 0] > 0.001
      }

      for (sourceOrder, targetNodeID) in visibleTargetsForSource.enumerated() {
        let key = Self.sourceTargetKey(source: categoryNode.id, target: targetNodeID)
        let value = aggregatedValueBySourceTarget[key, default: 0]
        guard value > 0 else { continue }

        let opacityNumerator = aggregatedOpacityNumeratorBySourceTarget[key, default: 0]
        let opacity = opacityNumerator / Double(value)

        filteredAppLinks.append(
          Self.dynamicAppLink(
            id: "filtered-\(categoryNode.id)-\(targetNodeID)",
            source: categoryNode.id,
            target: targetNodeID,
            value: value,
            sourceOrder: sourceOrder,
            targetOrder: targetOrderByID[targetNodeID, default: 0],
            opacity: opacity,
            contentsByID: contentsByID
          )
        )
      }
    }

    let filteredIncomingValueByAppID = Dictionary(grouping: filteredAppLinks, by: \.targetNodeID)
      .mapValues { groupedLinks in
        groupedLinks.reduce(CGFloat.zero) { partial, link in
          partial + link.value
        }
      }

    let appNodesByID = Dictionary(uniqueKeysWithValues: orderedAppNodes.map { ($0.id, $0) })
    let appPointsPerUnit = columns.first(where: { $0.id == "apps" })?.pointsPerUnit ?? 1
    let gapScale = Self.appGapScale(
      visibleCount: visibleAppIDs.count, baseCount: orderedAppNodes.count)

    let filteredAppNodes = visibleAppIDs.enumerated().compactMap {
      index, appID -> SankeyNodeSpec? in
      let baseNode = appNodesByID[appID] ?? Self.syntheticOtherAppNode()
      let value = filteredIncomingValueByAppID[appID, default: 0]
      guard value > 0.001 else {
        return nil
      }

      let preferredHeight: CGFloat?
      if appID == otherNodeID {
        preferredHeight = max(value * appPointsPerUnit, 8)
      } else {
        let baseValue = max(incomingValueByAppID[appID, default: value], 0.001)
        preferredHeight = Self.scaledPreferredHeight(
          baseNode.preferredHeight,
          newValue: value,
          baseValue: baseValue
        )
      }

      return SankeyNodeSpec(
        id: appID,
        columnID: baseNode.columnID,
        order: index,
        visualWeight: value,
        preferredHeight: preferredHeight,
        gapBefore: index == 0 ? 0 : baseNode.gapBefore * gapScale
      )
    }

    let nonAppContents = contents.filter { !appNodeIDs.contains($0.id) }
    let filteredAppContents = visibleAppIDs.compactMap { appID -> WeeklySankeyNodeContent? in
      let baseContent = contentsByID[appID] ?? Self.syntheticOtherAppContent()
      let value = filteredIncomingValueByAppID[appID, default: 0]
      guard value > 0.001 else {
        return nil
      }

      return Self.appContent(
        from: baseContent,
        value: value,
        totalValue: totalAppValue
      )
    }

    return WeeklySankeyFixture(
      columns: columns,
      nodes: nodes.filter { $0.columnID != "apps" } + filteredAppNodes,
      links: links.filter { !appNodeIDs.contains($0.targetNodeID) } + filteredAppLinks,
      contents: nonAppContents + filteredAppContents
    )
  }

  private static func appGapScale(visibleCount: Int, baseCount: Int) -> CGFloat {
    guard baseCount > 1 else {
      return 1
    }

    let density = CGFloat(max(visibleCount - 1, 0)) / CGFloat(baseCount - 1)
    return max(0.4, density)
  }

  private static func scaledPreferredHeight(
    _ basePreferredHeight: CGFloat?,
    newValue: CGFloat,
    baseValue: CGFloat
  ) -> CGFloat? {
    guard let basePreferredHeight else {
      return nil
    }

    return max((basePreferredHeight / baseValue) * newValue, 6)
  }

  private static func appContent(
    from baseContent: WeeklySankeyNodeContent,
    value: CGFloat,
    totalValue: CGFloat
  ) -> WeeklySankeyNodeContent {
    let share = max(min(value / totalValue, 1), 0)
    let durationMinutes = Int(value.rounded())

    return WeeklySankeyNodeContent(
      id: baseContent.id,
      title: baseContent.title,
      durationText: formattedDuration(minutes: durationMinutes),
      shareText: "\(Int((share * 100).rounded()))%",
      barColorHex: baseContent.barColorHex,
      labelKind: baseContent.labelKind
    )
  }

  private static func formattedDuration(minutes: Int) -> String {
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if hours > 0, remainingMinutes > 0 {
      return "\(hours)hr \(remainingMinutes)min"
    }

    if hours > 0 {
      return "\(hours)hr"
    }

    return "\(remainingMinutes)min"
  }

  private static func sourceTargetKey(source: String, target: String) -> String {
    "\(source)->\(target)"
  }

  private static func orderedFilteredAppIDs(
    visibleAppIDs: Set<String>,
    orderedCategoryNodes: [SankeyNodeSpec],
    aggregatedValueBySourceTarget: [String: CGFloat],
    incomingValueByAppID: [String: CGFloat]
  ) -> [String] {
    let categoryRankByID = Dictionary(
      uniqueKeysWithValues: orderedCategoryNodes.enumerated().map { ($1.id, CGFloat($0)) }
    )

    func anchorY(for appID: String) -> CGFloat {
      var totalValue: CGFloat = 0
      var weightedRank: CGFloat = 0

      for categoryNode in orderedCategoryNodes {
        let value = aggregatedValueBySourceTarget[
          sourceTargetKey(source: categoryNode.id, target: appID),
          default: 0
        ]
        guard value > 0 else {
          continue
        }

        totalValue += value
        weightedRank += categoryRankByID[categoryNode.id, default: 0] * value
      }

      guard totalValue > 0 else {
        return .greatestFiniteMagnitude
      }

      return weightedRank / totalValue
    }

    return visibleAppIDs.sorted { lhs, rhs in
      let lhsAnchor = anchorY(for: lhs)
      let rhsAnchor = anchorY(for: rhs)

      if abs(lhsAnchor - rhsAnchor) > 0.001 {
        return lhsAnchor < rhsAnchor
      }

      let lhsValue = incomingValueByAppID[lhs, default: 0]
      let rhsValue = incomingValueByAppID[rhs, default: 0]
      if abs(lhsValue - rhsValue) > 0.001 {
        return lhsValue > rhsValue
      }

      return lhs < rhs
    }
  }

  private static func syntheticOtherAppNode() -> SankeyNodeSpec {
    SankeyNodeSpec(
      id: "other",
      columnID: "apps",
      order: 0,
      visualWeight: 0,
      preferredHeight: 18,
      gapBefore: 20
    )
  }

  private static func syntheticOtherAppContent() -> WeeklySankeyNodeContent {
    WeeklySankeyNodeContent(
      id: "other",
      title: "Other",
      durationText: "0min",
      shareText: "0%",
      barColorHex: "D9D9D9",
      labelKind: .app(.none)
    )
  }
}

#Preview("Weekly Sankey Distribution", traits: .fixedLayout(width: 1002, height: 640)) {
  WeeklySankeyPreviewCard(variant: .airierOptimized)
    .padding(18)
    .background(Color(hex: "F7F3F0"))
}

#Preview("Weekly Sankey Iterations", traits: .fixedLayout(width: 1002, height: 2080)) {
  WeeklySankeyPreviewGallery()
    .background(Color(hex: "F7F3F0"))
}

#Preview("Weekly Sankey Filtering") {
  WeeklySankeyFilterTuningPreview()
}

private struct WeeklySankeyFilterTuningPreview: View {
  @State private var variant: WeeklySankeyPreviewVariant = .airierOptimized
  @State private var minAppSharePercent: Double = 2
  @State private var capsVisibleApps = false
  @State private var maxVisibleApps = 6

  private var appFilterPolicy: WeeklySankeyAppFilterPolicy {
    WeeklySankeyAppFilterPolicy(
      minAppSharePercent: Int(minAppSharePercent.rounded()),
      maxVisibleApps: capsVisibleApps ? maxVisibleApps : nil
    )
  }

  private var diagnostics: WeeklySankeyPreviewDiagnostics {
    WeeklySankeyDistributionSection.previewDiagnostics(
      for: variant,
      appFilterPolicy: appFilterPolicy
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Text("Layout")
            .font(.custom("Nunito-Regular", size: 12))

          Picker("Layout", selection: $variant) {
            Text("Base").tag(WeeklySankeyPreviewVariant.balanced)
            Text("Airy").tag(WeeklySankeyPreviewVariant.airier)
            Text("Optimized").tag(WeeklySankeyPreviewVariant.airierOptimized)
          }
          .pickerStyle(.segmented)
          .frame(width: 320)
        }

        HStack(spacing: 12) {
          Text("Min App Share")
            .font(.custom("Nunito-Regular", size: 12))

          Slider(value: $minAppSharePercent, in: 1...10, step: 1)
            .frame(width: 220)

          Text("\(Int(minAppSharePercent.rounded()))%")
            .font(.custom("Nunito-Regular", size: 12))
            .monospacedDigit()
        }

        HStack(spacing: 12) {
          Toggle("Cap Right Rail", isOn: $capsVisibleApps)
            .toggleStyle(.checkbox)
            .font(.custom("Nunito-Regular", size: 12))

          Stepper(value: $maxVisibleApps, in: 3...10) {
            Text("Top \(maxVisibleApps)")
              .font(.custom("Nunito-Regular", size: 12))
              .monospacedDigit()
          }
          .disabled(!capsVisibleApps)
          .opacity(capsVisibleApps ? 1 : 0.55)
        }
      }

      Text(appFilterPolicy.summary)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))

      Text(diagnostics.summary)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))

      WeeklySankeyDistributionSection(
        variant: variant,
        appFilterPolicy: appFilterPolicy
      )
    }
    .padding(18)
    .background(Color(hex: "F7F3F0"))
  }
}

private struct WeeklySankeyPreviewGallery: View {
  private let rows = WeeklySankeyPreviewVariant.allCases.map { variant in
    WeeklySankeyPreviewComparisonRow(
      variant: variant,
      diagnostics: WeeklySankeyDistributionSection.previewDiagnostics(for: variant)
    )
  }

  var body: some View {
    let sortedRows = rows.sorted { lhs, rhs in
      if abs(lhs.diagnostics.programmaticScore - rhs.diagnostics.programmaticScore) > 0.5 {
        return lhs.diagnostics.programmaticScore < rhs.diagnostics.programmaticScore
      }
      return lhs.variant.id < rhs.variant.id
    }

    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Programmatic Sankey Iterations")
          .font(.custom("Nunito-Bold", size: 16))
          .foregroundStyle(Color(hex: "3B2418"))

        Text(
          "Lower score is better. The score heavily penalizes label overlaps and right-rail overflow, then uses crossings as the secondary tie-breaker."
        )
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))
      }
      .padding(.horizontal, 2)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(sortedRows.enumerated()), id: \.element.variant.id) { index, row in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(index == 0 ? "Best" : "\(index + 1)")
              .font(.custom("Nunito-Bold", size: 11))
              .foregroundStyle(index == 0 ? Color.white : Color(hex: "7C5A46"))
              .padding(.horizontal, index == 0 ? 10 : 8)
              .padding(.vertical, 4)
              .background(
                Capsule(style: .continuous)
                  .fill(index == 0 ? Color(hex: "B46531") : Color.white)
              )
              .overlay(
                Capsule(style: .continuous)
                  .stroke(Color(hex: "E3D6CF"), lineWidth: 1)
              )

            Text(row.variant.title)
              .font(.custom("Nunito-Bold", size: 13))
              .foregroundStyle(Color(hex: "3B2418"))

            Text(row.diagnostics.shortSummary)
              .font(.custom("Nunito-Regular", size: 12))
              .foregroundStyle(Color(hex: "6E584B"))
          }
        }
      }

      ForEach(WeeklySankeyPreviewVariant.allCases) { variant in
        WeeklySankeyPreviewCard(variant: variant)
      }
    }
    .padding(18)
  }
}

private enum WeeklySankeyPreviewVariant: String, CaseIterable, Identifiable {
  case balanced
  case airier
  case airierOptimized

  var id: String { rawValue }

  var title: String {
    switch self {
    case .balanced:
      return "Baseline"
    case .airier:
      return "Airier"
    case .airierOptimized:
      return "Airier + Optimized Order"
    }
  }

  var summary: String {
    switch self {
    case .balanced:
      return "Current art-directed geometry with the original fixed downstream order."
    case .airier:
      return "Stronger left-to-right taper, looser right rail, softer downstream curves."
    case .airierOptimized:
      return "Airier geometry plus barycenter sweeps and local swaps to reduce crossings."
    }
  }

  var fixture: WeeklySankeyFixture {
    switch self {
    case .balanced:
      return .balanced
    case .airier, .airierOptimized:
      return .airier
    }
  }

  var layoutOptions: SankeyLayoutOptions {
    switch self {
    case .balanced, .airier:
      return SankeyLayoutOptions(
        bandOrdering: .oppositeNodeCenter,
        nodeOrdering: .input,
        sweepPasses: 0,
        localSwapPasses: 0
      )
    case .airierOptimized:
      return .aesthetic
    }
  }
}

private struct WeeklySankeyPreviewDiagnostics {
  let programmaticScore: CGFloat
  let weightedCrossings: CGFloat
  let labelOverlapPairs: Int
  let tightestLabelGap: CGFloat
  let appBottomClearance: CGFloat

  var shortSummary: String {
    let scoreText = String(format: "%.0f", programmaticScore)
    let crossingText = String(format: "%.0f", weightedCrossings)
    let clearanceText = String(format: "%.1f", appBottomClearance)
    return
      "Score \(scoreText) | crossings \(crossingText) | overlaps \(labelOverlapPairs) | clearance \(clearanceText)pt"
  }

  var summary: String {
    let scoreText = String(format: "%.0f", programmaticScore)
    let crossingText = String(format: "%.0f", weightedCrossings)
    let gapText = String(format: "%.1f", tightestLabelGap)
    let clearanceText = String(format: "%.1f", appBottomClearance)
    return
      "Programmatic score: \(scoreText) | Weighted crossings: \(crossingText) | Label overlaps: \(labelOverlapPairs) | Tightest label gap: \(gapText)pt | App bottom clearance: \(clearanceText)pt"
  }
}

private struct WeeklySankeyPreviewComparisonRow {
  let variant: WeeklySankeyPreviewVariant
  let diagnostics: WeeklySankeyPreviewDiagnostics
}

private struct WeeklySankeyPreviewCard: View {
  let variant: WeeklySankeyPreviewVariant

  private var diagnostics: WeeklySankeyPreviewDiagnostics {
    WeeklySankeyDistributionSection.previewDiagnostics(for: variant)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 10) {
        Text(variant.title)
          .font(.custom("Nunito-Bold", size: 12))
          .foregroundStyle(Color.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            Capsule(style: .continuous)
              .fill(Color(hex: "B46531"))
          )

        Text(variant.summary)
          .font(.custom("Nunito-Bold", size: 13))
          .foregroundStyle(Color(hex: "3B2418"))
      }

      Text(diagnostics.summary)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))

      WeeklySankeyDistributionSection(variant: variant)
    }
  }
}

extension WeeklySankeyDistributionSection {
  fileprivate static func previewDiagnostics(
    for variant: WeeklySankeyPreviewVariant,
    appFilterPolicy: WeeklySankeyAppFilterPolicy = .default
  ) -> WeeklySankeyPreviewDiagnostics {
    let section = WeeklySankeyDistributionSection(
      variant: variant,
      appFilterPolicy: appFilterPolicy
    )
    let layout = section.layout
    let placements = section.labelPlacements(for: layout)
    let labelOverlapPairs = labelOverlapPairs(
      layout: layout,
      fixture: section.fixture,
      placements: placements
    )
    let tightestLabelGap = tightestLabelGap(
      layout: layout,
      fixture: section.fixture,
      placements: placements
    )
    let appBottomClearance = appBottomClearance(
      layout: layout,
      fixture: section.fixture,
      placements: placements
    )
    let weightedCrossings = weightedCrossingScore(layout: layout, fixture: section.fixture)

    return WeeklySankeyPreviewDiagnostics(
      programmaticScore: programmaticScore(
        weightedCrossings: weightedCrossings,
        labelOverlapPairs: labelOverlapPairs,
        tightestLabelGap: tightestLabelGap,
        appBottomClearance: appBottomClearance
      ),
      weightedCrossings: weightedCrossings,
      labelOverlapPairs: labelOverlapPairs,
      tightestLabelGap: tightestLabelGap,
      appBottomClearance: appBottomClearance
    )
  }

  fileprivate static func programmaticScore(
    weightedCrossings: CGFloat,
    labelOverlapPairs: Int,
    tightestLabelGap: CGFloat,
    appBottomClearance: CGFloat
  ) -> CGFloat {
    let overlapPenalty = CGFloat(labelOverlapPairs) * 10_000
    let overflowPenalty = max(-appBottomClearance, 0) * 90
    let gapPenalty = max(12 - tightestLabelGap, 0) * 35
    return overlapPenalty + overflowPenalty + gapPenalty + weightedCrossings
  }

  fileprivate static func weightedCrossingScore(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture
  ) -> CGFloat {
    let columnIndexByID = Dictionary(
      uniqueKeysWithValues: fixture.columns.enumerated().map { ($1.id, $0) })
    let ranksByNodeID = Dictionary(
      uniqueKeysWithValues: Dictionary(grouping: layout.nodes, by: \.columnID).flatMap { _, nodes in
        nodes
          .sorted { lhs, rhs in
            if abs(lhs.frame.midY - rhs.frame.midY) > 0.5 {
              return lhs.frame.midY < rhs.frame.midY
            }
            return lhs.id < rhs.id
          }
          .enumerated()
          .map { ($1.id, $0) }
      }
    )

    var score: CGFloat = 0

    for sourceColumnIndex in 0..<(fixture.columns.count - 1) {
      let targetColumnIndex = sourceColumnIndex + 1
      let relevantLinks = fixture.links.filter { link in
        guard
          let sourceLayout = layout.nodeLayoutsByID[link.sourceNodeID],
          let targetLayout = layout.nodeLayoutsByID[link.targetNodeID]
        else {
          return false
        }

        return columnIndexByID[sourceLayout.columnID] == sourceColumnIndex
          && columnIndexByID[targetLayout.columnID] == targetColumnIndex
      }

      guard relevantLinks.count > 1 else {
        continue
      }

      for lhsIndex in 0..<(relevantLinks.count - 1) {
        let lhsLink = relevantLinks[lhsIndex]
        let lhsSourceRank = ranksByNodeID[lhsLink.sourceNodeID] ?? 0
        let lhsTargetRank = ranksByNodeID[lhsLink.targetNodeID] ?? 0

        for rhsIndex in (lhsIndex + 1)..<relevantLinks.count {
          let rhsLink = relevantLinks[rhsIndex]
          let rhsSourceRank = ranksByNodeID[rhsLink.sourceNodeID] ?? 0
          let rhsTargetRank = ranksByNodeID[rhsLink.targetNodeID] ?? 0

          let sourceDelta = lhsSourceRank - rhsSourceRank
          let targetDelta = lhsTargetRank - rhsTargetRank

          if sourceDelta == 0 || targetDelta == 0 {
            continue
          }

          if (sourceDelta < 0 && targetDelta > 0) || (sourceDelta > 0 && targetDelta < 0) {
            score += max(lhsLink.value, 0) * max(rhsLink.value, 0)
          }
        }
      }
    }

    return score
  }

  fileprivate static func labelOverlapPairs(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture,
    placements: [String: WeeklySankeyLabelPlacement]
  ) -> Int {
    let framesByColumn = labelFramesByColumn(
      layout: layout, fixture: fixture, placements: placements)
    var overlapPairs = 0

    for columnFrames in framesByColumn.values {
      guard columnFrames.count > 1 else {
        continue
      }

      for lhsIndex in 0..<(columnFrames.count - 1) {
        for rhsIndex in (lhsIndex + 1)..<columnFrames.count {
          if columnFrames[lhsIndex].intersects(columnFrames[rhsIndex]) {
            overlapPairs += 1
          }
        }
      }
    }

    return overlapPairs
  }

  fileprivate static func tightestLabelGap(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture,
    placements: [String: WeeklySankeyLabelPlacement]
  ) -> CGFloat {
    let framesByColumn = labelFramesByColumn(
      layout: layout, fixture: fixture, placements: placements)
    var minimumGap = CGFloat.greatestFiniteMagnitude

    for columnFrames in framesByColumn.values {
      let sortedFrames = columnFrames.sorted { lhs, rhs in
        if abs(lhs.minY - rhs.minY) > 0.5 {
          return lhs.minY < rhs.minY
        }
        return lhs.minX < rhs.minX
      }

      for index in 0..<(sortedFrames.count - 1) {
        minimumGap = min(minimumGap, sortedFrames[index + 1].minY - sortedFrames[index].maxY)
      }
    }

    if minimumGap == .greatestFiniteMagnitude {
      return 0
    }

    return minimumGap
  }

  fileprivate static func appBottomClearance(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture,
    placements: [String: WeeklySankeyLabelPlacement]
  ) -> CGFloat {
    let appFrames =
      labelFramesByColumn(layout: layout, fixture: fixture, placements: placements)["apps"] ?? []
    guard let maxY = appFrames.map(\.maxY).max() else {
      return 0
    }

    return (Design.sectionSize.height - Design.appLabelBottomPadding) - maxY
  }

  fileprivate static func labelFramesByColumn(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture,
    placements: [String: WeeklySankeyLabelPlacement]
  ) -> [String: [CGRect]] {
    fixture.contents.reduce(into: [String: [CGRect]]()) { partialResult, content in
      guard
        let node = layout.nodeLayoutsByID[content.id],
        let placement = placements[content.id]
      else {
        return
      }

      partialResult[node.columnID, default: []].append(
        CGRect(origin: placement.origin, size: content.labelSize)
      )
    }
  }
}

extension SankeyColumnSpec {
  fileprivate func updating(
    x: CGFloat? = nil,
    topY: CGFloat? = nil,
    barWidth: CGFloat? = nil,
    pointsPerUnit: CGFloat? = nil
  ) -> SankeyColumnSpec {
    return SankeyColumnSpec(
      id: id,
      x: x ?? self.x,
      topY: topY ?? self.topY,
      barWidth: barWidth ?? self.barWidth,
      pointsPerUnit: pointsPerUnit ?? self.pointsPerUnit
    )
  }
}

extension SankeyNodeSpec {
  fileprivate func updating(
    preferredHeight: CGFloat? = nil,
    gapBefore: CGFloat? = nil
  ) -> SankeyNodeSpec {
    let resolvedPreferredHeight: CGFloat?
    if let preferredHeight {
      resolvedPreferredHeight = preferredHeight
    } else {
      resolvedPreferredHeight = self.preferredHeight
    }

    return SankeyNodeSpec(
      id: id,
      columnID: columnID,
      order: order,
      visualWeight: visualWeight,
      preferredHeight: resolvedPreferredHeight,
      gapBefore: gapBefore ?? self.gapBefore
    )
  }
}

extension SankeyLinkSpec {
  fileprivate func updatingStyle(_ transform: (SankeyRibbonStyle) -> SankeyRibbonStyle)
    -> SankeyLinkSpec
  {
    return SankeyLinkSpec(
      id: id,
      sourceNodeID: sourceNodeID,
      targetNodeID: targetNodeID,
      value: value,
      sourceOrder: sourceOrder,
      targetOrder: targetOrder,
      sourceBandOverride: sourceBandOverride,
      targetBandOverride: targetBandOverride,
      style: transform(style)
    )
  }
}

extension SankeyRibbonStyle {
  fileprivate func updating(
    leadingColor: Color? = nil,
    trailingColor: Color? = nil,
    opacity: Double? = nil,
    zIndex: Double? = nil,
    leadingControlFactor: CGFloat? = nil,
    trailingControlFactor: CGFloat? = nil,
    topStartBend: CGFloat? = nil,
    topEndBend: CGFloat? = nil,
    bottomStartBend: CGFloat? = nil,
    bottomEndBend: CGFloat? = nil
  ) -> SankeyRibbonStyle {
    return SankeyRibbonStyle(
      leadingColor: leadingColor ?? self.leadingColor,
      trailingColor: trailingColor ?? self.trailingColor,
      opacity: opacity ?? self.opacity,
      zIndex: zIndex ?? self.zIndex,
      leadingControlFactor: leadingControlFactor ?? self.leadingControlFactor,
      trailingControlFactor: trailingControlFactor ?? self.trailingControlFactor,
      topStartBend: topStartBend ?? self.topStartBend,
      topEndBend: topEndBend ?? self.topEndBend,
      bottomStartBend: bottomStartBend ?? self.bottomStartBend,
      bottomEndBend: bottomEndBend ?? self.bottomEndBend
    )
  }
}
