import Foundation

enum CodexPromptPreferences {
  private static let overridesKey = "chatGPTPromptOverrides"

  static func hasStoredOverrides(
    in defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.object(forKey: overridesKey) != nil
  }

  static func load(
    from defaults: UserDefaults = .standard
  ) -> ActivityCardPromptOverrides {
    guard let data = defaults.data(forKey: overridesKey) else {
      return ActivityCardPromptOverrides()
    }
    guard let overrides = try? JSONDecoder().decode(ActivityCardPromptOverrides.self, from: data) else {
      return ActivityCardPromptOverrides()
    }
    return overrides
  }

  static func save(
    _ overrides: ActivityCardPromptOverrides,
    to defaults: UserDefaults = .standard
  ) {
    try? saveVerified(overrides, to: defaults)
  }

  static func reset(
    in defaults: UserDefaults = .standard
  ) {
    defaults.removeObject(forKey: overridesKey)
  }

  static func saveVerified(
    _ overrides: ActivityCardPromptOverrides,
    to defaults: UserDefaults
  ) throws {
    let previousValue = defaults.object(forKey: overridesKey)
    let data: Data
    do {
      data = try JSONEncoder().encode(overrides)
    } catch {
      throw ProviderPromptPreferencesError.encodingFailed
    }

    defaults.set(data, forKey: overridesKey)
    guard load(from: defaults) == overrides else {
      restore(previousValue, forKey: overridesKey, in: defaults)
      throw ProviderPromptPreferencesError.writeVerificationFailed
    }
  }

  private static func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

}

enum CodexPromptDefaults {
  static let titleBlock = """
    TITLE GOAL

    Write one glanceable, evidence-backed memory cue for each card. The user should recognize what happened next week without opening the summary. Usually use 4-10 words.

    BOUNDARIES BEFORE TITLES

    Re-segment the supplied evidence before choosing title words; previous cards and their 15-minute seams are drafts. Keep a meeting or huddle separate from subsequent hands-on artifact work when both sides can be at least 10 minutes, even if they share a project. When a direct conversation begins near a draft seam, continues into the next batch, and then gives way to a different browsing episode, place the boundary after the conversation ends when both resulting cards can be at least 10 minutes. After that pass, freeze boundaries—proper names and title phrasing must not move them.

    CUE PRIORITY

    1. Re-read only the evidence inside each final card.
    2. Choose the sustained goal or strongest recurring cue, weighting duration and deliberate interaction over novelty.
    3. Add the details that distinguish the episode: person and topic, familiar project, named artifact, comparison subjects, game mode or character, service, place, cadence, or real-world target.
    4. A deliberate completion such as configuring a scheduled task may outrank longer preparatory browsing when it is the clearest reconstructable outcome.
    5. Prefer what the user acted on over a passive notification, advertisement, or briefly visible noun.

    FOCUSED CARDS

    - For a meeting or huddle, name the interaction type, person, and main project or decision topic. Do not append secondary work.
    - When the evidence says a scheduled, daily, or recurring check was configured, title that setup with its cadence, named service, and target. Do not dilute it with surrounding searches or detours.
    - For a sustained comparison, name two to four recurring subjects and the artifact type instead of saying “AI models,” “outputs,” or “research.”
    - For launch or storyboard work, preserve the named treatment and artifact type—frames, storyboards, or clips—rather than collapsing it to “visuals.”
    - For a game, prefer the supported mode, character, and memorable observed event over a generic game-session label.
    - When several tools support one artifact, name the artifact rather than the tools.

    MIXED CARDS

    - For diffuse passive switching with no deliberate thread, use an honest “Scattered” title with recurring channels such as email, X, news, or YouTube. Do not promote one unusual product or article.
    - For a direct conversation, include the observed person and salient topic rather than “catch-up”; the person usually matters more than the messaging app.
    - For intentional browsing, preserve observed proper names for destinations, stores, artifacts, and benchmark sites. Prefer “Tokyo flower shops and Design Bench” over “Japanese culture and AI designs.”

    GROUNDING

    Describe only observed actions and outcomes. Reading is not deciding, reviewing is not creating, investigating is not fixing, and drafting is not sending. Never invent a differentiator.

    PATTERN EXAMPLES

    - “Slack huddle with Priya on checkout launch”
    - “Set up daily Zillow rent checks”
    - “Compared Runway, Pika, Veo, and Luma clips”
    - “Maya’s sick-day texts and weekend plans”
    - “Kyoto ceramics, screenplay notes, and Design Bench”

    FINAL CHECK

    Reject a title that foregrounds a shorter passive detour, copies an old title after evidence changed, claims an unsupported outcome, omits an observed person from a conversation cue, or stays generic despite a stronger supported proper name.
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
    [H:MM AM/PM] - [H:MM AM/PM]: [specific action] [in app/tool] [on what]
    Each line should be one sentence (~25 words max). Be concise but detailed.

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
    7:30 AM - 7:35: AM Slack
    7:35 AM - 8:00 AM coding"
    (Too coarse — what doc? which Slack channel? coding what?)
    """
}

struct CodexPromptSections {
  let title: String
  let summary: String
  let detailedSummary: String

  init(overrides: ActivityCardPromptOverrides) {
    self.title = CodexPromptSections.compose(
      defaultBlock: CodexPromptDefaults.titleBlock, custom: overrides.titleBlock)
    self.summary = CodexPromptSections.compose(
      defaultBlock: CodexPromptDefaults.summaryBlock, custom: overrides.summaryBlock)
    self.detailedSummary = CodexPromptSections.compose(
      defaultBlock: CodexPromptDefaults.detailedSummaryBlock, custom: overrides.detailedBlock)
  }

  private static func compose(defaultBlock: String, custom: String?) -> String {
    let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? defaultBlock : trimmed
  }
}
