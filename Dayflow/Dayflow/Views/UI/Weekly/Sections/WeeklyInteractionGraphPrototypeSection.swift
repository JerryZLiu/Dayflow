import AppKit
import SwiftUI

struct WeeklyInteractionGraphPrototypeSection: View {
  let snapshot: WeeklyInteractionGraphSnapshot

  private enum Design {
    static let sectionSize = CGSize(width: 660, height: 631)
    static let cornerRadius: CGFloat = 6
    static let borderColor = Color(hex: "E7DDD5")
    static let background = Color(hex: "FBF6F0")
    static let titleColor = Color(hex: "B46531")
    static let titleOrigin = CGPoint(x: 29, y: 22)
    static let subtitleOrigin = CGPoint(x: 29, y: 56)
    static let graphOrigin = CGPoint(x: 24, y: 92)
    static let graphSize = CGSize(width: 602, height: 438)
    static let legendY: CGFloat = 577
  }

  private var layout: WeeklyInteractionGraphLayout {
    WeeklyInteractionGraphLayoutBuilder.layout(
      snapshot: snapshot,
      in: CGRect(origin: .zero, size: Design.graphSize)
    )
  }

  var body: some View {
    let layout = layout

    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Design.background)

      Text(snapshot.title)
        .font(.custom("InstrumentSerif-Regular", size: 20))
        .foregroundStyle(Design.titleColor)
        .offset(x: Design.titleOrigin.x, y: Design.titleOrigin.y)

      Text(snapshot.subtitle)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(.black)
        .offset(x: Design.subtitleOrigin.x, y: Design.subtitleOrigin.y)

      graphLayer(layout: layout)
        .frame(width: Design.graphSize.width, height: Design.graphSize.height)
        .offset(x: Design.graphOrigin.x, y: Design.graphOrigin.y)

      WeeklyInteractionGraphLegend()
        .frame(maxWidth: .infinity)
        .offset(y: Design.legendY)
    }
    .frame(width: Design.sectionSize.width, height: Design.sectionSize.height)
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(Design.borderColor, lineWidth: 1)
    )
  }

  private func graphLayer(layout: WeeklyInteractionGraphLayout) -> some View {
    ZStack {
      Canvas { context, _ in
        for edge in layout.edges.sorted(by: edgeSort(lhs:rhs:)) {
          context.stroke(
            edge.path,
            with: .color(edge.color.opacity(edge.opacity)),
            style: StrokeStyle(lineWidth: edge.lineWidth, lineCap: .round, lineJoin: .round)
          )
        }

        for dot in layout.connectorDots {
          let rect = CGRect(
            x: dot.center.x - (dot.diameter / 2),
            y: dot.center.y - (dot.diameter / 2),
            width: dot.diameter,
            height: dot.diameter
          )
          let path = Path(ellipseIn: rect)
          context.fill(path, with: .color(Design.background))
          context.stroke(
            path,
            with: .color(dot.color),
            lineWidth: 1.5
          )
        }
      }

      ForEach(layout.nodes) { node in
        WeeklyInteractionGraphNodeBadge(node: node)
          .frame(width: node.diameter, height: node.diameter)
          .position(node.center)
      }
    }
  }

  private func edgeSort(
    lhs: WeeklyInteractionGraphEdgeLayout,
    rhs: WeeklyInteractionGraphEdgeLayout
  ) -> Bool {
    if lhs.zIndex == rhs.zIndex {
      return lhs.id < rhs.id
    }
    return lhs.zIndex < rhs.zIndex
  }
}

private struct WeeklyInteractionGraphNodeBadge: View {
  let node: WeeklyInteractionGraphNodeLayout

  private var shellGradient: LinearGradient {
    switch node.category {
    case .work:
      return LinearGradient(
        colors: [Color(hex: "EEF3FF"), Color(hex: "F8FAFF")],
        startPoint: .top,
        endPoint: .bottom
      )
    case .personal:
      return LinearGradient(
        colors: [Color(hex: "EFECE8"), Color(hex: "F8F6F4")],
        startPoint: .top,
        endPoint: .bottom
      )
    case .distraction:
      return LinearGradient(
        colors: [Color(hex: "FFDCCF"), Color(hex: "F8F2EE")],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(shellGradient)
        .overlay(
          Circle()
            .stroke(node.category.borderColor, lineWidth: node.borderWidth)
        )
        .shadow(
          color: node.category.borderColor.opacity(node.isCenter ? 0.22 : 0.08),
          radius: node.isCenter ? 5 : 2,
          x: 0,
          y: 0
        )

      WeeklyInteractionGraphGlyphView(
        glyph: node.glyph,
        diameter: node.diameter
      )
      .padding(node.diameter * 0.2)
    }
  }
}

private struct WeeklyInteractionGraphGlyphView: View {
  let glyph: WeeklyInteractionGraphGlyph
  let diameter: CGFloat

  var body: some View {
    Group {
      switch glyph {
      case .figma:
        WeeklyInteractionFigmaGlyph()
      case .youtube:
        WeeklyInteractionYouTubeGlyph()
      case .x:
        WeeklyInteractionMonogramGlyph(
          text: "X",
          background: .black,
          foreground: .white,
          cornerRadius: diameter * 0.11,
          fontSize: diameter * 0.34
        )
      case .notion:
        WeeklyInteractionNotionGlyph(fontSize: diameter * 0.34)
      case .slack:
        WeeklyInteractionSlackGlyph()
      case .zoom:
        WeeklyInteractionZoomGlyph(fontSize: diameter * 0.24)
      case .reddit:
        WeeklyInteractionMonogramGlyph(
          text: "r",
          background: Color(hex: "FC7645"),
          foreground: .white,
          cornerRadius: diameter * 0.5,
          fontSize: diameter * 0.34
        )
      case .linear:
        WeeklyInteractionMonogramGlyph(
          text: "L",
          background: Color(hex: "2B2724"),
          foreground: .white,
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      case .framer:
        WeeklyInteractionMonogramGlyph(
          text: "F",
          background: .black,
          foreground: .white,
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      case .bookmark:
        WeeklyInteractionBookmarkGlyph()
      case .cube:
        WeeklyInteractionCubeGlyph()
      case .burst:
        WeeklyInteractionBurstGlyph()
      case .bullseye:
        WeeklyInteractionBullseyeGlyph()
      case .bars:
        WeeklyInteractionBarsGlyph()
      case .asset(let name):
        Image(name)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      case .monogram(let text, let backgroundHex, let foregroundHex):
        WeeklyInteractionMonogramGlyph(
          text: text,
          background: Color(hex: backgroundHex),
          foreground: Color(hex: foregroundHex),
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      }
    }
  }
}

private struct WeeklyInteractionMonogramGlyph: View {
  let text: String
  let background: Color
  let foreground: Color
  let cornerRadius: CGFloat
  let fontSize: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(background)
      .overlay {
        Text(text)
          .font(.system(size: fontSize, weight: .semibold, design: .rounded))
          .foregroundStyle(foreground)
      }
  }
}

private struct WeeklyInteractionFigmaGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let circle = width * 0.28
      let pillWidth = width * 0.56

      ZStack {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: circle * 0.7, style: .continuous)
              .fill(Color(hex: "F96E4F"))
              .frame(width: pillWidth, height: circle)

            Circle()
              .fill(Color(hex: "29B6F6"))
              .frame(width: circle, height: circle)
          }

          HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: circle * 0.7, style: .continuous)
              .fill(Color(hex: "A857E8"))
              .frame(width: pillWidth, height: circle)

            Circle()
              .fill(Color(hex: "29B6F6"))
              .frame(width: circle, height: circle)
          }

          HStack(spacing: 0) {
            Circle()
              .fill(Color(hex: "34C759"))
              .frame(width: circle, height: circle)

            Spacer(minLength: 0)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

private struct WeeklyInteractionYouTubeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let height = proxy.size.height

      RoundedRectangle(cornerRadius: height * 0.22, style: .continuous)
        .fill(Color(hex: "FF2626"))
        .overlay {
          Image(systemName: "play.fill")
            .font(.system(size: width * 0.28, weight: .bold))
            .foregroundStyle(.white)
            .offset(x: width * 0.03)
        }
    }
    .aspectRatio(1.35, contentMode: .fit)
  }
}

private struct WeeklyInteractionSlackGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let bar = width * 0.18
      let long = width * 0.44

      ZStack {
        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(Color(hex: "36C5F0"))
          .frame(width: bar, height: long)
          .offset(x: -bar * 0.9, y: long * 0.2)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(Color(hex: "2EB67D"))
          .frame(width: long, height: bar)
          .offset(x: -bar * 0.2, y: bar * 0.9)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(Color(hex: "E01E5A"))
          .frame(width: bar, height: long)
          .offset(x: bar * 0.9, y: -long * 0.2)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(Color(hex: "ECB22E"))
          .frame(width: long, height: bar)
          .offset(x: bar * 0.2, y: -bar * 0.9)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

private struct WeeklyInteractionNotionGlyph: View {
  let fontSize: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(.white)
      .overlay(
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .stroke(.black, lineWidth: 1.5)
      )
      .overlay {
        Text("N")
          .font(.system(size: fontSize, weight: .black, design: .serif))
          .foregroundStyle(.black)
      }
  }
}

private struct WeeklyInteractionZoomGlyph: View {
  let fontSize: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: 9, style: .continuous)
      .fill(Color(hex: "4C8BFF"))
      .overlay {
        Image(systemName: "video.fill")
          .font(.system(size: fontSize, weight: .semibold))
          .foregroundStyle(.white)
      }
  }
}

private struct WeeklyInteractionBookmarkGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width

      Image(systemName: "bookmark.fill")
        .resizable()
        .scaledToFit()
        .foregroundStyle(Color(hex: "FC7645"))
        .frame(width: width * 0.56, height: width * 0.68)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct WeeklyInteractionCubeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)

      ZStack {
        Image(systemName: "shippingbox.fill")
          .resizable()
          .scaledToFit()
          .foregroundStyle(Color(hex: "2B2724"))
          .frame(width: size * 0.78, height: size * 0.78)

        Image(systemName: "shippingbox")
          .resizable()
          .scaledToFit()
          .foregroundStyle(Color(hex: "A2A2A2"))
          .frame(width: size * 0.78, height: size * 0.78)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct WeeklyInteractionBurstGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)
      let strokeLength = size * 0.34
      let strokeWidth = max(size * 0.028, 1.2)

      ZStack {
        ForEach(0..<12, id: \.self) { index in
          Capsule(style: .continuous)
            .fill(Color(hex: "E08A69"))
            .frame(width: strokeWidth, height: strokeLength)
            .offset(y: -size * 0.18)
            .rotationEffect(.degrees(Double(index) * 30))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct WeeklyInteractionBullseyeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)

      ZStack {
        Circle()
          .stroke(Color(hex: "B5C34C"), lineWidth: max(size * 0.1, 2))
          .frame(width: size * 0.66, height: size * 0.66)

        Circle()
          .stroke(Color(hex: "69751E"), lineWidth: max(size * 0.08, 1.5))
          .frame(width: size * 0.38, height: size * 0.38)

        Circle()
          .fill(Color(hex: "69751E"))
          .frame(width: size * 0.12, height: size * 0.12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct WeeklyInteractionBarsGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let barWidth = width * 0.12

      HStack(alignment: .bottom, spacing: width * 0.06) {
        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(Color(hex: "7E7E85"))
          .frame(width: barWidth, height: width * 0.34)

        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(Color(hex: "606067"))
          .frame(width: barWidth, height: width * 0.54)

        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(Color(hex: "7E7E85"))
          .frame(width: barWidth, height: width * 0.24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct WeeklyInteractionGraphLegend: View {
  var body: some View {
    HStack(spacing: 24) {
      legendItem(for: .work, title: "Work")
      legendItem(for: .personal, title: "Personal")
      legendItem(for: .distraction, title: "Distraction")
    }
  }

  private func legendItem(
    for category: WeeklyInteractionGraphCategory,
    title: String
  ) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(category.fillColor)
        .overlay(
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .stroke(category.borderColor, lineWidth: 1.75)
        )
        .frame(width: 16, height: 12)

      Text(title)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(.black)
    }
  }
}

enum WeeklyInteractionGraphCategory: String, CaseIterable {
  case work
  case personal
  case distraction

  var fillColor: Color {
    switch self {
    case .work:
      return Color(hex: "EEF3FF")
    case .personal:
      return Color(hex: "E6E6E6")
    case .distraction:
      return Color(hex: "FFDCCF")
    }
  }

  var borderColor: Color {
    switch self {
    case .work:
      return Color(hex: "4779E9")
    case .personal:
      return Color(hex: "B8B8B8")
    case .distraction:
      return Color(hex: "FC7645")
    }
  }

  var edgeColor: Color {
    Color(hex: edgeHex)
  }

  var edgeHex: String {
    switch self {
    case .work:
      return "4779E9"
    case .personal:
      return "9BA1A9"
    case .distraction:
      return "FC7645"
    }
  }
}

enum WeeklyInteractionGraphGlyph {
  case figma
  case youtube
  case x
  case notion
  case slack
  case zoom
  case reddit
  case linear
  case framer
  case bookmark
  case cube
  case burst
  case bullseye
  case bars
  case asset(String)
  case monogram(String, backgroundHex: String, foregroundHex: String)
}

struct WeeklyInteractionGraphSnapshot {
  let title: String
  let subtitle: String
  let nodes: [WeeklyInteractionGraphNode]
  let edges: [WeeklyInteractionGraphEdge]
  let preferredCenterNodeID: String?

  init(
    title: String,
    subtitle: String,
    nodes: [WeeklyInteractionGraphNode],
    edges: [WeeklyInteractionGraphEdge],
    preferredCenterNodeID: String? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.nodes = nodes
    self.edges = edges
    self.preferredCenterNodeID = preferredCenterNodeID
  }
}

struct WeeklyInteractionGraphNode: Identifiable {
  let id: String
  let title: String
  let category: WeeklyInteractionGraphCategory
  let glyph: WeeklyInteractionGraphGlyph
  let importanceBoost: CGFloat

  init(
    id: String,
    title: String,
    category: WeeklyInteractionGraphCategory,
    glyph: WeeklyInteractionGraphGlyph,
    importanceBoost: CGFloat = 0
  ) {
    self.id = id
    self.title = title
    self.category = category
    self.glyph = glyph
    self.importanceBoost = importanceBoost
  }
}

struct WeeklyInteractionGraphEdge: Identifiable {
  let id: String
  let sourceID: String
  let targetID: String
  let weight: CGFloat

  init(
    id: String,
    sourceID: String,
    targetID: String,
    weight: CGFloat = 1
  ) {
    self.id = id
    self.sourceID = sourceID
    self.targetID = targetID
    self.weight = weight
  }
}

private struct WeeklyInteractionGraphLayout {
  let nodes: [WeeklyInteractionGraphNodeLayout]
  let edges: [WeeklyInteractionGraphEdgeLayout]
  let connectorDots: [WeeklyInteractionGraphConnectorDot]
}

private struct WeeklyInteractionGraphNodeLayout: Identifiable {
  let id: String
  let node: WeeklyInteractionGraphNode
  let center: CGPoint
  let diameter: CGFloat
  let borderWidth: CGFloat
  let isCenter: Bool

  var category: WeeklyInteractionGraphCategory { node.category }
  var glyph: WeeklyInteractionGraphGlyph { node.glyph }
}

private struct WeeklyInteractionGraphEdgeLayout: Identifiable {
  let id: String
  let path: Path
  let color: Color
  let opacity: Double
  let lineWidth: CGFloat
  let zIndex: Double
}

private struct WeeklyInteractionGraphConnectorDot: Identifiable {
  let id: String
  let center: CGPoint
  let color: Color
  let diameter: CGFloat
}

private enum WeeklyInteractionGraphLayoutBuilder {
  private enum EdgeKind {
    case hub
    case local
    case bridge
  }

  private struct Slot: Identifiable {
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

  private struct Template {
    let center: CGPoint
    let slotsByCategory: [WeeklyInteractionGraphCategory: [Slot]]
  }

  private struct AssignedNodeSlot {
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

  private static func resolveCenterNodeID(snapshot: WeeklyInteractionGraphSnapshot) -> String {
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

  private static func template(for snapshot: WeeklyInteractionGraphSnapshot) -> Template {
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

  private static func incidentWeights(
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

  private static func edgeWeights(
    snapshot: WeeklyInteractionGraphSnapshot
  ) -> [String: CGFloat] {
    var weights: [String: CGFloat] = [:]

    for edge in snapshot.edges {
      weights[edgeKey(edge.sourceID, edge.targetID)] = edge.weight
    }

    return weights
  }

  private static func slots(
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

  private static func overflowSlots(
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

  private static func assignNodes(
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

  private static func slotScore(
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

  private static func visibleEdges(
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

  private static func buildAttachmentAngles(
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

  private static func anchorPoint(
    for node: WeeklyInteractionGraphNodeLayout,
    angle: CGFloat
  ) -> CGPoint {
    let radius = (node.diameter / 2) - max(node.borderWidth * 0.35, 0.8)
    return node.center + CGPoint(unitAngle: angle, radius: radius)
  }

  private static func edgeKind(
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

  private static func guidePoint(
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

  private static func edgeColor(
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

  private static func edgeOpacity(
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

  private static func lineWidth(
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

  private static func edgeZIndex(for kind: EdgeKind) -> Double {
    switch kind {
    case .hub:
      return 2
    case .local:
      return 1
    case .bridge:
      return 0
    }
  }

  private static func controlLength(
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

  private static func guidePullLength(
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

  private static func tangentVector(
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

  private static func point(
    x: CGFloat,
    y: CGFloat,
    in bounds: CGRect
  ) -> CGPoint {
    CGPoint(
      x: bounds.minX + (bounds.width * x),
      y: bounds.minY + (bounds.height * y)
    )
  }

  private static func categorySort(
    lhs: WeeklyInteractionGraphCategory,
    rhs: WeeklyInteractionGraphCategory
  ) -> Bool {
    let order: [WeeklyInteractionGraphCategory] = [.work, .personal, .distraction]
    return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
  }

  private static func edgeKey(_ lhs: String, _ rhs: String) -> String {
    lhs < rhs ? "\(lhs)|\(rhs)" : "\(rhs)|\(lhs)"
  }

  private static func angleBetween(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    atan2(b.y - a.y, b.x - a.x)
  }
}

extension CGPoint {
  fileprivate init(unitAngle angle: CGFloat, radius: CGFloat) {
    self.init(x: cos(angle) * radius, y: sin(angle) * radius)
  }

  fileprivate static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
  }

  fileprivate static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
  }

  fileprivate static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
    CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
  }

  fileprivate static func normalized(from start: CGPoint, to end: CGPoint) -> CGPoint {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = max(sqrt((dx * dx) + (dy * dy)), 0.001)
    return CGPoint(x: dx / length, y: dy / length)
  }

  fileprivate func rotated(by angle: CGFloat) -> CGPoint {
    CGPoint(
      x: (x * cos(angle)) - (y * sin(angle)),
      y: (x * sin(angle)) + (y * cos(angle))
    )
  }

  fileprivate func dot(_ other: CGPoint) -> CGFloat {
    (x * other.x) + (y * other.y)
  }

  fileprivate func distance(to other: CGPoint) -> CGFloat {
    sqrt(pow(other.x - x, 2) + pow(other.y - y, 2))
  }
}

private enum WeeklyInteractionGraphFixtures {
  static let title = "Interactions between most used applications"
  static let subtitle = "More than 80% of recorded time was spent using these applications."

  static let figmaReference = WeeklyInteractionGraphSnapshot(
    title: title,
    subtitle: subtitle,
    nodes: [
      .init(id: "figma", title: "Figma", category: .work, glyph: .figma, importanceBoost: 10),
      .init(
        id: "raindrop", title: "Raindrop", category: .work,
        glyph: .monogram("R", backgroundHex: "2B2724", foregroundHex: "FFFFFF"), importanceBoost: 3),
      .init(id: "framer", title: "Framer", category: .work, glyph: .framer),
      .init(id: "notion", title: "Notion", category: .work, glyph: .notion),
      .init(id: "slack", title: "Slack", category: .work, glyph: .slack),
      .init(id: "stats", title: "Stats", category: .work, glyph: .bars),
      .init(id: "zoom", title: "Zoom", category: .work, glyph: .zoom),
      .init(id: "focus", title: "Focus", category: .work, glyph: .bullseye),
      .init(id: "cube", title: "Cube", category: .personal, glyph: .cube, importanceBoost: 2),
      .init(id: "chatgpt", title: "ChatGPT", category: .personal, glyph: .asset("ChatGPTLogo")),
      .init(id: "burst", title: "Burst", category: .personal, glyph: .burst, importanceBoost: 2),
      .init(id: "x", title: "X", category: .distraction, glyph: .x),
      .init(id: "save", title: "Saved", category: .distraction, glyph: .bookmark),
      .init(id: "reddit", title: "Reddit", category: .distraction, glyph: .reddit),
      .init(id: "youtube", title: "YouTube", category: .distraction, glyph: .youtube),
    ],
    edges: [
      .init(id: "f1", sourceID: "figma", targetID: "raindrop", weight: 7.2),
      .init(id: "f2", sourceID: "figma", targetID: "framer", weight: 4.2),
      .init(id: "f3", sourceID: "figma", targetID: "notion", weight: 4.8),
      .init(id: "f4", sourceID: "figma", targetID: "slack", weight: 5.8),
      .init(id: "f5", sourceID: "figma", targetID: "stats", weight: 2.1),
      .init(id: "f6", sourceID: "figma", targetID: "zoom", weight: 2.5),
      .init(id: "f7", sourceID: "figma", targetID: "focus", weight: 1.6),
      .init(id: "f8", sourceID: "figma", targetID: "cube", weight: 3.3),
      .init(id: "f9", sourceID: "figma", targetID: "chatgpt", weight: 2.9),
      .init(id: "f10", sourceID: "figma", targetID: "burst", weight: 3.1),
      .init(id: "f11", sourceID: "figma", targetID: "x", weight: 3.4),
      .init(id: "f12", sourceID: "figma", targetID: "save", weight: 2.0),
      .init(id: "f13", sourceID: "figma", targetID: "reddit", weight: 2.3),
      .init(id: "f14", sourceID: "figma", targetID: "youtube", weight: 4.0),
      .init(id: "f15", sourceID: "slack", targetID: "notion", weight: 2.4),
      .init(id: "f16", sourceID: "slack", targetID: "zoom", weight: 2.2),
      .init(id: "f17", sourceID: "slack", targetID: "stats", weight: 1.7),
      .init(id: "f18", sourceID: "cube", targetID: "burst", weight: 2.0),
      .init(id: "f19", sourceID: "chatgpt", targetID: "burst", weight: 1.8),
      .init(id: "f20", sourceID: "x", targetID: "save", weight: 2.3),
      .init(id: "f21", sourceID: "x", targetID: "reddit", weight: 3.0),
      .init(id: "f22", sourceID: "x", targetID: "youtube", weight: 2.5),
      .init(id: "f23", sourceID: "reddit", targetID: "youtube", weight: 2.8),
      .init(id: "f24", sourceID: "cube", targetID: "youtube", weight: 1.3),
      .init(id: "f25", sourceID: "focus", targetID: "chatgpt", weight: 1.2),
    ],
    preferredCenterNodeID: "figma"
  )

  static let dualHubTension = WeeklyInteractionGraphSnapshot(
    title: title,
    subtitle: "Edge case: two strong work hubs compete for the center of gravity.",
    nodes: [
      .init(id: "figma", title: "Figma", category: .work, glyph: .figma, importanceBoost: 5),
      .init(id: "slack", title: "Slack", category: .work, glyph: .slack, importanceBoost: 5),
      .init(id: "github", title: "GitHub", category: .work, glyph: .asset("GithubIcon")),
      .init(id: "notion", title: "Notion", category: .work, glyph: .notion),
      .init(id: "zoom", title: "Zoom", category: .work, glyph: .zoom),
      .init(id: "chatgpt", title: "ChatGPT", category: .personal, glyph: .asset("ChatGPTLogo")),
      .init(
        id: "mail", title: "Mail", category: .personal,
        glyph: .monogram("M", backgroundHex: "D9D9D9", foregroundHex: "333333")),
      .init(id: "youtube", title: "YouTube", category: .distraction, glyph: .youtube),
      .init(id: "x", title: "X", category: .distraction, glyph: .x),
      .init(id: "reddit", title: "Reddit", category: .distraction, glyph: .reddit),
    ],
    edges: [
      .init(id: "d1", sourceID: "figma", targetID: "github", weight: 5),
      .init(id: "d2", sourceID: "figma", targetID: "notion", weight: 4),
      .init(id: "d3", sourceID: "figma", targetID: "chatgpt", weight: 2.5),
      .init(id: "d4", sourceID: "figma", targetID: "youtube", weight: 1.3),
      .init(id: "d5", sourceID: "slack", targetID: "zoom", weight: 4.5),
      .init(id: "d6", sourceID: "slack", targetID: "mail", weight: 4),
      .init(id: "d7", sourceID: "slack", targetID: "notion", weight: 2.4),
      .init(id: "d8", sourceID: "slack", targetID: "x", weight: 1.2),
      .init(id: "d9", sourceID: "figma", targetID: "slack", weight: 4.3),
      .init(id: "d10", sourceID: "youtube", targetID: "reddit", weight: 2.4),
      .init(id: "d11", sourceID: "x", targetID: "reddit", weight: 2.1),
      .init(id: "d12", sourceID: "chatgpt", targetID: "mail", weight: 1.4),
    ]
  )

  static let distractionSpike = WeeklyInteractionGraphSnapshot(
    title: title,
    subtitle: "Edge case: one work hub with a dense distraction cluster on the right.",
    nodes: [
      .init(id: "figma", title: "Figma", category: .work, glyph: .figma, importanceBoost: 7),
      .init(id: "github", title: "GitHub", category: .work, glyph: .asset("GithubIcon")),
      .init(id: "notion", title: "Notion", category: .work, glyph: .notion),
      .init(id: "slack", title: "Slack", category: .work, glyph: .slack),
      .init(id: "chatgpt", title: "ChatGPT", category: .personal, glyph: .asset("ChatGPTLogo")),
      .init(id: "cube", title: "Cube", category: .personal, glyph: .cube),
      .init(id: "youtube", title: "YouTube", category: .distraction, glyph: .youtube),
      .init(id: "x", title: "X", category: .distraction, glyph: .x),
      .init(id: "reddit", title: "Reddit", category: .distraction, glyph: .reddit),
      .init(id: "news", title: "News", category: .distraction, glyph: .bookmark),
      .init(
        id: "twitch", title: "Twitch", category: .distraction,
        glyph: .monogram("T", backgroundHex: "8C5CFF", foregroundHex: "FFFFFF")),
      .init(id: "music", title: "Music", category: .distraction, glyph: .burst),
    ],
    edges: [
      .init(id: "s1", sourceID: "figma", targetID: "github", weight: 4),
      .init(id: "s2", sourceID: "figma", targetID: "notion", weight: 4),
      .init(id: "s3", sourceID: "figma", targetID: "slack", weight: 4),
      .init(id: "s4", sourceID: "figma", targetID: "chatgpt", weight: 2.5),
      .init(id: "s5", sourceID: "figma", targetID: "cube", weight: 2.2),
      .init(id: "s6", sourceID: "figma", targetID: "youtube", weight: 3.2),
      .init(id: "s7", sourceID: "figma", targetID: "x", weight: 2.4),
      .init(id: "s8", sourceID: "figma", targetID: "reddit", weight: 2.1),
      .init(id: "s9", sourceID: "youtube", targetID: "x", weight: 3.5),
      .init(id: "s10", sourceID: "youtube", targetID: "reddit", weight: 3.5),
      .init(id: "s11", sourceID: "youtube", targetID: "news", weight: 3.1),
      .init(id: "s12", sourceID: "youtube", targetID: "twitch", weight: 2.9),
      .init(id: "s13", sourceID: "youtube", targetID: "music", weight: 2.7),
      .init(id: "s14", sourceID: "x", targetID: "reddit", weight: 2.8),
      .init(id: "s15", sourceID: "reddit", targetID: "news", weight: 2.6),
      .init(id: "s16", sourceID: "twitch", targetID: "music", weight: 2.4),
      .init(id: "s17", sourceID: "cube", targetID: "youtube", weight: 1.7),
    ],
    preferredCenterNodeID: "figma"
  )

  static let longTailNoise = WeeklyInteractionGraphSnapshot(
    title: title,
    subtitle: "Edge case: lots of small low-weight peripherals around one dominant app.",
    nodes: [
      .init(id: "figma", title: "Figma", category: .work, glyph: .figma, importanceBoost: 9),
      .init(id: "github", title: "GitHub", category: .work, glyph: .asset("GithubIcon")),
      .init(id: "notion", title: "Notion", category: .work, glyph: .notion),
      .init(id: "slack", title: "Slack", category: .work, glyph: .slack),
      .init(id: "zoom", title: "Zoom", category: .work, glyph: .zoom),
      .init(id: "chatgpt", title: "ChatGPT", category: .personal, glyph: .asset("ChatGPTLogo")),
      .init(id: "chrome", title: "Chrome", category: .personal, glyph: .asset("ChromeFavicon")),
      .init(id: "linear", title: "Linear", category: .personal, glyph: .linear),
      .init(
        id: "calendar", title: "Calendar", category: .personal,
        glyph: .monogram("C", backgroundHex: "D9D9D9", foregroundHex: "333333")),
      .init(
        id: "mail", title: "Mail", category: .personal,
        glyph: .monogram("M", backgroundHex: "D9D9D9", foregroundHex: "333333")),
      .init(id: "youtube", title: "YouTube", category: .distraction, glyph: .youtube),
      .init(id: "x", title: "X", category: .distraction, glyph: .x),
      .init(id: "reddit", title: "Reddit", category: .distraction, glyph: .reddit),
      .init(id: "news", title: "News", category: .distraction, glyph: .bookmark),
    ],
    edges: [
      .init(id: "l1", sourceID: "figma", targetID: "github", weight: 5),
      .init(id: "l2", sourceID: "figma", targetID: "notion", weight: 4.4),
      .init(id: "l3", sourceID: "figma", targetID: "slack", weight: 4.1),
      .init(id: "l4", sourceID: "figma", targetID: "zoom", weight: 3.6),
      .init(id: "l5", sourceID: "figma", targetID: "chatgpt", weight: 2.2),
      .init(id: "l6", sourceID: "figma", targetID: "chrome", weight: 1.9),
      .init(id: "l7", sourceID: "figma", targetID: "linear", weight: 1.7),
      .init(id: "l8", sourceID: "figma", targetID: "calendar", weight: 1.2),
      .init(id: "l9", sourceID: "figma", targetID: "mail", weight: 1.1),
      .init(id: "l10", sourceID: "figma", targetID: "youtube", weight: 1.4),
      .init(id: "l11", sourceID: "figma", targetID: "x", weight: 1.1),
      .init(id: "l12", sourceID: "figma", targetID: "reddit", weight: 1.0),
      .init(id: "l13", sourceID: "figma", targetID: "news", weight: 0.9),
      .init(id: "l14", sourceID: "chatgpt", targetID: "chrome", weight: 1.2),
      .init(id: "l15", sourceID: "youtube", targetID: "x", weight: 1.1),
    ],
    preferredCenterNodeID: "figma"
  )
}

#Preview("Interaction Graph – Figma Reference", traits: .fixedLayout(width: 660, height: 631)) {
  WeeklyInteractionGraphPrototypeSection(snapshot: WeeklyInteractionGraphFixtures.figmaReference)
}

#Preview("Interaction Graph – Two Hubs", traits: .fixedLayout(width: 660, height: 631)) {
  WeeklyInteractionGraphPrototypeSection(snapshot: WeeklyInteractionGraphFixtures.dualHubTension)
}

#Preview(
  "Interaction Graph – Dense Distraction Cluster", traits: .fixedLayout(width: 660, height: 631)
) {
  WeeklyInteractionGraphPrototypeSection(snapshot: WeeklyInteractionGraphFixtures.distractionSpike)
}

#Preview("Interaction Graph – Long Tail", traits: .fixedLayout(width: 660, height: 631)) {
  WeeklyInteractionGraphPrototypeSection(snapshot: WeeklyInteractionGraphFixtures.longTailNoise)
}
