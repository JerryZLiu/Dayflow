import SwiftUI

private let weeklyTreemapContentCoordinateSpace = "weekly-treemap-content"

struct WeeklyTreemapSection: View {
  let snapshot: WeeklyTreemapSnapshot
  @State private var hoveredLeaf: WeeklyTreemapHoverState?

  private enum Design {
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

  private var contentLayer: some View {
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

  private func hoverCardOrigin(for frame: CGRect, in size: CGSize) -> CGPoint {
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

private struct WeeklyTreemapCategoryCard: View {
  let category: WeeklyTreemapCategory
  let onLeafHover: (WeeklyTreemapHoverState?) -> Void

  private enum Design {
    static let cornerRadius: CGFloat = 4
    static let tileGap: CGFloat = 4
    static let horizontalPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 8
    static let headerHorizontalPadding: CGFloat = 10
    static let headerTopPadding: CGFloat = 8
    static let headerBottomPadding: CGFloat = 8
    static let minimumContentHeight: CGFloat = 36
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(category.palette.shellFill)
        .overlay(
          RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
            .stroke(category.palette.shellBorder, lineWidth: 1)
        )

      VStack(spacing: 0) {
        WeeklyTreemapCategoryHeader(category: category)
          .padding(.horizontal, Design.headerHorizontalPadding)
          .padding(.top, Design.headerTopPadding)
          .padding(.bottom, Design.headerBottomPadding)

        GeometryReader { proxy in
          let contentRect = CGRect(origin: .zero, size: proxy.size)
          let displayApps = WeeklyTreemapAggregation.appsForDisplay(
            category.apps,
            in: contentRect,
            gap: Design.tileGap
          )
          let placements = SquarifiedTreemapLayout.place(
            displayApps,
            value: { $0.weight },
            order: WeeklyTreemapApp.displayOrder,
            in: contentRect,
            gap: Design.tileGap
          )

          ZStack(alignment: .topLeading) {
            ForEach(placements) { placement in
              WeeklyTreemapLeafTile(
                app: placement.item,
                palette: category.palette,
                onHoverChanged: onLeafHover
              )
              .frame(width: placement.frame.width, height: placement.frame.height)
              .offset(x: placement.frame.minX, y: placement.frame.minY)
            }
          }
        }
        .padding(.horizontal, Design.horizontalPadding)
        .padding(.bottom, Design.bottomPadding)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
  }
}

private struct WeeklyTreemapCategoryHeader: View {
  let category: WeeklyTreemapCategory

  var body: some View {
    ViewThatFits {
      HStack(spacing: 8) {
        titleText
        Spacer(minLength: 8)
        durationText
      }

      VStack(alignment: .leading, spacing: 0) {
        titleText
        durationText
      }

      titleText
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var titleText: some View {
    Text(category.name)
      .font(.custom("Nunito-Regular", size: 12))
      .foregroundStyle(category.palette.headerText)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
  }

  private var durationText: some View {
    Text(category.formattedDuration)
      .font(.custom("Nunito-Regular", size: 12))
      .foregroundStyle(category.palette.headerText)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
  }
}

private struct WeeklyTreemapLeafTile: View {
  let app: WeeklyTreemapApp
  let palette: WeeklyTreemapPalette
  let onHoverChanged: (WeeklyTreemapHoverState?) -> Void

  private enum Design {
    static let cornerRadius: CGFloat = 4
  }

  var body: some View {
    GeometryReader { proxy in
      let typography = WeeklyTreemapLeafTypography.resolve(for: proxy.size)
      let presentationMode = WeeklyTreemapLeafPresentationMode.resolve(
        for: proxy.size,
        hasChange: app.change != nil
      )

      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(palette.tileFill)
        .overlay(
          RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
            .stroke(palette.tileBorder, lineWidth: 1)
        )
        .overlay {
          if app.isPlaceholder {
            EmptyView()
          } else {
            tileContent(using: typography, presentationMode: presentationMode)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding(typography.padding)
          }
        }
        .overlay {
          EmptyView()
        }
        .contentShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
        .onHover { isHovering in
          guard presentationMode != .full, !app.isPlaceholder else {
            if !isHovering {
              onHoverChanged(nil)
            }
            return
          }

          if isHovering {
            onHoverChanged(
              WeeklyTreemapHoverState(
                app: app,
                palette: palette,
                frame: proxy.frame(in: .named(weeklyTreemapContentCoordinateSpace))
              )
            )
          } else {
            onHoverChanged(nil)
          }
        }
    }
  }

  private func fullContent(using typography: WeeklyTreemapLeafTypography) -> some View {
    VStack(spacing: typography.lineSpacing) {
      nameText(fontSize: typography.nameFontSize)

      Text(app.formattedDuration)
        .font(.custom("Nunito-Regular", size: typography.detailFontSize))
        .foregroundStyle(Color(hex: "333333"))
        .lineLimit(1)
        .minimumScaleFactor(0.85)

      if let change = app.change {
        Text(change.text)
          .font(.custom("SpaceMono-Regular", size: typography.deltaFontSize))
          .foregroundStyle(change.color)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
    }
  }

  private func compactContent(using typography: WeeklyTreemapLeafTypography) -> some View {
    VStack(spacing: max(typography.lineSpacing - 1, 1)) {
      nameText(fontSize: max(typography.nameFontSize - 2, 11))

      Text(app.formattedDuration)
        .font(.custom("Nunito-Regular", size: max(typography.detailFontSize - 1, 10)))
        .foregroundStyle(Color(hex: "333333"))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
  }

  private func labelOnlyContent(using typography: WeeklyTreemapLeafTypography) -> some View {
    nameText(fontSize: max(typography.nameFontSize - 3, 10))
  }

  @ViewBuilder
  private func tileContent(
    using typography: WeeklyTreemapLeafTypography,
    presentationMode: WeeklyTreemapLeafPresentationMode
  ) -> some View {
    switch presentationMode {
    case .full:
      fullContent(using: typography)
    case .compact:
      compactContent(using: typography)
    case .labelOnly:
      labelOnlyContent(using: typography)
    }
  }

  private func nameText(fontSize: CGFloat) -> some View {
    Text(app.name)
      .font(.custom("InstrumentSerif-Regular", size: fontSize))
      .foregroundStyle(Color.black)
      .multilineTextAlignment(.center)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
  }
}

private struct WeeklyTreemapHoverCard: View {
  let app: WeeklyTreemapApp
  let palette: WeeklyTreemapPalette

  private enum Design {
    static let cornerRadius: CGFloat = 6
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(app.name)
        .font(.custom("InstrumentSerif-Regular", size: 17))
        .foregroundStyle(Color.black)
        .lineLimit(1)

      Text(app.formattedDuration)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "333333"))
        .lineLimit(1)

      if let change = app.change {
        Text(change.text)
          .font(.custom("SpaceMono-Regular", size: 12))
          .foregroundStyle(change.color)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Color.white.opacity(0.96))
        .overlay(
          RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
            .fill(palette.shellFill.opacity(0.85))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(palette.shellBorder.opacity(0.95), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 6)
  }
}

private struct WeeklyTreemapHoverState {
  let app: WeeklyTreemapApp
  let palette: WeeklyTreemapPalette
  let frame: CGRect
}

private enum WeeklyTreemapLeafTypography {
  case large
  case medium
  case compact

  var nameFontSize: CGFloat {
    switch self {
    case .large:
      return 20
    case .medium:
      return 16
    case .compact:
      return 13
    }
  }

  var detailFontSize: CGFloat {
    switch self {
    case .large, .medium:
      return 12
    case .compact:
      return 10
    }
  }

  var deltaFontSize: CGFloat {
    switch self {
    case .large, .medium:
      return 12
    case .compact:
      return 10
    }
  }

  var lineSpacing: CGFloat {
    switch self {
    case .large:
      return 4
    case .medium:
      return 3
    case .compact:
      return 2
    }
  }

  var padding: CGFloat {
    switch self {
    case .large:
      return 12
    case .medium:
      return 10
    case .compact:
      return 6
    }
  }

  static func resolve(for size: CGSize) -> WeeklyTreemapLeafTypography {
    if size.width >= 160, size.height >= 110 {
      return .large
    }

    if size.width >= 90, size.height >= 54 {
      return .medium
    }

    return .compact
  }
}

private enum WeeklyTreemapLeafPresentationMode {
  case full
  case compact
  case labelOnly

  static func resolve(for size: CGSize, hasChange: Bool) -> WeeklyTreemapLeafPresentationMode {
    let fullHeight: CGFloat = hasChange ? 72 : 56
    if size.width >= 90, size.height >= fullHeight {
      return .full
    }

    if size.width >= 58, size.height >= 34 {
      return .compact
    }

    return .labelOnly
  }
}

private enum WeeklyTreemapAggregation {
  private static let minimumLeafWidth: CGFloat = 44
  private static let minimumLeafHeight: CGFloat = 28
  private static let minimumLeafArea: CGFloat = 1600

  static func appsForDisplay(
    _ apps: [WeeklyTreemapApp],
    in rect: CGRect,
    gap: CGFloat
  ) -> [WeeklyTreemapApp] {
    var working = apps.sorted(by: WeeklyTreemapApp.displayOrder)

    while working.count > 1 {
      let placements = SquarifiedTreemapLayout.place(
        working,
        value: { $0.weight },
        order: WeeklyTreemapApp.displayOrder,
        in: rect,
        gap: gap
      )

      let hasUnreadableLeaf = placements.contains { placement in
        guard !placement.item.isAggregate else { return false }
        return placement.frame.width < minimumLeafWidth
          || placement.frame.height < minimumLeafHeight
          || placement.frame.area < minimumLeafArea
      }

      guard hasUnreadableLeaf else { break }
      working = mergeSmallestLeafIntoOther(working)
    }

    return working
  }

  private static func mergeSmallestLeafIntoOther(_ apps: [WeeklyTreemapApp]) -> [WeeklyTreemapApp] {
    guard let candidate = apps.reversed().first(where: { !$0.isAggregate }) else {
      return apps
    }

    var remaining = apps.filter { $0.id != candidate.id }

    if let index = remaining.firstIndex(where: \.isAggregate) {
      remaining[index] = remaining[index].merging(candidate)
    } else {
      remaining.append(.aggregate(containing: [candidate]))
    }

    return remaining.sorted(by: WeeklyTreemapApp.displayOrder)
  }
}

private struct TreemapPlacement<Item: Identifiable>: Identifiable {
  let item: Item
  let frame: CGRect

  var id: Item.ID { item.id }
}

private enum SquarifiedTreemapLayout {
  private struct RawPlacement<Item> {
    let item: Item
    let frame: CGRect
  }

  static func place<Item: Identifiable>(
    _ items: [Item],
    value: (Item) -> CGFloat,
    order: (Item, Item) -> Bool,
    in rect: CGRect,
    gap: CGFloat
  ) -> [TreemapPlacement<Item>] {
    let visibleItems = items.filter { value($0) > 0 }
    guard !visibleItems.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

    let orderedItems = visibleItems.sorted(by: order)
    let totalValue = orderedItems.reduce(CGFloat(0)) { partial, item in
      partial + value(item)
    }
    guard totalValue > 0 else { return [] }

    let totalArea = rect.area
    let scaledItems: [(Item, CGFloat)] = orderedItems.map { item in
      (item, (value(item) / totalValue) * totalArea)
    }

    return squarify(scaledItems, in: rect).compactMap { placement in
      let insetFrame = placement.frame.insetBy(dx: gap / 2, dy: gap / 2)
      guard insetFrame.width > 0, insetFrame.height > 0 else { return nil }
      return TreemapPlacement(item: placement.item, frame: insetFrame)
    }
  }

  private static func squarify<Item>(
    _ items: [(Item, CGFloat)],
    in rect: CGRect
  ) -> [RawPlacement<Item>] {
    guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
    if items.count == 1 {
      return [RawPlacement(item: items[0].0, frame: rect)]
    }

    var remaining = items
    var availableRect = rect
    var placements: [RawPlacement<Item>] = []

    while !remaining.isEmpty, availableRect.width > 0, availableRect.height > 0 {
      let shortSide = min(availableRect.width, availableRect.height)

      var row: [(Item, CGFloat)] = []
      var rowArea: CGFloat = 0
      var bestWorstAspect = CGFloat.infinity

      for item in remaining {
        let candidateRow = row + [item]
        let candidateArea = rowArea + item.1
        let candidateWorstAspect = worstAspectRatio(
          for: candidateRow.map(\.1),
          totalArea: candidateArea,
          shortSide: shortSide
        )

        if row.isEmpty || candidateWorstAspect <= bestWorstAspect {
          row = candidateRow
          rowArea = candidateArea
          bestWorstAspect = candidateWorstAspect
        } else {
          break
        }
      }

      let stripLength = rowArea / shortSide
      let laysOutVertically = availableRect.width >= availableRect.height

      var offset: CGFloat = 0
      for (item, area) in row {
        let span = stripLength > 0 ? area / stripLength : 0
        let childRect: CGRect

        if laysOutVertically {
          childRect = CGRect(
            x: availableRect.minX,
            y: availableRect.minY + offset,
            width: stripLength,
            height: span
          )
        } else {
          childRect = CGRect(
            x: availableRect.minX + offset,
            y: availableRect.minY,
            width: span,
            height: stripLength
          )
        }

        placements.append(RawPlacement(item: item, frame: childRect))
        offset += span
      }

      if laysOutVertically {
        availableRect = CGRect(
          x: availableRect.minX + stripLength,
          y: availableRect.minY,
          width: availableRect.width - stripLength,
          height: availableRect.height
        )
      } else {
        availableRect = CGRect(
          x: availableRect.minX,
          y: availableRect.minY + stripLength,
          width: availableRect.width,
          height: availableRect.height - stripLength
        )
      }

      remaining.removeFirst(row.count)
    }

    return placements
  }

  private static func worstAspectRatio(
    for areas: [CGFloat],
    totalArea: CGFloat,
    shortSide: CGFloat
  ) -> CGFloat {
    let stripLength = totalArea / shortSide
    guard stripLength > 0 else { return .infinity }

    var worst: CGFloat = 0
    for area in areas {
      let span = area / stripLength
      guard span > 0 else { continue }
      worst = max(worst, max(stripLength / span, span / stripLength))
    }

    return worst
  }
}

struct WeeklyTreemapSnapshot {
  let title: String
  let categories: [WeeklyTreemapCategory]

  static let figmaPreview = WeeklyTreemapSnapshot(
    title: "Most used per category",
    categories: [
      WeeklyTreemapCategory(
        id: "design",
        name: "Design",
        palette: .design,
        apps: [
          WeeklyTreemapApp(
            id: "figma",
            name: "Figma",
            duration: 18 * 3600 + 24 * 60,
            change: .positive(45)
          ),
          WeeklyTreemapApp(
            id: "midjourney",
            name: "Midjourney",
            duration: 6 * 3600 + 7 * 60,
            change: .negative(45)
          ),
        ]
      ),
      WeeklyTreemapCategory(
        id: "communication",
        name: "Communication",
        palette: .communication,
        apps: [
          WeeklyTreemapApp(
            id: "zoom",
            name: "Zoom",
            duration: 18 * 3600 + 24 * 60,
            change: .neutral(2)
          ),
          WeeklyTreemapApp(
            id: "slack",
            name: "Slack",
            duration: 5 * 3600 + 24 * 60,
            change: .negative(45)
          ),
          WeeklyTreemapApp(
            id: "clickup",
            name: "ClickUp",
            duration: 24 * 60,
            change: .neutral(2)
          ),
        ]
      ),
      WeeklyTreemapCategory(
        id: "testing",
        name: "Testing",
        palette: .testing,
        apps: [
          WeeklyTreemapApp(
            id: "dayflow",
            name: "Dayflow",
            duration: 5 * 3600 + 24 * 60,
            change: .positive(45)
          ),
          WeeklyTreemapApp(
            id: "testing-clickup",
            name: "ClickUp",
            duration: 4 * 3600 + 24 * 60,
            change: .negative(45)
          ),
          WeeklyTreemapApp(
            id: "testing-slack",
            name: "Slack",
            duration: 3 * 3600 + 24 * 60,
            change: .positive(45)
          ),
        ]
      ),
      WeeklyTreemapCategory(
        id: "research",
        name: "Research",
        palette: .research,
        apps: [
          WeeklyTreemapApp(
            id: "chatgpt",
            name: "ChatGPT",
            duration: 4 * 3600 + 24 * 60,
            change: .neutral(2)
          ),
          WeeklyTreemapApp(
            id: "google",
            name: "Google",
            duration: 3 * 3600 + 24 * 60,
            change: .neutral(2)
          ),
          WeeklyTreemapApp(
            id: "claude",
            name: "Claude",
            duration: 2 * 3600 + 24 * 60,
            change: .negative(45)
          ),
        ]
      ),
    ]
  )

  static let dominantCategoryPreview = WeeklyTreemapSnapshot(
    title: "Most used per category",
    categories: [
      WeeklyTreemapCategory(
        id: "design",
        name: "Design",
        palette: .design,
        apps: [
          WeeklyTreemapApp(
            id: "figma", name: "Figma", duration: hours(31, 20), change: .positive(62)),
          WeeklyTreemapApp(
            id: "framer", name: "Framer", duration: hours(7, 40), change: .negative(18)),
          WeeklyTreemapApp(
            id: "after-effects", name: "After Effects", duration: hours(1, 10), change: .neutral(4)),
          WeeklyTreemapApp(
            id: "coolors", name: "Coolors", duration: hours(0, 18), change: .positive(6)),
          WeeklyTreemapApp(
            id: "fonts", name: "Adobe Fonts", duration: hours(0, 11), change: .negative(2)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "communication",
        name: "Communication",
        palette: .communication,
        apps: [
          WeeklyTreemapApp(id: "zoom", name: "Zoom", duration: hours(4, 5), change: .negative(12)),
          WeeklyTreemapApp(
            id: "slack", name: "Slack", duration: hours(1, 35), change: .positive(8)),
          WeeklyTreemapApp(id: "meet", name: "Meet", duration: hours(0, 42), change: .neutral(0)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "testing",
        name: "Testing",
        palette: .testing,
        apps: [
          WeeklyTreemapApp(
            id: "dayflow", name: "Dayflow", duration: hours(2, 24), change: .positive(24)),
          WeeklyTreemapApp(
            id: "clickup", name: "ClickUp", duration: hours(0, 53), change: .negative(9)),
          WeeklyTreemapApp(
            id: "posthog", name: "PostHog", duration: hours(0, 21), change: .neutral(1)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "research",
        name: "Research",
        palette: .research,
        apps: [
          WeeklyTreemapApp(
            id: "chatgpt", name: "ChatGPT", duration: hours(1, 46), change: .positive(14)),
          WeeklyTreemapApp(
            id: "claude", name: "Claude", duration: hours(0, 44), change: .negative(5)),
          WeeklyTreemapApp(
            id: "google", name: "Google", duration: hours(0, 28), change: .neutral(2)),
        ]
      ),
    ]
  )

  static let tinyTailPreview = WeeklyTreemapSnapshot(
    title: "Most used per category",
    categories: [
      WeeklyTreemapCategory(
        id: "research",
        name: "Research",
        palette: .research,
        apps: [
          WeeklyTreemapApp(
            id: "chatgpt", name: "ChatGPT", duration: hours(6, 12), change: .positive(22)),
          WeeklyTreemapApp(
            id: "google", name: "Google", duration: hours(2, 54), change: .neutral(3)),
          WeeklyTreemapApp(
            id: "claude", name: "Claude", duration: hours(1, 47), change: .negative(11)),
          WeeklyTreemapApp(
            id: "perplexity", name: "Perplexity", duration: hours(0, 34), change: .positive(7)),
          WeeklyTreemapApp(
            id: "wiki", name: "Wikipedia", duration: hours(0, 18), change: .neutral(2)),
          WeeklyTreemapApp(id: "docs", name: "Docs", duration: hours(0, 15), change: .negative(1)),
          WeeklyTreemapApp(
            id: "hn", name: "Hacker News", duration: hours(0, 8), change: .neutral(0)),
          WeeklyTreemapApp(
            id: "reddit", name: "Reddit", duration: hours(0, 6), change: .positive(1)),
          WeeklyTreemapApp(
            id: "stack", name: "Stack Overflow", duration: hours(0, 5), change: .neutral(0)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "communication",
        name: "Communication",
        palette: .communication,
        apps: [
          WeeklyTreemapApp(id: "zoom", name: "Zoom", duration: hours(5, 40), change: .neutral(5)),
          WeeklyTreemapApp(
            id: "slack", name: "Slack", duration: hours(4, 26), change: .negative(14)),
          WeeklyTreemapApp(
            id: "linear", name: "Linear", duration: hours(1, 12), change: .positive(12)),
          WeeklyTreemapApp(id: "mail", name: "Mail", duration: hours(0, 29), change: .neutral(2)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "design",
        name: "Design",
        palette: .design,
        apps: [
          WeeklyTreemapApp(
            id: "figma", name: "Figma", duration: hours(7, 30), change: .positive(18)),
          WeeklyTreemapApp(
            id: "midjourney", name: "Midjourney", duration: hours(2, 4), change: .negative(6)),
        ]
      ),
    ]
  )

  static let crowdedPreview = WeeklyTreemapSnapshot(
    title: "Most used per category",
    categories: [
      WeeklyTreemapCategory(
        id: "design",
        name: "Design",
        palette: .design,
        apps: [
          WeeklyTreemapApp(
            id: "figma", name: "Figma", duration: hours(8, 30), change: .positive(14)),
          WeeklyTreemapApp(
            id: "midjourney", name: "Midjourney", duration: hours(6, 10), change: .negative(9)),
          WeeklyTreemapApp(
            id: "framer", name: "Framer", duration: hours(4, 40), change: .positive(6)),
          WeeklyTreemapApp(
            id: "spline", name: "Spline", duration: hours(3, 20), change: .neutral(2)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "communication",
        name: "Communication",
        palette: .communication,
        apps: [
          WeeklyTreemapApp(id: "zoom", name: "Zoom", duration: hours(7, 45), change: .negative(6)),
          WeeklyTreemapApp(
            id: "slack", name: "Slack", duration: hours(6, 55), change: .positive(11)),
          WeeklyTreemapApp(
            id: "discord", name: "Discord", duration: hours(3, 12), change: .neutral(1)),
          WeeklyTreemapApp(id: "mail", name: "Mail", duration: hours(1, 38), change: .negative(3)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "testing",
        name: "Testing",
        palette: .testing,
        apps: [
          WeeklyTreemapApp(
            id: "dayflow", name: "Dayflow", duration: hours(5, 10), change: .positive(17)),
          WeeklyTreemapApp(
            id: "clickup", name: "ClickUp", duration: hours(4, 24), change: .negative(12)),
          WeeklyTreemapApp(id: "slack", name: "Slack", duration: hours(3, 28), change: .neutral(2)),
          WeeklyTreemapApp(
            id: "posthog", name: "PostHog", duration: hours(1, 52), change: .positive(4)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "research",
        name: "Research",
        palette: .research,
        apps: [
          WeeklyTreemapApp(
            id: "chatgpt", name: "ChatGPT", duration: hours(5, 24), change: .positive(8)),
          WeeklyTreemapApp(
            id: "google", name: "Google", duration: hours(4, 42), change: .neutral(3)),
          WeeklyTreemapApp(
            id: "claude", name: "Claude", duration: hours(3, 8), change: .negative(7)),
          WeeklyTreemapApp(
            id: "perplexity", name: "Perplexity", duration: hours(2, 16), change: .positive(5)),
        ]
      ),
    ]
  )

  private static func hours(_ hours: Int, _ minutes: Int) -> TimeInterval {
    TimeInterval((hours * 60 + minutes) * 60)
  }
}

struct WeeklyTreemapCategory: Identifiable {
  let id: String
  let name: String
  let palette: WeeklyTreemapPalette
  let apps: [WeeklyTreemapApp]

  var totalDuration: TimeInterval {
    apps.reduce(0) { partial, app in
      partial + app.duration
    }
  }

  var weight: CGFloat {
    max(CGFloat(totalDuration), 1)
  }

  var formattedDuration: String {
    totalDuration.weeklyTreemapDurationString
  }

  static func displayOrder(_ lhs: WeeklyTreemapCategory, _ rhs: WeeklyTreemapCategory) -> Bool {
    if lhs.weight != rhs.weight {
      return lhs.weight > rhs.weight
    }

    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
  }
}

struct WeeklyTreemapApp: Identifiable {
  let id: String
  let name: String
  let duration: TimeInterval
  let change: WeeklyTreemapChange?
  let isAggregate: Bool
  let isPlaceholder: Bool

  init(
    id: String,
    name: String,
    duration: TimeInterval,
    change: WeeklyTreemapChange?,
    isAggregate: Bool = false,
    isPlaceholder: Bool = false
  ) {
    self.id = id
    self.name = name
    self.duration = duration
    self.change = change
    self.isAggregate = isAggregate
    self.isPlaceholder = isPlaceholder
  }

  var weight: CGFloat {
    max(CGFloat(duration), 1)
  }

  var formattedDuration: String {
    duration.weeklyTreemapDurationString
  }

  static func displayOrder(_ lhs: WeeklyTreemapApp, _ rhs: WeeklyTreemapApp) -> Bool {
    if lhs.weight != rhs.weight {
      return lhs.weight > rhs.weight
    }

    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
  }

  func merging(_ other: WeeklyTreemapApp) -> WeeklyTreemapApp {
    WeeklyTreemapApp(
      id: id,
      name: name,
      duration: duration + other.duration,
      change: nil,
      isAggregate: true,
      isPlaceholder: false
    )
  }

  static func aggregate(containing apps: [WeeklyTreemapApp]) -> WeeklyTreemapApp {
    WeeklyTreemapApp(
      id: "other",
      name: "Other",
      duration: apps.reduce(0) { $0 + $1.duration },
      change: nil,
      isAggregate: true,
      isPlaceholder: false
    )
  }
}

struct WeeklyTreemapChange {
  let text: String
  let color: Color

  static func positive(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "+ \(minutes)m", color: Color(hex: "3AA34C"))
  }

  static func negative(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "- \(minutes)m", color: Color(hex: "DE2121"))
  }

  static func neutral(_ minutes: Int) -> WeeklyTreemapChange {
    WeeklyTreemapChange(text: "\(minutes)m", color: Color(hex: "8D8C8A"))
  }
}

struct WeeklyTreemapPalette {
  let shellFill: Color
  let shellBorder: Color
  let tileFill: Color
  let tileBorder: Color
  let headerText: Color

  static let design = WeeklyTreemapPalette(
    shellFill: Color(hex: "DE9DFC").opacity(0.25),
    shellBorder: Color(hex: "E2A3FF"),
    tileFill: Color(hex: "FAF3FF"),
    tileBorder: Color(hex: "E6B0FF"),
    headerText: Color(hex: "B922FF")
  )

  static let communication = WeeklyTreemapPalette(
    shellFill: Color(hex: "2DBFAE").opacity(0.25),
    shellBorder: Color(hex: "76CCC2"),
    tileFill: Color(hex: "E4F9F7"),
    tileBorder: Color(hex: "B4D2CE"),
    headerText: Color(hex: "00907F")
  )

  static let testing = WeeklyTreemapPalette(
    shellFill: Color(hex: "FC7645").opacity(0.25),
    shellBorder: Color(hex: "F7936F"),
    tileFill: Color(hex: "FFEDE7"),
    tileBorder: Color(hex: "FFB9A1"),
    headerText: Color(hex: "F04407")
  )

  static let research = WeeklyTreemapPalette(
    shellFill: Color(hex: "93BCFF").opacity(0.25),
    shellBorder: Color(hex: "91AEF1"),
    tileFill: Color(hex: "EEF4FF"),
    tileBorder: Color(hex: "B9D4FF"),
    headerText: Color(hex: "2061F5")
  )
}

extension TimeInterval {
  fileprivate var weeklyTreemapDurationString: String {
    let totalMinutes = Int(self / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0, minutes > 0 {
      return "\(hours)hr \(minutes)m"
    }

    if hours > 0 {
      return "\(hours)hr"
    }

    return "\(minutes)m"
  }
}

extension CGRect {
  fileprivate var area: CGFloat {
    width * height
  }
}

#Preview("Weekly Treemap", traits: .fixedLayout(width: 958, height: 549)) {
  WeeklyTreemapPreviewHarness()
    .background(Color(hex: "F7F3F0"))
}

private struct WeeklyTreemapPreviewHarness: View {
  @State private var selectedDataset = WeeklyTreemapPreviewDataset.balanced

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        ForEach(WeeklyTreemapPreviewDataset.allCases) { dataset in
          Button {
            selectedDataset = dataset
          } label: {
            Text(dataset.title)
              .font(.custom("Nunito-Regular", size: 12))
              .foregroundStyle(selectedDataset == dataset ? Color.white : Color(hex: "7C5A46"))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(
                Capsule(style: .continuous)
                  .fill(
                    selectedDataset == dataset ? Color(hex: "B46531") : Color.white.opacity(0.75))
              )
              .overlay(
                Capsule(style: .continuous)
                  .stroke(Color(hex: "E3D6CF"), lineWidth: 1)
              )
          }
          .buttonStyle(.plain)
        }
      }

      WeeklyTreemapSection(snapshot: selectedDataset.snapshot)
    }
    .padding(18)
  }
}

private enum WeeklyTreemapPreviewDataset: String, CaseIterable, Identifiable {
  case balanced
  case dominant
  case tinyTail
  case crowded

  var id: String { rawValue }

  var title: String {
    switch self {
    case .balanced:
      return "Balanced"
    case .dominant:
      return "Dominant"
    case .tinyTail:
      return "Tiny Tail"
    case .crowded:
      return "Crowded"
    }
  }

  var snapshot: WeeklyTreemapSnapshot {
    switch self {
    case .balanced:
      return .figmaPreview
    case .dominant:
      return .dominantCategoryPreview
    case .tinyTail:
      return .tinyTailPreview
    case .crowded:
      return .crowdedPreview
    }
  }
}
