import SwiftUI

struct WeeklyTreemapSnapshot {
  let title: String
  let categories: [WeeklyTreemapCategory]

  static let figmaPreview = WeeklyTreemapSnapshot(
    title: "Most used per category",
    categories: [
      WeeklyTreemapCategory(
        id: "design",
        name: "Design",
        palette: .design,
        apps: [
          WeeklyTreemapApp(
            id: "figma",
            name: "Figma",
            duration: 18 * 3600 + 24 * 60,
            change: .positive(45)
          ),
          WeeklyTreemapApp(
            id: "midjourney",
            name: "Midjourney",
            duration: 6 * 3600 + 7 * 60,
            change: .negative(45)
          ),
        ]
      ),
      WeeklyTreemapCategory(
        id: "communication",
        name: "Communication",
        palette: .communication,
        apps: [
          WeeklyTreemapApp(
            id: "zoom",
            name: "Zoom",
            duration: 18 * 3600 + 24 * 60,
            change: .neutral(2)
          ),
          WeeklyTreemapApp(
            id: "slack",
            name: "Slack",
            duration: 5 * 3600 + 24 * 60,
            change: .negative(45)
          ),
          WeeklyTreemapApp(
            id: "clickup",
            name: "ClickUp",
            duration: 24 * 60,
            change: .neutral(2)
          ),
        ]
      ),
      WeeklyTreemapCategory(
        id: "testing",
        name: "Testing",
        palette: .testing,
        apps: [
          WeeklyTreemapApp(
            id: "dayflow",
            name: "Dayflow",
            duration: 5 * 3600 + 24 * 60,
            change: .positive(45)
          ),
          WeeklyTreemapApp(
            id: "testing-clickup",
            name: "ClickUp",
            duration: 4 * 3600 + 24 * 60,
            change: .negative(45)
          ),
          WeeklyTreemapApp(
            id: "testing-slack",
            name: "Slack",
            duration: 3 * 3600 + 24 * 60,
            change: .positive(45)
          ),
        ]
      ),
      WeeklyTreemapCategory(
        id: "research",
        name: "Research",
        palette: .research,
        apps: [
          WeeklyTreemapApp(
            id: "chatgpt",
            name: "ChatGPT",
            duration: 4 * 3600 + 24 * 60,
            change: .neutral(2)
          ),
          WeeklyTreemapApp(
            id: "google",
            name: "Google",
            duration: 3 * 3600 + 24 * 60,
            change: .neutral(2)
          ),
          WeeklyTreemapApp(
            id: "claude",
            name: "Claude",
            duration: 2 * 3600 + 24 * 60,
            change: .negative(45)
          ),
        ]
      ),
    ]
  )

  static let dominantCategoryPreview = WeeklyTreemapSnapshot(
    title: "Most used per category",
    categories: [
      WeeklyTreemapCategory(
        id: "design",
        name: "Design",
        palette: .design,
        apps: [
          WeeklyTreemapApp(
            id: "figma", name: "Figma", duration: hours(31, 20), change: .positive(62)),
          WeeklyTreemapApp(
            id: "framer", name: "Framer", duration: hours(7, 40), change: .negative(18)),
          WeeklyTreemapApp(
            id: "after-effects", name: "After Effects", duration: hours(1, 10), change: .neutral(4)),
          WeeklyTreemapApp(
            id: "coolors", name: "Coolors", duration: hours(0, 18), change: .positive(6)),
          WeeklyTreemapApp(
            id: "fonts", name: "Adobe Fonts", duration: hours(0, 11), change: .negative(2)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "communication",
        name: "Communication",
        palette: .communication,
        apps: [
          WeeklyTreemapApp(id: "zoom", name: "Zoom", duration: hours(4, 5), change: .negative(12)),
          WeeklyTreemapApp(
            id: "slack", name: "Slack", duration: hours(1, 35), change: .positive(8)),
          WeeklyTreemapApp(id: "meet", name: "Meet", duration: hours(0, 42), change: .neutral(0)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "testing",
        name: "Testing",
        palette: .testing,
        apps: [
          WeeklyTreemapApp(
            id: "dayflow", name: "Dayflow", duration: hours(2, 24), change: .positive(24)),
          WeeklyTreemapApp(
            id: "clickup", name: "ClickUp", duration: hours(0, 53), change: .negative(9)),
          WeeklyTreemapApp(
            id: "posthog", name: "PostHog", duration: hours(0, 21), change: .neutral(1)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "research",
        name: "Research",
        palette: .research,
        apps: [
          WeeklyTreemapApp(
            id: "chatgpt", name: "ChatGPT", duration: hours(1, 46), change: .positive(14)),
          WeeklyTreemapApp(
            id: "claude", name: "Claude", duration: hours(0, 44), change: .negative(5)),
          WeeklyTreemapApp(
            id: "google", name: "Google", duration: hours(0, 28), change: .neutral(2)),
        ]
      ),
    ]
  )

  static let tinyTailPreview = WeeklyTreemapSnapshot(
    title: "Most used per category",
    categories: [
      WeeklyTreemapCategory(
        id: "research",
        name: "Research",
        palette: .research,
        apps: [
          WeeklyTreemapApp(
            id: "chatgpt", name: "ChatGPT", duration: hours(6, 12), change: .positive(22)),
          WeeklyTreemapApp(
            id: "google", name: "Google", duration: hours(2, 54), change: .neutral(3)),
          WeeklyTreemapApp(
            id: "claude", name: "Claude", duration: hours(1, 47), change: .negative(11)),
          WeeklyTreemapApp(
            id: "perplexity", name: "Perplexity", duration: hours(0, 34), change: .positive(7)),
          WeeklyTreemapApp(
            id: "wiki", name: "Wikipedia", duration: hours(0, 18), change: .neutral(2)),
          WeeklyTreemapApp(id: "docs", name: "Docs", duration: hours(0, 15), change: .negative(1)),
          WeeklyTreemapApp(
            id: "hn", name: "Hacker News", duration: hours(0, 8), change: .neutral(0)),
          WeeklyTreemapApp(
            id: "reddit", name: "Reddit", duration: hours(0, 6), change: .positive(1)),
          WeeklyTreemapApp(
            id: "stack", name: "Stack Overflow", duration: hours(0, 5), change: .neutral(0)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "communication",
        name: "Communication",
        palette: .communication,
        apps: [
          WeeklyTreemapApp(id: "zoom", name: "Zoom", duration: hours(5, 40), change: .neutral(5)),
          WeeklyTreemapApp(
            id: "slack", name: "Slack", duration: hours(4, 26), change: .negative(14)),
          WeeklyTreemapApp(
            id: "linear", name: "Linear", duration: hours(1, 12), change: .positive(12)),
          WeeklyTreemapApp(id: "mail", name: "Mail", duration: hours(0, 29), change: .neutral(2)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "design",
        name: "Design",
        palette: .design,
        apps: [
          WeeklyTreemapApp(
            id: "figma", name: "Figma", duration: hours(7, 30), change: .positive(18)),
          WeeklyTreemapApp(
            id: "midjourney", name: "Midjourney", duration: hours(2, 4), change: .negative(6)),
        ]
      ),
    ]
  )

  static let crowdedPreview = WeeklyTreemapSnapshot(
    title: "Most used per category",
    categories: [
      WeeklyTreemapCategory(
        id: "design",
        name: "Design",
        palette: .design,
        apps: [
          WeeklyTreemapApp(
            id: "figma", name: "Figma", duration: hours(8, 30), change: .positive(14)),
          WeeklyTreemapApp(
            id: "midjourney", name: "Midjourney", duration: hours(6, 10), change: .negative(9)),
          WeeklyTreemapApp(
            id: "framer", name: "Framer", duration: hours(4, 40), change: .positive(6)),
          WeeklyTreemapApp(
            id: "spline", name: "Spline", duration: hours(3, 20), change: .neutral(2)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "communication",
        name: "Communication",
        palette: .communication,
        apps: [
          WeeklyTreemapApp(id: "zoom", name: "Zoom", duration: hours(7, 45), change: .negative(6)),
          WeeklyTreemapApp(
            id: "slack", name: "Slack", duration: hours(6, 55), change: .positive(11)),
          WeeklyTreemapApp(
            id: "discord", name: "Discord", duration: hours(3, 12), change: .neutral(1)),
          WeeklyTreemapApp(id: "mail", name: "Mail", duration: hours(1, 38), change: .negative(3)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "testing",
        name: "Testing",
        palette: .testing,
        apps: [
          WeeklyTreemapApp(
            id: "dayflow", name: "Dayflow", duration: hours(5, 10), change: .positive(17)),
          WeeklyTreemapApp(
            id: "clickup", name: "ClickUp", duration: hours(4, 24), change: .negative(12)),
          WeeklyTreemapApp(id: "slack", name: "Slack", duration: hours(3, 28), change: .neutral(2)),
          WeeklyTreemapApp(
            id: "posthog", name: "PostHog", duration: hours(1, 52), change: .positive(4)),
        ]
      ),
      WeeklyTreemapCategory(
        id: "research",
        name: "Research",
        palette: .research,
        apps: [
          WeeklyTreemapApp(
            id: "chatgpt", name: "ChatGPT", duration: hours(5, 24), change: .positive(8)),
          WeeklyTreemapApp(
            id: "google", name: "Google", duration: hours(4, 42), change: .neutral(3)),
          WeeklyTreemapApp(
            id: "claude", name: "Claude", duration: hours(3, 8), change: .negative(7)),
          WeeklyTreemapApp(
            id: "perplexity", name: "Perplexity", duration: hours(2, 16), change: .positive(5)),
        ]
      ),
    ]
  )

  static func hours(_ hours: Int, _ minutes: Int) -> TimeInterval {
    TimeInterval((hours * 60 + minutes) * 60)
  }
}
