import SwiftUI

extension WeeklySankeyFixture {
  static func makeAirierFixture(from base: WeeklySankeyFixture) -> WeeklySankeyFixture {
    WeeklySankeyFixture(
      columns: base.columns.map { column in
        switch column.id {
        case "source":
          return column.updating(topY: 147)
        case "categories":
          return column.updating(topY: 80, pointsPerUnit: 2.14)
        case "apps":
          return column.updating(topY: 18, pointsPerUnit: 1.22)
        default:
          return column
        }
      },
      nodes: base.nodes.map { node in
        switch node.id {
        case "source-communication":
          return node.updating(preferredHeight: 312)
        case "research":
          return node.updating(preferredHeight: 46)
        case "communication":
          return node.updating(preferredHeight: 40, gapBefore: 24)
        case "design":
          return node.updating(preferredHeight: 84, gapBefore: 24)
        case "general":
          return node.updating(preferredHeight: 36, gapBefore: 24)
        case "testing":
          return node.updating(preferredHeight: 28, gapBefore: 24)
        case "distractions":
          return node.updating(preferredHeight: 32, gapBefore: 24)
        case "personal":
          return node.updating(preferredHeight: 16, gapBefore: 24)
        case "chatgpt":
          return node.updating(preferredHeight: 18)
        case "zoom":
          return node.updating(preferredHeight: 10, gapBefore: 24)
        case "clickup":
          return node.updating(preferredHeight: 7, gapBefore: 24)
        case "slack":
          return node.updating(preferredHeight: 30, gapBefore: 68)
        case "youtube":
          return node.updating(preferredHeight: 16, gapBefore: 44)
        case "claude":
          return node.updating(preferredHeight: 18, gapBefore: 36)
        case "figma":
          return node.updating(preferredHeight: 56, gapBefore: 46)
        case "x":
          return node.updating(preferredHeight: 24, gapBefore: 20)
        case "medium":
          return node.updating(preferredHeight: 8, gapBefore: 20)
        case "other":
          return node.updating(preferredHeight: 18, gapBefore: 20)
        default:
          return node
        }
      },
      links: base.links.map { link in
        link.updatingStyle { style in
          if link.sourceNodeID == "source-communication" {
            return style.updating(
              opacity: min(style.opacity * 0.96, 1),
              leadingControlFactor: 0.28,
              trailingControlFactor: 0.38,
              topStartBend: style.topStartBend * 0.9,
              topEndBend: style.topEndBend * 1.1,
              bottomStartBend: style.bottomStartBend * 0.9,
              bottomEndBend: style.bottomEndBend * 1.1
            )
          }

          return style.updating(
            opacity: min(style.opacity * 0.93, 1),
            leadingControlFactor: 0.34,
            trailingControlFactor: 0.32,
            topStartBend: style.topStartBend * 1.1,
            topEndBend: style.topEndBend * 1.18,
            bottomStartBend: style.bottomStartBend * 1.1,
            bottomEndBend: style.bottomEndBend * 1.18
          )
        }
      },
      contents: base.contents
    )
  }

  func filteringRightRail(
    using policy: WeeklySankeyAppFilterPolicy
  ) -> WeeklySankeyFixture {
    let orderedAppNodes =
      nodes
      .filter { $0.columnID == "apps" }
      .sorted { $0.order < $1.order }
    guard !orderedAppNodes.isEmpty else {
      return self
    }

    let orderedCategoryNodes =
      nodes
      .filter { $0.columnID == "categories" }
      .sorted { $0.order < $1.order }
    let appNodeIDs = Set(orderedAppNodes.map(\.id))
    let appLinks = links.filter { appNodeIDs.contains($0.targetNodeID) }
    let totalAppValue = appLinks.reduce(CGFloat.zero) { partial, link in
      partial + link.value
    }
    guard totalAppValue > 0 else {
      return self
    }

    let otherNodeID = "other"
    let incomingValueByAppID = Dictionary(grouping: appLinks, by: \.targetNodeID)
      .mapValues { groupedLinks in
        groupedLinks.reduce(CGFloat.zero) { partial, link in
          partial + link.value
        }
      }
    let appIndexByID = Dictionary(
      uniqueKeysWithValues: orderedAppNodes.enumerated().map { ($1.id, $0) }
    )

    let candidateAppIDs = orderedAppNodes.map(\.id).filter { $0 != otherNodeID }
    let minimumVisibleValue = totalAppValue * CGFloat(policy.minAppSharePercent) / 100
    let thresholdVisibleIDs = candidateAppIDs.filter { appID in
      incomingValueByAppID[appID, default: 0] >= minimumVisibleValue
    }

    let keptAppIDs: Set<String>
    if let maxVisibleApps = policy.maxVisibleApps {
      let cappedIDs =
        thresholdVisibleIDs
        .sorted { lhs, rhs in
          let lhsValue = incomingValueByAppID[lhs, default: 0]
          let rhsValue = incomingValueByAppID[rhs, default: 0]

          if abs(lhsValue - rhsValue) > 0.001 {
            return lhsValue > rhsValue
          }

          return appIndexByID[lhs, default: Int.max] < appIndexByID[rhs, default: Int.max]
        }
        .prefix(maxVisibleApps)
      keptAppIDs = Set(cappedIDs)
    } else {
      keptAppIDs = Set(thresholdVisibleIDs)
    }

    let collapsedAppIDs = Set(candidateAppIDs).subtracting(keptAppIDs)
    let shouldShowOther =
      incomingValueByAppID[otherNodeID, default: 0] > 0
      || !collapsedAppIDs.isEmpty

    var visibleAppIDSet = keptAppIDs
    if shouldShowOther {
      visibleAppIDSet.insert(otherNodeID)
    }

    var aggregatedValueBySourceTarget: [String: CGFloat] = [:]
    var aggregatedOpacityNumeratorBySourceTarget: [String: Double] = [:]

    for link in appLinks {
      let targetNodeID: String
      if visibleAppIDSet.contains(link.targetNodeID) {
        targetNodeID = link.targetNodeID
      } else if shouldShowOther {
        targetNodeID = otherNodeID
      } else {
        continue
      }

      let key = Self.sourceTargetKey(source: link.sourceNodeID, target: targetNodeID)
      aggregatedValueBySourceTarget[key, default: 0] += link.value
      aggregatedOpacityNumeratorBySourceTarget[key, default: 0] +=
        link.style.opacity * Double(link.value)
    }

    let visibleAppIDs = Self.orderedFilteredAppIDs(
      visibleAppIDs: visibleAppIDSet,
      orderedCategoryNodes: orderedCategoryNodes,
      aggregatedValueBySourceTarget: aggregatedValueBySourceTarget,
      incomingValueByAppID: incomingValueByAppID
    )
    let targetOrderByID = Dictionary(
      uniqueKeysWithValues: visibleAppIDs.enumerated().map { ($1, $0) })
    var filteredAppLinks: [SankeyLinkSpec] = []

    for categoryNode in orderedCategoryNodes {
      let visibleTargetsForSource = visibleAppIDs.filter { targetNodeID in
        let key = Self.sourceTargetKey(source: categoryNode.id, target: targetNodeID)
        return aggregatedValueBySourceTarget[key, default: 0] > 0.001
      }

      for (sourceOrder, targetNodeID) in visibleTargetsForSource.enumerated() {
        let key = Self.sourceTargetKey(source: categoryNode.id, target: targetNodeID)
        let value = aggregatedValueBySourceTarget[key, default: 0]
        guard value > 0 else { continue }

        let opacityNumerator = aggregatedOpacityNumeratorBySourceTarget[key, default: 0]
        let opacity = opacityNumerator / Double(value)

        filteredAppLinks.append(
          Self.dynamicAppLink(
            id: "filtered-\(categoryNode.id)-\(targetNodeID)",
            source: categoryNode.id,
            target: targetNodeID,
            value: value,
            sourceOrder: sourceOrder,
            targetOrder: targetOrderByID[targetNodeID, default: 0],
            opacity: opacity,
            contentsByID: contentsByID
          )
        )
      }
    }

    let filteredIncomingValueByAppID = Dictionary(grouping: filteredAppLinks, by: \.targetNodeID)
      .mapValues { groupedLinks in
        groupedLinks.reduce(CGFloat.zero) { partial, link in
          partial + link.value
        }
      }

    let appNodesByID = Dictionary(uniqueKeysWithValues: orderedAppNodes.map { ($0.id, $0) })
    let appPointsPerUnit = columns.first(where: { $0.id == "apps" })?.pointsPerUnit ?? 1
    let gapScale = Self.appGapScale(
      visibleCount: visibleAppIDs.count, baseCount: orderedAppNodes.count)

    let filteredAppNodes = visibleAppIDs.enumerated().compactMap {
      index, appID -> SankeyNodeSpec? in
      let baseNode = appNodesByID[appID] ?? Self.syntheticOtherAppNode()
      let value = filteredIncomingValueByAppID[appID, default: 0]
      guard value > 0.001 else {
        return nil
      }

      let preferredHeight: CGFloat?
      if appID == otherNodeID {
        preferredHeight = max(value * appPointsPerUnit, 8)
      } else {
        let baseValue = max(incomingValueByAppID[appID, default: value], 0.001)
        preferredHeight = Self.scaledPreferredHeight(
          baseNode.preferredHeight,
          newValue: value,
          baseValue: baseValue
        )
      }

      return SankeyNodeSpec(
        id: appID,
        columnID: baseNode.columnID,
        order: index,
        visualWeight: value,
        preferredHeight: preferredHeight,
        gapBefore: index == 0 ? 0 : baseNode.gapBefore * gapScale
      )
    }

    let nonAppContents = contents.filter { !appNodeIDs.contains($0.id) }
    let filteredAppContents = visibleAppIDs.compactMap { appID -> WeeklySankeyNodeContent? in
      let baseContent = contentsByID[appID] ?? Self.syntheticOtherAppContent()
      let value = filteredIncomingValueByAppID[appID, default: 0]
      guard value > 0.001 else {
        return nil
      }

      return Self.appContent(
        from: baseContent,
        value: value,
        totalValue: totalAppValue
      )
    }

    return WeeklySankeyFixture(
      columns: columns,
      nodes: nodes.filter { $0.columnID != "apps" } + filteredAppNodes,
      links: links.filter { !appNodeIDs.contains($0.targetNodeID) } + filteredAppLinks,
      contents: nonAppContents + filteredAppContents
    )
  }

  static func appGapScale(visibleCount: Int, baseCount: Int) -> CGFloat {
    guard baseCount > 1 else {
      return 1
    }

    let density = CGFloat(max(visibleCount - 1, 0)) / CGFloat(baseCount - 1)
    return max(0.4, density)
  }

  static func scaledPreferredHeight(
    _ basePreferredHeight: CGFloat?,
    newValue: CGFloat,
    baseValue: CGFloat
  ) -> CGFloat? {
    guard let basePreferredHeight else {
      return nil
    }

    return max((basePreferredHeight / baseValue) * newValue, 6)
  }

  static func appContent(
    from baseContent: WeeklySankeyNodeContent,
    value: CGFloat,
    totalValue: CGFloat
  ) -> WeeklySankeyNodeContent {
    let share = max(min(value / totalValue, 1), 0)
    let durationMinutes = Int(value.rounded())

    return WeeklySankeyNodeContent(
      id: baseContent.id,
      title: baseContent.title,
      durationText: formattedDuration(minutes: durationMinutes),
      shareText: "\(Int((share * 100).rounded()))%",
      barColorHex: baseContent.barColorHex,
      labelKind: baseContent.labelKind
    )
  }

  static func formattedDuration(minutes: Int) -> String {
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if hours > 0, remainingMinutes > 0 {
      return "\(hours)hr \(remainingMinutes)min"
    }

    if hours > 0 {
      return "\(hours)hr"
    }

    return "\(remainingMinutes)min"
  }

  static func sourceTargetKey(source: String, target: String) -> String {
    "\(source)->\(target)"
  }

  static func orderedFilteredAppIDs(
    visibleAppIDs: Set<String>,
    orderedCategoryNodes: [SankeyNodeSpec],
    aggregatedValueBySourceTarget: [String: CGFloat],
    incomingValueByAppID: [String: CGFloat]
  ) -> [String] {
    let categoryRankByID = Dictionary(
      uniqueKeysWithValues: orderedCategoryNodes.enumerated().map { ($1.id, CGFloat($0)) }
    )

    func anchorY(for appID: String) -> CGFloat {
      var totalValue: CGFloat = 0
      var weightedRank: CGFloat = 0

      for categoryNode in orderedCategoryNodes {
        let value = aggregatedValueBySourceTarget[
          sourceTargetKey(source: categoryNode.id, target: appID),
          default: 0
        ]
        guard value > 0 else {
          continue
        }

        totalValue += value
        weightedRank += categoryRankByID[categoryNode.id, default: 0] * value
      }

      guard totalValue > 0 else {
        return .greatestFiniteMagnitude
      }

      return weightedRank / totalValue
    }

    return visibleAppIDs.sorted { lhs, rhs in
      let lhsAnchor = anchorY(for: lhs)
      let rhsAnchor = anchorY(for: rhs)

      if abs(lhsAnchor - rhsAnchor) > 0.001 {
        return lhsAnchor < rhsAnchor
      }

      let lhsValue = incomingValueByAppID[lhs, default: 0]
      let rhsValue = incomingValueByAppID[rhs, default: 0]
      if abs(lhsValue - rhsValue) > 0.001 {
        return lhsValue > rhsValue
      }

      return lhs < rhs
    }
  }

  static func syntheticOtherAppNode() -> SankeyNodeSpec {
    SankeyNodeSpec(
      id: "other",
      columnID: "apps",
      order: 0,
      visualWeight: 0,
      preferredHeight: 18,
      gapBefore: 20
    )
  }

  static func syntheticOtherAppContent() -> WeeklySankeyNodeContent {
    WeeklySankeyNodeContent(
      id: "other",
      title: "Other",
      durationText: "0min",
      shareText: "0%",
      barColorHex: "D9D9D9",
      labelKind: .app(.none)
    )
  }
}

#Preview("Weekly Sankey Distribution", traits: .fixedLayout(width: 1002, height: 640)) {
  WeeklySankeyPreviewCard(variant: .airierOptimized)
    .padding(18)
    .background(Color(hex: "F7F3F0"))
}

#Preview("Weekly Sankey Iterations", traits: .fixedLayout(width: 1002, height: 2080)) {
  WeeklySankeyPreviewGallery()
    .background(Color(hex: "F7F3F0"))
}

#Preview("Weekly Sankey Filtering") {
  WeeklySankeyFilterTuningPreview()
}
