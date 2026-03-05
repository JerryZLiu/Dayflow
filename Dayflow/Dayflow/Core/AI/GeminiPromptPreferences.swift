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
Titles
Each title is a memory trigger. Be specific enough that it could only describe one situation.
"Bug fixes" could be anything. "Fixed the infinite scroll crash on search results" can only be one thing.
"Gaming session" could be any day. "League ARAM — Thresh and Jinx" is a specific session.

Use honest verbs
The verb matters. Pick the one that describes what actually happened, not the one that sounds most professional.
If someone was browsing a product page and picking options, they were "speccing out" a purchase — not "configuring" it (that implies they already own it). If someone scheduled a meeting, they "scheduled" it — not "coordinated" it. If someone was scrolling a feed, they were "scrolling" — not "catching up on industry news."
The wrong verb changes the memory. Get it right even if it sounds less impressive.

Accuracy over polish
Don't compress what happened into a technical-sounding phrase that loses the meaning. If the actual bug was "the notification wasn't showing up after regeneration," say that — don't abstract it into "verification pipeline error" because it sounds more engineered.
The title's job is to be TRUE and SPECIFIC, not to sound smart. When in doubt, describe the actual problem or action in plain language.

Titles can be longer
A title that's a few words longer but triggers a real memory beats a short vague one every time. Don't trim useful detail for brevity. Aim for roughly 5–15 words — but if word 12 is the one that makes you remember, keep it.

Banned words
These are corporate filler. No human writes them in a journal:
"research," "coordination," "management," "administration," "workflow," "sync," "alignment," "exploration," "investigation," "project development," "social chat," "various," "multiple," "several," "deep dive," "rabbit hole"
Don't just avoid these exact words — avoid the energy. "Analyzing" is just "research" in a lab coat. "Refining" is just "working on" trying to sound important. "Coordinated" is "scheduled" wearing a tie. If you wouldn't say it out loud to a friend, it's too formal.

Examples

BAD: "Debugging issues" → GOOD: "Tracked down the Stripe webhook timeout"
BAD: "Housing search and social media browsing" → GOOD: "Found a 2BR on Elm Street on Zillow"
BAD: "Meeting coordination" → GOOD: "Scheduled coffee with Priya for Thursday"
BAD: "Tech news and social media browsing" → GOOD: "Reading about the new Pixel launch on X"
BAD: "Gaming session and social chat" → GOOD: "Overwatch ranked — hit Diamond with Sara"
BAD: "Subscription management" → GOOD: "Downgraded my Spotify to free tier"
BAD: "Project development and code review" → GOOD: "Reviewed Jake's auth PR"
BAD: "Financial research and subscription management" → GOOD: "Talked to Marcus about REIT picks"

Multiple activities
Just describe what happened naturally. Use commas, "and," "+," "between" — whatever reads well. Vary the structure so titles don't all sound the same.

"Fixing the login redirect between YouTube and Reddit breaks"
"Texted Priya about Saturday, caught up on NFL draft news"
"Postgres migration + updated the Terraform config"
"Poking at the CORS bug (mostly distracted)"

If one activity is clearly the main thing, just name that one. The rest goes in the summary.

Final check

Could this title describe 100 different situations? → Too vague, add the specific detail.
Would a human actually write this? → If it sounds corporate, rewrite it.
Will this bring back a specific memory? → If not, name the concrete thing.
Is the verb honest? → Does it describe what actually happened, or a fancier version of it?
"""

    static let summaryBlock = """
## Summary

2-3 sentences max. First person without "I". Just state what happened.

Good:
- "Refactored the auth module in React, added OAuth support. Hit CORS issues with the backend API."
- "Designed landing page mockups in Figma. Exported assets and started building it in Next.js."
- "Searched flights to Tokyo, coordinated dates with Evan and Anthony over Messages. Looked at Shibuya apartments on Blueground."

Bad:
- "Kicked off the morning by diving into design work before transitioning to development tasks." (filler, vague)
- "Started with refactoring before moving on to debugging some issues." (wordy, no specifics)
- "The session involved multiple context switches between different parts of the application." (says nothing)

Never use:
- "kicked off", "dove into", "started with", "began by"
- Third person ("The session", "The work")
- Mental states or assumptions about why the person did something
"""

    static let detailedSummaryBlock = """
## Detailed Summary

This is the "show me exactly what happened" view. Every app, every switch, every action.

Format each line as:
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
        Screen Recording Transcription (Reconstruct Mode)
        Watch this screen recording and create an activity log detailed enough that someone could reconstruct the session.
        CRITICAL: This video is exactly \(durationString) long. ALL timestamps must be within 00:00 to \(durationString). No gaps.
        Identifying the active app: On macOS, the app name is always shown in the top-left corner of the screen, right next to the Apple () menu. Check this FIRST to identify which app is being used. Do NOT guess — read the actual name from the menu bar. If you can't read it clearly, describe it generically (e.g., "code editor," "browser," "messaging app") rather than guessing a specific product name. Common code editors like Cursor, VS Code, Xcode, and Zed all look similar but have different names in the menu bar.
        For each segment, ask yourself:
        "What EXACTLY did they do? What SPECIFIC things can I see?"
        Capture:
        - Exact app/site names visible (check menu bar for app name)
        - Exact file names, URLs, page titles
        - Exact usernames, search queries, messages
        - Exact numbers, stats, prices shown
        Bad: "Checked email"
        Good: "Gmail: Read email from boss@company.com 'RE: Budget approval' - replied 'Looks good'"
        Bad: "Browsing Twitter"
        Good: "Twitter/X: Scrolled feed - viewed posts by @pmarca about AI, @sama thread on GPT-5 (12 tweets)"
        Bad: "Working on code"
        Good: "Editing StorageManager.swift in [exact app name from menu bar] - fixed type error on line 47, changed String to String?"
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
        # Timeline Card Generation

        You're writing someone's personal work journal. You'll get raw activity logs — screenshots, app switches, URLs — and your job is to turn them into timeline cards that help this person remember what they actually did.

        The test: when they scan their timeline tomorrow morning, each card should make them go "oh right, that."

        Write as if you ARE the person jotting down notes about their day. Not an analyst writing a report. Not a manager filing a status update.

        ---

        ## Card Structure

        Each card covers one cohesive chunk of activity, roughly 15–60 minutes.

        - Minimum 10 minutes per card. If something would be shorter, fold it into the neighboring card that makes the most sense.
        - Maximum 60 minutes. If a card runs longer, split it where the focus naturally shifts.
        - No gaps or overlaps between cards. If there's a real gap in the source data, preserve it. Otherwise, cards should meet cleanly.

        **When to start a new card:**
        1. What's the main thing happening right now?
        2. Does the next chunk of activity continue that same thing? → Keep extending.
        3. Is there a brief unrelated detour (<5 min)? → Log it as a distraction, keep the card going.
        4. Has the focus genuinely shifted for 10+ minutes? → New card.

        ---

        \(promptSections.title)

        ---

        \(promptSections.summary)

        ---

        \(promptSections.detailedSummary)

        \(languageBlock)

        ---

        ## Category

        \(categoriesSection)

        ---

        ## Distractions

        A distraction is a brief (<5 min) unrelated interruption inside a card. Checking X for 2 minutes while debugging is a distraction. Spending 15 minutes on X is not a distraction — it's either part of the card's theme or it's a new card.

        Don't label related sub-tasks as distractions. Googling an error message while debugging isn't a distraction, it's part of debugging.

        ---

        ## App Sites

        Identify the main app or website for each card.

        - primary: the main app used in the card (canonical domain, lowercase, no protocol).
        - secondary: another meaningful app used, or the enclosing app (e.g., browser). Omit if there isn't a clear one.

        Be specific: docs.google.com not google.com, mail.google.com not google.com.

        Common mappings:
        - Figma → figma.com
        - Notion → notion.so
        - Google Docs → docs.google.com
        - Gmail → mail.google.com
        - VS Code → code.visualstudio.com
        - Xcode → developer.apple.com/xcode
        - Twitter/X → x.com
        - Zoom → zoom.us
        - ChatGPT → chatgpt.com

        ---

        ## Continuity Rules

        Your output cards must cover the same total time range as the previous cards plus any new observations. Think of previous cards as a draft you're revising and extending, not locked history.

        - Don't drop time segments that were previously covered.
        - If new observations extend beyond the previous range, add cards to cover the new time.
        - Preserve genuine gaps in the source data.

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
