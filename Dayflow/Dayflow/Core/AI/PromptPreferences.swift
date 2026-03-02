import Foundation

struct VideoPromptOverrides: Codable, Equatable {
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

enum VideoPromptPreferences {
    private static let overridesKey = "geminiPromptOverrides"
    private static let store = UserDefaults.standard

    static func load() -> VideoPromptOverrides {
        guard let data = store.data(forKey: overridesKey) else {
            return VideoPromptOverrides()
        }
        guard let overrides = try? JSONDecoder().decode(VideoPromptOverrides.self, from: data) else {
            return VideoPromptOverrides()
        }
        return overrides
    }

    static func save(_ overrides: VideoPromptOverrides) {
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

struct VideoPromptSections {
    let title: String
    let summary: String
    let detailedSummary: String

    init(overrides: VideoPromptOverrides) {
        self.title = VideoPromptSections.compose(defaultBlock: GeminiPromptDefaults.titleBlock, custom: overrides.titleBlock)
        self.summary = VideoPromptSections.compose(defaultBlock: GeminiPromptDefaults.summaryBlock, custom: overrides.summaryBlock)
        self.detailedSummary = VideoPromptSections.compose(defaultBlock: GeminiPromptDefaults.detailedSummaryBlock, custom: overrides.detailedBlock)
    }

    private static func compose(defaultBlock: String, custom: String?) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultBlock : trimmed
    }
}

/// Shared prompt templates used by multiple LLM providers.
///
/// When prompts must remain *exactly* identical between providers, keep them here and call these helpers.
enum LLMPromptTemplates {
    static func screenRecordingTranscriptionPrompt(durationString: String) -> String {
        """
        # Screen Recording Transcription (Reconstruct Mode)

        Watch this screen recording and create an activity log detailed enough that someone could reconstruct the session.

        CRITICAL: This video is exactly \(durationString) long. ALL timestamps must be within 00:00 to \(durationString). No gaps.

        For each segment, ask yourself:
        "What EXACTLY did they do? What SPECIFIC things can I see?"

        Capture:
        - Exact app/site names visible
        - Exact file names, URLs, page titles
        - Exact usernames, search queries, messages
        - Exact numbers, stats, prices shown

        Bad: "Checked email"
        Good: "Gmail: Read email from boss@company.com 'RE: Budget approval' - replied 'Looks good'"

        Bad: "Browsing Twitter"
        Good: "Twitter/X: Scrolled feed - viewed posts by @pmarca about AI, @sama thread on GPT-5 (12 tweets)"

        Bad: "Working on code"
        Good: "VS Code: Editing StorageManager.swift - fixed type error on line 47, changed String to String?"

        Segments:
        - 3-8 segments total
        - You may use 1 segment only if the user appears idle for most of the recording
        - Group by GOAL not app (IDE + Terminal + Browser for the same task = 1 segment)
        - Do not create gaps; cover the full timeline

        Return ONLY JSON in this format:
        [
          {
            "startTimestamp": "MM:SS",
            "endTimestamp": "MM:SS",
            "description": "1-3 sentences with specific details"
          }
        ]
        """
    }

    static func activityCardsPrompt(
        existingCardsString: String,
        transcriptText: String,
        categoriesSection: String,
        promptSections: VideoPromptSections,
        languageBlock: String
    ) -> String {
        """
        You are a digital anthropologist, observing a user's raw activity log. Your goal is to synthesize this log into a high-level, human-readable story of their session, presented as a series of timeline cards.
        THE GOLDEN RULE:
            Create cards that narrate one cohesive session, aiming for 15–60 minutes. Keep every card ≥10 minutes, split up any cards that are >60 minutes, and if a prospective card would be <10 minutes, merge it into the neighboring card that preserves the best story.

            CONTINUITY RULE:
            You may adjust boundaries for clarity, but never introduce new gaps or overlaps. Preserve any original gaps in the source timeline and keep adjacent covered
          spans meeting cleanly.

            CORE DIRECTIVES:
            - Theme Test Before Extending: Extend the current card only when the new observations continue the same dominant activity. Shifts shorter than 10 minutes should
          be logged as distractions or merged into the adjacent segment that keeps the theme coherent; shifts ≥10 minutes become new cards.
        
        \(promptSections.title)

        \(promptSections.summary)

        \(categoriesSection)

        \(promptSections.detailedSummary)

        \(languageBlock)

        APP SITES (Website Logos)
        Identify the main app or website used for each card and include an appSites object.

        Rules:
        - primary: The canonical domain (or canonical product path) of the main app used in the card.
        - secondary: Another meaningful app used during this session OR the enclosing app (e.g., browser), if relevant.
        - Format: lower-case, no protocol, no query or fragments. Use product subdomains/paths when they are canonical (e.g., docs.google.com for Google Docs).
        - Be specific: prefer product domains over generic ones (docs.google.com over google.com).
        - If you cannot determine a secondary, omit it.
        - Do not invent brands; rely on evidence from observations.

        Canonical examples:
        - Figma → figma.com
        - Notion → notion.so
        - Google Docs → docs.google.com
        - Gmail → mail.google.com
        - Google Sheets → sheets.google.com
        - Zoom → zoom.us
        - ChatGPT → chatgpt.com
        - VS Code → code.visualstudio.com
        - Xcode → developer.apple.com/xcode
        - Chrome → google.com/chrome
        - Safari → apple.com/safari
        - Twitter/X → x.com

        YOUR MENTAL MODEL (How to Decide):
        Before making a decision, ask yourself these questions in order:

        What is the dominant theme of the current card?
        Do the new observations continue or relate to this theme? If yes, extend the card.
        Is this a brief (<5 min) and unrelated pivot? If yes, add it as a distraction to the current card and continue extending.
        Is this a sustained shift in focus (>15 min) that represents a different activity category or goal? If yes, create a new card regardless of the current card's length.

        DISTRACTIONS:
        A "distraction" is a brief (<5 min) and unrelated activity that interrupts the main theme of a card. Sustained activities (>5 min) are NOT distractions - they either belong to the current theme or warrant a new card. Don't label related sub-tasks as distractions.

        INPUT/OUTPUT CONTRACT:
        Your output cards MUST cover the same total time range as the "Previous cards" plus any new time from observations.
        - If Previous cards span 11:11 AM - 11:53 AM, your output must also cover 11:11 AM - 11:53 AM (you may restructure the cards, but don't drop time segments)
        - If new observations extend beyond the previous cards' time range, create additional cards to cover that new time
        - The only exception: if there's a genuine gap between previous cards (e.g., 11:27 AM to 11:33 AM with no activity), preserve that gap
        - Think of "Previous cards" as a DRAFT that you're revising/extending, not as locked history

        INPUTS:
        Previous cards: \(existingCardsString)
        New observations: \(transcriptText)
        Return ONLY a JSON array with this EXACT structure:

                [
                  {
                    "startTime": "1:12 AM",
                    "endTime": "1:30 AM",
                    "category": "",
                    "subcategory": "",
                    "title": "",
                    "summary": "",
                    "detailedSummary": "",
                    "distractions": [
                      {
                        "startTime": "1:15 AM",
                        "endTime": "1:18 AM",
                        "title": "",
                        "summary": ""
                      }
                    ],
                    "appSites": {
                      "primary": "",
                      "secondary": ""
                    }
                  }
                ]
        """
    }
}
