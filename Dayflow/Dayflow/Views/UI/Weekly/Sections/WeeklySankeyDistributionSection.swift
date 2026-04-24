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

  var showsEmptyState: Bool {
    guard liveInput != nil else {
      return false
    }

    return fixture.nodes.isEmpty || fixture.links.isEmpty || fixture.contents.isEmpty
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
