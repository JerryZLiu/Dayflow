import SwiftUI

extension WeeklySankeyFixture {
  static let sourceBlendNeutral = Color(hex: "F4F4F4")
  static let previewTotalMinutes = 80 * 60

  static let balanced = WeeklySankeyFixture(
    columns: [
      SankeyColumnSpec(id: "source", x: 52, topY: 151, barWidth: 10, pointsPerUnit: 2.7),
      SankeyColumnSpec(id: "categories", x: 434, topY: 86, barWidth: 10, pointsPerUnit: 2.08),
      SankeyColumnSpec(id: "apps", x: 798, topY: 16, barWidth: 10, pointsPerUnit: 1.42),
    ],
    nodes: [
      SankeyNodeSpec(
        id: "source-communication",
        columnID: "source",
        order: 0,
        visualWeight: 100,
        preferredHeight: 298
      ),

      SankeyNodeSpec(
        id: "research",
        columnID: "categories",
        order: 0,
        visualWeight: 18,
        preferredHeight: 42
      ),
      SankeyNodeSpec(
        id: "communication",
        columnID: "categories",
        order: 1,
        visualWeight: 16,
        preferredHeight: 36,
        gapBefore: 22
      ),
      SankeyNodeSpec(
        id: "design",
        columnID: "categories",
        order: 2,
        visualWeight: 27,
        preferredHeight: 76,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "general",
        columnID: "categories",
        order: 3,
        visualWeight: 13,
        preferredHeight: 34,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "testing",
        columnID: "categories",
        order: 4,
        visualWeight: 10,
        preferredHeight: 26,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "distractions",
        columnID: "categories",
        order: 5,
        visualWeight: 11,
        preferredHeight: 30,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "personal",
        columnID: "categories",
        order: 6,
        visualWeight: 5,
        preferredHeight: 14,
        gapBefore: 24
      ),

      SankeyNodeSpec(
        id: "chatgpt",
        columnID: "apps",
        order: 0,
        visualWeight: 12,
        preferredHeight: 22
      ),
      SankeyNodeSpec(
        id: "zoom",
        columnID: "apps",
        order: 1,
        visualWeight: 6,
        preferredHeight: 12,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "clickup",
        columnID: "apps",
        order: 2,
        visualWeight: 4,
        preferredHeight: 8,
        gapBefore: 24
      ),
      SankeyNodeSpec(
        id: "slack",
        columnID: "apps",
        order: 3,
        visualWeight: 12,
        preferredHeight: 34,
        gapBefore: 62
      ),
      SankeyNodeSpec(
        id: "youtube",
        columnID: "apps",
        order: 4,
        visualWeight: 8,
        preferredHeight: 18,
        gapBefore: 42
      ),
      SankeyNodeSpec(
        id: "claude",
        columnID: "apps",
        order: 5,
        visualWeight: 11,
        preferredHeight: 22,
        gapBefore: 34
      ),
      SankeyNodeSpec(
        id: "figma",
        columnID: "apps",
        order: 6,
        visualWeight: 24,
        preferredHeight: 62,
        gapBefore: 42
      ),
      SankeyNodeSpec(
        id: "x",
        columnID: "apps",
        order: 7,
        visualWeight: 11,
        preferredHeight: 28,
        gapBefore: 18
      ),
      SankeyNodeSpec(
        id: "medium",
        columnID: "apps",
        order: 8,
        visualWeight: 4,
        preferredHeight: 10,
        gapBefore: 20
      ),
      SankeyNodeSpec(
        id: "other",
        columnID: "apps",
        order: 9,
        visualWeight: 8,
        preferredHeight: 22,
        gapBefore: 20
      ),
    ],
    links: [
      sourceLink(
        id: "left-research", target: "research", value: 18, order: 0, opacity: 0.88
      ),
      sourceLink(
        id: "left-communication", target: "communication", value: 16, order: 1, opacity: 0.86),
      sourceLink(
        id: "left-design", target: "design", value: 27, order: 2, opacity: 0.84),
      sourceLink(
        id: "left-general", target: "general", value: 13, order: 3, opacity: 0.86),
      sourceLink(
        id: "left-testing", target: "testing", value: 10, order: 4, opacity: 0.86),
      sourceLink(
        id: "left-distractions", target: "distractions", value: 11, order: 5, opacity: 0.88),
      sourceLink(
        id: "left-personal", target: "personal", value: 5, order: 6, opacity: 0.88),

      appLink(
        id: "research-chatgpt", source: "research", target: "chatgpt", value: 12, sourceOrder: 0,
        targetOrder: 0, opacity: 0.88),
      appLink(
        id: "research-zoom", source: "research", target: "zoom", value: 6, sourceOrder: 1,
        targetOrder: 1, opacity: 0.82),

      appLink(
        id: "communication-clickup", source: "communication", target: "clickup", value: 4,
        sourceOrder: 0, targetOrder: 2, opacity: 0.88),
      appLink(
        id: "communication-slack", source: "communication", target: "slack", value: 12,
        sourceOrder: 1, targetOrder: 3, opacity: 0.84),

      appLink(
        id: "design-youtube", source: "design", target: "youtube", value: 2, sourceOrder: 0,
        targetOrder: 4, opacity: 0.78),
      appLink(
        id: "design-claude", source: "design", target: "claude", value: 5, sourceOrder: 1,
        targetOrder: 5, opacity: 0.80),
      appLink(
        id: "design-figma", source: "design", target: "figma", value: 20, sourceOrder: 2,
        targetOrder: 6, opacity: 0.88),

      appLink(
        id: "general-youtube", source: "general", target: "youtube", value: 3, sourceOrder: 0,
        targetOrder: 4, opacity: 0.82),
      appLink(
        id: "general-other", source: "general", target: "other", value: 5, sourceOrder: 1,
        targetOrder: 9, opacity: 0.80),
      appLink(
        id: "general-x", source: "general", target: "x", value: 5, sourceOrder: 2, targetOrder: 7,
        opacity: 0.80),

      appLink(
        id: "testing-claude", source: "testing", target: "claude", value: 6, sourceOrder: 0,
        targetOrder: 5, opacity: 0.84),
      appLink(
        id: "testing-figma", source: "testing", target: "figma", value: 3, sourceOrder: 1,
        targetOrder: 6, opacity: 0.84),
      appLink(
        id: "testing-x", source: "testing", target: "x", value: 1, sourceOrder: 2, targetOrder: 7,
        opacity: 0.78),

      appLink(
        id: "distractions-youtube", source: "distractions", target: "youtube", value: 3,
        sourceOrder: 0, targetOrder: 4, opacity: 0.82),
      appLink(
        id: "distractions-x", source: "distractions", target: "x", value: 5, sourceOrder: 1,
        targetOrder: 7, opacity: 0.82),
      appLink(
        id: "distractions-medium", source: "distractions", target: "medium", value: 3,
        sourceOrder: 2, targetOrder: 8, opacity: 0.80),

      appLink(
        id: "personal-other", source: "personal", target: "other", value: 3, sourceOrder: 0,
        targetOrder: 9, opacity: 0.78),
      appLink(
        id: "personal-medium", source: "personal", target: "medium", value: 1, sourceOrder: 1,
        targetOrder: 8, opacity: 0.76),
      appLink(
        id: "personal-figma", source: "personal", target: "figma", value: 1, sourceOrder: 2,
        targetOrder: 6, opacity: 0.76),
    ],
    contents: [
      WeeklySankeyNodeContent(
        id: "source-communication",
        title: "Communication",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "D9CBC0",
        labelKind: .plain
      ),

      WeeklySankeyNodeContent(
        id: "research",
        title: "Research",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "93BCFF",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "communication",
        title: "Communication",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "6CDACD",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "design",
        title: "Design",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "DE9DFC",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "general",
        title: "General",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "BFB6AE",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "testing",
        title: "Testing",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "FFA189",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "distractions",
        title: "Distractions",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "FF5950",
        labelKind: .plain
      ),
      WeeklySankeyNodeContent(
        id: "personal",
        title: "Personal",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "FFC6B7",
        labelKind: .plain
      ),

      WeeklySankeyNodeContent(
        id: "chatgpt",
        title: "Chat GPT",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "333333",
        labelKind: .app(.asset("ChatGPTLogo"))
      ),
      WeeklySankeyNodeContent(
        id: "zoom",
        title: "Zoom",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "4085FD",
        labelKind: .app(.favicon(raw: "zoom.us", host: "zoom.us"))
      ),
      WeeklySankeyNodeContent(
        id: "clickup",
        title: "ClickUp",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "FD1BB9",
        labelKind: .app(.favicon(raw: "clickup.com", host: "clickup.com"))
      ),
      WeeklySankeyNodeContent(
        id: "slack",
        title: "Slack",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "36C5F0",
        labelKind: .app(.favicon(raw: "slack.com", host: "slack.com"))
      ),
      WeeklySankeyNodeContent(
        id: "youtube",
        title: "YouTube",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "FF0000",
        labelKind: .app(.favicon(raw: "youtube.com", host: "youtube.com"))
      ),
      WeeklySankeyNodeContent(
        id: "claude",
        title: "Claude",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "D97757",
        labelKind: .app(.asset("ClaudeLogo"))
      ),
      WeeklySankeyNodeContent(
        id: "figma",
        title: "Figma",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "FF7262",
        labelKind: .app(.favicon(raw: "figma.com", host: "figma.com"))
      ),
      WeeklySankeyNodeContent(
        id: "x",
        title: "X",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "000000",
        labelKind: .app(.monogram(text: "X", background: .black, foreground: .white))
      ),
      WeeklySankeyNodeContent(
        id: "medium",
        title: "Medium",
        durationText: "6hr 25min",
        shareText: "8%",
        barColorHex: "000000",
        labelKind: .app(.monogram(text: "M", background: .black, foreground: .white))
      ),
      WeeklySankeyNodeContent(
        id: "other",
        title: "Other",
        durationText: "21hr 51min",
        shareText: "24%",
        barColorHex: "D9D9D9",
        labelKind: .app(.none)
      ),
    ]
  )

  static let airier = makeAirierFixture(from: .balanced)

}
