import SwiftUI

enum WeeklyInteractionGraphCategory: String, CaseIterable {
  case work
  case personal
  case distraction

  var fillColor: Color {
    switch self {
    case .work:
      return Color(hex: "EEF3FF")
    case .personal:
      return Color(hex: "E6E6E6")
    case .distraction:
      return Color(hex: "FFDCCF")
    }
  }

  var borderColor: Color {
    switch self {
    case .work:
      return Color(hex: "4779E9")
    case .personal:
      return Color(hex: "B8B8B8")
    case .distraction:
      return Color(hex: "FC7645")
    }
  }

  var edgeColor: Color {
    Color(hex: edgeHex)
  }

  var edgeHex: String {
    switch self {
    case .work:
      return "4779E9"
    case .personal:
      return "9BA1A9"
    case .distraction:
      return "FC7645"
    }
  }
}

enum WeeklyInteractionGraphGlyph {
  case figma
  case youtube
  case x
  case notion
  case slack
  case zoom
  case reddit
  case linear
  case framer
  case bookmark
  case cube
  case burst
  case bullseye
  case bars
  case asset(String)
  case monogram(String, backgroundHex: String, foregroundHex: String)
}

struct WeeklyInteractionGraphSnapshot {
  let title: String
  let subtitle: String
  let nodes: [WeeklyInteractionGraphNode]
  let edges: [WeeklyInteractionGraphEdge]
  let preferredCenterNodeID: String?

  init(
    title: String,
    subtitle: String,
    nodes: [WeeklyInteractionGraphNode],
    edges: [WeeklyInteractionGraphEdge],
    preferredCenterNodeID: String? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.nodes = nodes
    self.edges = edges
    self.preferredCenterNodeID = preferredCenterNodeID
  }
}

struct WeeklyInteractionGraphNode: Identifiable {
  let id: String
  let title: String
  let category: WeeklyInteractionGraphCategory
  let glyph: WeeklyInteractionGraphGlyph
  let importanceBoost: CGFloat

  init(
    id: String,
    title: String,
    category: WeeklyInteractionGraphCategory,
    glyph: WeeklyInteractionGraphGlyph,
    importanceBoost: CGFloat = 0
  ) {
    self.id = id
    self.title = title
    self.category = category
    self.glyph = glyph
    self.importanceBoost = importanceBoost
  }
}

struct WeeklyInteractionGraphEdge: Identifiable {
  let id: String
  let sourceID: String
  let targetID: String
  let weight: CGFloat

  init(
    id: String,
    sourceID: String,
    targetID: String,
    weight: CGFloat = 1
  ) {
    self.id = id
    self.sourceID = sourceID
    self.targetID = targetID
    self.weight = weight
  }
}

struct WeeklyInteractionGraphLayout {
  let nodes: [WeeklyInteractionGraphNodeLayout]
  let edges: [WeeklyInteractionGraphEdgeLayout]
  let connectorDots: [WeeklyInteractionGraphConnectorDot]
}

struct WeeklyInteractionGraphNodeLayout: Identifiable {
  let id: String
  let node: WeeklyInteractionGraphNode
  let center: CGPoint
  let diameter: CGFloat
  let borderWidth: CGFloat
  let isCenter: Bool

  var category: WeeklyInteractionGraphCategory { node.category }
  var glyph: WeeklyInteractionGraphGlyph { node.glyph }
}

struct WeeklyInteractionGraphEdgeLayout: Identifiable {
  let id: String
  let path: Path
  let color: Color
  let opacity: Double
  let lineWidth: CGFloat
  let zIndex: Double
}

struct WeeklyInteractionGraphConnectorDot: Identifiable {
  let id: String
  let center: CGPoint
  let color: Color
  let diameter: CGFloat
}
