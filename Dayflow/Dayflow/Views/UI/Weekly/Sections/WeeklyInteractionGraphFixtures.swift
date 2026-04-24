import SwiftUI

enum WeeklyInteractionGraphFixtures {
  static let title = "Interactions between most used applications"
  static let subtitle = "More than 80% of recorded time was spent using these applications."

  static let figmaReference = WeeklyInteractionGraphSnapshot(
    title: title,
    subtitle: subtitle,
    nodes: [
      .init(id: "figma", title: "Figma", category: .work, glyph: .figma, importanceBoost: 10),
      .init(
        id: "raindrop", title: "Raindrop", category: .work,
        glyph: .monogram("R", backgroundHex: "2B2724", foregroundHex: "FFFFFF"), importanceBoost: 3),
      .init(id: "framer", title: "Framer", category: .work, glyph: .framer),
      .init(id: "notion", title: "Notion", category: .work, glyph: .notion),
      .init(id: "slack", title: "Slack", category: .work, glyph: .slack),
      .init(id: "stats", title: "Stats", category: .work, glyph: .bars),
      .init(id: "zoom", title: "Zoom", category: .work, glyph: .zoom),
      .init(id: "focus", title: "Focus", category: .work, glyph: .bullseye),
      .init(id: "cube", title: "Cube", category: .personal, glyph: .cube, importanceBoost: 2),
      .init(id: "chatgpt", title: "ChatGPT", category: .personal, glyph: .asset("ChatGPTLogo")),
      .init(id: "burst", title: "Burst", category: .personal, glyph: .burst, importanceBoost: 2),
      .init(id: "x", title: "X", category: .distraction, glyph: .x),
      .init(id: "save", title: "Saved", category: .distraction, glyph: .bookmark),
      .init(id: "reddit", title: "Reddit", category: .distraction, glyph: .reddit),
      .init(id: "youtube", title: "YouTube", category: .distraction, glyph: .youtube),
    ],
    edges: [
      .init(id: "f1", sourceID: "figma", targetID: "raindrop", weight: 7.2),
      .init(id: "f2", sourceID: "figma", targetID: "framer", weight: 4.2),
      .init(id: "f3", sourceID: "figma", targetID: "notion", weight: 4.8),
      .init(id: "f4", sourceID: "figma", targetID: "slack", weight: 5.8),
      .init(id: "f5", sourceID: "figma", targetID: "stats", weight: 2.1),
      .init(id: "f6", sourceID: "figma", targetID: "zoom", weight: 2.5),
      .init(id: "f7", sourceID: "figma", targetID: "focus", weight: 1.6),
      .init(id: "f8", sourceID: "figma", targetID: "cube", weight: 3.3),
      .init(id: "f9", sourceID: "figma", targetID: "chatgpt", weight: 2.9),
      .init(id: "f10", sourceID: "figma", targetID: "burst", weight: 3.1),
      .init(id: "f11", sourceID: "figma", targetID: "x", weight: 3.4),
      .init(id: "f12", sourceID: "figma", targetID: "save", weight: 2.0),
      .init(id: "f13", sourceID: "figma", targetID: "reddit", weight: 2.3),
      .init(id: "f14", sourceID: "figma", targetID: "youtube", weight: 4.0),
      .init(id: "f15", sourceID: "slack", targetID: "notion", weight: 2.4),
      .init(id: "f16", sourceID: "slack", targetID: "zoom", weight: 2.2),
      .init(id: "f17", sourceID: "slack", targetID: "stats", weight: 1.7),
      .init(id: "f18", sourceID: "cube", targetID: "burst", weight: 2.0),
      .init(id: "f19", sourceID: "chatgpt", targetID: "burst", weight: 1.8),
      .init(id: "f20", sourceID: "x", targetID: "save", weight: 2.3),
      .init(id: "f21", sourceID: "x", targetID: "reddit", weight: 3.0),
      .init(id: "f22", sourceID: "x", targetID: "youtube", weight: 2.5),
      .init(id: "f23", sourceID: "reddit", targetID: "youtube", weight: 2.8),
      .init(id: "f24", sourceID: "cube", targetID: "youtube", weight: 1.3),
      .init(id: "f25", sourceID: "focus", targetID: "chatgpt", weight: 1.2),
    ],
    preferredCenterNodeID: "figma"
  )

  static let dualHubTension = WeeklyInteractionGraphSnapshot(
    title: title,
    subtitle: "Edge case: two strong work hubs compete for the center of gravity.",
    nodes: [
      .init(id: "figma", title: "Figma", category: .work, glyph: .figma, importanceBoost: 5),
      .init(id: "slack", title: "Slack", category: .work, glyph: .slack, importanceBoost: 5),
      .init(id: "github", title: "GitHub", category: .work, glyph: .asset("GithubIcon")),
      .init(id: "notion", title: "Notion", category: .work, glyph: .notion),
      .init(id: "zoom", title: "Zoom", category: .work, glyph: .zoom),
      .init(id: "chatgpt", title: "ChatGPT", category: .personal, glyph: .asset("ChatGPTLogo")),
      .init(
        id: "mail", title: "Mail", category: .personal,
        glyph: .monogram("M", backgroundHex: "D9D9D9", foregroundHex: "333333")),
      .init(id: "youtube", title: "YouTube", category: .distraction, glyph: .youtube),
      .init(id: "x", title: "X", category: .distraction, glyph: .x),
      .init(id: "reddit", title: "Reddit", category: .distraction, glyph: .reddit),
    ],
    edges: [
      .init(id: "d1", sourceID: "figma", targetID: "github", weight: 5),
      .init(id: "d2", sourceID: "figma", targetID: "notion", weight: 4),
      .init(id: "d3", sourceID: "figma", targetID: "chatgpt", weight: 2.5),
      .init(id: "d4", sourceID: "figma", targetID: "youtube", weight: 1.3),
      .init(id: "d5", sourceID: "slack", targetID: "zoom", weight: 4.5),
      .init(id: "d6", sourceID: "slack", targetID: "mail", weight: 4),
      .init(id: "d7", sourceID: "slack", targetID: "notion", weight: 2.4),
      .init(id: "d8", sourceID: "slack", targetID: "x", weight: 1.2),
      .init(id: "d9", sourceID: "figma", targetID: "slack", weight: 4.3),
      .init(id: "d10", sourceID: "youtube", targetID: "reddit", weight: 2.4),
      .init(id: "d11", sourceID: "x", targetID: "reddit", weight: 2.1),
      .init(id: "d12", sourceID: "chatgpt", targetID: "mail", weight: 1.4),
    ]
  )

  static let distractionSpike = WeeklyInteractionGraphSnapshot(
    title: title,
    subtitle: "Edge case: one work hub with a dense distraction cluster on the right.",
    nodes: [
      .init(id: "figma", title: "Figma", category: .work, glyph: .figma, importanceBoost: 7),
      .init(id: "github", title: "GitHub", category: .work, glyph: .asset("GithubIcon")),
      .init(id: "notion", title: "Notion", category: .work, glyph: .notion),
      .init(id: "slack", title: "Slack", category: .work, glyph: .slack),
      .init(id: "chatgpt", title: "ChatGPT", category: .personal, glyph: .asset("ChatGPTLogo")),
      .init(id: "cube", title: "Cube", category: .personal, glyph: .cube),
      .init(id: "youtube", title: "YouTube", category: .distraction, glyph: .youtube),
      .init(id: "x", title: "X", category: .distraction, glyph: .x),
      .init(id: "reddit", title: "Reddit", category: .distraction, glyph: .reddit),
      .init(id: "news", title: "News", category: .distraction, glyph: .bookmark),
      .init(
        id: "twitch", title: "Twitch", category: .distraction,
        glyph: .monogram("T", backgroundHex: "8C5CFF", foregroundHex: "FFFFFF")),
      .init(id: "music", title: "Music", category: .distraction, glyph: .burst),
    ],
    edges: [
      .init(id: "s1", sourceID: "figma", targetID: "github", weight: 4),
      .init(id: "s2", sourceID: "figma", targetID: "notion", weight: 4),
      .init(id: "s3", sourceID: "figma", targetID: "slack", weight: 4),
      .init(id: "s4", sourceID: "figma", targetID: "chatgpt", weight: 2.5),
      .init(id: "s5", sourceID: "figma", targetID: "cube", weight: 2.2),
      .init(id: "s6", sourceID: "figma", targetID: "youtube", weight: 3.2),
      .init(id: "s7", sourceID: "figma", targetID: "x", weight: 2.4),
      .init(id: "s8", sourceID: "figma", targetID: "reddit", weight: 2.1),
      .init(id: "s9", sourceID: "youtube", targetID: "x", weight: 3.5),
      .init(id: "s10", sourceID: "youtube", targetID: "reddit", weight: 3.5),
      .init(id: "s11", sourceID: "youtube", targetID: "news", weight: 3.1),
      .init(id: "s12", sourceID: "youtube", targetID: "twitch", weight: 2.9),
      .init(id: "s13", sourceID: "youtube", targetID: "music", weight: 2.7),
      .init(id: "s14", sourceID: "x", targetID: "reddit", weight: 2.8),
      .init(id: "s15", sourceID: "reddit", targetID: "news", weight: 2.6),
      .init(id: "s16", sourceID: "twitch", targetID: "music", weight: 2.4),
      .init(id: "s17", sourceID: "cube", targetID: "youtube", weight: 1.7),
    ],
    preferredCenterNodeID: "figma"
  )

  static let longTailNoise = WeeklyInteractionGraphSnapshot(
    title: title,
    subtitle: "Edge case: lots of small low-weight peripherals around one dominant app.",
    nodes: [
      .init(id: "figma", title: "Figma", category: .work, glyph: .figma, importanceBoost: 9),
      .init(id: "github", title: "GitHub", category: .work, glyph: .asset("GithubIcon")),
      .init(id: "notion", title: "Notion", category: .work, glyph: .notion),
      .init(id: "slack", title: "Slack", category: .work, glyph: .slack),
      .init(id: "zoom", title: "Zoom", category: .work, glyph: .zoom),
      .init(id: "chatgpt", title: "ChatGPT", category: .personal, glyph: .asset("ChatGPTLogo")),
      .init(id: "chrome", title: "Chrome", category: .personal, glyph: .asset("ChromeFavicon")),
      .init(id: "linear", title: "Linear", category: .personal, glyph: .linear),
      .init(
        id: "calendar", title: "Calendar", category: .personal,
        glyph: .monogram("C", backgroundHex: "D9D9D9", foregroundHex: "333333")),
      .init(
        id: "mail", title: "Mail", category: .personal,
        glyph: .monogram("M", backgroundHex: "D9D9D9", foregroundHex: "333333")),
      .init(id: "youtube", title: "YouTube", category: .distraction, glyph: .youtube),
      .init(id: "x", title: "X", category: .distraction, glyph: .x),
      .init(id: "reddit", title: "Reddit", category: .distraction, glyph: .reddit),
      .init(id: "news", title: "News", category: .distraction, glyph: .bookmark),
    ],
    edges: [
      .init(id: "l1", sourceID: "figma", targetID: "github", weight: 5),
      .init(id: "l2", sourceID: "figma", targetID: "notion", weight: 4.4),
      .init(id: "l3", sourceID: "figma", targetID: "slack", weight: 4.1),
      .init(id: "l4", sourceID: "figma", targetID: "zoom", weight: 3.6),
      .init(id: "l5", sourceID: "figma", targetID: "chatgpt", weight: 2.2),
      .init(id: "l6", sourceID: "figma", targetID: "chrome", weight: 1.9),
      .init(id: "l7", sourceID: "figma", targetID: "linear", weight: 1.7),
      .init(id: "l8", sourceID: "figma", targetID: "calendar", weight: 1.2),
      .init(id: "l9", sourceID: "figma", targetID: "mail", weight: 1.1),
      .init(id: "l10", sourceID: "figma", targetID: "youtube", weight: 1.4),
      .init(id: "l11", sourceID: "figma", targetID: "x", weight: 1.1),
      .init(id: "l12", sourceID: "figma", targetID: "reddit", weight: 1.0),
      .init(id: "l13", sourceID: "figma", targetID: "news", weight: 0.9),
      .init(id: "l14", sourceID: "chatgpt", targetID: "chrome", weight: 1.2),
      .init(id: "l15", sourceID: "youtube", targetID: "x", weight: 1.1),
    ],
    preferredCenterNodeID: "figma"
  )
}

#Preview("Interaction Graph – Figma Reference", traits: .fixedLayout(width: 660, height: 631)) {
  WeeklyInteractionGraphPrototypeSection(snapshot: WeeklyInteractionGraphFixtures.figmaReference)
}

#Preview("Interaction Graph – Two Hubs", traits: .fixedLayout(width: 660, height: 631)) {
  WeeklyInteractionGraphPrototypeSection(snapshot: WeeklyInteractionGraphFixtures.dualHubTension)
}

#Preview(
  "Interaction Graph – Dense Distraction Cluster", traits: .fixedLayout(width: 660, height: 631)
) {
  WeeklyInteractionGraphPrototypeSection(snapshot: WeeklyInteractionGraphFixtures.distractionSpike)
}

#Preview("Interaction Graph – Long Tail", traits: .fixedLayout(width: 660, height: 631)) {
  WeeklyInteractionGraphPrototypeSection(snapshot: WeeklyInteractionGraphFixtures.longTailNoise)
}
