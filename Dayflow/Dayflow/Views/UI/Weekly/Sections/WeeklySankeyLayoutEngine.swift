import SwiftUI

enum SankeyBandOrdering {
  case explicit
  case oppositeNodeCenter
}

enum SankeyNodeOrdering {
  case input
  case weightedBarycenter
}

struct SankeyLayoutOptions {
  let bandOrdering: SankeyBandOrdering
  let nodeOrdering: SankeyNodeOrdering
  let sweepPasses: Int
  let localSwapPasses: Int

  static let aesthetic = SankeyLayoutOptions(
    bandOrdering: .oppositeNodeCenter,
    nodeOrdering: .weightedBarycenter,
    sweepPasses: 6,
    localSwapPasses: 4
  )
}

struct SankeyColumnSpec: Identifiable {
  let id: String
  let x: CGFloat
  let topY: CGFloat
  let barWidth: CGFloat
  let pointsPerUnit: CGFloat

  init(
    id: String,
    x: CGFloat,
    topY: CGFloat,
    barWidth: CGFloat = 6,
    pointsPerUnit: CGFloat = 1
  ) {
    self.id = id
    self.x = x
    self.topY = topY
    self.barWidth = barWidth
    self.pointsPerUnit = pointsPerUnit
  }
}

struct SankeyNodeSpec: Identifiable {
  let id: String
  let columnID: String
  let order: Int
  let visualWeight: CGFloat
  let preferredHeight: CGFloat?
  let gapBefore: CGFloat

  init(
    id: String,
    columnID: String,
    order: Int,
    visualWeight: CGFloat = 1,
    preferredHeight: CGFloat? = nil,
    gapBefore: CGFloat = 0
  ) {
    self.id = id
    self.columnID = columnID
    self.order = order
    self.visualWeight = visualWeight
    self.preferredHeight = preferredHeight
    self.gapBefore = gapBefore
  }
}

struct SankeyLinkSpec: Identifiable {
  let id: String
  let sourceNodeID: String
  let targetNodeID: String
  let value: CGFloat
  let sourceOrder: Int
  let targetOrder: Int
  let sourceBandOverride: ClosedRange<CGFloat>?
  let targetBandOverride: ClosedRange<CGFloat>?
  let style: SankeyRibbonStyle

  init(
    id: String,
    sourceNodeID: String,
    targetNodeID: String,
    value: CGFloat,
    sourceOrder: Int,
    targetOrder: Int,
    sourceBandOverride: ClosedRange<CGFloat>? = nil,
    targetBandOverride: ClosedRange<CGFloat>? = nil,
    style: SankeyRibbonStyle
  ) {
    self.id = id
    self.sourceNodeID = sourceNodeID
    self.targetNodeID = targetNodeID
    self.value = value
    self.sourceOrder = sourceOrder
    self.targetOrder = targetOrder
    self.sourceBandOverride = sourceBandOverride
    self.targetBandOverride = targetBandOverride
    self.style = style
  }
}

struct SankeyRibbonStyle {
  let leadingColor: Color
  let trailingColor: Color
  let opacity: Double
  let zIndex: Double
  let leadingControlFactor: CGFloat
  let trailingControlFactor: CGFloat
  let topStartBend: CGFloat
  let topEndBend: CGFloat
  let bottomStartBend: CGFloat
  let bottomEndBend: CGFloat

  init(
    color: Color,
    opacity: Double,
    zIndex: Double = 0,
    leadingControlFactor: CGFloat = 0.34,
    trailingControlFactor: CGFloat = 0.34,
    topStartBend: CGFloat = 0,
    topEndBend: CGFloat = 0,
    bottomStartBend: CGFloat = 0,
    bottomEndBend: CGFloat = 0
  ) {
    self.leadingColor = color
    self.trailingColor = color
    self.opacity = opacity
    self.zIndex = zIndex
    self.leadingControlFactor = leadingControlFactor
    self.trailingControlFactor = trailingControlFactor
    self.topStartBend = topStartBend
    self.topEndBend = topEndBend
    self.bottomStartBend = bottomStartBend
    self.bottomEndBend = bottomEndBend
  }

  init(
    leadingColor: Color,
    trailingColor: Color,
    opacity: Double,
    zIndex: Double = 0,
    leadingControlFactor: CGFloat = 0.34,
    trailingControlFactor: CGFloat = 0.34,
    topStartBend: CGFloat = 0,
    topEndBend: CGFloat = 0,
    bottomStartBend: CGFloat = 0,
    bottomEndBend: CGFloat = 0
  ) {
    self.leadingColor = leadingColor
    self.trailingColor = trailingColor
    self.opacity = opacity
    self.zIndex = zIndex
    self.leadingControlFactor = leadingControlFactor
    self.trailingControlFactor = trailingControlFactor
    self.topStartBend = topStartBend
    self.topEndBend = topEndBend
    self.bottomStartBend = bottomStartBend
    self.bottomEndBend = bottomEndBend
  }
}

struct SankeyNodeLayout: Identifiable {
  let id: String
  let columnID: String
  let frame: CGRect
}

struct SankeyRibbonLayout: Identifiable {
  let id: String
  let path: Path
  let leadingColor: Color
  let trailingColor: Color
  let gradientStartPoint: CGPoint
  let gradientEndPoint: CGPoint
  let opacity: Double
  let zIndex: Double
}

struct SankeyLayoutResult {
  let nodes: [SankeyNodeLayout]
  let ribbons: [SankeyRibbonLayout]

  var nodeLayoutsByID: [String: SankeyNodeLayout] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  }
}

enum SankeyLayoutEngine {
  static func layout(
    columns: [SankeyColumnSpec],
    nodes: [SankeyNodeSpec],
    links: [SankeyLinkSpec],
    options: SankeyLayoutOptions = .aesthetic
  ) -> SankeyLayoutResult {
    let columnsByID = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
    let orderedNodes = orderedNodes(columns: columns, nodes: nodes, links: links, options: options)
    let nodeLayouts = buildNodeLayouts(
      columns: columns, columnsByID: columnsByID, nodes: orderedNodes)
    let nodeLayoutsByID = Dictionary(uniqueKeysWithValues: nodeLayouts.map { ($0.id, $0) })

    let outgoingBands = buildAutoBands(
      links: links,
      nodeLayoutsByID: nodeLayoutsByID,
      keyPath: \.sourceNodeID,
      oppositeNodeKeyPath: \.targetNodeID,
      orderPath: \.sourceOrder,
      options: options
    )
    let incomingBands = buildAutoBands(
      links: links,
      nodeLayoutsByID: nodeLayoutsByID,
      keyPath: \.targetNodeID,
      oppositeNodeKeyPath: \.sourceNodeID,
      orderPath: \.targetOrder,
      options: options
    )

    let ribbons = links.compactMap { link -> SankeyRibbonLayout? in
      guard let sourceNode = nodeLayoutsByID[link.sourceNodeID],
        let targetNode = nodeLayoutsByID[link.targetNodeID]
      else {
        return nil
      }

      let sourceBand = bandRange(
        override: link.sourceBandOverride,
        fallback: outgoingBands[link.id],
        in: sourceNode.frame
      )
      let targetBand = bandRange(
        override: link.targetBandOverride,
        fallback: incomingBands[link.id],
        in: targetNode.frame
      )

      return SankeyRibbonLayout(
        id: link.id,
        path: ribbonPath(
          from: sourceNode.frame,
          sourceBand: sourceBand,
          to: targetNode.frame,
          targetBand: targetBand,
          style: link.style
        ),
        leadingColor: link.style.leadingColor,
        trailingColor: link.style.trailingColor,
        gradientStartPoint: CGPoint(
          x: sourceNode.frame.maxX,
          y: (sourceBand.lowerBound + sourceBand.upperBound) / 2
        ),
        gradientEndPoint: CGPoint(
          x: targetNode.frame.minX,
          y: (targetBand.lowerBound + targetBand.upperBound) / 2
        ),
        opacity: link.style.opacity,
        zIndex: link.style.zIndex
      )
    }

    return SankeyLayoutResult(nodes: nodeLayouts, ribbons: ribbons)
  }

  private static func orderedNodes(
    columns: [SankeyColumnSpec],
    nodes: [SankeyNodeSpec],
    links: [SankeyLinkSpec],
    options: SankeyLayoutOptions
  ) -> [SankeyNodeSpec] {
    guard options.nodeOrdering == .weightedBarycenter, columns.count > 1 else {
      return nodes
    }

    let columnIndexByID = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1.id, $0) })
    let nodeColumnIndexByID = Dictionary(
      uniqueKeysWithValues: nodes.compactMap { node -> (String, Int)? in
        guard let columnIndex = columnIndexByID[node.columnID] else { return nil }
        return (node.id, columnIndex)
      }
    )

    var orderedNodeIDsByColumn = columns.map { column in
      nodes
        .filter { $0.columnID == column.id }
        .sorted(by: { $0.order < $1.order })
        .map(\.id)
    }

    guard orderedNodeIDsByColumn.count > 1 else {
      return nodes
    }

    for _ in 0..<max(options.sweepPasses, 0) {
      for columnIndex in 1..<orderedNodeIDsByColumn.count {
        orderedNodeIDsByColumn[columnIndex] = barycenterSortedNodeIDs(
          for: columnIndex,
          usingAdjacentColumn: columnIndex - 1,
          orderedNodeIDsByColumn: orderedNodeIDsByColumn,
          links: links,
          nodeColumnIndexByID: nodeColumnIndexByID,
          relation: .incoming
        )
      }

      if orderedNodeIDsByColumn.count > 2 {
        for columnIndex in stride(from: orderedNodeIDsByColumn.count - 2, through: 0, by: -1) {
          orderedNodeIDsByColumn[columnIndex] = barycenterSortedNodeIDs(
            for: columnIndex,
            usingAdjacentColumn: columnIndex + 1,
            orderedNodeIDsByColumn: orderedNodeIDsByColumn,
            links: links,
            nodeColumnIndexByID: nodeColumnIndexByID,
            relation: .outgoing
          )
        }
      }

      for _ in 0..<max(options.localSwapPasses, 0) {
        var didImprove = false

        for columnIndex in 1..<orderedNodeIDsByColumn.count {
          let improved = refineColumnByAdjacentSwaps(
            columnIndex: columnIndex,
            orderedNodeIDsByColumn: &orderedNodeIDsByColumn,
            links: links,
            nodeColumnIndexByID: nodeColumnIndexByID
          )
          didImprove = didImprove || improved
        }

        if !didImprove {
          break
        }
      }
    }

    let updatedOrderByNodeID = Dictionary(
      uniqueKeysWithValues: orderedNodeIDsByColumn.flatMap { nodeIDs in
        nodeIDs.enumerated().map { ($1, $0) }
      }
    )

    return nodes.map { node in
      guard let order = updatedOrderByNodeID[node.id] else {
        return node
      }

      return SankeyNodeSpec(
        id: node.id,
        columnID: node.columnID,
        order: order,
        visualWeight: node.visualWeight,
        preferredHeight: node.preferredHeight,
        gapBefore: node.gapBefore
      )
    }
  }

  private static func buildNodeLayouts(
    columns: [SankeyColumnSpec],
    columnsByID: [String: SankeyColumnSpec],
    nodes: [SankeyNodeSpec]
  ) -> [SankeyNodeLayout] {
    var layouts: [SankeyNodeLayout] = []
    let groupedNodes = Dictionary(grouping: nodes, by: \.columnID)

    for columnSpec in columns {
      guard let columnNodes = groupedNodes[columnSpec.id],
        let column = columnsByID[columnSpec.id]
      else { continue }

      var cursorY = column.topY

      for node in columnNodes.sorted(by: { $0.order < $1.order }) {
        cursorY += node.gapBefore
        let height = node.preferredHeight ?? (node.visualWeight * column.pointsPerUnit)
        let frame = CGRect(
          x: column.x,
          y: cursorY,
          width: column.barWidth,
          height: max(height, 1)
        )
        layouts.append(
          SankeyNodeLayout(
            id: node.id,
            columnID: column.id,
            frame: frame
          )
        )
        cursorY += frame.height
      }
    }

    return layouts
  }

  private static func barycenterSortedNodeIDs(
    for columnIndex: Int,
    usingAdjacentColumn adjacentColumnIndex: Int,
    orderedNodeIDsByColumn: [[String]],
    links: [SankeyLinkSpec],
    nodeColumnIndexByID: [String: Int],
    relation: SankeyAdjacentRelation
  ) -> [String] {
    let currentNodeIDs = orderedNodeIDsByColumn[columnIndex]
    guard !currentNodeIDs.isEmpty else {
      return currentNodeIDs
    }

    let adjacentRanks = Dictionary(
      uniqueKeysWithValues: orderedNodeIDsByColumn[adjacentColumnIndex].enumerated().map {
        ($1, $0)
      }
    )
    let currentRanks = Dictionary(
      uniqueKeysWithValues: currentNodeIDs.enumerated().map { ($1, $0) })

    let barycentersByNodeID = Dictionary(
      uniqueKeysWithValues: currentNodeIDs.map { nodeID in
        let nodeLinks = links.filter { link in
          switch relation {
          case .incoming:
            guard link.targetNodeID == nodeID else { return false }
            return nodeColumnIndexByID[link.sourceNodeID] == adjacentColumnIndex
          case .outgoing:
            guard link.sourceNodeID == nodeID else { return false }
            return nodeColumnIndexByID[link.targetNodeID] == adjacentColumnIndex
          }
        }

        let totalWeight = nodeLinks.reduce(CGFloat(0)) { partial, link in
          partial + max(link.value, 0)
        }

        guard totalWeight > 0 else {
          return (nodeID, CGFloat(currentRanks[nodeID] ?? 0))
        }

        let barycenter =
          nodeLinks.reduce(CGFloat(0)) { partial, link in
            let adjacentNodeID: String
            switch relation {
            case .incoming:
              adjacentNodeID = link.sourceNodeID
            case .outgoing:
              adjacentNodeID = link.targetNodeID
            }

            let adjacentRank = CGFloat(adjacentRanks[adjacentNodeID] ?? 0)
            return partial + (adjacentRank * max(link.value, 0))
          } / totalWeight

        return (nodeID, barycenter)
      }
    )

    return currentNodeIDs.sorted { lhs, rhs in
      let lhsBarycenter = barycentersByNodeID[lhs] ?? CGFloat(currentRanks[lhs] ?? 0)
      let rhsBarycenter = barycentersByNodeID[rhs] ?? CGFloat(currentRanks[rhs] ?? 0)

      if abs(lhsBarycenter - rhsBarycenter) > 0.001 {
        return lhsBarycenter < rhsBarycenter
      }

      let lhsRank = currentRanks[lhs] ?? 0
      let rhsRank = currentRanks[rhs] ?? 0
      if lhsRank != rhsRank {
        return lhsRank < rhsRank
      }

      return lhs < rhs
    }
  }

  private static func refineColumnByAdjacentSwaps(
    columnIndex: Int,
    orderedNodeIDsByColumn: inout [[String]],
    links: [SankeyLinkSpec],
    nodeColumnIndexByID: [String: Int]
  ) -> Bool {
    guard orderedNodeIDsByColumn.indices.contains(columnIndex),
      orderedNodeIDsByColumn[columnIndex].count > 1
    else {
      return false
    }

    var didImprove = false
    var didSwapInPass = true

    while didSwapInPass {
      didSwapInPass = false
      var nodeIDs = orderedNodeIDsByColumn[columnIndex]
      var index = 0

      while index < nodeIDs.count - 1 {
        let currentScore = localCrossingScore(
          around: columnIndex,
          orderedNodeIDsByColumn: orderedNodeIDsByColumn,
          links: links,
          nodeColumnIndexByID: nodeColumnIndexByID
        )

        var swappedLayout = orderedNodeIDsByColumn
        swappedLayout[columnIndex].swapAt(index, index + 1)

        let swappedScore = localCrossingScore(
          around: columnIndex,
          orderedNodeIDsByColumn: swappedLayout,
          links: links,
          nodeColumnIndexByID: nodeColumnIndexByID
        )

        if swappedScore + 0.001 < currentScore {
          orderedNodeIDsByColumn = swappedLayout
          nodeIDs = swappedLayout[columnIndex]
          didImprove = true
          didSwapInPass = true
        } else {
          index += 1
        }
      }
    }

    return didImprove
  }

  private static func localCrossingScore(
    around columnIndex: Int,
    orderedNodeIDsByColumn: [[String]],
    links: [SankeyLinkSpec],
    nodeColumnIndexByID: [String: Int]
  ) -> CGFloat {
    var total: CGFloat = 0

    if columnIndex > 0 {
      total += weightedCrossingScore(
        between: columnIndex - 1,
        and: columnIndex,
        orderedNodeIDsByColumn: orderedNodeIDsByColumn,
        links: links,
        nodeColumnIndexByID: nodeColumnIndexByID
      )
    }

    if columnIndex < orderedNodeIDsByColumn.count - 1 {
      total += weightedCrossingScore(
        between: columnIndex,
        and: columnIndex + 1,
        orderedNodeIDsByColumn: orderedNodeIDsByColumn,
        links: links,
        nodeColumnIndexByID: nodeColumnIndexByID
      )
    }

    return total
  }

  private static func weightedCrossingScore(
    between sourceColumnIndex: Int,
    and targetColumnIndex: Int,
    orderedNodeIDsByColumn: [[String]],
    links: [SankeyLinkSpec],
    nodeColumnIndexByID: [String: Int]
  ) -> CGFloat {
    let rankByNodeID = Dictionary(
      uniqueKeysWithValues: orderedNodeIDsByColumn.flatMap { nodeIDs in
        nodeIDs.enumerated().map { ($1, $0) }
      }
    )

    let relevantLinks = links.filter { link in
      nodeColumnIndexByID[link.sourceNodeID] == sourceColumnIndex
        && nodeColumnIndexByID[link.targetNodeID] == targetColumnIndex
    }

    guard relevantLinks.count > 1 else {
      return 0
    }

    var score: CGFloat = 0

    for lhsIndex in 0..<(relevantLinks.count - 1) {
      let lhsLink = relevantLinks[lhsIndex]
      let lhsSourceRank = rankByNodeID[lhsLink.sourceNodeID] ?? 0
      let lhsTargetRank = rankByNodeID[lhsLink.targetNodeID] ?? 0

      for rhsIndex in (lhsIndex + 1)..<relevantLinks.count {
        let rhsLink = relevantLinks[rhsIndex]
        let rhsSourceRank = rankByNodeID[rhsLink.sourceNodeID] ?? 0
        let rhsTargetRank = rankByNodeID[rhsLink.targetNodeID] ?? 0

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

    return score
  }

  private static func buildAutoBands(
    links: [SankeyLinkSpec],
    nodeLayoutsByID: [String: SankeyNodeLayout],
    keyPath: KeyPath<SankeyLinkSpec, String>,
    oppositeNodeKeyPath: KeyPath<SankeyLinkSpec, String>,
    orderPath: KeyPath<SankeyLinkSpec, Int>,
    options: SankeyLayoutOptions
  ) -> [String: ClosedRange<CGFloat>] {
    let groupedLinks = Dictionary(grouping: links, by: { $0[keyPath: keyPath] })
    var rangesByLinkID: [String: ClosedRange<CGFloat>] = [:]

    for (nodeID, nodeLinks) in groupedLinks {
      guard nodeLayoutsByID[nodeID] != nil else { continue }
      let sortedLinks = nodeLinks.sorted {
        compareLinks(
          lhs: $0,
          rhs: $1,
          nodeLayoutsByID: nodeLayoutsByID,
          oppositeNodeKeyPath: oppositeNodeKeyPath,
          orderPath: orderPath,
          bandOrdering: options.bandOrdering
        )
      }

      let totalValue = sortedLinks.reduce(CGFloat(0)) { partial, link in
        partial + max(link.value, 0)
      }
      guard totalValue > 0 else { continue }

      var cursor: CGFloat = 0
      for link in sortedLinks {
        let start = cursor / totalValue
        cursor += max(link.value, 0)
        let end = cursor / totalValue
        rangesByLinkID[link.id] = start...end
      }
    }

    return rangesByLinkID
  }

  private static func bandRange(
    override: ClosedRange<CGFloat>?,
    fallback: ClosedRange<CGFloat>?,
    in frame: CGRect
  ) -> ClosedRange<CGFloat> {
    let band = override ?? fallback ?? (0...1)
    let lower = max(0, min(1, band.lowerBound))
    let upper = max(lower, min(1, band.upperBound))

    let top = frame.minY + (frame.height * lower)
    let bottom = frame.minY + (frame.height * upper)
    return top...bottom
  }

  private static func ribbonPath(
    from sourceFrame: CGRect,
    sourceBand: ClosedRange<CGFloat>,
    to targetFrame: CGRect,
    targetBand: ClosedRange<CGFloat>,
    style: SankeyRibbonStyle
  ) -> Path {
    let startX = sourceFrame.maxX
    let endX = targetFrame.minX
    let distanceX = max(endX - startX, 1)
    let sampleCount = max(18, Int(distanceX / 22))

    let topPoints = (0...sampleCount).map { index in
      sampledEdgePoint(
        index: index,
        sampleCount: sampleCount,
        startX: startX,
        endX: endX,
        startY: sourceBand.lowerBound,
        endY: targetBand.lowerBound,
        startBend: style.topStartBend,
        endBend: style.topEndBend
      )
    }

    let bottomPoints = (0...sampleCount).map { index in
      sampledEdgePoint(
        index: index,
        sampleCount: sampleCount,
        startX: startX,
        endX: endX,
        startY: sourceBand.upperBound,
        endY: targetBand.upperBound,
        startBend: style.bottomStartBend,
        endBend: style.bottomEndBend
      )
    }

    var path = Path()
    if let firstTop = topPoints.first {
      path.move(to: firstTop)
      for point in topPoints.dropFirst() {
        path.addLine(to: point)
      }

      for point in bottomPoints.reversed() {
        path.addLine(to: point)
      }

      path.closeSubpath()
    }

    return path
  }

  private static func compareLinks(
    lhs: SankeyLinkSpec,
    rhs: SankeyLinkSpec,
    nodeLayoutsByID: [String: SankeyNodeLayout],
    oppositeNodeKeyPath: KeyPath<SankeyLinkSpec, String>,
    orderPath: KeyPath<SankeyLinkSpec, Int>,
    bandOrdering: SankeyBandOrdering
  ) -> Bool {
    switch bandOrdering {
    case .explicit:
      return explicitLinkOrder(lhs: lhs, rhs: rhs, orderPath: orderPath)
    case .oppositeNodeCenter:
      let lhsCenter = nodeLayoutsByID[lhs[keyPath: oppositeNodeKeyPath]]?.frame.midY ?? 0
      let rhsCenter = nodeLayoutsByID[rhs[keyPath: oppositeNodeKeyPath]]?.frame.midY ?? 0

      if abs(lhsCenter - rhsCenter) > 0.5 {
        return lhsCenter < rhsCenter
      }

      if lhs.value != rhs.value {
        return lhs.value > rhs.value
      }

      return explicitLinkOrder(lhs: lhs, rhs: rhs, orderPath: orderPath)
    }
  }

  private static func explicitLinkOrder(
    lhs: SankeyLinkSpec,
    rhs: SankeyLinkSpec,
    orderPath: KeyPath<SankeyLinkSpec, Int>
  ) -> Bool {
    if lhs[keyPath: orderPath] == rhs[keyPath: orderPath] {
      return lhs.id < rhs.id
    }
    return lhs[keyPath: orderPath] < rhs[keyPath: orderPath]
  }

  private static func sampledEdgePoint(
    index: Int,
    sampleCount: Int,
    startX: CGFloat,
    endX: CGFloat,
    startY: CGFloat,
    endY: CGFloat,
    startBend: CGFloat,
    endBend: CGFloat
  ) -> CGPoint {
    let t = CGFloat(index) / CGFloat(max(sampleCount, 1))
    let easedT = smootherStep(t)
    let x = startX + ((endX - startX) * t)
    let startInfluence = (1 - t) * bellCurve(t)
    let endInfluence = t * bellCurve(t)
    let y =
      startY
      + ((endY - startY) * easedT)
      + (startBend * startInfluence)
      + (endBend * endInfluence)

    return CGPoint(x: x, y: y)
  }

  private static func bellCurve(_ t: CGFloat) -> CGFloat {
    4 * t * (1 - t)
  }

  private static func smootherStep(_ t: CGFloat) -> CGFloat {
    let clamped = min(max(t, 0), 1)
    return clamped * clamped * clamped * (clamped * ((clamped * 6) - 15) + 10)
  }
}

private enum SankeyAdjacentRelation {
  case incoming
  case outgoing
}
