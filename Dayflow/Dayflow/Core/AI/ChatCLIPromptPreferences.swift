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
TITLES

Write titles like you'd answer "what were you doing?"

Formula: [Main thing] + optional quick context

Good:
- "Prepped Mia's Duke interview"
- "Japan flights with Evan"
- "Nick Fuentes interview, then UI diagrams"
- "Debugged auth flow in React"
- "League game, checked DayFlow between"
- "Watched Succession finale"
- "Booked Denver flights on Expedia"

Bad:
- "Twitter scrolling, YouTube video, and UI diagrams" (laundry list)
- "Duke interview prep and DayFlow code review" (unrelated things jammed together)
- "Extended browsing session" (vague, formal)
- "Random browsing and activities" (says nothing)
- "Worked on DayFlow project" (what specifically?)
- "Early morning digital drift" (poetic fluff)

If there's a secondary thing, make it context not a co-headline:
- "Prepped Duke interview, League between" ✓
- "Duke interview prep and League of Legends" ✗
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
