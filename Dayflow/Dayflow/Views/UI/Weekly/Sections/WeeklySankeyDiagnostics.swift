import SwiftUI

extension WeeklySankeyDistributionSection {
  static func previewDiagnostics(
    for variant: WeeklySankeyPreviewVariant,
    appFilterPolicy: WeeklySankeyAppFilterPolicy = .default
  ) -> WeeklySankeyPreviewDiagnostics {
    let section = WeeklySankeyDistributionSection(
      variant: variant,
      appFilterPolicy: appFilterPolicy
    )
    let layout = section.layout
    let placements = section.labelPlacements(for: layout)
    let labelOverlapPairs = labelOverlapPairs(
      layout: layout,
      fixture: section.fixture,
      placements: placements
    )
    let tightestLabelGap = tightestLabelGap(
      layout: layout,
      fixture: section.fixture,
      placements: placements
    )
    let appBottomClearance = appBottomClearance(
      layout: layout,
      fixture: section.fixture,
      placements: placements
    )
    let weightedCrossings = weightedCrossingScore(layout: layout, fixture: section.fixture)

    return WeeklySankeyPreviewDiagnostics(
      programmaticScore: programmaticScore(
        weightedCrossings: weightedCrossings,
        labelOverlapPairs: labelOverlapPairs,
        tightestLabelGap: tightestLabelGap,
        appBottomClearance: appBottomClearance
      ),
      weightedCrossings: weightedCrossings,
      labelOverlapPairs: labelOverlapPairs,
      tightestLabelGap: tightestLabelGap,
      appBottomClearance: appBottomClearance
    )
  }

  static func programmaticScore(
    weightedCrossings: CGFloat,
    labelOverlapPairs: Int,
    tightestLabelGap: CGFloat,
    appBottomClearance: CGFloat
  ) -> CGFloat {
    let overlapPenalty = CGFloat(labelOverlapPairs) * 10_000
    let overflowPenalty = max(-appBottomClearance, 0) * 90
    let gapPenalty = max(12 - tightestLabelGap, 0) * 35
    return overlapPenalty + overflowPenalty + gapPenalty + weightedCrossings
  }

  static func weightedCrossingScore(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture
  ) -> CGFloat {
    let columnIndexByID = Dictionary(
      uniqueKeysWithValues: fixture.columns.enumerated().map { ($1.id, $0) })
    let ranksByNodeID = Dictionary(
      uniqueKeysWithValues: Dictionary(grouping: layout.nodes, by: \.columnID).flatMap { _, nodes in
        nodes
          .sorted { lhs, rhs in
            if abs(lhs.frame.midY - rhs.frame.midY) > 0.5 {
              return lhs.frame.midY < rhs.frame.midY
            }
            return lhs.id < rhs.id
          }
          .enumerated()
          .map { ($1.id, $0) }
      }
    )

    var score: CGFloat = 0

    for sourceColumnIndex in 0..<(fixture.columns.count - 1) {
      let targetColumnIndex = sourceColumnIndex + 1
      let relevantLinks = fixture.links.filter { link in
        guard
          let sourceLayout = layout.nodeLayoutsByID[link.sourceNodeID],
          let targetLayout = layout.nodeLayoutsByID[link.targetNodeID]
        else {
          return false
        }

        return columnIndexByID[sourceLayout.columnID] == sourceColumnIndex
          && columnIndexByID[targetLayout.columnID] == targetColumnIndex
      }

      guard relevantLinks.count > 1 else {
        continue
      }

      for lhsIndex in 0..<(relevantLinks.count - 1) {
        let lhsLink = relevantLinks[lhsIndex]
        let lhsSourceRank = ranksByNodeID[lhsLink.sourceNodeID] ?? 0
        let lhsTargetRank = ranksByNodeID[lhsLink.targetNodeID] ?? 0

        for rhsIndex in (lhsIndex + 1)..<relevantLinks.count {
          let rhsLink = relevantLinks[rhsIndex]
          let rhsSourceRank = ranksByNodeID[rhsLink.sourceNodeID] ?? 0
          let rhsTargetRank = ranksByNodeID[rhsLink.targetNodeID] ?? 0

          let sourceDelta = lhsSourceRank - rhsSourceRank
          let targetDelta = lhsTargetRank - rhsTargetRank

          if sourceDelta == 0 || targetDelta == 0 {
            continue
          }

          if (sourceDelta < 0 && targetDelta > 0) || (sourceDelta > 0 && targetDelta < 0) {
            score += max(lhsLink.value, 0) * max(rhsLink.value, 0)
          }
        }
      }
    }

    return score
  }

  static func labelOverlapPairs(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture,
    placements: [String: WeeklySankeyLabelPlacement]
  ) -> Int {
    let framesByColumn = labelFramesByColumn(
      layout: layout, fixture: fixture, placements: placements)
    var overlapPairs = 0

    for columnFrames in framesByColumn.values {
      guard columnFrames.count > 1 else {
        continue
      }

      for lhsIndex in 0..<(columnFrames.count - 1) {
        for rhsIndex in (lhsIndex + 1)..<columnFrames.count {
          if columnFrames[lhsIndex].intersects(columnFrames[rhsIndex]) {
            overlapPairs += 1
          }
        }
      }
    }

    return overlapPairs
  }

  static func tightestLabelGap(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture,
    placements: [String: WeeklySankeyLabelPlacement]
  ) -> CGFloat {
    let framesByColumn = labelFramesByColumn(
      layout: layout, fixture: fixture, placements: placements)
    var minimumGap = CGFloat.greatestFiniteMagnitude

    for columnFrames in framesByColumn.values {
      let sortedFrames = columnFrames.sorted { lhs, rhs in
        if abs(lhs.minY - rhs.minY) > 0.5 {
          return lhs.minY < rhs.minY
        }
        return lhs.minX < rhs.minX
      }

      for index in 0..<(sortedFrames.count - 1) {
        minimumGap = min(minimumGap, sortedFrames[index + 1].minY - sortedFrames[index].maxY)
      }
    }

    if minimumGap == .greatestFiniteMagnitude {
      return 0
    }

    return minimumGap
  }

  static func appBottomClearance(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture,
    placements: [String: WeeklySankeyLabelPlacement]
  ) -> CGFloat {
    let appFrames =
      labelFramesByColumn(layout: layout, fixture: fixture, placements: placements)["apps"] ?? []
    guard let maxY = appFrames.map(\.maxY).max() else {
      return 0
    }

    return (Design.sectionSize.height - Design.appLabelBottomPadding) - maxY
  }

  static func labelFramesByColumn(
    layout: SankeyLayoutResult,
    fixture: WeeklySankeyFixture,
    placements: [String: WeeklySankeyLabelPlacement]
  ) -> [String: [CGRect]] {
    fixture.contents.reduce(into: [String: [CGRect]]()) { partialResult, content in
      guard
        let node = layout.nodeLayoutsByID[content.id],
        let placement = placements[content.id]
      else {
        return
      }

      partialResult[node.columnID, default: []].append(
        CGRect(origin: placement.origin, size: content.labelSize)
      )
    }
  }
}
