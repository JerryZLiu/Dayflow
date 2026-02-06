import Foundation

struct OllamaPromptOverrides: Codable, Equatable {
    var summaryBlock: String?
    var titleBlock: String?

    var isEmpty: Bool {
        [summaryBlock, titleBlock].allSatisfy { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty
        }
    }
}

enum OllamaPromptPreferences {
    private static let overridesKey = "ollamaPromptOverrides"
    private static let store = UserDefaults.standard

    static func load() -> OllamaPromptOverrides {
        guard let data = store.data(forKey: overridesKey) else {
            return OllamaPromptOverrides()
        }
        guard let overrides = try? JSONDecoder().decode(OllamaPromptOverrides.self, from: data) else {
            return OllamaPromptOverrides()
        }
        return overrides
    }

    static func save(_ overrides: OllamaPromptOverrides) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        store.set(data, forKey: overridesKey)
    }

    static func reset() {
        store.removeObject(forKey: overridesKey)
    }
}

enum OllamaPromptDefaults {
    static let summaryBlock = """
          SUMMARY GUIDELINES:
          - Write in first person without using "I" (like a personal journal entry)
          - 2-3 sentences maximum
          - Include specific details (app names, search topics, etc.)
          - Natural, conversational tone

          GOOD EXAMPLES:
          "Managed Mac system preferences focusing on software updates and accessibility settings. Browsed Chrome searching for iPhone wireless charging info while
          checking Twitter and Slack messages."

          "Configured GitHub Actions pipeline for automated testing. Quick Slack check interrupted focus, then back to debugging deployment issues."

          "Researched React performance optimization techniques in Chrome, reading articles about useMemo patterns. Switched between documentation tabs and took notes in
           Notion about component re-rendering."

          "Updated Xcode project dependencies and resolved build errors in SwiftUI views. Tested app on simulator while responding to client messages about timeline
          changes."

          "Browsed Instagram and TikTok while listening to Spotify playlist. Responded to personal messages on WhatsApp about weekend plans."

          "Researched vacation destinations on travel websites and compared flight prices. Checked weather forecasts for different cities while reading travel reviews."

          BAD EXAMPLES:
          - "The user did various computer activities" (too vague, wrong perspective, never say the user)
          - "I was working on my computer doing different tasks" (uses "I", not specific)
          - "Spent time on multiple applications and websites" (generic, no details)
    """

    static let titleBlock = """
        Write one activity title for a 15-minute window using ONLY the observations.
        Rules:
        - 5-10 words, natural and specific, single line
        - Choose the dominant activity (most time), not necessarily the first
        - Ignore brief interruptions (<3 minutes)
        - Include a second activity only if both take ~5+ minutes
        - If 3+ unrelated activities appear, output exactly: "Scattered apps and sites"
        - Prefer proper nouns/topics (Bookface, Claude, League of Legends, Paul Graham, etc.)
        - Never use: worked on, looked at, handled, various, some, multiple, browsing, browse, multitasking, tabs, brief, quick, short
        - Do NOT use the word "browsing"; use "scrolling" or "reading" instead
        - Avoid long lists; no more than one conjunction
        - Return only the title text (no quotes, no JSON)
    """
}

struct OllamaPromptSections {
    let summary: String
    let title: String

    init(overrides: OllamaPromptOverrides) {
        self.summary = OllamaPromptSections.compose(defaultBlock: OllamaPromptDefaults.summaryBlock, custom: overrides.summaryBlock)
        self.title = OllamaPromptSections.compose(defaultBlock: OllamaPromptDefaults.titleBlock, custom: overrides.titleBlock)
    }

    private static func compose(defaultBlock: String, custom: String?) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultBlock : trimmed
    }
}
