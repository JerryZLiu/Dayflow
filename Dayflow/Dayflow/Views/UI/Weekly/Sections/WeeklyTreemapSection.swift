import SwiftUI

let weeklyTreemapContentCoordinateSpace = "weekly-treemap-content"

struct WeeklyTreemapSection: View {
  let snapshot: WeeklyTreemapSnapshot
  @State var hoveredLeaf: WeeklyTreemapHoverState?

  enum Design {
    static let sectionSize = CGSize(width: 958, height: 549)
    static let cornerRadius: CGFloat = 4
    static let borderColor = Color(hex: "EBE6E3")
    static let background = Color.white.opacity(0.6)
    static let titleOrigin = CGPoint(x: 40, y: 34)
    static let contentOrigin = CGPoint(x: 77, y: 86)
    static let contentSize = CGSize(width: 797, height: 400)
    static let categoryGap: CGFloat = 6
    static let hoverCardSize = CGSize(width: 176, height: 92)
    static let hoverCardGap: CGFloat = 10
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Design.background)

      Text(snapshot.title)
        .font(.custom("InstrumentSerif-Regular", size: 20))
        .foregroundStyle(Color(hex: "B46531"))
        .offset(x: Design.titleOrigin.x, y: Design.titleOrigin.y)

      contentLayer
        .frame(width: Design.contentSize.width, height: Design.contentSize.height)
        .offset(x: Design.contentOrigin.x, y: Design.contentOrigin.y)
    }
    .frame(width: Design.sectionSize.width, height: Design.sectionSize.height)
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(Design.borderColor, lineWidth: 1)
    )
  }

  var contentLayer: some View {
    GeometryReader { proxy in
      let placements = SquarifiedTreemapLayout.place(
        snapshot.categories,
        value: { $0.weight },
        order: WeeklyTreemapCategory.displayOrder,
        in: CGRect(origin: .zero, size: proxy.size),
        gap: Design.categoryGap
      )

      ZStack(alignment: .topLeading) {
        ForEach(placements) { placement in
          WeeklyTreemapCategoryCard(
            category: placement.item,
            onLeafHover: { state in
              withAnimation(.easeOut(duration: 0.14)) {
                hoveredLeaf = state
              }
            }
          )
          .frame(width: placement.frame.width, height: placement.frame.height)
          .offset(x: placement.frame.minX, y: placement.frame.minY)
        }

        if let hoveredLeaf {
          WeeklyTreemapHoverCard(
            app: hoveredLeaf.app,
            palette: hoveredLeaf.palette
          )
          .frame(width: Design.hoverCardSize.width, height: Design.hoverCardSize.height)
          .offset(
            x: hoverCardOrigin(for: hoveredLeaf.frame, in: proxy.size).x,
            y: hoverCardOrigin(for: hoveredLeaf.frame, in: proxy.size).y
          )
          .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center)))
          .zIndex(10)
          .allowsHitTesting(false)
        }
      }
      .coordinateSpace(name: weeklyTreemapContentCoordinateSpace)
    }
  }

  func hoverCardOrigin(for frame: CGRect, in size: CGSize) -> CGPoint {
    let cardWidth = Design.hoverCardSize.width
    let cardHeight = Design.hoverCardSize.height

    let centeredX = frame.midX - (cardWidth / 2)
    let x = min(max(centeredX, 0), size.width - cardWidth)

    let preferredAboveY = frame.minY - cardHeight - Design.hoverCardGap
    if preferredAboveY >= 0 {
      return CGPoint(x: x, y: preferredAboveY)
    }

    let belowY = frame.maxY + Design.hoverCardGap
    let clampedBelowY = min(belowY, size.height - cardHeight)
    return CGPoint(x: x, y: max(clampedBelowY, 0))
  }
}
