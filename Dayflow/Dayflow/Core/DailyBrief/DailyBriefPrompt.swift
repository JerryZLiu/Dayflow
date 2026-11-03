//
//  DailyBriefPrompt.swift
//  Dayflow
//
//  The two prompts for the Daily brief. One run writes only the docket; the other
//  writes every other section. They run at the same time and the app merges the
//  answers. Mirrors reports/daily_brief_prompt_docket.md and
//  reports/daily_brief_prompt_extras.md; keep them in sync. `{{KEY}}` placeholders
//  are filled by DailyBriefGenerator.
//

import Foundation

enum DailyBriefPrompt {
  /// Every placeholder the docket prompt can use.
  static let docketPlaceholderNames = [
    "USER_NAME", "TODAY_LONG", "YESTERDAY_LONG", "TIMEZONE", "YESTERDAY_CARDS",
    "CATEGORIES_WITH_DESCRIPTIONS", "FEEDBACK_DAYS", "FEEDBACK_SUMMARY", "RECENT_BRIEF_ITEMS",
    "OVERRIDE_INSTRUCTIONS",
  ]

  /// Every placeholder the other-sections prompt can use: the same, plus the screenshots folder.
  static let extrasPlaceholderNames = docketPlaceholderNames + ["CANDIDATES_DIR"]

  /// Replaces every `{{KEY}}` in the template with `values[KEY]` in a single pass,
  /// so text inside a value (a card title, an override instruction) is never re-expanded.
  /// Unknown placeholders are left as they are.
  static func build(template: String, values: [String: String]) -> String {
    var output = ""
    var remaining = template[...]
    while let open = remaining.range(of: "{{") {
      output.append(contentsOf: remaining[..<open.lowerBound])
      let afterOpen = remaining[open.upperBound...]
      guard let close = afterOpen.range(of: "}}") else {
        remaining = remaining[open.lowerBound...]
        break
      }
      let key = String(afterOpen[..<close.lowerBound])
      output.append(values[key] ?? "{{\(key)}}")
      remaining = afterOpen[close.upperBound...]
    }
    output.append(contentsOf: remaining)

    // An empty optional block (like the override instructions) leaves extra blank lines.
    while output.contains("\n\n\n") {
      output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return output
  }

  /// The "Extra instructions from the user" block, or "" when there are none.
  static func overrideInstructionsBlock(_ instructions: String) -> String {
    let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return """
      ## Extra instructions from the user

      They typed these preferences into Dayflow. They take priority over the defaults above
      whenever the two disagree (for example, which sections to include or skip, how many items,
      or what to focus on). The output shape below still applies. Ignore instructions about parts
      of the brief this prompt doesn't write.

      \(trimmed)
      """
  }

  // MARK: - Shared parts

  /// What the run knows about the person. Both prompts include it.
  private static let aboutThem = """
    ## What you know about them

    ### Yesterday's timeline
    These are yesterday's activity cards (start–end, category, title, summary, apps/sites). Idle cards are
    already removed.

    {{YESTERDAY_CARDS}}

    ### Their categories
    {{CATEGORIES_WITH_DESCRIPTIONS}}

    ### What they did with past briefs
    This is feedback from the last {{FEEDBACK_DAYS}} days on the parts of the brief you're writing: what
    they opened, saved, dismissed with the X, or checked off. Items with no feedback were ignored. Lean
    toward what they engage with. Treat a dismissal as a strong signal against that kind of item.

    {{FEEDBACK_SUMMARY}}

    ### Items from recent briefs
    Don't repeat these unless something meaningfully changed (and say what changed).

    {{RECENT_BRIEF_ITEMS}}
    """

  /// How to write. Both prompts include it.
  private static let writingStyle = """
    ## Writing style

    The goal is that they understand each item in a few seconds, on the first read. Write whatever makes
    that most likely: not so terse that a line reads like shorthand they have to decode, and not so
    descriptive that it explains things they already know.

    - **Lead with the point.** The title says the whole thing on its own (the action, the decision, the
      result). The first sentence under it says why it matters or what to do today. Names, numbers, and
      details come after that. Someone who reads only the titles should still get the brief.
    - **Use their words.** They know their own projects, people, tools, and team jargon, so name those
      directly instead of explaining them. Spell out anything they wouldn't know, such as a label you made
      up or an acronym from someone else's field.
    - **Write plain, complete sentences.** Use common words. Don't drop small words like "the" or "to",
      don't stack nouns, and don't use unusual metaphors. A title can be a short phrase, but it needs a
      verb or a clear subject ("Send Jeremy the paywall options by Friday", not "Paywall iters (J)").
    - **Keep the tone plain and warm.** No hype words, no exclamation marks, no emoji, no "Great job!"
      Write in second person when you address them.
    """

  /// Dayflow's tools and the user's connectors, described the same way in both prompts.
  private static let dayflowAndConnectorTools = """
    - **Dayflow tools** (`mcp__dayflow__*`): read older history, such as the last 2 weeks of timeline, search
      for an activity, or get the time breakdown. Use them to tell a one-off from an ongoing project.
    - **Their connectors** (whatever tools are available besides Dayflow's, e.g. Slack, Linear, Gmail,
      Notion, Google Drive): read only. You can search and read; you cannot send, post, create, or edit
      anything, and those calls will be refused. If no connectors are available, work from the timeline.
    """

  // MARK: - Docket prompt

  /// What the docket run knows about the person. Like `aboutThem`, but its cards carry
  /// their minute-by-minute detail lines.
  private static let aboutThemWithDetail = """
    ## What you know about them

    ### Yesterday's timeline
    These are yesterday's activity cards (cardId, start–end, category, title, summary, apps/sites), each
    followed by its minute-by-minute detail lines. Idle cards are already removed.

    {{YESTERDAY_CARDS}}

    ### Their categories
    {{CATEGORIES_WITH_DESCRIPTIONS}}

    ### What they did with past lists
    This is feedback from the last {{FEEDBACK_DAYS}} days: what they opened, saved, dismissed with the X,
    or checked off. Items with no feedback were ignored. Treat a dismissal as a strong signal against that
    kind of item.

    {{FEEDBACK_SUMMARY}}

    ### Items from recent lists
    Don't repeat these unless something meaningfully changed (and say what changed).

    {{RECENT_BRIEF_ITEMS}}
    """

  static let docketTemplate = """
    You're writing the docket for today's Daily brief for {{USER_NAME}}, a person who uses Dayflow, an app
    that records their screen and turns it into a timeline of what they did. They'll open the brief this
    morning inside Dayflow. Today is {{TODAY_LONG}} ({{TIMEZONE}}). Yesterday was {{YESTERDAY_LONG}}.

    The docket is the "Your docket today" list at the top of the brief: the few things most worth doing
    today. The rest of the brief (reading, news, screenshots, what they finished) is written separately,
    so your only job is the docket.

    ## What the docket is for

    The docket should read like a list from a sharp assistant who watched their day and checked their
    messages: the things they'd want to be reminded of first thing in the morning. Every item should be:

    1. **Useful.** Doing it today moves real work forward, answers someone who's waiting on them, or keeps
       a deadline from slipping.
    2. **Correct.** Grounded in evidence you actually found: a card, a message, an issue, a doc. Never
       invented, never padded.
    3. **Concrete.** One action they can start right away, not a topic or a vague intention.

    The docket is a daily habit, so being trusted matters more than being complete. One made-up or stale
    item teaches them to skim it. **Leave an item out instead of including a weak one.** Two excellent
    items are better than five decent ones, and an empty docket is fine on a day with nothing clear.

    Things that make an item weak, and should get it cut:
    - Generic: it could have been written for anyone ("Catch up on email", "Plan your week").
    - Already done: the timeline or a connector shows they finished it, or someone else did.
    - Obvious: a routine chore they clearly already track.
    - Low confidence: you're guessing at a deadline, a request, or what they care about.

    \(aboutThem)

    ## Tools you can use

    \(dayflowAndConnectorTools)
    - **WebSearch / WebFetch**: when an item depends on an outside fact (an event date, an application
      deadline, a release), check it. Open every link you include and confirm it says what you claim.

    The best items usually come from combining sources: a thread yesterday's cards show them reading, plus
    the connector message where someone asked them for something, plus the timeline showing it's half
    done. Before keeping an item, check that it isn't already finished.

    Budget: aim to finish in about 10 minutes. Prefer a few targeted searches over many broad ones.

    ## What a good docket item looks like

    Aim for 3–6 items, fewer when the evidence is thin. Each item is one action, phrased as the thing to
    do, not a topic ("Reply to Maggie about the Miami dates", not "Maggie"). Put the most important or most
    time-sensitive item first. Include a due date only if a source states it. Attach the evidence: the
    people involved, and the docs, threads, or issues it came from (with links when the connector gives
    one).

    The brief shows the docket as cards they can hand to an AI agent (Claude Code or Codex), so each item
    also carries:

    - `detail`: one or two sentences on what the task is and why it matters now. The title already says
      the action, so don't repeat it.
    - `prompt`: a complete, ready-to-send prompt for an agent that would do the task, written as {{USER_NAME}}
      would write it to a capable colleague. Say what to produce, the facts it needs (names, numbers,
      ticket ids, constraints people stated), and what "done" looks like. Split it into short paragraphs or
      a numbered list when it has steps. Don't invent facts to make it sound complete.
    - `agent`: true when an agent could do it without them (research, a draft, a prototype, a write-up);
      false when it needs them (a decision only they can make, testing on their own machine, a meeting).
      Write the prompt either way.
    - `feedback`: what people said about the task, one note per message, each with `name` (full name),
      `source` (where it was said, e.g. "#design, Oct 21" or "Huddle notes, Oct 22"), `text` (quote it word
      for word when it's short; otherwise a faithful one-sentence paraphrase) and `url` when you have one.
      Skip it when nobody said anything.
    - `feedbackSummary` and `feedbackUrl`: when every feedback note is from one person, a two-sentence
      summary of what they want and the link to the main message. The card shows it in place of the notes.
    - `attach`: titles of the `links` an agent needs to do the task (the doc or mock it works from), when
      any.

    \(writingStyle)

    {{OVERRIDE_INSTRUCTIONS}}

    ## Output

    Your final answer is one JSON object (it's checked against a schema) with `notes` and `docket`.

    Show your reasoning; it's how the docket gets debugged. `notes` is a short account of the run: what
    you looked at, what you found, which candidates you dropped and why, and anything you weren't sure
    about. Every item also gets a `why`: one or two sentences on why it made the cut, naming the evidence
    (the card, thread, doc, or page and what it said). The user never sees `notes` or `why`, so be candid.
    For example:

    ```json
    {
      "notes": "Read 24 cards (mostly Flow paywall work and Slack). Searched Slack for paywall and launch threads; found Jeremy's request. Dropped 'review the onboarding copy' because Maggie finished it yesterday.",
      "docket": [
        {
          "title": "Draft Flow paywall options for Jeremy",
          "detail": "He asked for them in #design and wants a bigger Start button. Look at how other apps handle paywalls and include a 7-day free trial option.",
          "due": "2026-10-24",
          "people": [{ "name": "Jeremy Hong", "note": "Asked for a bigger Start button" }],
          "links": [{ "title": "Daily design comp", "url": "https://...", "app": "figma" }],
          "prompt": "Design five options for the Flow paywall shown at the end of onboarding. Each needs a clear CTA to a 7-day free trial and a Start button that stands out more than today's.\\n\\nLook at how the highest-converting productivity apps handle their paywalls first, and note what each option borrows. Work from the Daily design comp in Figma.",
          "agent": true,
          "feedback": [{ "name": "Jeremy Hong", "source": "#design, Oct 21", "text": "can we make start way more obvious", "url": "https://..." }],
          "feedbackSummary": "Wants paywall options with a 7-day trial and a Start button that stands out more.",
          "feedbackUrl": "https://...",
          "attach": ["Daily design comp"],
          "why": "Jeremy asked for paywall options in #design on Oct 21 and cards 1201–1210 show the paywall half done."
        }
      ]
    }
    ```

    Use only the fields shown. Dates are yyyy-MM-dd. `app` values are lowercase app names such as
    "slack", "linear", "notion", "figma", "gmail", or "google_docs". Omit a field when you don't have it;
    never write placeholder values. If nothing clears the bar today, write `{"notes": "...", "docket": []}`.
    """

  // MARK: - Other-sections prompt

  static let extrasTemplate = """
    You're writing today's Daily brief for {{USER_NAME}}, a person who uses Dayflow, an app
    that records their screen and turns it into a timeline of what they did. They'll open it this morning
    inside Dayflow. Today is {{TODAY_LONG}} ({{TIMEZONE}}). Yesterday was {{YESTERDAY_LONG}}.

    The brief's to-do list ("Your docket today") is written separately, so don't suggest tasks. You write
    the other sections, described below.

    ## What this brief is for

    The brief should feel like a note from a sharp friend who watched their day and then went looking for
    things they'd be glad to know. In priority order, every item should be:

    1. **Enjoyable.** Something that makes them smile, feel seen, or feel a small spark of curiosity.
    2. **Useful.** It saves them time, reminds them of something real, or helps the work they're doing.
    3. **Correct.** Grounded in evidence you actually found. Never invented, never padded.

    The brief is a daily habit, so being trusted matters more than being complete. One mediocre item
    teaches them to skim; three skims teach them to ignore the brief. **Leave a section out instead of filling it
    with weak items.** A brief with three excellent sections is better than one with six decent ones.
    Before keeping any item, ask: "Would they be glad I showed them this, or would they shrug?" If
    the answer is a shrug, cut it.

    Things that make an item weak, and should get it cut:
    - Generic: it could have been written for anyone ("Here's an AI news roundup").
    - Stale or obvious: they already know it, or it's restating their own timeline back to them without
      adding anything.
    - Low confidence: you're guessing at a decision, a number, or what they care about.
    - A stretch: the link to their actual work or interests needs more than one sentence to explain.

    \(aboutThem)

    If a whole section keeps getting ignored in the feedback above, show it less often or drop it.

    ## Tools you can use

    \(dayflowAndConnectorTools)
    - **WebSearch / WebFetch**: for the reading and news sections. Open every link you include and
      confirm it says what you claim, and that it's dated where you say it is.
    - **Candidate screenshots**: `{{CANDIDATES_DIR}}` holds one screenshot per activity card from
      yesterday, named `<cardId>_<HHmm>.jpg`. `{{CANDIDATES_DIR}}/index.json` lists each file with its
      card id, times, and title. View the files with the Read tool.

    Budget: aim to finish in about 10 minutes. Prefer a few targeted searches over many broad ones.

    ## Sections

    Each section is optional. Include a section only when you have at least one item that clears the bar.
    Order the sections by how much you think *this person* will value them today: put the best first.
    Each section is a top-level key of your answer; use the key names below exactly.

    ### `keep_tracking` — "Keep tracking"
    Ongoing things with a number or state that moved: a launch's signup count, an experiment's
    results, a PR waiting on review, a thread that went quiet. Each item gives the thing being tracked,
    the current state in one line, where it came from, and the date of that state. Only include an item
    when you found the actual current state; "check on X" is not an item.

    ### `completed_yesterday` — "What you completed yesterday"
    1–4 real accomplishments from yesterday, phrased the way they'd tell a friend ("Shipped the island map
    in Flow"). Group cards that belong to one piece of work. Give each the project or area it belongs
    to, the apps involved, and the single best `cardId` to illustrate it (its screenshot will be shown;
    use a card id from the timeline above). Skip this section on a day with no real finished work;
    browsing is not an accomplishment.

    ### `team_decisions` — "Key team decisions"
    Decisions made in the last 2 days, found in their connectors (Slack threads, meeting notes, docs),
    that affect what they're working on. One sentence each, stating the decision itself ("Launch moved to
    Nov 1 because of the payments review"), plus who was involved, where (`place`), when, and a link. Only
    include a decision when the source shows it was actually agreed, not just proposed.

    ### `related_reading` — "Related to your interests"
    2–6 articles, talks, videos, or examples connected to something specific they spent real time on
    recently. Put one sentence naming the thread you're following in `related_reading_intro` ("You've
    been deep in Flow's retention loop, so…"). Each item: title, source, URL, a one-line reason it's worth
    their time, and an image URL if the page has a good one (og:image). Favor primary sources, standout
    essays, and concrete examples over listicles and SEO pages. Things from their personal life (a trip,
    a hobby, a restaurant they saved) count when they're clearly enjoyable.

    ### `industry_news` — "Latest in your industry"
    1–3 headlines from the last 48 hours that matter to their field or their company specifically. Each item:
    headline, publication, URL, publish date. Skip this section entirely on a slow news day; never pad it with
    general tech news.

    ### `site_seeing` — "Recent site-seeing"
    3–8 of the most visually interesting moments from yesterday, picked by actually looking at the
    candidate screenshots: beautiful images, striking designs, places, art, games, fun videos. They don't
    need to be work. Each item: the screenshot file name exactly as listed in index.json and a short
    caption (≤ 8 words). Never pick adult or sexual content. Skip screens that are mostly text, code,
    spreadsheets, or chat, and screens showing passwords or financial account details.

    \(writingStyle)

    {{OVERRIDE_INSTRUCTIONS}}

    ## Output

    Your final answer is one JSON object (it's checked against a schema). Each section you include is a
    top-level key holding its items; leave out the keys of sections you skip. `order` lists the sections
    you included, best first.

    Show your reasoning; it's how the brief gets debugged. `notes` is a short account of the run: what
    you looked at, what you found, which sections you skipped and why, and anything you weren't sure
    about. Every item also gets a `why`: one or two sentences on why it made the cut, naming the
    evidence (the card, thread, doc, or page and what it said). The user never sees `notes` or `why`,
    so be candid. For example:

    ```json
    {
      "notes": "Read 24 cards (mostly Flow paywall work and Slack). Searched Slack for launch threads; found the launch date change. Skipped industry_news: nothing relevant in the last 48 hours.",
      "order": ["completed_yesterday", "related_reading", "site_seeing"],
      "keep_tracking": [
        { "label": "Flow onboarding progress", "status": "50 invites sent, 20 onboarded, 3 dropped off.", "app": "slack", "asOf": "2026-10-19", "url": "https://...", "why": "..." }
      ],
      "completed_yesterday": [
        { "project": "Flow", "title": "Shipped the island map in Flow", "apps": ["claude", "chatgpt"], "cardId": 1234, "why": "..." }
      ],
      "team_decisions": [
        { "decision": "Launch moved to Nov 1 because of the payments review.", "date": "2026-10-19", "people": ["Maggie Chang"], "place": "#dayflow", "app": "slack", "url": "https://...", "why": "..." }
      ],
      "related_reading_intro": "You've been deep in Flow's retention loop, so these might spark some ideas.",
      "related_reading": [
        { "title": "The Mechanics & Monetization of Idle Games", "source": "GDC", "url": "https://...", "reason": "How idle games pace rewards to bring players back daily.", "imageUrl": "https://...", "why": "..." }
      ],
      "industry_news": [
        { "headline": "...", "source": "Financial Times", "url": "https://...", "published": "2026-10-21", "why": "..." }
      ],
      "site_seeing": [
        { "file": "1234_1342.jpg", "caption": "Shoji bar, saved for Miami", "why": "..." }
      ]
    }
    ```

    Use only the fields shown. Dates are yyyy-MM-dd. `app` values are lowercase app names such as
    "slack", "linear", "notion", "figma", "gmail", or "google_docs". Omit a field when you don't have it;
    never write placeholder values. If nothing clears the bar today, write `{"notes": "...", "order": []}`.
    """
}
