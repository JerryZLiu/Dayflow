import Foundation

enum ClaudePromptPreferences {
  private static let overridesKey = "claudePromptOverrides"

  static func hasStoredOverrides(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: overridesKey) != nil
  }

  static func load(from defaults: UserDefaults = .standard) -> ActivityCardPromptOverrides {
    guard let data = defaults.data(forKey: overridesKey),
      let overrides = try? JSONDecoder().decode(ActivityCardPromptOverrides.self, from: data)
    else {
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

  static func reset(in defaults: UserDefaults = .standard) {
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
      if let previousValue {
        defaults.set(previousValue, forKey: overridesKey)
      } else {
        defaults.removeObject(forKey: overridesKey)
      }
      throw ProviderPromptPreferencesError.writeVerificationFailed
    }
  }
}

enum ClaudePromptDefaults {
  static let titleBlock = """
    <title_goal>
    Write one glanceable memory cue for every fixed card. The user should recognize the episode next week without opening its summary. Use natural language, usually 4-10 words.
    </title_goal>

    <selection_order>
    1. Identify the most coherent observed goal or event inside this card from sustained evidence, recurrence, and deliberate interaction. Do not choose the last screen or the most unusual noun.
    2. If one activity clearly occupies more supported minutes, title only that activity. Prefer a direct conversation or concrete artifact over diffuse passive pages and notifications.
    3. Add the strongest supported anchor that distinguishes this episode from its neighbors: a person, artifact, game character or mode, place, feature, comparison subjects, or real-world automation target.
    </selection_order>

    <rules>
    - Recompute every title after final boundaries change; previous titles are drafts.
    - A brief passive headline, newsletter, notification, advertisement, or one-off name cannot take over a longer episode.
    - A short direct interaction may be the best cue only when the rest of the card is diffuse passive catch-up and no longer coherent activity exists. Name the actual person and supported topic. Do not append unrelated brief debugging, group threads, or notifications.
    - When research leads into configuring a recurring check, prefer the setup action and real-world target over generic research or the agent UI.
    - When several tools or models support review of one named artifact, title the artifact being reviewed. When the task itself is a structured comparison, name two or three recurring items or the two compared styles.
    - For a merged gaming episode, choose the most sustained or distinctive character, mode, map, or action. Do not mention earlier shorter matches with "then," "after," or a chronological list.
    - "And" is fine for one shared goal or a balanced compound. Do not use it to expose a shorter incidental activity.
    </rules>

    <mixed_cards>
    Determine whether time was fragmented from its evidence, not from its draft title. For a long span of diffuse passive switching, use "Scattered" plus two or three familiar channels and ignore incidental newsletters or headlines. Avoid repeating "Scattered" within one returned array when a later mixed episode can use a concrete balanced compound, but never change boundaries or promote an incidental activity merely to avoid the repeated word.
    </mixed_cards>

    <examples>
    <example>
    Evidence: apartment research followed by configuring an agent to check Lisbon rents each morning.
    Title: Setting Up Daily Lisbon Rent Checks
    </example>
    <example>
    Evidence: recurring side-by-side judgments of Runway, Pika, and Luma clips.
    Title: Comparing Runway, Pika, and Luma Clips
    </example>
    <example>
    Evidence: several image tools used while judging the opening frames of one launch trailer.
    Title: Reviewing Launch Trailer Opening Frames
    </example>
    <example>
    Evidence: eleven minutes messaging Priya about feeling ill and dinner, plus a three-minute unrelated debugger check.
    Title: Messages With Priya About Feeling Ill
    </example>
    <example>
    Evidence: one merged Overwatch episode with a shorter ranked match followed by a longer Kiriko arcade run on Lijiang Tower.
    Title: Kiriko Team Fights on Lijiang Tower
    </example>
    </examples>

    <final_check>
    Compare every title with its fixed evidence and neighboring cards. Reject a title that foregrounds a shorter detour, preserves match chronology, promotes an incidental newsletter or headline, or uses generic phrases such as "research," "design work," "agent task," "results," or unnamed "AI models" despite a stronger cue. Stay broad when the evidence is genuinely broad.
    </final_check>
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

struct ClaudePromptSections {
  let title: String
  let summary: String
  let detailedSummary: String

  init(overrides: ActivityCardPromptOverrides) {
    self.title = ClaudePromptSections.compose(
      defaultBlock: ClaudePromptDefaults.titleBlock, custom: overrides.titleBlock)
    self.summary = ClaudePromptSections.compose(
      defaultBlock: ClaudePromptDefaults.summaryBlock, custom: overrides.summaryBlock)
    self.detailedSummary = ClaudePromptSections.compose(
      defaultBlock: ClaudePromptDefaults.detailedSummaryBlock, custom: overrides.detailedBlock)
  }

  private static func compose(defaultBlock: String, custom: String?) -> String {
    let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? defaultBlock : trimmed
  }
}
