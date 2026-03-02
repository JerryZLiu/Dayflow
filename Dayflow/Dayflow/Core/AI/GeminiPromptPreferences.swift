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
TITLE GUIDELINES
Core principle: If you read this title next week, would you know what you actually did?
Be specific, but concise:
Every title needs concrete details. Name the actual thing—the show, the person, the feature, the file, the game. But keep it scannable—aim for roughly 5-10 words. Extra details belong in the summary.

Bad: "Watched videos" → Good: "The Office bloopers on YouTube"
Bad: "Worked on UI" → Good: "Fixed navbar overlap on mobile"
Bad: "Had a call" → Good: "Call with James about venue options"
Bad: "Did research" → Good: "Comparing gyms near the new apartment"
Bad: "Debugged issues" → Good: "Tracked down Stripe webhook failures"
Bad: "Played games" → Good: "Civilization VI — finally beat Deity difficulty"
Bad: "Browsed YouTube" → Good: "Veritasium video on turbulence"
Bad: "Chatted with team" → Good: "Slack debate about monorepo vs multirepo"
Bad: "Made a reservation" → Good: "Booked Nobu for Saturday 7pm"
Bad: "Coded" → Good: "Built CSV export for transactions"

Don't overload the title:
If you're using em-dashes, parentheses, or listing 3+ things—you're probably cramming summary content into the title.

Bad: "Apartment hunting — Zillow listings in Brooklyn, StreetEasy saved searches, and broker fee research"
Good: "Apartment hunting in Brooklyn"
Bad: "Weekly metrics review — signups, churn rate, MRR growth, and cohort retention"
Good: "Weekly metrics review"
Bad: "Call with Mom — talked about Dad's birthday, her knee surgery, and Aunt Linda's visit"
Good: "Call with Mom"

Avoid vague words:
These words hide what actually happened:

"worked on" → doing what to it?
"looked at" → reviewing? debugging? reading?
"handled" → fixed? ignored? escalated?
"dealt with" → means nothing
"various" / "some" / "multiple" → name them or pick the main one
"deep dive" / "rabbit hole" → just say what you researched
"sync" / "aligned" / "circled back" → say what you discussed or decided
"browsing" / "iterations" / "analytics" → what specifically?

Avoid repetitive structure:
Don't start every title with a verb. Mix it up naturally:

"Fixed the infinite scroll bug on search results"
"Breaking Bad rewatch — season 3 finale"
"Call with recruiter about the Stripe role"
"AWS cost spike investigation"
"Planning the bachelor party itinerary"
"Stardew Valley — finished the community center"
"iPhone vs Pixel camera comparison for Mom"
"Morning coffee + Hacker News catch-up"

If several titles in a row start with "Fixed... Debugged... Built... Reviewed..." — vary the structure.
Use "and" sparingly:
Don't use "and" to connect unrelated things. Pick the main activity for the title; the rest goes in the summary.

Bad: "Fixed bug and replied to emails" → Good: "Fixed pagination crash" (emails in summary)
Bad: "YouTube then coded" → Good: "Built the settings modal" (YouTube is a distraction)
Bad: "Read articles, watched TikTok, checked Discord" → Good: "Scattered browsing" (it was scattered, just say that)

"And" is okay when both parts serve the same goal:

OK: "Designed and prototyped the onboarding flow"
OK: "Researched and booked the Airbnb in Lisbon"
OK: "Drafted and sent the investor update"

When it's genuinely scattered:
If there was no main focus—just bouncing between tabs—don't force a fake throughline:

"YouTube and Twitter browsing"
"Scattered browsing break"
"Catching up on Reddit and Discord"

Before finalizing: would this title help you remember what you actually did?
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
[H:MM AM/PM] - [H:MM AM/PM]: [specific action] [in app/tool] [on what]

Include:
- Specific file/document names when visible
- Page titles, tabs, search queries
- Actions: opened, edited, scrolled, searched, replied, watched
- Content context: what topic, what section, who you messaged

Good example:
"7:00 AM - 7:08 AM: edited "Q4 Launch Plan" in Notion, added timeline section
7:08 AM - 7:10 AM: replied to Mike in Slack #engineering
7:10 AM - 7:12 AM: scrolled X home feed
7:12 AM - 7:18 AM: back to Notion, wrote launch risks section
7:18 AM - 7:20 AM: searched Google "feature flag best practices"
7:20 AM - 7:25 AM: read LaunchDarkly docs
7:25 AM - 7:30 AM: added feature flag notes to Notion doc"

Bad example:
"7:00 AM - 7:30 AM writing Notion doc
7:30 AM - 7:35 AM: Slack
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
