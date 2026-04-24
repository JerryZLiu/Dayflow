import SwiftUI

extension WeeklySankeyFixture {
  static func live(
    cards: [TimelineCard],
    categories: [TimelineCategory],
    weekRange: WeeklyDateRange,
    geometry: WeeklySankeyFixture
  ) -> WeeklySankeyFixture {
    let orderedCategories =
      categories
      .sorted { $0.order < $1.order }
      .filter { !$0.isSystem }
    let categoryLookup = firstCategoryLookup(
      from: orderedCategories,
      normalizedKey: normalizedCategoryKey
    )
    let visibleWorkdays = Set(workdayStrings(for: weekRange.weekStart))
    let workweekCards = cards.filter { visibleWorkdays.contains($0.day) }

    var minutesByCategoryID: [String: Int] = [:]
    var categoryByID: [String: WeeklySankeyCategoryBucket] = [:]
    var minutesByAppID: [String: Int] = [:]
    var appByID: [String: WeeklySankeyAppBucket] = [:]
    var minutesByCategoryAppKey: [String: Int] = [:]

    for card in workweekCards {
      let categoryID = normalizedCategoryKey(displayName(for: card.category))
      guard categoryID != "system" else {
        continue
      }

      let minutes = totalMinutes(for: card)
      guard minutes > 0 else {
        continue
      }

      let categoryBucket = resolvedCategoryBucket(
        id: categoryID,
        card: card,
        categories: categoryLookup
      )
      minutesByCategoryID[categoryID, default: 0] += minutes
      categoryByID[categoryID] = categoryBucket

      let appBucket =
        resolvedAppBucket(
          primaryRaw: card.appSites?.primary,
          secondaryRaw: card.appSites?.secondary
        )
        ?? otherAppBucket()

      minutesByAppID[appBucket.id, default: 0] += minutes
      if appByID[appBucket.id] == nil {
        appByID[appBucket.id] = appBucket
      }

      let categoryAppKey = sourceTargetKey(source: categoryID, target: appBucket.id)
      minutesByCategoryAppKey[categoryAppKey, default: 0] += minutes
    }

    let totalMinutes = minutesByCategoryID.values.reduce(0, +)
    guard totalMinutes > 0 else {
      return WeeklySankeyFixture(
        columns: geometry.columns,
        nodes: [],
        links: [],
        contents: []
      )
    }

    let categoryBuckets: [WeeklySankeyCategoryBucket] = minutesByCategoryID.compactMap { entry in
      let (categoryID, minutes) = entry

      guard let bucket = categoryByID[categoryID] else {
        return nil
      }

      return WeeklySankeyCategoryBucket(
        id: bucket.id,
        title: bucket.title,
        colorHex: bucket.colorHex,
        totalMinutes: minutes,
        order: bucket.order
      )
    }
    .sorted { lhs, rhs in
      if lhs.order != rhs.order {
        return lhs.order < rhs.order
      }
      if lhs.totalMinutes != rhs.totalMinutes {
        return lhs.totalMinutes > rhs.totalMinutes
      }
      return lhs.title < rhs.title
    }

    let appBuckets: [WeeklySankeyAppBucket] = minutesByAppID.compactMap { entry in
      let (appID, minutes) = entry

      guard let bucket = appByID[appID] else {
        return nil
      }

      return WeeklySankeyAppBucket(
        id: bucket.id,
        title: bucket.title,
        colorHex: bucket.colorHex,
        iconSource: bucket.iconSource,
        raw: bucket.raw,
        host: bucket.host,
        totalMinutes: minutes
      )
    }
    .sorted { lhs, rhs in
      if lhs.totalMinutes != rhs.totalMinutes {
        return lhs.totalMinutes > rhs.totalMinutes
      }
      return lhs.title < rhs.title
    }

    let sourceID = "source-week"
    let columns = liveColumns(totalMinutes: totalMinutes, geometry: geometry)
    let categoryNodes = categoryBuckets.enumerated().map { index, bucket in
      SankeyNodeSpec(
        id: bucket.id,
        columnID: "categories",
        order: index,
        visualWeight: CGFloat(bucket.totalMinutes),
        preferredHeight: max(CGFloat(bucket.totalMinutes) * columns.categoryPointsPerMinute, 14),
        gapBefore: index == 0 ? 0 : 24
      )
    }
    let appNodes = appBuckets.enumerated().map { index, bucket in
      SankeyNodeSpec(
        id: bucket.id,
        columnID: "apps",
        order: index,
        visualWeight: CGFloat(bucket.totalMinutes),
        preferredHeight: max(CGFloat(bucket.totalMinutes) * columns.appPointsPerMinute, 8),
        gapBefore: index == 0 ? 0 : 20
      )
    }

    let sourceNode = SankeyNodeSpec(
      id: sourceID,
      columnID: "source",
      order: 0,
      visualWeight: CGFloat(totalMinutes),
      preferredHeight: 300
    )

    let appOrderByID: [String: Int] = Dictionary(
      uniqueKeysWithValues: appBuckets.enumerated().map { ($1.id, $0) }
    )
    let sourceContent = WeeklySankeyNodeContent(
      id: sourceID,
      title: weekRange == WeeklyDateRange.containing(Date()) ? "This Week" : "Week Total",
      durationText: formattedDuration(minutes: totalMinutes),
      shareText: "100%",
      barColorHex: "D9CBC0",
      labelKind: .plain
    )
    let categoryContents = categoryBuckets.map { bucket in
      WeeklySankeyNodeContent(
        id: bucket.id,
        title: bucket.title,
        durationText: formattedDuration(minutes: bucket.totalMinutes),
        shareText: shareText(minutes: bucket.totalMinutes, totalMinutes: totalMinutes),
        barColorHex: bucket.colorHex,
        labelKind: .plain
      )
    }
    let appContents = appBuckets.map { bucket in
      WeeklySankeyNodeContent(
        id: bucket.id,
        title: bucket.title,
        durationText: formattedDuration(minutes: bucket.totalMinutes),
        shareText: shareText(minutes: bucket.totalMinutes, totalMinutes: totalMinutes),
        barColorHex: bucket.colorHex,
        labelKind: .app(bucket.iconSource)
      )
    }
    let contents: [WeeklySankeyNodeContent] = [sourceContent] + categoryContents + appContents
    let contentsByID: [String: WeeklySankeyNodeContent] = Dictionary(
      uniqueKeysWithValues: contents.map { ($0.id, $0) }
    )

    let sourceLinks = categoryBuckets.enumerated().map { index, bucket in
      dynamicSourceLink(
        id: "live-left-\(bucket.id)",
        sourceNodeID: sourceID,
        targetNodeID: bucket.id,
        value: CGFloat(bucket.totalMinutes),
        sourceOrder: index,
        opacity: sourceOpacity(for: bucket.totalMinutes, totalMinutes: totalMinutes),
        targetColorHex: bucket.colorHex
      )
    }

    var appLinks: [SankeyLinkSpec] = []
    for categoryBucket in categoryBuckets {
      let categoryTargets =
        appBuckets
        .filter { bucket in
          minutesByCategoryAppKey[
            sourceTargetKey(source: categoryBucket.id, target: bucket.id), default: 0] > 0
        }
        .sorted { lhs, rhs in
          let lhsValue =
            minutesByCategoryAppKey[
              sourceTargetKey(source: categoryBucket.id, target: lhs.id), default: 0]
          let rhsValue =
            minutesByCategoryAppKey[
              sourceTargetKey(source: categoryBucket.id, target: rhs.id), default: 0]

          if lhsValue != rhsValue {
            return lhsValue > rhsValue
          }

          return appOrderByID[lhs.id, default: Int.max] < appOrderByID[rhs.id, default: Int.max]
        }

      for (sourceOrder, appBucket) in categoryTargets.enumerated() {
        let key = sourceTargetKey(source: categoryBucket.id, target: appBucket.id)
        let minutes = minutesByCategoryAppKey[key, default: 0]
        guard minutes > 0 else {
          continue
        }

        appLinks.append(
          dynamicAppLink(
            id: "live-\(categoryBucket.id)-\(appBucket.id)",
            source: categoryBucket.id,
            target: appBucket.id,
            value: CGFloat(minutes),
            sourceOrder: sourceOrder,
            targetOrder: appOrderByID[appBucket.id, default: 0],
            opacity: appOpacity(minutes: minutes, totalMinutes: totalMinutes),
            contentsByID: contentsByID
          )
        )
      }
    }

    return WeeklySankeyFixture(
      columns: columns.columns,
      nodes: [sourceNode] + categoryNodes + appNodes,
      links: sourceLinks + appLinks,
      contents: contents
    )
  }

  static func sourceLink(
    id: String,
    target: String,
    value: CGFloat,
    order: Int,
    opacity: Double
  ) -> SankeyLinkSpec {
    let center = CGFloat(3)
    let spread = CGFloat(order) - center

    return SankeyLinkSpec(
      id: id,
      sourceNodeID: "source-communication",
      targetNodeID: target,
      value: value,
      sourceOrder: order,
      targetOrder: 0,
      style: SankeyRibbonStyle(
        leadingColor: sourceBlendNeutral,
        trailingColor: categoryRibbonColor(for: target),
        opacity: opacity,
        zIndex: Double(order),
        leadingControlFactor: 0.26,
        trailingControlFactor: 0.34,
        topStartBend: spread * 6,
        topEndBend: spread * 2,
        bottomStartBend: spread * 6,
        bottomEndBend: spread * 2
      )
    )
  }

  static func appLink(
    id: String,
    source: String,
    target: String,
    value: CGFloat,
    sourceOrder: Int,
    targetOrder: Int,
    opacity: Double
  ) -> SankeyLinkSpec {
    let slope = CGFloat(targetOrder - sourceOrder)

    return SankeyLinkSpec(
      id: id,
      sourceNodeID: source,
      targetNodeID: target,
      value: value,
      sourceOrder: sourceOrder,
      targetOrder: targetOrder,
      style: SankeyRibbonStyle(
        leadingColor: categoryRibbonColor(for: source),
        trailingColor: appRibbonColor(for: target),
        opacity: opacity,
        zIndex: 100 + Double(targetOrder * 10 + sourceOrder),
        leadingControlFactor: 0.3,
        trailingControlFactor: 0.3,
        topStartBend: slope * 1.5,
        topEndBend: slope * 4,
        bottomStartBend: slope * 1.5,
        bottomEndBend: slope * 4
      )
    )
  }

}
