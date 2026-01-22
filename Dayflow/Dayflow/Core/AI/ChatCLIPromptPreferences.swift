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
Your title should help the user mentally reconstruct what they did. Be specific, but concise.
Rule 1: Lead with a strong verb
Strong verbs say what actually happened:

built, implemented, fixed, debugged, shipped
booked, planned, coordinated, scheduled
watched, played, browsed, read
drafted, wrote, edited
researched, investigated, diagnosed

Weak verbs hide what happened:

"worked on" → worked on what? doing what to it?
"looked at" → were you reviewing? debugging? reading?
"handled" → did you fix it? respond to it? ignore it?
"dealt with" → means nothing
"did some" → means nothing

Examples:

Bad: "Worked on UI" → Good: "Fixed dropdown overflow in settings page"
Bad: "Looked at analytics" → Good: "Built retention dashboard in Amplitude"
Bad: "Handled customer issue" → Good: "Debugged sync failure for enterprise user"
Bad: "Did some research" → Good: "Researched Stripe vs Paddle for payments"


Rule 2: Name the specific thing
Every title needs a concrete noun—the thing you acted on:

A feature: "onboarding flow," "search filters," "export modal"
A bug: "login timeout," "memory leak," "race condition"
A file: "UserService.ts" (only if the file IS the work)
A person: "with Mike," "with the design team" (for conversations)
A place/event: "dinner at Nobu," "SFO flight for Tuesday"
A decision: "pricing tiers," "API versioning strategy"

The more specific, the better:

Bad: "Fixed bug" → Good: "Fixed OAuth token refresh on mobile"
Bad: "Had meeting" → Good: "Planned launch timeline with marketing"
Bad: "Made reservation" → Good: "Booked dinner at Resy for Saturday"
Bad: "Played games" → Good: "Played Elden Ring, cleared Rennala boss"
Bad: "Watched videos" → Good: "Watched UFC 300 highlights"


Rule 3: One throughline per title
Ask: what's the ONE main thing? Everything else goes in summary.
Signs you have two things crammed together:

"and" between unrelated activities
"+" connecting topics
"while" or "before" forcing a connection
Title longer than ~10 words

Bad examples and fixes:

Bad: "Fixed bug and answered emails" → Good: "Fixed checkout timeout" (emails go in summary)
Bad: "Booked flights + reviewed PRs" → Good: "Booked SFO flight for Tuesday" (PRs go in summary)
Bad: "Wrote docs while on support" → Good: "Wrote API migration guide" (support is a distraction)
Bad: "Talked to Lisa and checked metrics" → Good: "Scoped Q2 roadmap with Lisa" (metrics is secondary)

Exception: "and" is okay when both things are part of the same goal:

OK: "Diagnosed memory leak and deployed hotfix" (both are fixing the issue)
OK: "Designed and prototyped new nav" (same feature)


Rule 4: Avoid clichés and corporate speak
Banned phrases:

"deep dive" → just say what you researched
"rabbit hole" → just name what you looked at
"sync" / "aligned" / "circled back" → say what you decided or discussed
"product discussion" → discussion about what?
"analytics work" → what metric? what question?
"various" / "multiple" / "several" → name them or pick the main one

Examples:

Bad: "Deep dive into performance" → Good: "Profiled slow queries in orders table"
Bad: "Synced with team on launch" → Good: "Finalized launch checklist with ops"
Bad: "Did various research" → Good: "Compared AWS vs GCP pricing for video hosting"


The test
Before finalizing a title, ask: "If I read this title next week, would I know what I actually did?"
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
