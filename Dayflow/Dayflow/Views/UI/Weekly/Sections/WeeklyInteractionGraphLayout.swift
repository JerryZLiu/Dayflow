import SwiftUI

enum WeeklyInteractionGraphLayoutBuilder {
  enum EdgeKind {
    case hub
    case local
    case bridge
  }

  struct Slot: Identifiable {
    let id: String
    let category: WeeklyInteractionGraphCategory
    let center: CGPoint
    let diameter: CGFloat
    let priority: CGFloat

    func point(in bounds: CGRect) -> CGPoint {
      CGPoint(
        x: bounds.minX + (bounds.width * center.x),
        y: bounds.minY + (bounds.height * center.y)
      )
    }
  }

  struct Template {
    let center: CGPoint
    let slotsByCategory: [WeeklyInteractionGraphCategory: [Slot]]
  }

  struct AssignedNodeSlot {
    let node: WeeklyInteractionGraphNode
    let slot: Slot
  }

  static func layout(
    snapshot: WeeklyInteractionGraphSnapshot,
    in bounds: CGRect
  ) -> WeeklyInteractionGraphLayout {
    let centerNodeID = resolveCenterNodeID(snapshot: snapshot)
    let nodeLookup = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
    let strengths = incidentWeights(snapshot: snapshot)
    let template = template(for: snapshot)
    let graphCenter = CGPoint(
      x: bounds.minX + (bounds.width * template.center.x),
      y: bounds.minY + (bounds.height * template.center.y)
    )
    let edgeWeights = edgeWeights(snapshot: snapshot)

    let nonCenterNodes = snapshot.nodes.filter { $0.id != centerNodeID }
    let groupedByCategory = Dictionary(grouping: nonCenterNodes, by: \.category)

    var nodeLayouts: [String: WeeklyInteractionGraphNodeLayout] = [:]
    var placedCenters: [String: CGPoint] = [:]

    if let centerNode = nodeLookup[centerNodeID] {
      nodeLayouts[centerNode.id] = WeeklyInteractionGraphNodeLayout(
        id: centerNode.id,
        node: centerNode,
        center: graphCenter,
        diameter: 89.6,
        borderWidth: 3,
        isCenter: true
      )
      placedCenters[centerNode.id] = graphCenter
    }

    for category in WeeklyInteractionGraphCategory.allCases {
      let categoryNodes = groupedByCategory[category] ?? []
      guard categoryNodes.isEmpty == false else { continue }

      let categorySlots = slots(
        for: category,
        count: categoryNodes.count,
        in: template
      )
      let assignments = assignNodes(
        categoryNodes,
        to: categorySlots,
        in: bounds,
        graphCenter: graphCenter,
        centerNodeID: centerNodeID,
        edgeWeights: edgeWeights,
        strengths: strengths,
        placedCenters: &placedCenters
      )

      for assignment in assignments {
        let center = assignment.slot.point(in: bounds)

        nodeLayouts[assignment.node.id] = WeeklyInteractionGraphNodeLayout(
          id: assignment.node.id,
          node: assignment.node,
          center: center,
          diameter: assignment.slot.diameter,
          borderWidth: assignment.slot.diameter >= 54 ? 3 : 2.25,
          isCenter: false
        )
      }
    }

    let visibleEdges = visibleEdges(
      snapshot: snapshot,
      centerNodeID: centerNodeID
    )
    let attachmentAngles = buildAttachmentAngles(
      edges: visibleEdges,
      nodeLayouts: nodeLayouts
    )

    var edgeLayouts: [WeeklyInteractionGraphEdgeLayout] = []
    var connectorDots: [WeeklyInteractionGraphConnectorDot] = []

    let maxWeight = max(visibleEdges.map(\.weight).max() ?? 1, 1)

    for edge in visibleEdges {
      guard
        let sourceNode = nodeLayouts[edge.sourceID],
        let targetNode = nodeLayouts[edge.targetID],
        let sourceAngle = attachmentAngles[edge.sourceID]?[edge.id],
        let targetAngle = attachmentAngles[edge.targetID]?[edge.id]
      else {
        continue
      }

      let sourcePoint = anchorPoint(for: sourceNode, angle: sourceAngle)
      let targetPoint = anchorPoint(for: targetNode, angle: targetAngle)
      let distance = sourcePoint.distance(to: targetPoint)
      let weightRatio = max(0.25, edge.weight / maxWeight)
      let kind = edgeKind(source: sourceNode, target: targetNode)
      let guide = guidePoint(
        for: kind,
        source: sourceNode,
        target: targetNode,
        in: bounds,
        graphCenter: graphCenter
      )
      let sourceTangent = tangentVector(
        angle: sourceAngle,
        from: sourcePoint,
        toward: guide ?? targetPoint
      )
      let targetTangent = tangentVector(
        angle: targetAngle,
        from: targetPoint,
        toward: guide ?? sourcePoint
      )
      let tangentLength = controlLength(
        for: kind,
        distance: distance,
        weightRatio: weightRatio
      )
      let guidePull = guidePullLength(
        for: kind,
        distance: distance
      )

      var sourceControl = sourcePoint + (sourceTangent * tangentLength)
      var targetControl = targetPoint + (targetTangent * tangentLength)

      if let guide {
        sourceControl =
          sourceControl + (CGPoint.normalized(from: sourcePoint, to: guide) * guidePull)
        targetControl =
          targetControl + (CGPoint.normalized(from: targetPoint, to: guide) * guidePull)
      }

      var path = Path()
      path.move(to: sourcePoint)
      path.addCurve(
        to: targetPoint,
        control1: sourceControl,
        control2: targetControl
      )

      let color = edgeColor(source: sourceNode.category, target: targetNode.category)
      let opacity = edgeOpacity(
        source: sourceNode,
        target: targetNode,
        weightRatio: weightRatio,
        kind: kind
      )

      edgeLayouts.append(
        WeeklyInteractionGraphEdgeLayout(
          id: edge.id,
          path: path,
          color: color,
          opacity: opacity,
          lineWidth: lineWidth(for: kind, weightRatio: weightRatio),
          zIndex: edgeZIndex(for: kind)
        )
      )

      connectorDots.append(
        WeeklyInteractionGraphConnectorDot(
          id: "\(edge.id)-source",
          center: sourcePoint,
          color: sourceNode.category.borderColor,
          diameter: 6
        )
      )
      connectorDots.append(
        WeeklyInteractionGraphConnectorDot(
          id: "\(edge.id)-target",
          center: targetPoint,
          color: targetNode.category.borderColor,
          diameter: 6
        )
      )
    }

    return WeeklyInteractionGraphLayout(
      nodes: nodeLayouts.values.sorted(by: { lhs, rhs in
        if lhs.isCenter == rhs.isCenter {
          return lhs.id < rhs.id
        }
        return !lhs.isCenter && rhs.isCenter
      }),
      edges: edgeLayouts,
      connectorDots: connectorDots
    )
  }

  static func resolveCenterNodeID(snapshot: WeeklyInteractionGraphSnapshot) -> String {
    if let preferred = snapshot.preferredCenterNodeID {
      return preferred
    }

    let strengths = incidentWeights(snapshot: snapshot)
    let sortedNodes = snapshot.nodes.sorted { lhs, rhs in
      let lhsScore = (strengths[lhs.id] ?? 0) + lhs.importanceBoost
      let rhsScore = (strengths[rhs.id] ?? 0) + rhs.importanceBoost
      if lhsScore == rhsScore {
        return lhs.id < rhs.id
      }
      return lhsScore > rhsScore
    }

    return sortedNodes.first?.id ?? snapshot.nodes.first?.id ?? ""
  }

  static func template(for snapshot: WeeklyInteractionGraphSnapshot) -> Template {
    Template(
      center: CGPoint(x: 0.4631, y: 0.4650),
      slotsByCategory: [
        .work: [
          Slot(
            id: "work-left-primary", category: .work, center: CGPoint(x: 0.2220, y: 0.1965),
            diameter: 67.1, priority: 0),
          Slot(
            id: "work-bottom-primary", category: .work, center: CGPoint(x: 0.1669, y: 0.8929),
            diameter: 56.7, priority: 1),
          Slot(
            id: "work-top-secondary", category: .work, center: CGPoint(x: 0.3909, y: 0.1483),
            diameter: 48.3, priority: 2),
          Slot(
            id: "work-mid-left", category: .work, center: CGPoint(x: 0.1769, y: 0.4124),
            diameter: 43.9, priority: 3),
          Slot(
            id: "work-inner-bottom", category: .work, center: CGPoint(x: 0.3115, y: 0.7087),
            diameter: 35.5, priority: 4),
          Slot(
            id: "work-outer-left", category: .work, center: CGPoint(x: 0.0796, y: 0.6052),
            diameter: 36.6, priority: 5),
          Slot(
            id: "work-upper-left", category: .work, center: CGPoint(x: 0.1080, y: 0.3150),
            diameter: 38.0, priority: 6),
        ],
        .personal: [
          Slot(
            id: "personal-bottom-right", category: .personal, center: CGPoint(x: 0.7296, y: 0.9048),
            diameter: 67.1, priority: 0),
          Slot(
            id: "personal-mid-right", category: .personal, center: CGPoint(x: 0.7281, y: 0.6197),
            diameter: 58.2, priority: 1),
          Slot(
            id: "personal-bottom-mid", category: .personal, center: CGPoint(x: 0.5412, y: 0.8100),
            diameter: 39.0, priority: 2),
          Slot(
            id: "personal-inner-bottom", category: .personal, center: CGPoint(x: 0.4111, y: 0.8403),
            diameter: 35.2, priority: 3),
          Slot(
            id: "personal-lower-right", category: .personal, center: CGPoint(x: 0.8670, y: 0.7600),
            diameter: 39.0, priority: 4),
        ],
        .distraction: [
          Slot(
            id: "distraction-right-primary", category: .distraction,
            center: CGPoint(x: 0.9467, y: 0.4714), diameter: 56.5, priority: 0),
          Slot(
            id: "distraction-inner-primary", category: .distraction,
            center: CGPoint(x: 0.5664, y: 0.2330), diameter: 56.7, priority: 1),
          Slot(
            id: "distraction-cap", category: .distraction, center: CGPoint(x: 0.6326, y: 0.0729),
            diameter: 42.1, priority: 2),
          Slot(
            id: "distraction-top-right", category: .distraction,
            center: CGPoint(x: 0.8171, y: 0.1652), diameter: 40.6, priority: 3),
          Slot(
            id: "distraction-lower-right", category: .distraction,
            center: CGPoint(x: 0.8640, y: 0.7800), diameter: 42.0, priority: 4),
          Slot(
            id: "distraction-upper-arc", category: .distraction,
            center: CGPoint(x: 0.7420, y: 0.0580), diameter: 36.0, priority: 5),
        ],
      ]
    )
  }

  static func incidentWeights(
    snapshot: WeeklyInteractionGraphSnapshot
  ) -> [String: CGFloat] {
    var weights: [String: CGFloat] = [:]

    for node in snapshot.nodes {
      weights[node.id] = node.importanceBoost
    }

    for edge in snapshot.edges {
      weights[edge.sourceID, default: 0] += edge.weight
      weights[edge.targetID, default: 0] += edge.weight
    }

    return weights
  }

  static func edgeWeights(
    snapshot: WeeklyInteractionGraphSnapshot
  ) -> [String: CGFloat] {
    var weights: [String: CGFloat] = [:]

    for edge in snapshot.edges {
      weights[edgeKey(edge.sourceID, edge.targetID)] = edge.weight
    }

    return weights
  }

  static func slots(
    for category: WeeklyInteractionGraphCategory,
    count: Int,
    in template: Template
  ) -> [Slot] {
    let baseSlots = template.slotsByCategory[category] ?? []
    if count <= baseSlots.count {
      return Array(baseSlots.prefix(count))
    }

    return baseSlots
      + overflowSlots(
        for: category,
        startingAt: baseSlots.count,
        count: count - baseSlots.count
      )
  }

  static func overflowSlots(
    for category: WeeklyInteractionGraphCategory,
    startingAt startIndex: Int,
    count: Int
  ) -> [Slot] {
    let anchors: [CGPoint]

    switch category {
    case .work:
      anchors = [
        CGPoint(x: 0.0820, y: 0.2250),
        CGPoint(x: 0.0660, y: 0.4900),
        CGPoint(x: 0.1280, y: 0.7600),
        CGPoint(x: 0.2350, y: 0.9680),
      ]
    case .personal:
      anchors = [
        CGPoint(x: 0.8850, y: 0.6550),
        CGPoint(x: 0.7920, y: 0.9800),
        CGPoint(x: 0.6260, y: 0.9400),
        CGPoint(x: 0.5000, y: 0.9000),
      ]
    case .distraction:
      anchors = [
        CGPoint(x: 0.7000, y: 0.0420),
        CGPoint(x: 0.9060, y: 0.2850),
        CGPoint(x: 0.9220, y: 0.6750),
        CGPoint(x: 0.7880, y: 0.8450),
      ]
    }

    return anchors.prefix(count).enumerated().map { index, anchor in
      Slot(
        id: "\(category.rawValue)-overflow-\(startIndex + index)",
        category: category,
        center: anchor,
        diameter: 36,
        priority: CGFloat(startIndex + index)
      )
    }
  }

  static func assignNodes(
    _ nodes: [WeeklyInteractionGraphNode],
    to slots: [Slot],
    in bounds: CGRect,
    graphCenter: CGPoint,
    centerNodeID: String,
    edgeWeights: [String: CGFloat],
    strengths: [String: CGFloat],
    placedCenters: inout [String: CGPoint]
  ) -> [AssignedNodeSlot] {
    let sortedNodes = nodes.sorted { lhs, rhs in
      let lhsScore = (strengths[lhs.id] ?? 0) + lhs.importanceBoost
      let rhsScore = (strengths[rhs.id] ?? 0) + rhs.importanceBoost
      if lhsScore == rhsScore {
        return lhs.id < rhs.id
      }
      return lhsScore > rhsScore
    }

    var remainingSlots = slots
    var assignments: [AssignedNodeSlot] = []

    for node in sortedNodes {
      guard
        let bestSlot = remainingSlots.min(by: { lhs, rhs in
          slotScore(
            node: node,
            slot: lhs,
            in: bounds,
            graphCenter: graphCenter,
            centerNodeID: centerNodeID,
            edgeWeights: edgeWeights,
            placedCenters: placedCenters
          )
            < slotScore(
              node: node,
              slot: rhs,
              in: bounds,
              graphCenter: graphCenter,
              centerNodeID: centerNodeID,
              edgeWeights: edgeWeights,
              placedCenters: placedCenters
            )
        })
      else {
        continue
      }

      assignments.append(.init(node: node, slot: bestSlot))
      placedCenters[node.id] = bestSlot.point(in: bounds)
      remainingSlots.removeAll(where: { $0.id == bestSlot.id })
    }

    return assignments
  }

  static func slotScore(
    node: WeeklyInteractionGraphNode,
    slot: Slot,
    in bounds: CGRect,
    graphCenter: CGPoint,
    centerNodeID: String,
    edgeWeights: [String: CGFloat],
    placedCenters: [String: CGPoint]
  ) -> CGFloat {
    let slotCenter = slot.point(in: bounds)
    let centerWeight = edgeWeights[edgeKey(node.id, centerNodeID)] ?? 0
    let prominencePenalty = slot.priority * 160
    let centerDistancePenalty = slotCenter.distance(to: graphCenter) * max(centerWeight, 1) * 0.22

    let relationPenalty = placedCenters.reduce(CGFloat.zero) { partial, pair in
      let weight = edgeWeights[edgeKey(node.id, pair.key)] ?? 0
      guard weight > 0 else { return partial }
      return partial + (slotCenter.distance(to: pair.value) * weight * 0.16)
    }

    return prominencePenalty + centerDistancePenalty + relationPenalty
  }

  static func visibleEdges(
    snapshot: WeeklyInteractionGraphSnapshot,
    centerNodeID: String
  ) -> [WeeklyInteractionGraphEdge] {
    let hubEdges = snapshot.edges.filter { edge in
      edge.sourceID == centerNodeID || edge.targetID == centerNodeID
    }
    let secondaryEdges = snapshot.edges
      .filter { edge in
        edge.sourceID != centerNodeID && edge.targetID != centerNodeID
      }
      .sorted { lhs, rhs in
        if lhs.weight == rhs.weight {
          return lhs.id < rhs.id
        }
        return lhs.weight > rhs.weight
      }

    guard secondaryEdges.isEmpty == false else { return hubEdges }

    let maxSecondary = min(max(snapshot.nodes.count / 2, 4), 9)
    let threshold = (secondaryEdges.first?.weight ?? 0) * 0.58
    let keptSecondaryIDs = Set(
      secondaryEdges.enumerated().compactMap { index, edge in
        if index < maxSecondary || edge.weight >= threshold {
          return edge.id
        }
        return nil
      }
    )

    return snapshot.edges.filter { edge in
      if edge.sourceID == centerNodeID || edge.targetID == centerNodeID {
        return true
      }
      return keptSecondaryIDs.contains(edge.id)
    }
  }

  static func buildAttachmentAngles(
    edges: [WeeklyInteractionGraphEdge],
    nodeLayouts: [String: WeeklyInteractionGraphNodeLayout]
  ) -> [String: [String: CGFloat]] {
    var anglesByNode: [String: [String: CGFloat]] = [:]

    for (nodeID, nodeLayout) in nodeLayouts {
      let incidents = edges.compactMap { edge -> (edgeID: String, angle: CGFloat)? in
        if edge.sourceID == nodeID, let other = nodeLayouts[edge.targetID] {
          return (edge.id, angleBetween(nodeLayout.center, other.center))
        }

        if edge.targetID == nodeID, let other = nodeLayouts[edge.sourceID] {
          return (edge.id, angleBetween(nodeLayout.center, other.center))
        }

        return nil
      }
      .sorted { lhs, rhs in lhs.angle < rhs.angle }

      var nodeAngles: [String: CGFloat] = [:]
      let midpoint = CGFloat(incidents.count - 1) / 2
      let spacing = nodeLayout.isCenter ? 0.065 : 0.085

      for (index, incident) in incidents.enumerated() {
        let offsetIndex = CGFloat(index) - midpoint
        let offsetAngle = offsetIndex * spacing
        nodeAngles[incident.edgeID] = incident.angle + offsetAngle
      }

      anglesByNode[nodeID] = nodeAngles
    }

    return anglesByNode
  }

  static func anchorPoint(
    for node: WeeklyInteractionGraphNodeLayout,
    angle: CGFloat
  ) -> CGPoint {
    let radius = (node.diameter / 2) - max(node.borderWidth * 0.35, 0.8)
    return node.center + CGPoint(unitAngle: angle, radius: radius)
  }

  static func edgeKind(
    source: WeeklyInteractionGraphNodeLayout,
    target: WeeklyInteractionGraphNodeLayout
  ) -> EdgeKind {
    if source.isCenter || target.isCenter {
      return .hub
    }

    if source.category == target.category {
      return .local
    }

    return .bridge
  }

  static func guidePoint(
    for kind: EdgeKind,
    source: WeeklyInteractionGraphNodeLayout,
    target: WeeklyInteractionGraphNodeLayout,
    in bounds: CGRect,
    graphCenter: CGPoint,
  ) -> CGPoint? {
    switch kind {
    case .hub:
      let outerNode = source.isCenter ? target : source
      let isUpper = outerNode.center.y < graphCenter.y

      switch outerNode.category {
      case .work:
        return point(x: 0.22, y: isUpper ? 0.27 : 0.80, in: bounds)
      case .personal:
        return point(x: isUpper ? 0.66 : 0.61, y: isUpper ? 0.59 : 0.84, in: bounds)
      case .distraction:
        return point(x: isUpper ? 0.76 : 0.91, y: isUpper ? 0.21 : 0.63, in: bounds)
      }

    case .local:
      let midpoint = CGPoint.midpoint(source.center, target.center)
      let averageIsUpper = midpoint.y < graphCenter.y

      switch source.category {
      case .work:
        return point(x: 0.18, y: averageIsUpper ? 0.36 : 0.81, in: bounds)
      case .personal:
        return point(
          x: midpoint.x < graphCenter.x ? 0.56 : 0.70, y: averageIsUpper ? 0.63 : 0.83, in: bounds)
      case .distraction:
        return point(x: averageIsUpper ? 0.79 : 0.89, y: averageIsUpper ? 0.20 : 0.67, in: bounds)
      }

    case .bridge:
      let categories = [source.category, target.category].sorted(by: categorySort(lhs:rhs:))
      let midpoint = CGPoint.midpoint(source.center, target.center)

      if categories == [.work, .personal] {
        return point(x: midpoint.x < graphCenter.x ? 0.40 : 0.48, y: 0.90, in: bounds)
      }

      if categories == [.personal, .distraction] {
        return point(x: 0.88, y: midpoint.y < graphCenter.y ? 0.61 : 0.77, in: bounds)
      }

      return point(
        x: midpoint.y < graphCenter.y ? 0.76 : 0.89, y: midpoint.y < graphCenter.y ? 0.28 : 0.60,
        in: bounds)
    }
  }

  static func edgeColor(
    source: WeeklyInteractionGraphCategory,
    target: WeeklyInteractionGraphCategory
  ) -> Color {
    if source == target {
      return source.edgeColor
    }

    let sourceNS = NSColor(hex: source.edgeHex) ?? .systemBlue
    let targetNS = NSColor(hex: target.edgeHex) ?? .systemBlue
    let blend = sourceNS.blended(with: 0.5, of: targetNS) ?? sourceNS
    return Color(nsColor: blend)
  }

  static func edgeOpacity(
    source: WeeklyInteractionGraphNodeLayout,
    target: WeeklyInteractionGraphNodeLayout,
    weightRatio: CGFloat,
    kind: EdgeKind
  ) -> Double {
    let base: CGFloat =
      switch kind {
      case .hub:
        0.80
      case .local:
        0.48
      case .bridge:
        0.26
      }

    let emphasis: CGFloat =
      switch kind {
      case .hub:
        0.12
      case .local:
        0.14
      case .bridge:
        0.10
      }

    let categoryBoost: CGFloat
    if kind == .bridge, source.category != target.category {
      categoryBoost = 0
    } else if source.category == target.category {
      categoryBoost = 0.02
    } else {
      categoryBoost = 0
    }

    return Double(min(base + categoryBoost + (weightRatio * emphasis), 0.92))
  }

  static func lineWidth(
    for kind: EdgeKind,
    weightRatio: CGFloat
  ) -> CGFloat {
    let base: CGFloat =
      switch kind {
      case .hub:
        1.55
      case .local:
        1.1
      case .bridge:
        0.95
      }

    let lift: CGFloat =
      switch kind {
      case .hub:
        1.05
      case .local:
        0.65
      case .bridge:
        0.4
      }

    return base + (weightRatio * lift)
  }

  static func edgeZIndex(for kind: EdgeKind) -> Double {
    switch kind {
    case .hub:
      return 2
    case .local:
      return 1
    case .bridge:
      return 0
    }
  }

  static func controlLength(
    for kind: EdgeKind,
    distance: CGFloat,
    weightRatio: CGFloat
  ) -> CGFloat {
    let base: CGFloat =
      switch kind {
      case .hub:
        min(max(distance * 0.15, 22), 46)
      case .local:
        min(max(distance * 0.14, 18), 34)
      case .bridge:
        min(max(distance * 0.18, 26), 52)
      }

    return base + (weightRatio * 8)
  }

  static func guidePullLength(
    for kind: EdgeKind,
    distance: CGFloat
  ) -> CGFloat {
    switch kind {
    case .hub:
      return min(max(distance * 0.12, 18), 40)
    case .local:
      return min(max(distance * 0.08, 10), 24)
    case .bridge:
      return min(max(distance * 0.18, 30), 74)
    }
  }

  static func tangentVector(
    angle: CGFloat,
    from point: CGPoint,
    toward target: CGPoint
  ) -> CGPoint {
    let radial = CGPoint(unitAngle: angle, radius: 1)
    let clockwise = radial.rotated(by: .pi / 2)
    let counterClockwise = radial.rotated(by: -.pi / 2)
    let targetVector = CGPoint.normalized(from: point, to: target)

    if clockwise.dot(targetVector) > counterClockwise.dot(targetVector) {
      return clockwise
    }

    return counterClockwise
  }

  static func point(
    x: CGFloat,
    y: CGFloat,
    in bounds: CGRect
  ) -> CGPoint {
    CGPoint(
      x: bounds.minX + (bounds.width * x),
      y: bounds.minY + (bounds.height * y)
    )
  }

  static func categorySort(
    lhs: WeeklyInteractionGraphCategory,
    rhs: WeeklyInteractionGraphCategory
  ) -> Bool {
    let order: [WeeklyInteractionGraphCategory] = [.work, .personal, .distraction]
    return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
  }

  static func edgeKey(_ lhs: String, _ rhs: String) -> String {
    lhs < rhs ? "\(lhs)|\(rhs)" : "\(rhs)|\(lhs)"
  }

  static func angleBetween(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    atan2(b.y - a.y, b.x - a.x)
  }
}

extension CGPoint {
  init(unitAngle angle: CGFloat, radius: CGFloat) {
    self.init(x: cos(angle) * radius, y: sin(angle) * radius)
  }

  static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
  }

  static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
  }

  static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
    CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
  }

  static func normalized(from start: CGPoint, to end: CGPoint) -> CGPoint {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = max(sqrt((dx * dx) + (dy * dy)), 0.001)
    return CGPoint(x: dx / length, y: dy / length)
  }

  func rotated(by angle: CGFloat) -> CGPoint {
    CGPoint(
      x: (x * cos(angle)) - (y * sin(angle)),
      y: (x * sin(angle)) + (y * cos(angle))
    )
  }

  func dot(_ other: CGPoint) -> CGFloat {
    (x * other.x) + (y * other.y)
  }

  func distance(to other: CGPoint) -> CGFloat {
    sqrt(pow(other.x - x, 2) + pow(other.y - y, 2))
  }
}
