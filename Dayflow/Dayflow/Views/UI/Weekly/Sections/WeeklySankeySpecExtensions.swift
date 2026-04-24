import SwiftUI

extension SankeyColumnSpec {
  func updating(
    x: CGFloat? = nil,
    topY: CGFloat? = nil,
    barWidth: CGFloat? = nil,
    pointsPerUnit: CGFloat? = nil
  ) -> SankeyColumnSpec {
    return SankeyColumnSpec(
      id: id,
      x: x ?? self.x,
      topY: topY ?? self.topY,
      barWidth: barWidth ?? self.barWidth,
      pointsPerUnit: pointsPerUnit ?? self.pointsPerUnit
    )
  }
}

extension SankeyNodeSpec {
  func updating(
    preferredHeight: CGFloat? = nil,
    gapBefore: CGFloat? = nil
  ) -> SankeyNodeSpec {
    let resolvedPreferredHeight: CGFloat?
    if let preferredHeight {
      resolvedPreferredHeight = preferredHeight
    } else {
      resolvedPreferredHeight = self.preferredHeight
    }

    return SankeyNodeSpec(
      id: id,
      columnID: columnID,
      order: order,
      visualWeight: visualWeight,
      preferredHeight: resolvedPreferredHeight,
      gapBefore: gapBefore ?? self.gapBefore
    )
  }
}

extension SankeyLinkSpec {
  func updatingStyle(_ transform: (SankeyRibbonStyle) -> SankeyRibbonStyle)
    -> SankeyLinkSpec
  {
    return SankeyLinkSpec(
      id: id,
      sourceNodeID: sourceNodeID,
      targetNodeID: targetNodeID,
      value: value,
      sourceOrder: sourceOrder,
      targetOrder: targetOrder,
      sourceBandOverride: sourceBandOverride,
      targetBandOverride: targetBandOverride,
      style: transform(style)
    )
  }
}

extension SankeyRibbonStyle {
  func updating(
    leadingColor: Color? = nil,
    trailingColor: Color? = nil,
    opacity: Double? = nil,
    zIndex: Double? = nil,
    leadingControlFactor: CGFloat? = nil,
    trailingControlFactor: CGFloat? = nil,
    topStartBend: CGFloat? = nil,
    topEndBend: CGFloat? = nil,
    bottomStartBend: CGFloat? = nil,
    bottomEndBend: CGFloat? = nil
  ) -> SankeyRibbonStyle {
    return SankeyRibbonStyle(
      leadingColor: leadingColor ?? self.leadingColor,
      trailingColor: trailingColor ?? self.trailingColor,
      opacity: opacity ?? self.opacity,
      zIndex: zIndex ?? self.zIndex,
      leadingControlFactor: leadingControlFactor ?? self.leadingControlFactor,
      trailingControlFactor: trailingControlFactor ?? self.trailingControlFactor,
      topStartBend: topStartBend ?? self.topStartBend,
      topEndBend: topEndBend ?? self.topEndBend,
      bottomStartBend: bottomStartBend ?? self.bottomStartBend,
      bottomEndBend: bottomEndBend ?? self.bottomEndBend
    )
  }
}
