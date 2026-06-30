import AppKit
import SwiftUI

struct WeeklySankeyCard: View {
  let model: WeeklySankeyModel
  let width: CGFloat

  @State private var hoveredNodeID: String?
  @State private var pinnedNodeID: String?

  private var activeNodeID: String? {
    pinnedNodeID ?? hoveredNodeID
  }

  private var height: CGFloat {
    width * WeeklySankeyDesign.virtualHeight / WeeklySankeyDesign.virtualWidth
  }

  var body: some View {
    let scale = WeeklySankeyScale(size: CGSize(width: width, height: height))

    ZStack(alignment: .topLeading) {
      Canvas { context, size in
        let scale = WeeklySankeyScale(size: size)
        drawUnderlays(in: &context, scale: scale)
        drawFlows(in: &context, scale: scale)
      }

      WeeklySankeyFlowInteractionLayer(
        model: model,
        size: CGSize(width: width, height: height),
        onHoveredNodeChanged: { hoveredNodeID = $0 },
        onFlowTapped: { togglePinned($0) },
        onEmptyTapped: { pinnedNodeID = nil }
      )

      ForEach(model.nodes) { node in
        let frame = scale.displayFrame(node.bar)

        Rectangle()
          .fill(Color(hex: node.barColorHex))
          .frame(width: frame.width, height: frame.height)
          .offset(x: frame.minX, y: frame.minY)
          .opacity(nodeOpacity(node.id))
          .contentShape(Rectangle())
          .onHover { isHovering in
            updateHoveredNode(node.id, isHovering: isHovering)
          }
          .onTapGesture {
            togglePinned(node.id)
          }
      }

      WeeklySankeyPlainLabel(
        node: model.source,
        opacity: nodeOpacity(model.source.id),
        scale: scale
      )
      .onHover { updateHoveredNode(model.source.id, isHovering: $0) }
      .onTapGesture { togglePinned(model.source.id) }

      ForEach(model.categories) { category in
        WeeklySankeyPlainLabel(
          node: category,
          opacity: nodeOpacity(category.id),
          scale: scale
        )
        .onHover { updateHoveredNode(category.id, isHovering: $0) }
        .onTapGesture { togglePinned(category.id) }
      }

      ForEach(model.apps) { app in
        WeeklySankeyAppLabel(node: app, opacity: nodeOpacity(app.id), scale: scale)
          .onHover { updateHoveredNode(app.id, isHovering: $0) }
          .onTapGesture { togglePinned(app.id) }
      }

      Text("Weekly breakdown")
        .font(.custom("InstrumentSerif-Regular", size: 20))
        .foregroundStyle(Color(hex: "B46531"))
        .offset(
          x: scale.displayX(72),
          y: scale.displayY(64)
        )
    }
    .frame(
      width: width,
      height: height
    )
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

  private func drawUnderlays(in context: inout GraphicsContext, scale: WeeklySankeyScale) {
    guard let firstCategory = model.categories.first, let firstApp = model.apps.first else {
      return
    }

    let categoryTop = model.categories.map { $0.bar.minY }.min() ?? firstCategory.bar.minY
    let categoryBottom = model.categories.map { $0.bar.maxY }.max() ?? firstCategory.bar.maxY
    let appTop = model.apps.map { $0.bar.minY }.min() ?? firstApp.bar.minY
    let appBottom = model.apps.map { $0.bar.maxY }.max() ?? firstApp.bar.maxY

    let sourcePath = sankeyColumnUnderlayPath(
      x0: model.source.bar.maxX,
      y0Top: model.source.bar.minY,
      y0Bottom: model.source.bar.maxY,
      x1: firstCategory.bar.minX,
      y1Top: categoryTop,
      y1Bottom: categoryBottom,
      tension: WeeklySankeyDesign.sourceCurveTension,
      scale: scale
    )

    context.fill(
      sourcePath,
      with: .linearGradient(
        Gradient(stops: [
          .init(color: Color(hex: "E6DBD1").opacity(0.48), location: 0),
          .init(color: Color(hex: "EFE9E3").opacity(0.34), location: 0.42),
          .init(color: Color(hex: "F4EEE9").opacity(0.2), location: 0.76),
          .init(color: Color(hex: "F7F2ED").opacity(0.08), location: 1),
        ]),
        startPoint: scale.point(x: model.source.bar.maxX, y: 0),
        endPoint: scale.point(x: firstCategory.bar.minX, y: 0)
      )
    )

    let rightPath = sankeyColumnUnderlayPath(
      x0: firstCategory.bar.minX + WeeklySankeyLayout.base.categories.width,
      y0Top: categoryTop,
      y0Bottom: categoryBottom,
      x1: firstApp.bar.minX,
      y1Top: appTop,
      y1Bottom: appBottom,
      tension: 0.22,
      scale: scale
    )

    context.opacity = 0.72
    context.fill(
      rightPath,
      with: .linearGradient(
        Gradient(stops: [
          .init(color: Color(hex: "EFE7E0").opacity(0.08), location: 0),
          .init(color: Color(hex: "F4EEE9").opacity(0.11), location: 0.46),
          .init(color: Color(hex: "EFE7E0").opacity(0.07), location: 1),
        ]),
        startPoint: scale.point(
          x: firstCategory.bar.minX + WeeklySankeyLayout.base.categories.width,
          y: 0
        ),
        endPoint: scale.point(x: firstApp.bar.minX, y: 0)
      )
    )
    context.opacity = 1
  }

  private func drawFlows(in context: inout GraphicsContext, scale: WeeklySankeyScale) {
    for flow in model.flows {
      let related = flowIsRelated(flow, activeNodeID)
      let activeOpacity = activeNodeID == nil || related ? 1.0 : 0.12
      let path = sankeyRibbonPath(
        flow: flow,
        curveTensionOverride: flow.from == model.source.id
          ? WeeklySankeyDesign.sourceCurveTension
          : nil,
        scale: scale
      )

      context.opacity = activeOpacity
      context.fill(
        path,
        with: .linearGradient(
          Gradient(stops: gradientStops(for: flow)),
          startPoint: scale.point(x: flow.x0, y: 0),
          endPoint: scale.point(x: flow.x1, y: 0)
        )
      )
      context.opacity = 1
    }
  }

  private func gradientStops(for flow: WeeklySankeyFlow) -> [Gradient.Stop] {
    let sourceFlow = flow.from == model.source.id
    let strength = max(0.08, min(flow.opacity, 0.36))
    let fromColor = sankeyRibbonTint(flow.fromColorHex)
    let toColor = sankeyRibbonTint(flow.toColorHex)

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

  private func sankeyRibbonTint(_ colorHex: String) -> String {
    let normalized = colorHex.replacingOccurrences(of: "#", with: "").uppercased()
    if normalized == "000000" || normalized == "333333" {
      return "CAC2BA"
    }
    if normalized == "D9D9D9" || normalized == "BFB6AE" {
      return "CFC8C1"
    }
    return normalized
  }

  private func flowIsRelated(_ flow: WeeklySankeyFlow, _ activeNodeID: String?) -> Bool {
    guard let activeNodeID else { return true }
    if activeNodeID == model.source.id { return true }
    return flow.from == activeNodeID || flow.to == activeNodeID
  }

  private func nodeOpacity(_ nodeID: String) -> Double {
    guard let activeNodeID else { return 1 }
    if nodeID == activeNodeID || activeNodeID == model.source.id {
      return 1
    }

    let related = model.flows.contains { flow in
      (flow.from == activeNodeID && flow.to == nodeID)
        || (flow.to == activeNodeID && flow.from == nodeID)
        || (flow.from == model.source.id && flow.to == activeNodeID && nodeID == model.source.id)
    }

    return related ? 1 : 0.25
  }

  private func updateHoveredNode(_ nodeID: String, isHovering: Bool) {
    if isHovering {
      hoveredNodeID = nodeID
    } else if hoveredNodeID == nodeID {
      hoveredNodeID = nil
    }
  }

  private func togglePinned(_ nodeID: String) {
    pinnedNodeID = pinnedNodeID == nodeID ? nil : nodeID
  }
}

private struct WeeklySankeyFlowInteractionLayer: View {
  let model: WeeklySankeyModel
  let size: CGSize
  let onHoveredNodeChanged: (String?) -> Void
  let onFlowTapped: (String) -> Void
  let onEmptyTapped: () -> Void

  var body: some View {
    Rectangle()
      .fill(Color.clear)
      .frame(
        width: size.width,
        height: size.height
      )
      .contentShape(Rectangle())
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let location):
          onHoveredNodeChanged(flow(at: location)?.to)
        case .ended:
          onHoveredNodeChanged(nil)
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
          .onEnded { value in
            if let flow = flow(at: value.location) {
              onFlowTapped(flow.to)
            } else {
              onEmptyTapped()
            }
          }
      )
      .accessibilityHidden(true)
  }

  private func flow(at point: CGPoint) -> WeeklySankeyFlow? {
    let scale = WeeklySankeyScale(size: size)

    return model.flows.reversed().first { flow in
      let hitFlow = flow.expandingVertically(by: 8 / scale.y)
      let path = sankeyRibbonPath(
        flow: hitFlow,
        curveTensionOverride: flow.from == model.source.id
          ? WeeklySankeyDesign.sourceCurveTension
          : nil,
        scale: scale
      )
      return path.contains(point, eoFill: false)
    }
  }
}

private struct WeeklySankeyPlainLabel: View {
  let node: WeeklySankeyNode
  let opacity: Double
  let scale: WeeklySankeyScale

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(node.name)
        .font(.custom("Figtree-Regular", size: 10))
        .foregroundStyle(Color.black)
        .lineLimit(1)

      metaLine(fontSize: 10)
    }
    .frame(width: scale.displayWidth(node.label.width), alignment: .leading)
    .offset(
      x: scale.displayX(node.label.x),
      y: scale.displayY(node.label.y)
    )
    .opacity(opacity)
    .contentShape(Rectangle())
  }

  private func metaLine(fontSize: CGFloat) -> some View {
    HStack(alignment: .top, spacing: 4) {
      Text(node.metric)
      Rectangle()
        .fill(Color(hex: "CFC7C1"))
        .frame(width: 0.5, height: 11)
      Text(node.percent)
    }
    .font(.custom("Figtree-Regular", size: fontSize))
    .foregroundStyle(Color(hex: "717171"))
    .lineLimit(1)
  }
}

private struct WeeklySankeyAppLabel: View {
  let node: WeeklySankeyNode
  let opacity: Double
  let scale: WeeklySankeyScale

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      if node.icon != .none {
        WeeklySankeyIconView(icon: node.icon)
          .frame(width: 14, height: 14)
      }

      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(node.name)
          .font(.custom("Figtree-Regular", size: 10))
          .foregroundStyle(Color.black)
          .lineLimit(1)

        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text(node.metric)
          Rectangle()
            .fill(Color(hex: "CFC7C1"))
            .frame(width: 0.5, height: 10)
          Text(node.percent)
        }
        .font(.custom("Figtree-Regular", size: 9))
        .foregroundStyle(Color(hex: "717171"))
        .lineLimit(1)
      }
      .lineLimit(1)
    }
    .frame(
      width: scale.displayWidth(node.label.width),
      height: scale.displayHeight(WeeklySankeyLayout.base.apps.labelHeight),
      alignment: .leading
    )
    .offset(
      x: scale.displayX(node.label.x),
      y: scale.displayY(node.label.y)
    )
    .opacity(opacity)
    .contentShape(Rectangle())
  }
}

private struct WeeklySankeyIconView: View {
  let icon: WeeklySankeyIcon

  var body: some View {
    switch icon {
    case .asset(let name):
      if let image = NSImage(named: name) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        fallbackMonogram("?")
      }
    case .favicon(
      let primaryRaw, let secondaryRaw, let primaryHost, let secondaryHost, let fallbackRaw):
      FaviconImageView(
        primaryRaw: primaryRaw,
        secondaryRaw: secondaryRaw,
        primaryHost: primaryHost,
        secondaryHost: secondaryHost,
        fallbackRaw: fallbackRaw,
        size: 14,
        cornerRadius: 3
      )
    case .monogram(let text, let backgroundHex, let foregroundHex):
      fallbackMonogram(text, backgroundHex: backgroundHex, foregroundHex: foregroundHex)
    case .none:
      Color.clear
    }
  }

  private func fallbackMonogram(
    _ text: String,
    backgroundHex: String = "111111",
    foregroundHex: String = "FFFFFF"
  ) -> some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(Color(hex: backgroundHex))
      .overlay {
        Text(text)
          .font(.custom("Figtree-Bold", size: 8))
          .foregroundStyle(Color(hex: foregroundHex))
      }
  }
}

private func sankeyRibbonPath(
  flow: WeeklySankeyFlow,
  curveTensionOverride: CGFloat?,
  scale: WeeklySankeyScale
) -> Path {
  let curve = max(90, (flow.x1 - flow.x0) * (curveTensionOverride ?? flow.curveTension))
  var path = Path()
  path.move(to: scale.point(x: flow.x0, y: flow.y0Top))
  path.addCurve(
    to: scale.point(x: flow.x1, y: flow.y1Top),
    control1: scale.point(x: flow.x0 + curve, y: flow.y0Top),
    control2: scale.point(x: flow.x1 - curve, y: flow.y1Top)
  )
  path.addLine(to: scale.point(x: flow.x1, y: flow.y1Bottom))
  path.addCurve(
    to: scale.point(x: flow.x0, y: flow.y0Bottom),
    control1: scale.point(x: flow.x1 - curve, y: flow.y1Bottom),
    control2: scale.point(x: flow.x0 + curve, y: flow.y0Bottom)
  )
  path.closeSubpath()
  return path
}

private func sankeyColumnUnderlayPath(
  x0: CGFloat,
  y0Top: CGFloat,
  y0Bottom: CGFloat,
  x1: CGFloat,
  y1Top: CGFloat,
  y1Bottom: CGFloat,
  tension: CGFloat,
  scale: WeeklySankeyScale
) -> Path {
  let curve = max(90, (x1 - x0) * tension)
  var path = Path()
  path.move(to: scale.point(x: x0, y: y0Top))
  path.addCurve(
    to: scale.point(x: x1, y: y1Top),
    control1: scale.point(x: x0 + curve, y: y0Top),
    control2: scale.point(x: x1 - curve, y: y1Top)
  )
  path.addLine(to: scale.point(x: x1, y: y1Bottom))
  path.addCurve(
    to: scale.point(x: x0, y: y0Bottom),
    control1: scale.point(x: x1 - curve, y: y1Bottom),
    control2: scale.point(x: x0 + curve, y: y0Bottom)
  )
  path.closeSubpath()
  return path
}
