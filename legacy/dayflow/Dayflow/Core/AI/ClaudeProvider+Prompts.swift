import AppKit
import Foundation

extension ClaudeProvider {
  // MARK: - Claude prompt builders

  func buildCardsPrompt(
    observations: [Observation],
    context: ActivityGenerationContext,
    overrides: ActivityCardPromptOverrides? = nil
  )
    -> String
  {
    // Use explicit string concatenation to avoid GRDB SQL interpolation pollution
    let transcriptText = observations.map { obs in
      let startTime = formatTimestampForPrompt(obs.startTs)
      let endTime = formatTimestampForPrompt(obs.endTs)
      return "[" + startTime + " - " + endTime + "]: " + obs.observation
    }.joined(separator: "\n")

    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let existingCardsData = try? encoder.encode(context.existingCards)
    let existingCardsJSON = existingCardsData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    let promptSections = ClaudePromptSections(
      overrides: overrides ?? ClaudePromptPreferences.load()
    )

    // Build prompt with explicit string concatenation to avoid GRDB SQL interpolation pollution
    let categoriesSectionText = categoriesSection(from: context.categories)

    let languageBlock =
      LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
      .map { "\n\n\($0)" } ?? ""

    let boundaryBlock: String
    if context.hasPreviousCardWithinFiveMinutes {
      boundaryBlock = """
        <ongoing_segmentation>
        Rewrite the full connected span from the supplied evidence. Previous cards preserve content only; their boundaries, titles, and categories are provisional.

        Apply this order:
        1. Group observations by the user's immediate goal, not by app or batch edge.
        2. Preserve exact source coverage and genuine gaps. Every card, including the final card, must be 10-60 minutes.
        3. Absorb a 1-4-minute moment into the longer adjacent episode. For a distinct 5-9-minute episode, borrow only enough adjacent minutes to reach 10 while keeping its neighbors at least 10. If an earlier pass had to absorb it, restore it once later evidence makes that split valid.
        4. Merge app switches serving one goal, back-to-back sessions in the same game, a live collaboration across artifact edits, and adjacent diffuse passive switching when the combined card is at most 60 minutes.
        5. Split a sustained immediate-goal change when both cards remain at least 10 minutes. Communication to browsing and artifact creation/review to structured comparison are goal changes even inside one broad project.
        6. Freeze the boundaries. Then recompute every title and category from only the evidence inside its final card; borrowed or absorbed activity stays in the summaries unless it dominates.

        Boundary evolution example: a draft 1:00-1:28 coding card contains a distinct 1:20-1:28 flight search, then 1:28-1:43 workout evidence arrives. Return 1:00-1:20 coding, 1:20-1:30 flight search, and 1:30-1:43 workout.
        </ongoing_segmentation>
        """
    } else {
      boundaryBlock = """
        FRESH SEGMENT MODE — EXACTLY ONE CARD:
        No previous card belongs to this batch's contiguous source-evidence segment. Nearby history separated by a genuine gap is left untouched. Return exactly ONE new card covering the entire supplied observation span, regardless of internal activity or goal changes. This card is provisional; later sliding-window passes may split it once each resulting activity has at least 10 minutes of supporting evidence.

        Do not split this batch. Title and categorize its dominant activity, and put shorter or unrelated activity in the summary and detailed summary. This rule overrides all other coherence and splitting guidance for this call.
        """
    }

    return """
      You are synthesizing a user's activity log into timeline cards. Each card represents one main thing they did.

      CORE PRINCIPLE:
      Each card represents one coherent activity when the hard duration rule allows it. Time boundaries take priority over semantic purity.

      \(boundaryBlock)

      CONTINUITY RULE:
      Never introduce gaps or overlaps. Adjacent cards should meet cleanly. Preserve any original gaps from the source timeline.

      """ + promptSections.title + """


        """ + promptSections.summary + """


          """ + promptSections.detailedSummary + """

          """ + languageBlock + """

          DISTRACTIONS

          A distraction is a brief (<5 min) unrelated interruption that doesn't change the card's main focus.

          NOT distractions:
          - A 24-minute League game (that's its own card)
          - A 10-minute Twitter scroll (new card or merge thoughtfully)
          - Sub-tasks related to the main activity

          """ + categoriesSectionText + """


          APP SITES (Website Logos)

          Identify the main app or website used for each card. Output the canonical DOMAIN, not the app name.

          Rules:
          - primary: The canonical domain of the main app/website used in the card.
          - secondary: Another meaningful app used during this session, if relevant.
          - Format: lower-case, no protocol, no query or fragments.
          - Use product subdomains/paths when canonical (e.g., docs.google.com for Google Docs).
          - Be specific: prefer product domains over generic ones (docs.google.com over google.com).
          - If you cannot determine a secondary, omit it.
          - Do not invent brands; rely on evidence from observations.

          Canonical examples (app → domain):
          - Figma → figma.com
          - Notion → notion.so
          - Google Docs → docs.google.com
          - Gmail → mail.google.com
          - VS Code → code.visualstudio.com
          - Xcode → developer.apple.com/xcode
          - Slack → slack.com
          - Twitter/X → x.com
          - Messages → support.apple.com/messages
          - Terminal → terminal (exception, doens't have a url)
          - Codex → chatgpt.com
          - Claude Code/Claude → claude.ai

          ✗ WRONG: "primary": "Messages" (app name, not a domain)
          ✗ WRONG: "primary": "Ghostty IDE" (app name, not a domain)
          ✓ CORRECT: "primary": "figma.com", "secondary": "notion.so"

          DECISION PROCESS

          Before finalizing a card, ask:
          1. What's the one main thing in this card?
          2. Can I title it without using "and" between unrelated things?
          3. Are there any sustained (>10 min) activities that should be their own card?
          4. Are the "distractions" actually brief interruptions, or separate activities?

          INPUT/OUTPUT CONTRACT:
          Your output cards MUST cover the same total time range as the "Previous cards" plus any new time from observations.
          - If Previous cards span 11:11 AM - 11:53 AM, your output must also cover 11:11 AM - 11:53 AM (you may restructure the cards, but don't drop time segments)
          - If new observations extend beyond the previous cards' time range, create additional cards to cover that new time
          - The only exception: if there's a genuine gap between previous cards (e.g., 11:27 AM to 11:33 AM with no activity), preserve that gap
          - Think of "Previous cards" as a DRAFT that you're revising/extending, not as locked history

          INPUTS:
          Previous cards: \(existingCardsJSON)
          New observations: \(transcriptText)

          FINAL REQUIRED CHECK — APPLY AFTER READING ALL INPUTS:
          1. Obey the active mode above. In FRESH SEGMENT MODE, return exactly one card for the supplied span. Otherwise, re-segment the entire supplied span; old card endpoints are drafts, not preferred boundaries.
          2. In ongoing mode, scan observations and previous-card details for a distinct 5-9-minute episode that an earlier pass absorbed. If later evidence now makes a valid split possible, restore it as a 10-minute card by borrowing only the minimum adjacent minutes.
          3. Merge neighboring same-game cards and adjacent diffuse passive switching when allowed. Split sustained immediate-goal changes, including communication to browsing, when both sides remain at least 10 minutes.
          4. Verify exact source coverage, preserve genuine source gaps, and ensure every returned card is 10-60 minutes with no overlaps.
          5. Only after boundaries pass, regenerate every title. If one activity occupies more than half a card, title it alone and omit borrowed or brief activity.
          6. Name recurring comparison items or styles, a named conversation partner and topic, or the artifact reviewed through several tools. In balanced mixed cards, prefer concrete products, places, or artifacts over abstract categories.
          7. Merge consecutive cards whose evidence is diffuse passive switching when their combined duration is at most 60 minutes; do not keep them separate by giving one an incidental specific title.
          8. Keep a sustained side-by-side comparison separate from earlier artifact preparation or review when both cards can remain at least 10 minutes. Name its concrete compared items or styles.
          9. If the rest of a card is diffuse passive catch-up, a named direct conversation may be its best cue even when brief. Use that person and topic, then keep the person out of the next mixed-card title when they appear there only as borrowed minutes.
          10. Do not split one artifact-review episode merely because the tool or model changes. Start a new comparison card when a stable comparison axis becomes the sustained task, such as a recurring frame-by-frame judgment of two styles.
          11. If a named conversation card ends at a boundary and the next card begins with at most four minutes continuing that same person, treat those minutes as borrowed filler and keep the person out of the next title. Choose the later mixed card's longer concrete products, places, or artifacts instead.
          12. Keep a live collaboration together when the same person continues from a huddle into edits or review of the shared artifact; an app switch or earlier draft boundary alone is not a new episode.

          OUTPUT:
          Return ONLY a raw JSON array. No code fences, no markdown, no commentary.

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

  func buildCardsCorrectionPrompt(validationError: String, requiresSingleCard: Bool) -> String {
    let modeRequirement =
      requiresSingleCard
      ? "- This is a fresh segment. Return exactly ONE card covering the full supplied observation span."
      : "- Recheck the entire array, not only the issue named above. Absorb every 1-4-minute card into the longer adjacent episode; a short first card merges into the full following session and a short final card merges backward. For every 5-9-minute card, move only enough neighboring minutes to bring it to 10, even when the borrowed minutes are unrelated, while preserving every neighboring episode that can remain at least 10 minutes. Examples: 4 minutes plus a following 33-minute same-session card becomes one 37-minute card; an 8-minute middle card followed by 15 minutes becomes 10 minutes plus 13 minutes; a distinct 6-minute ending after 20 minutes becomes 16 minutes plus 10 minutes. Never return the same invalid short boundary."

    return """
      The previous JSON output has validation errors. Fix the existing output using the context from our ongoing conversation.

      Issues:
      \(validationError)

      Requirements:
      - Return the FULL corrected JSON output (not a diff).
      - Preserve exactly the source-supported coverage. Keep genuine source gaps uncovered; never bridge them. Cards may be separated only where the inputs have a real gap. No overlaps.
      - Change the timestamps that caused the validation error; do not return the same invalid boundaries. If the issue says the cards do not cover all supplied observations, find every gap between consecutive cards and close the uncovered boundary by extending an adjacent card. In particular, if one card ends at 5:38 and the next begins at 5:39, make them meet at 5:38 or 5:39 rather than returning that one-minute gap again. If the issue says a card covers a genuine source gap, restore that gap instead.
      - Every card must be 10-60 minutes, including the final card. There is no short-final-card exception unless the entire supplied span is under 10 minutes.
      \(modeRequirement)
      - The duration rule overrides semantic purity. When unrelated activities must be merged, title and categorize the dominant activity and move the shorter activity into the summary and detailed summary.
      - After merging, recompute the title and category from the combined duration. Never concatenate an absorbed short activity into the title unless it remains dominant by supported minutes. If nothing dominates, use a scattered title with at most two concrete anchors.
      - A future pass may split an activity only after it has at least 10 supported minutes.
      - Output JSON only. No code fences or extra text.
      """
  }

  func buildTranscriptionCorrectionPrompt(
    validationError: String,
    duration: String
  ) -> String {
    """
    The previous transcription response failed output validation. Correct that response using the screenshots and context already in this conversation.

    Issue:
    \(validationError)

    Return the FULL corrected JSON object, not a diff. Preserve factual activity descriptions unless a timestamp boundary requires regrouping. The first segment must start at 00:00:00, the last must end at \(duration), and consecutive segments must have no gaps or overlaps. Return JSON only, with no Markdown fence or commentary. Do not reread files or use tools.
    """
  }

  func buildScreenshotTranscriptionPrompt(
    numFrames: Int, duration: String, startTime: String, endTime: String
  ) -> String {
    return """
      Analyze these \(numFrames) screenshots from a \(duration) screen recording
      (\(startTime) to \(endTime)). They are 1 min apart and in order.

      Create an activity log detailed enough that someone could reconstruct what
      the user did.

      For each segment, ask yourself: "What EXACTLY did they do? What SPECIFIC
      things can I see?"

      Capture from screenshots:
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

      3-8 segments total.
      Exception: You may use 1 segment only if the user appears idle for most of the recording.
      Group by GOAL not app (debugging across IDE+Terminal+Browser = 1 segment).

      Timestamps must start at \(startTime) and end at \(endTime). No gaps.

      Return JSON only:
      {"segments":[{"start":"HH:MM:SS","end":"HH:MM:SS","description":"..."}]}
      """
  }

}
