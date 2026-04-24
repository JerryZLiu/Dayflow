import AppKit
import Foundation

extension ChatCLIProvider {
  // MARK: - Prompt builders

  func buildCardsPrompt(observations: [Observation], context: ActivityGenerationContext)
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
    let promptSections = ChatCLIPromptSections(overrides: ChatCLIPromptPreferences.load())

    // Build prompt with explicit concatenation to avoid GRDB SQL interpolation pollution
    let categoriesSectionText = categoriesSection(from: context.categories)

    let languageBlock =
      LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
      .map { "\n\n\($0)" } ?? ""

    return """
      You are synthesizing a user's activity log into timeline cards. Each card represents one main thing they did.

      CORE PRINCIPLE:
      Each card = one coherent activity. Time is a constraint (10-60 min), not a goal. 

      CARD BOUNDARIES:
      - Minimum card length: 10 minutes
      - Maximum card length: 60 minutes
      - Brief interruptions (<5 min) that don't change your focus = distractions within the card

      WHEN TO SPLIT (new card):
      - The user's GOAL changes, not just their tool/app
      - You'd need "and" to connect two genuinely unrelated activities in the title

      WHEN TO MERGE (same card):
      - Consecutive activities serve the same project or goal (e.g., reviewing mockups → discussing those mockups → iterating on those mockups = one design session)
      - Switching apps/tools within the same task (Figma → Meet → Figma for one design review)
      - Back-to-back games of the same game = one gaming session
      - Debugging across IDE + Terminal + Browser = one debugging session

      BIAS: Default to MERGING. Ask "would the user describe this as one sitting/session?" If yes, it's one card. Fewer rich cards are better than many granular ones.

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

  func buildCardsCorrectionPrompt(validationError: String) -> String {
    """
    The previous JSON output has validation errors. Fix the existing output using the context from our ongoing conversation.

    Issues:
    \(validationError)

    Requirements:
    - Return the FULL corrected JSON output (not a diff).
    - Preserve the same overall time coverage: no gaps or overlaps.
    - Each card must be 10-60 minutes, except the final card may be shorter.
    - If a mid-card is too short, merge it with an adjacent card and update title/summary accordingly.
    - Output JSON only. No code fences or extra text.
    """
  }

}
