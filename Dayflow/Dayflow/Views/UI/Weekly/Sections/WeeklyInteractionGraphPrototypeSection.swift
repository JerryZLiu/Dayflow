import AppKit
import SwiftUI

struct WeeklyInteractionGraphPrototypeSection: View {
  let snapshot: WeeklyInteractionGraphSnapshot

  enum Design {
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

  var layout: WeeklyInteractionGraphLayout {
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

  func graphLayer(layout: WeeklyInteractionGraphLayout) -> some View {
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

  func edgeSort(
    lhs: WeeklyInteractionGraphEdgeLayout,
    rhs: WeeklyInteractionGraphEdgeLayout
  ) -> Bool {
    if lhs.zIndex == rhs.zIndex {
      return lhs.id < rhs.id
    }
    return lhs.zIndex < rhs.zIndex
  }
}
