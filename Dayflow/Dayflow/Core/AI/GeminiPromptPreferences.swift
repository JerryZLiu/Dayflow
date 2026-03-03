import Foundation

struct GeminiPromptOverrides: Codable, Equatable {
    var titleBlock: String?
    var summaryBlock: String?
    var detailedBlock: String?

    var isEmpty: Bool {
        let values = [titleBlock, summaryBlock, detailedBlock]
        return values.allSatisfy { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty
        }
    }
}

enum GeminiPromptPreferences {
    private static let overridesKey = "geminiPromptOverrides"
    private static let store = UserDefaults.standard

    static func load() -> GeminiPromptOverrides {
        guard let data = store.data(forKey: overridesKey) else {
            return GeminiPromptOverrides()
        }
        guard let overrides = try? JSONDecoder().decode(GeminiPromptOverrides.self, from: data) else {
            return GeminiPromptOverrides()
        }
        return overrides
    }

    static func save(_ overrides: GeminiPromptOverrides) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        store.set(data, forKey: overridesKey)
    }

    static func reset() {
        store.removeObject(forKey: overridesKey)
    }
}

enum GeminiPromptDefaults {
    static let titleBlock = """
# Title Guidelines

You're writing titles for a personal work journal. Each title is a memory trigger — when someone scans their timeline the next morning, it should make them go "oh right, that."

Write like the person would describe their day to a friend. Not a status report, not a Jira ticket, not a timesheet.

## The One Rule

**Be specific enough that the title could only describe one situation.**

"Bug fixes" could be anything. "Fixed the infinite scroll crash on search results" can only be one thing.

"Gaming session" could be any day. "League ARAM — Thresh and Jinx" is a specific session.

## Banned Words

These are corporate filler. No human writes them in a journal:

"research," "coordination," "management," "administration," "workflow," "sync," "alignment," "exploration," "investigation," "project development," "social chat," "various," "multiple," "several," "deep dive," "rabbit hole"

## Examples

- BAD: "Debugging issues" → GOOD: "Tracked down the Stripe webhook timeout"
- BAD: "Housing search and social media browsing" → GOOD: "Found a 2BR on Elm Street on Zillow"
- BAD: "Meeting coordination" → GOOD: "Scheduled coffee with Priya for Thursday"
- BAD: "Tech news and social media browsing" → GOOD: "Reading about the new Gemini release on X"
- BAD: "Gaming session and social chat" → GOOD: "Overwatch ranked — hit Diamond with Sara"
- BAD: "Subscription management" → GOOD: "Downgraded my Spotify to free tier"
- BAD: "Project development and code review" → GOOD: "Reviewed Jake's auth PR"
- BAD: "Commercial real estate research and subscription management" → GOOD: "Chatted with Jeffrey about CRE stocks"

## Multiple Activities

Don't overthink it. Just describe what happened naturally. Use commas, "and," "+," "between" — whatever reads well. Vary the structure so titles don't all sound the same.

- "Regen notification debugging between YouTube and election news"
- "Texted Tommy about meeting up, browsed Apple M5 news"
- "KRC stock lookup + Claude billing change"
- "Poking at the auth bug (mostly distracted)"

If one activity is clearly the main thing, just name that. The rest goes in the summary.

## Final Check

1. Could this title describe 100 different situations? → Too vague, add detail.
2. Would a human actually write this? → If it sounds corporate, rewrite it.
3. Will this bring back a specific memory? → If not, name the concrete thing.
"""

    static let summaryBlock = """
SUMMARIES

2-3 sentences max. First person without "I". Just state what happened.

Good:
- "Refactored user auth module in React, added OAuth support. Hit CORS issues with the backend API."
- "Designed landing page mockups in Figma. Exported assets and started implementing in Next.js."
- "Searched flights to Tokyo, coordinated dates with Evan and Anthony over Messages. Looked at Shibuya apartments on Blueground."

Bad:
- "Kicked off the morning by diving into design work before transitioning to development tasks." (filler, vague)
- "Started with refactoring before moving on to debugging some issues." (wordy, no specifics)
- "The session involved multiple context switches between different parts of the application." (says nothing)

Never use:
- "kicked off", "dove into", "started with", "began by"
- Third person ("The session", "The work")
- Mental states or assumptions about intent
"""

    static let detailedSummaryBlock = """
DETAILED SUMMARY

Granular activity log — every context switch, every app, every distinct action. This is the "show me exactly what happened" view.

Format:
[H:MM AM/PM] - [H:MM AM/PM] [specific action] [in app/tool] [on what]

Include:
- Specific file/document names when visible
- Page titles, tabs, search queries
- Actions: opened, edited, scrolled, searched, replied, watched
- Content context: what topic, what section, who you messaged

Good example:
"7:00 AM - 7:08 AM edited "Q4 Launch Plan" in Notion, added timeline section
7:08 AM - 7:10 AM replied to Mike in Slack #engineering
7:10 AM - 7:12 AM scrolled X home feed
7:12 AM - 7:18 AM back to Notion, wrote launch risks section
7:18 AM - 7:20 AM searched Google "feature flag best practices"
7:20 AM - 7:25 AM read LaunchDarkly docs
7:25 AM - 7:30 AM added feature flag notes to Notion doc"

Bad example:
"7:00 AM - 7:30 AM writing Notion doc
7:30 AM - 7:35 AM Slack
7:35 AM - 8:00 AM coding"
(Too coarse — what doc? which Slack channel? coding what?)

The goal: someone could reconstruct exactly what you did just from the detailed summary.
"""
}

struct GeminiPromptSections {
    let title: String
    let summary: String
    let detailedSummary: String

    init(overrides: GeminiPromptOverrides) {
        self.title = GeminiPromptSections.compose(defaultBlock: GeminiPromptDefaults.titleBlock, custom: overrides.titleBlock)
        self.summary = GeminiPromptSections.compose(defaultBlock: GeminiPromptDefaults.summaryBlock, custom: overrides.summaryBlock)
        self.detailedSummary = GeminiPromptSections.compose(defaultBlock: GeminiPromptDefaults.detailedSummaryBlock, custom: overrides.detailedBlock)
    }

    private static func compose(defaultBlock: String, custom: String?) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultBlock : trimmed
    }
}
