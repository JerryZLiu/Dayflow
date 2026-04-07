import AppKit
import SwiftUI

struct WeeklySankeyDistributionSection: View {
  private let fixture = WeeklySankeyFixture.figmaInspired

  private var layout: SankeyLayoutResult {
    SankeyLayoutEngine.layout(
      columns: fixture.columns,
      nodes: fixture.nodes,
      links: fixture.links,
      options: .aesthetic
    )
  }

  var body: some View {
    let layout = layout

    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Design.background)

      Canvas { context, _ in
        for ribbon in layout.ribbons.sorted(by: ribbonSort(lhs:rhs:)) {
          let fillOpacity = ribbon.opacity * Design.ribbonOpacityScale
          context.fill(
            ribbon.path,
            with: .color(ribbon.color.opacity(fillOpacity))
          )
          context.stroke(
            ribbon.path,
            with: .color(Color.white.opacity(Design.ribbonHighlightOpacity)),
            lineWidth: Design.ribbonHighlightWidth
          )
        }
      }

      ForEach(layout.nodes) { node in
        if let content = fixture.contentsByID[node.id] {
          Rectangle()
            .fill(content.barColor)
            .frame(width: node.frame.width, height: node.frame.height)
            .offset(x: node.frame.minX, y: node.frame.minY)
        }
      }

      ForEach(fixture.contents) { content in
        if let node = layout.nodeLayoutsByID[content.id] {
          labelView(for: content)
            .frame(width: content.labelWidth, alignment: .leading)
            .offset(
              x: labelOrigin(for: node).x,
              y: labelOrigin(for: node).y
            )
        }
      }
    }
    .frame(width: Design.sectionSize.width, height: Design.sectionSize.height)
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(Design.borderColor, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func labelView(for content: WeeklySankeyNodeContent) -> some View {
    switch content.labelKind {
    case .plain:
      WeeklySankeyPlainLabel(content: content)
    case .app(let iconSource):
      WeeklySankeyAppLabel(content: content, iconSource: iconSource)
    }
  }

  private func labelOrigin(for node: SankeyNodeLayout) -> CGPoint {
    switch node.columnID {
    case "source":
      return CGPoint(x: node.frame.maxX + 18, y: node.frame.midY - 17)
    case "categories":
      return CGPoint(x: node.frame.maxX + 18, y: node.frame.midY - 17)
    case "apps":
      return CGPoint(x: node.frame.maxX + 14, y: node.frame.midY - 16)
    default:
      return CGPoint(x: node.frame.maxX + 14, y: node.frame.midY - 16)
    }
  }

  private func ribbonSort(lhs: SankeyRibbonLayout, rhs: SankeyRibbonLayout) -> Bool {
    if lhs.zIndex == rhs.zIndex {
      return lhs.id < rhs.id
    }
    return lhs.zIndex < rhs.zIndex
  }
}

extension WeeklySankeyDistributionSection {
  fileprivate enum Design {
    static let sectionSize = CGSize(width: 948, height: 549)
    static let cornerRadius: CGFloat = 4
    static let borderColor = Color(hex: "EBE6E3")
    static let background = Color.white.opacity(0.8)
    static let ribbonOpacityScale = 0.72
    static let ribbonHighlightOpacity = 0.26
    static let ribbonHighlightWidth: CGFloat = 0.5
  }
}

private struct WeeklySankeyPlainLabel: View {
  let content: WeeklySankeyNodeContent

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(content.title)
        .font(.custom("Nunito-Bold", size: 12))
        .foregroundStyle(.black)
        .lineLimit(1)
        .minimumScaleFactor(0.85)

      WeeklySankeyMetadataLine(
        durationText: content.durationText,
        shareText: content.shareText
      )
    }
  }
}

private struct WeeklySankeyAppLabel: View {
  let content: WeeklySankeyNodeContent
  let iconSource: WeeklySankeyIconSource

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      WeeklySankeyIconView(source: iconSource)
        .frame(width: 16, height: 16)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 1) {
        Text(content.title)
          .font(.custom("Nunito-Bold", size: 12))
          .foregroundStyle(.black)
          .lineLimit(1)
          .minimumScaleFactor(0.85)

        WeeklySankeyMetadataLine(
          durationText: content.durationText,
          shareText: content.shareText
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct WeeklySankeyMetadataLine: View {
  let durationText: String
  let shareText: String

  var body: some View {
    Text("\(durationText) | \(shareText)")
      .font(.custom("Nunito-Regular", size: 12))
      .foregroundStyle(Color(hex: "717171"))
      .lineLimit(1)
      .minimumScaleFactor(0.85)
  }
}

private struct WeeklySankeyIconView: View {
  let source: WeeklySankeyIconSource

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        fallbackView
      }
    }
    .frame(width: 16, height: 16)
    .task(id: source.cacheKey) {
      image = await source.resolveImage()
    }
  }

  @ViewBuilder
  private var fallbackView: some View {
    switch source {
    case .monogram(let text, let background, let foreground):
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(background)
        .overlay {
          Text(text)
            .font(.custom("Nunito-Bold", size: 9))
            .foregroundStyle(foreground)
        }
    case .none:
      Color.clear
    default:
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(Color.black.opacity(0.05))
    }
  }
}

private enum WeeklySankeyIconSource {
  case asset(String)
  case favicon(raw: String, host: String)
  case monogram(text: String, background: Color, foreground: Color)
  case none

  var cacheKey: String {
    switch self {
    case .asset(let name):
      return "asset:\(name)"
    case .favicon(let raw, let host):
      return "favicon:\(raw):\(host)"
    case .monogram(let text, _, _):
      return "monogram:\(text)"
    case .none:
      return "none"
    }
  }

  func resolveImage() async -> NSImage? {
    switch self {
    case .asset(let name):
      return NSImage(named: name)
    case .favicon(let raw, let host):
      return await FaviconService.shared.fetchFavicon(
        primaryRaw: raw,
        secondaryRaw: nil,
        primaryHost: host,
        secondaryHost: nil
      )
    case .monogram, .none:
      return nil
    }
  }
}

private enum WeeklySankeyLabelKind {
  case plain
  case app(WeeklySankeyIconSource)
}

private struct WeeklySankeyNodeContent: Identifiable {
  let id: String
  let title: String
  let durationText: String
  let shareText: String
  let barColor: Color
  let labelKind: WeeklySankeyLabelKind

  var labelWidth: CGFloat {
    switch labelKind {
    case .plain:
      return 120
    case .app:
      return 140
    }
  }
}

private struct WeeklySankeyFixture {
  let columns: [SankeyColumnSpec]
  let nodes: [SankeyNodeSpec]
  let links: [SankeyLinkSpec]
  let contents: [WeeklySankeyNodeContent]

  var contentsByID: [String: WeeklySankeyNodeContent] {
    Dictionary(uniqueKeysWithValues: contents.map { ($0.id, $0) })
  }
}

extension WeeklySankeyFixture {
  fileprivate static let figmaInspired = WeeklySankeyFixture(
    columns: [
      SankeyColumnSpec(id: "source", x: 78, topY: 166, barWidth: 6, pointsPerUnit: 2.12),
      SankeyColumnSpec(id: "categories", x: 470, topY: 82, barWidth: 6, pointsPerUnit: 2.08),
      SankeyColumnSpec(id: "apps", x: 792, topY: 48, barWidth: 6, pointsPerUnit: 2.08),
    ],
    nodes: [
      SankeyNodeSpec(
        id: "source-communication",
        columnID: "source",
        order: 0,
        visualWeight: 100
      ),

      SankeyNodeSpec(id: "research", columnID: "categories", order: 0, visualWeight: 18),
      SankeyNodeSpec(
        id: "communication", columnID: "categories", order: 1, visualWeight: 16, gapBefore: 12),
      SankeyNodeSpec(
        id: "design", columnID: "categories", order: 2, visualWeight: 27, gapBefore: 12),
      SankeyNodeSpec(
        id: "general", columnID: "categories", order: 3, visualWeight: 13, gapBefore: 12),
      SankeyNodeSpec(
        id: "testing", columnID: "categories", order: 4, visualWeight: 10, gapBefore: 12),
      SankeyNodeSpec(
        id: "distractions", columnID: "categories", order: 5, visualWeight: 11, gapBefore: 18),
      SankeyNodeSpec(
        id: "personal", columnID: "categories", order: 6, visualWeight: 5, gapBefore: 12),

      SankeyNodeSpec(id: "chatgpt", columnID: "apps", order: 0, visualWeight: 12),
      SankeyNodeSpec(id: "zoom", columnID: "apps", order: 1, visualWeight: 6, gapBefore: 10),
      SankeyNodeSpec(id: "clickup", columnID: "apps", order: 2, visualWeight: 4, gapBefore: 10),
      SankeyNodeSpec(id: "slack", columnID: "apps", order: 3, visualWeight: 12, gapBefore: 20),
      SankeyNodeSpec(id: "youtube", columnID: "apps", order: 4, visualWeight: 8, gapBefore: 12),
      SankeyNodeSpec(id: "claude", columnID: "apps", order: 5, visualWeight: 11, gapBefore: 10),
      SankeyNodeSpec(id: "figma", columnID: "apps", order: 6, visualWeight: 24, gapBefore: 12),
      SankeyNodeSpec(id: "x", columnID: "apps", order: 7, visualWeight: 11, gapBefore: 12),
      SankeyNodeSpec(id: "medium", columnID: "apps", order: 8, visualWeight: 4, gapBefore: 10),
      SankeyNodeSpec(id: "other", columnID: "apps", order: 9, visualWeight: 8, gapBefore: 18),
    ],
    links: [
      sourceLink(
        id: "left-research", target: "research", value: 18, order: 0, color: "E4EBF7", opacity: 0.88
      ),
      sourceLink(
        id: "left-communication", target: "communication", value: 16, order: 1, color: "E2F4F0",
        opacity: 0.86),
      sourceLink(
        id: "left-design", target: "design", value: 27, order: 2, color: "F1E4F5", opacity: 0.84),
      sourceLink(
        id: "left-general", target: "general", value: 13, order: 3, color: "EEEAE6", opacity: 0.86),
      sourceLink(
        id: "left-testing", target: "testing", value: 10, order: 4, color: "FDE8E1", opacity: 0.86),
      sourceLink(
        id: "left-distractions", target: "distractions", value: 11, order: 5, color: "FBE4E2",
        opacity: 0.88),
      sourceLink(
        id: "left-personal", target: "personal", value: 5, order: 6, color: "FAEEE7", opacity: 0.88),

      appLink(
        id: "research-chatgpt", source: "research", target: "chatgpt", value: 12, sourceOrder: 0,
        targetOrder: 0, color: "E4EBF7", opacity: 0.88),
      appLink(
        id: "research-zoom", source: "research", target: "zoom", value: 6, sourceOrder: 1,
        targetOrder: 1, color: "E4EBF7", opacity: 0.82),

      appLink(
        id: "communication-clickup", source: "communication", target: "clickup", value: 4,
        sourceOrder: 0, targetOrder: 2, color: "FBE7F4", opacity: 0.88),
      appLink(
        id: "communication-slack", source: "communication", target: "slack", value: 12,
        sourceOrder: 1, targetOrder: 3, color: "E3F7FB", opacity: 0.84),

      appLink(
        id: "design-youtube", source: "design", target: "youtube", value: 2, sourceOrder: 0,
        targetOrder: 4, color: "F6EEF5", opacity: 0.78),
      appLink(
        id: "design-claude", source: "design", target: "claude", value: 5, sourceOrder: 1,
        targetOrder: 5, color: "F4E9F4", opacity: 0.80),
      appLink(
        id: "design-figma", source: "design", target: "figma", value: 20, sourceOrder: 2,
        targetOrder: 6, color: "F4E4F3", opacity: 0.88),

      appLink(
        id: "general-youtube", source: "general", target: "youtube", value: 3, sourceOrder: 0,
        targetOrder: 4, color: "F3F0EE", opacity: 0.82),
      appLink(
        id: "general-other", source: "general", target: "other", value: 5, sourceOrder: 1,
        targetOrder: 9, color: "EEEAE7", opacity: 0.80),
      appLink(
        id: "general-x", source: "general", target: "x", value: 5, sourceOrder: 2, targetOrder: 7,
        color: "EFE7E4", opacity: 0.80),

      appLink(
        id: "testing-claude", source: "testing", target: "claude", value: 6, sourceOrder: 0,
        targetOrder: 5, color: "FCE6DE", opacity: 0.84),
      appLink(
        id: "testing-figma", source: "testing", target: "figma", value: 3, sourceOrder: 1,
        targetOrder: 6, color: "FBE3DF", opacity: 0.84),
      appLink(
        id: "testing-x", source: "testing", target: "x", value: 1, sourceOrder: 2, targetOrder: 7,
        color: "F6EAE6", opacity: 0.78),

      appLink(
        id: "distractions-youtube", source: "distractions", target: "youtube", value: 3,
        sourceOrder: 0, targetOrder: 4, color: "F9E3E1", opacity: 0.82),
      appLink(
        id: "distractions-x", source: "distractions", target: "x", value: 5, sourceOrder: 1,
        targetOrder: 7, color: "F4E6E2", opacity: 0.82),
      appLink(
        id: "distractions-medium", source: "distractions", target: "medium", value: 3,
        sourceOrder: 2, targetOrder: 8, color: "F2E7E3", opacity: 0.80),

      appLink(
        id: "personal-other", source: "personal", target: "other", value: 3, sourceOrder: 0,
        targetOrder: 9, color: "F5ECE7", opacity: 0.78),
      appLink(
        id: "personal-medium", source: "personal", target: "medium", value: 1, sourceOrder: 1,
        targetOrder: 8, color: "F4ECE8", opacity: 0.76),
      appLink(
        id: "personal-figma", source: "personal", target: "figma", value: 1, sourceOrder: 2,
        targetOrder: 6, color: "F7EAE6", opacity: 0.76),
    ],
    contents: [
      WeeklySankeyNodeContent(
        id: "source-communication",
        title: "Communication",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "D9CBC0"),
        labelKind: .plain
      ),

      WeeklySankeyNodeContent(
        id: "research",
        title: "Research",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "93BCFF"),
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "communication",
        title: "Communication",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "6CDACD"),
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "design",
        title: "Design",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "DE9DFC"),
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "general",
        title: "General",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "BFB6AE"),
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "testing",
        title: "Testing",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "FFA189"),
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "distractions",
        title: "Distractions",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "FF5950"),
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "personal",
        title: "Personal",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "FFC6B7"),
        labelKind: .plain
      ),

      WeeklySankeyNodeContent(
        id: "chatgpt",
        title: "Chat GPT",
        durationText: "6hr 25min",
        shareText: "8%",
        barColor: Color(hex: "333333"),
        labelKind: .app(.asset("ChatGPTLogo"))
      ),
      WeeklySankeyNodeContent(
        id: "zoom",
        title: "Zoom",
        durationText: "6hr 25min",
        shareText: "8%",
        barColor: Color(hex: "4085FD"),
        labelKind: .app(.favicon(raw: "zoom.us", host: "zoom.us"))
      ),
      WeeklySankeyNodeContent(
        id: "clickup",
        title: "ClickUp",
        durationText: "6hr 25min",
        shareText: "8%",
        barColor: Color(hex: "FD1BB9"),
        labelKind: .app(.favicon(raw: "clickup.com", host: "clickup.com"))
      ),
      WeeklySankeyNodeContent(
        id: "slack",
        title: "Slack",
        durationText: "6hr 25min",
        shareText: "8%",
        barColor: Color(hex: "36C5F0"),
        labelKind: .app(.favicon(raw: "slack.com", host: "slack.com"))
      ),
      WeeklySankeyNodeContent(
        id: "youtube",
        title: "YouTube",
        durationText: "6hr 25min",
        shareText: "8%",
        barColor: Color(hex: "FF0000"),
        labelKind: .app(.favicon(raw: "youtube.com", host: "youtube.com"))
      ),
      WeeklySankeyNodeContent(
        id: "claude",
        title: "Claude",
        durationText: "6hr 25min",
        shareText: "8%",
        barColor: Color(hex: "D97757"),
        labelKind: .app(.asset("ClaudeLogo"))
      ),
      WeeklySankeyNodeContent(
        id: "figma",
        title: "Figma",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "FF7262"),
        labelKind: .app(.favicon(raw: "figma.com", host: "figma.com"))
      ),
      WeeklySankeyNodeContent(
        id: "x",
        title: "X",
        durationText: "6hr 25min",
        shareText: "8%",
        barColor: .black,
        labelKind: .app(.monogram(text: "X", background: .black, foreground: .white))
      ),
      WeeklySankeyNodeContent(
        id: "medium",
        title: "Medium",
        durationText: "6hr 25min",
        shareText: "8%",
        barColor: .black,
        labelKind: .app(.monogram(text: "M", background: .black, foreground: .white))
      ),
      WeeklySankeyNodeContent(
        id: "other",
        title: "Other",
        durationText: "21hr 51min",
        shareText: "24%",
        barColor: Color(hex: "D9D9D9"),
        labelKind: .app(.none)
      ),
    ]
  )

  fileprivate static func sourceLink(
    id: String,
    target: String,
    value: CGFloat,
    order: Int,
    color: String,
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
        color: Color(hex: color),
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

  fileprivate static func appLink(
    id: String,
    source: String,
    target: String,
    value: CGFloat,
    sourceOrder: Int,
    targetOrder: Int,
    color: String,
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
        color: Color(hex: color),
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

#Preview("Weekly Sankey Distribution", traits: .fixedLayout(width: 948, height: 549)) {
  WeeklySankeyDistributionSection()
}
