import SwiftUI

enum SankeyBandOrdering {
  case explicit
  case oppositeNodeCenter
}

struct SankeyLayoutOptions {
  let bandOrdering: SankeyBandOrdering

  static let aesthetic = SankeyLayoutOptions(bandOrdering: .oppositeNodeCenter)
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
  let color: Color
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
    self.color = color
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
  let color: Color
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
    let nodeLayouts = buildNodeLayouts(columnsByID: columnsByID, nodes: nodes)
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
        color: link.style.color,
        opacity: link.style.opacity,
        zIndex: link.style.zIndex
      )
    }

    return SankeyLayoutResult(nodes: nodeLayouts, ribbons: ribbons)
  }

  private static func buildNodeLayouts(
    columnsByID: [String: SankeyColumnSpec],
    nodes: [SankeyNodeSpec]
  ) -> [SankeyNodeLayout] {
    var layouts: [SankeyNodeLayout] = []
    let groupedNodes = Dictionary(grouping: nodes, by: \.columnID)

    for (columnID, columnNodes) in groupedNodes {
      guard let column = columnsByID[columnID] else { continue }

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
            columnID: columnID,
            frame: frame
          )
        )
        cursorY += frame.height
      }
    }

    return layouts
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
