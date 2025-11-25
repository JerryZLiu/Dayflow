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

Minute-by-minute timeline. One line per activity.

Format:
"[H:MM AM/PM] - [H:MM AM/PM] [activity in app/tool]"

Example:
"7:00 AM - 7:30 AM writing Notion doc
7:30 AM - 7:35 AM Slack DMs
7:35 AM - 7:38 AM scrolling X
7:38 AM - 7:45 AM back to Notion doc
7:45 AM - 8:05 AM coding in Cursor"
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
