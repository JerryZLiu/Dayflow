import SwiftUI

enum WeeklyTreemapAggregation {
  static let minimumLeafWidth: CGFloat = 44
  static let minimumLeafHeight: CGFloat = 28
  static let minimumLeafArea: CGFloat = 1600

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

  static func mergeSmallestLeafIntoOther(_ apps: [WeeklyTreemapApp]) -> [WeeklyTreemapApp] {
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

struct TreemapPlacement<Item: Identifiable>: Identifiable {
  let item: Item
  let frame: CGRect

  var id: Item.ID { item.id }
}

enum SquarifiedTreemapLayout {
  struct RawPlacement<Item> {
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

  static func squarify<Item>(
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

  static func worstAspectRatio(
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
