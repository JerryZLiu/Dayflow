import SwiftUI

enum WeeklySankeyDesign {
  static let virtualWidth: CGFloat = 1748
  static let virtualHeight: CGFloat = 933
  static let sourceCurveTension: CGFloat = 0.15
  static let cardWidth: CGFloat = 958
}

struct WeeklySankeyScale {
  let x: CGFloat
  let y: CGFloat

  init(size: CGSize) {
    self.x = size.width / WeeklySankeyDesign.virtualWidth
    self.y = size.height / WeeklySankeyDesign.virtualHeight
  }

  func point(x: CGFloat, y: CGFloat) -> CGPoint {
    CGPoint(x: x * self.x, y: y * self.y)
  }

  func displayFrame(_ rect: CGRect) -> CGRect {
    CGRect(
      x: displayX(rect.minX),
      y: displayY(rect.minY),
      width: displayWidth(rect.width),
      height: displayHeight(rect.height)
    )
  }

  func displayX(_ value: CGFloat) -> CGFloat {
    value * x
  }

  func displayY(_ value: CGFloat) -> CGFloat {
    value * y
  }

  func displayWidth(_ value: CGFloat) -> CGFloat {
    value * x
  }

  func displayHeight(_ value: CGFloat) -> CGFloat {
    value * y
  }
}

enum WeeklySankeyLayout {
  static let base = WeeklySankeyLayoutSpec(
    source: WeeklySankeyColumnSpec(
      x: 72,
      width: 12,
      top: 273,
      bottom: 706,
      gap: 0,
      minHeight: 0,
      labelX: 105,
      labelTop: 0,
      labelBottom: 0,
      labelWidth: 220,
      labelHeight: 52,
      labelSpacing: 0
    ),
    categories: WeeklySankeyColumnSpec(
      x: 760,
      width: 12,
      top: 126,
      bottom: 828,
      gap: 20,
      minHeight: 40,
      labelX: 802,
      labelTop: 64,
      labelBottom: 874,
      labelWidth: 260,
      labelHeight: 54,
      labelSpacing: 12
    ),
    apps: WeeklySankeyColumnSpec(
      x: 1334,
      width: 12,
      top: 54,
      bottom: 928,
      gap: 20,
      minHeight: 28,
      labelX: 1372,
      labelTop: 38,
      labelBottom: 923,
      labelWidth: 330,
      labelHeight: 56,
      labelSpacing: 10
    )
  )
}

enum WeeklySankeyIcon: Equatable {
  case asset(String)
  case favicon(
    primaryRaw: String?,
    secondaryRaw: String?,
    primaryHost: String?,
    secondaryHost: String?,
    fallbackRaw: String?
  )
  case monogram(text: String, backgroundHex: String, foregroundHex: String)
  case none
}

struct WeeklySankeyLayoutSpec {
  let source: WeeklySankeyColumnSpec
  let categories: WeeklySankeyColumnSpec
  let apps: WeeklySankeyColumnSpec
}

struct WeeklySankeyColumnSpec {
  let x: CGFloat
  let width: CGFloat
  let top: CGFloat
  let bottom: CGFloat
  let gap: CGFloat
  let minHeight: CGFloat
  let labelX: CGFloat
  let labelTop: CGFloat
  let labelBottom: CGFloat
  let labelWidth: CGFloat
  let labelHeight: CGFloat
  let labelSpacing: CGFloat
}

struct WeeklySankeyModel {
  let id: String
  let seedLabel: String
  let source: WeeklySankeyNode
  let categories: [WeeklySankeyNode]
  let apps: [WeeklySankeyNode]
  let flows: [WeeklySankeyFlow]

  var nodes: [WeeklySankeyNode] {
    [source] + categories + apps
  }
}

struct WeeklySankeyNode: Identifiable {
  let id: String
  let name: String
  let metric: String
  let percent: String
  let minutes: Int
  let barColorHex: String
  let icon: WeeklySankeyIcon
  let bar: CGRect
  let label: WeeklySankeyLabelFrame
}

struct WeeklySankeyLabelFrame {
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat
}

struct WeeklySankeyFlow: Identifiable {
  let id: String
  let from: String
  let to: String
  let fromColorHex: String
  let toColorHex: String
  let x0: CGFloat
  let y0Top: CGFloat
  let y0Bottom: CGFloat
  let x1: CGFloat
  let y1Top: CGFloat
  let y1Bottom: CGFloat
  let curveTension: CGFloat
  let opacity: Double

  func expandingVertically(by amount: CGFloat) -> WeeklySankeyFlow {
    WeeklySankeyFlow(
      id: id,
      from: from,
      to: to,
      fromColorHex: fromColorHex,
      toColorHex: toColorHex,
      x0: x0,
      y0Top: y0Top - amount,
      y0Bottom: y0Bottom + amount,
      x1: x1,
      y1Top: y1Top - amount,
      y1Bottom: y1Bottom + amount,
      curveTension: curveTension,
      opacity: opacity
    )
  }
}
