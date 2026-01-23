import Foundation

struct ChatCLIPromptOverrides: Codable, Equatable {
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

enum ChatCLIPromptPreferences {
    private static let overridesKey = "chatCLIPromptOverrides"
    private static let store = UserDefaults.standard

    static func load() -> ChatCLIPromptOverrides {
        guard let data = store.data(forKey: overridesKey) else {
            return ChatCLIPromptOverrides()
        }
        guard let overrides = try? JSONDecoder().decode(ChatCLIPromptOverrides.self, from: data) else {
            return ChatCLIPromptOverrides()
        }
        return overrides
    }

    static func save(_ overrides: ChatCLIPromptOverrides) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        store.set(data, forKey: overridesKey)
    }

    static func reset() {
        store.removeObject(forKey: overridesKey)
    }
}

enum ChatCLIPromptDefaults {
    static let titleBlock = """
TITLE GUIDELINES:
Core principle: If you read this title next week, would you know what you actually did?
Be specific:
Every title needs concrete details—the feature, the bug, the person, the thing you were working on.

Bad: "Worked on UI" → Good: "Fixed dropdown overflow in settings page"
Bad: "Had a meeting" → Good: "Planned launch timeline with Sarah"
Bad: "Did research" → Good: "Compared Stripe vs Paddle pricing"
Bad: "Watched videos" → Good: "Watched UFC 300 highlights"
Bad: "Debugged issues" → Good: "Fixed OAuth token refresh on mobile"
Bad: "Chatted with team" → Good: "Decided on API versioning strategy with backend team"
Bad: "Played games" → Good: "Elden Ring — cleared Rennala boss"
Bad: "Made a reservation" → Good: "Booked dinner at Resy for Saturday"
Bad: "Browsed internet" → Good: "Researched visa requirements for Japan"
Bad: "Coded" → Good: "Built CSV export for dashboard"

Avoid vague words:
These words hide what actually happened:

"worked on" → doing what to it?
"looked at" → reviewing? debugging? reading?
"handled" → fixed? ignored? escalated?
"dealt with" → means nothing
"various" / "some" / "multiple" → name them or pick the main one
"deep dive" / "rabbit hole" → just say what you researched
"sync" / "aligned" / "circled back" → say what you discussed or decided

Avoid repetitive structure:
Don't start every title with a verb. Don't follow a formula. Mix it up naturally based on what the activity actually was:

Verb-first: "Fixed login timeout on mobile"
Noun-led: "SwiftUI scroll fixes"
Person-anchored: "Call with Sarah about pricing"
Topic-focused: "Gemini rate limits research"
Gerund: "Planning the beta access flow"
Casual: "Elden Ring — cleared Rennala boss"
Event: "Flight booking for Tokyo trip"
Conversational: "Trevor chat about launch timing"

If you notice several titles in a row starting with verbs like "Fixed... Debugged... Built... Implemented..." — vary the structure.
Use "and" sparingly:
Don't use "and" to connect unrelated things. If you have two unrelated activities, pick the more important one for the title. The other goes in the summary.

Bad: "Fixed bug and replied to emails" → Good: "Fixed checkout timeout" (emails in summary)
Bad: "Booked flights + reviewed PRs" → Good: "Booked SFO flight for Tuesday" (PRs in summary)
Bad: "Watched YouTube and coded" → Good: Title the main activity, YouTube is a distraction

"And" is okay when both parts serve the same goal:

OK: "Designed and prototyped new nav" (same feature)
OK: "Researched and booked Tokyo hotel" (same task)
OK: "Wrote and shipped the migration script" (same deliverable)
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

Granular activity log. This is the "show me exactly what happened" view.

Format:
[H:MM AM/PM] - [H:MM AM/PM] [specific action] [in app/tool] [on what]
Each line should be one sentence (~25 words max). Be concise but detailed.

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
"""
}

struct ChatCLIPromptSections {
    let title: String
    let summary: String
    let detailedSummary: String

    init(overrides: ChatCLIPromptOverrides) {
        self.title = ChatCLIPromptSections.compose(defaultBlock: ChatCLIPromptDefaults.titleBlock, custom: overrides.titleBlock)
        self.summary = ChatCLIPromptSections.compose(defaultBlock: ChatCLIPromptDefaults.summaryBlock, custom: overrides.summaryBlock)
        self.detailedSummary = ChatCLIPromptSections.compose(defaultBlock: ChatCLIPromptDefaults.detailedSummaryBlock, custom: overrides.detailedBlock)
    }

    private static func compose(defaultBlock: String, custom: String?) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultBlock : trimmed
    }
}
