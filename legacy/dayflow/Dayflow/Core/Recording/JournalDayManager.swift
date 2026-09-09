//
//  JournalDayManager.swift
//  Dayflow
//
//  Manages state and data for JournalDayView
//

import Combine
import Foundation
import SwiftUI

/// ObservableObject that manages journal day state, data loading, and flow transitions
@MainActor
final class JournalDayManager: ObservableObject {

  // MARK: - Published State

  /// The day being viewed (YYYY-MM-DD format, 4AM boundary)
  @Published private(set) var currentDay: String

  /// The journal entry for the current day (nil if none exists)
  @Published private(set) var entry: JournalEntry?

  /// Current flow state for the UI
  @Published var flowState: JournalFlowState = .intro

  /// Recent summary from a previous day (within 3 days) to show on intro
  @Published private(set) var recentSummary: (day: String, summary: String)?

  /// Pre-filled goals from most recent entry
  @Published private(set) var prefillGoals: String?

  /// Whether the current day is "today" (can edit)
  @Published private(set) var isToday: Bool = true

  /// Whether the day has enough timeline activity for summarization (1hr+)
  @Published private(set) var canSummarize: Bool = false

  /// Loading state for async operations
  @Published private(set) var isLoading: Bool = false

  /// Error message if something goes wrong
  @Published var errorMessage: String?

  // MARK: - Form Data (for editing)

  /// Editable form data synced with entry
  @Published var formIntentions: String = ""
  @Published var formNotes: String = ""
  @Published var formGoals: String = ""
  @Published var formReflections: String = ""
  @Published var formSummary: String = ""

  // MARK: - Private

  private let storage = StorageManager.shared

  // MARK: - Initialization

  init() {
    // Initialize with today's date using 4AM boundary
    let (dayString, _, _) = Date().getDayInfoFor4AMBoundary()
    self.currentDay = dayString
    self.isToday = true
  }

  // MARK: - Public Methods

  /// Load data for the current day
  func loadCurrentDay() {
    loadDay(currentDay)
  }

  /// Load data for a specific day
  func loadDay(_ day: String) {
    currentDay = day
    isToday = checkIsToday(day)

    // Fetch entry from storage
    entry = storage.fetchJournalEntry(forDay: day)

    // Sync form data with entry
    syncFormDataFromEntry()

    // Load recent summary (only if today and no entry yet)
    if isToday && (entry == nil || entry?.status == "draft") {
      recentSummary = storage.fetchRecentJournalSummary(withinDays: 3)
    } else {
      recentSummary = nil
    }

    // Load prefill goals
    prefillGoals = storage.fetchMostRecentGoals()

    // Pre-fill goals in form if empty
    if formGoals.isEmpty, let goals = prefillGoals {
      formGoals = goals
    }

    // Check if we can summarize (has 1hr+ timeline activity)
    canSummarize = storage.hasMinimumTimelineActivity(forDay: day, minimumMinutes: 60)

    // Determine initial flow state
    flowState = determineInitialFlowState()
  }

  /// Navigate to the previous day
  func navigateToPreviousDay() {
    // Block navigation while generating summary
    guard !isLoading else { return }

    guard let date = dateFromDayString(currentDay),
      let previousDate = Calendar.current.date(byAdding: .day, value: -1, to: date)
    else {
      return
    }
    let (dayString, _, _) = previousDate.getDayInfoFor4AMBoundary()
    AnalyticsService.shared.capture("journal_day_navigated", ["direction": "previous"])
    loadDay(dayString)
  }

  /// Navigate to the next day (capped at today)
  func navigateToNextDay() {
    // Block navigation while generating summary
    guard !isLoading else { return }

    guard let date = dateFromDayString(currentDay),
      let nextDate = Calendar.current.date(byAdding: .day, value: 1, to: date)
    else {
      return
    }

    // Don't go past today
    let (todayString, _, _) = Date().getDayInfoFor4AMBoundary()
    let (nextDayString, _, _) = nextDate.getDayInfoFor4AMBoundary()

    if nextDayString <= todayString {
      AnalyticsService.shared.capture("journal_day_navigated", ["direction": "next"])
      loadDay(nextDayString)
    }
  }

  /// Check if we can navigate forward (not at today)
  var canNavigateForward: Bool {
    let (todayString, _, _) = Date().getDayInfoFor4AMBoundary()
    return currentDay < todayString
  }

  // MARK: - Save Methods

  /// Save intentions form (morning)
  func saveIntentions() {
    // Normalize the form data
    let normalizedIntentions = normalizeListText(formIntentions)
    let normalizedGoals = normalizeListText(formGoals)
    let trimmedNotes = formNotes.trimmingCharacters(in: .whitespacesAndNewlines)

    // Save to storage
    storage.updateJournalIntentions(
      day: currentDay,
      intentions: normalizedIntentions.isEmpty ? nil : normalizedIntentions,
      notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
      goals: normalizedGoals.isEmpty ? nil : normalizedGoals
    )

    // Track analytics (character counts only, no content)
    AnalyticsService.shared.capture(
      "journal_intentions_saved",
      [
        "intentions_chars": normalizedIntentions.count,
        "notes_chars": trimmedNotes.count,
        "goals_chars": normalizedGoals.count,
      ])

    // Reload entry
    entry = storage.fetchJournalEntry(forDay: currentDay)
    syncFormDataFromEntry()

    // Transition to next state
    flowState = determinePostIntentionsState()
  }

  /// Save reflections (evening)
  func saveReflections() {
    let trimmedReflections = formReflections.trimmingCharacters(in: .whitespacesAndNewlines)

    storage.updateJournalReflections(
      day: currentDay,
      reflections: trimmedReflections.isEmpty ? nil : trimmedReflections
    )

    // Track analytics (character count only, no content)
    AnalyticsService.shared.capture(
      "journal_reflections_saved",
      [
        "reflections_chars": trimmedReflections.count
      ])

    // Reload entry
    entry = storage.fetchJournalEntry(forDay: currentDay)
    syncFormDataFromEntry()

    // Transition to saved state
    flowState = .reflectionSaved
  }

  /// Skip reflections
  func skipReflections() {
    AnalyticsService.shared.capture("journal_reflections_skipped")
    formReflections = ""
    flowState = .reflectionSaved
  }

  /// Save the AI summary (public API uses currentDay)
  func saveSummary(_ summary: String) {
    saveSummary(summary, forDay: currentDay)
  }

  /// Save the AI summary to a specific day (internal use for race-condition safety)
  private func saveSummary(_ summary: String, forDay day: String) {
    storage.updateJournalSummary(day: day, summary: summary)

    // Only reload entry and sync form if we're still on the same day
    if currentDay == day {
      entry = storage.fetchJournalEntry(forDay: day)
      syncFormDataFromEntry()
    }
  }

  // MARK: - Flow State Transitions

  /// Manually transition to intentions edit
  func startEditingIntentions() {
    flowState = .intentionsEdit
  }

  /// Go back from intentions edit
  func cancelEditingIntentions() {
    // Reset form to entry data
    syncFormDataFromEntry()
    flowState = determineInitialFlowState()
  }

  /// Start reflection editing
  func startReflecting() {
    flowState = .reflectionEdit
  }

  // MARK: - Computed Properties

  /// Formatted headline for the day
  var headline: String {
    guard let date = dateFromDayString(currentDay) else {
      return currentDay
    }

    let formatter = DateFormatter()

    if isToday {
      // "Today, November 24" - no day of week needed
      formatter.dateFormat = "MMMM d"
      return "Today, \(formatter.string(from: date))"
    } else {
      // "Monday, November 24" - day of week helps orient for past days
      formatter.dateFormat = "EEEE, MMMM d"
      return formatter.string(from: date)
    }
  }

  /// CTA title for intro screen
  var ctaTitle: String {
    if entry?.status == "intentions_set" || entry?.status == "complete" {
      return "Edit intentions"
    }
    return "Set today's intentions"
  }

  /// Intentions as a list of strings (for display)
  var intentionsList: [String] {
    splitLines(formIntentions)
  }

  /// Goals as a list of strings (for display)
  var goalsList: [String] {
    splitLines(formGoals)
  }

  // MARK: - Private Helpers

  private func checkIsToday(_ day: String) -> Bool {
    let (todayString, _, _) = Date().getDayInfoFor4AMBoundary()
    return day == todayString
  }

  private func dateFromDayString(_ day: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = Calendar.current.timeZone
    guard let date = formatter.date(from: day) else { return nil }
    // Use noon to avoid 4AM boundary issues when doing date arithmetic
    return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date)
  }

  private func syncFormDataFromEntry() {
    formIntentions = entry?.intentions ?? ""
    formNotes = entry?.notes ?? ""
    formGoals = entry?.goals ?? prefillGoals ?? ""
    formReflections = entry?.reflections ?? ""
    formSummary = entry?.summary ?? ""
  }

  private func determineInitialFlowState() -> JournalFlowState {
    guard let entry = entry else {
      // No entry exists
      if isToday {
        // Show summary from yesterday if available
        if recentSummary != nil {
          return .summary
        }
        return .intro
      } else {
        // Past day with no entry - read-only intro
        return .intro
      }
    }

    // Entry exists - determine based on status
    switch entry.status {
    case "complete":
      return .boardComplete

    case "intentions_set":
      if isToday {
        // Check if it's evening (after 4 PM) to prompt reflection
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 16 {
          // Check if reflections already exist
          if let reflections = entry.reflections, !reflections.isEmpty {
            return .reflectionSaved
          }
          return .reflectionPrompt
        }
      }
      // Show the board with intentions
      return .reflectionPrompt

    default:  // "draft" or unknown
      if isToday {
        if recentSummary != nil {
          return .summary
        }
        return .intro
      }
      return .intro
    }
  }

  private func determinePostIntentionsState() -> JournalFlowState {
    // After saving intentions, check time of day
    if isToday {
      let hour = Calendar.current.component(.hour, from: Date())
      if hour >= 16 {
        return .reflectionPrompt
      }
    }
    return .reflectionPrompt
  }

  private func normalizeListText(_ text: String) -> String {
    splitLines(text).joined(separator: "\n")
  }

  private func splitLines(_ text: String) -> [String] {
    text
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  // MARK: - Summary Generation

  /// Generate AI summary from timeline + journal data
  func generateSummary() async {
    // Capture day at start to prevent race condition if user navigates during generation
    let dayToSave = currentDay
    let capturedIntentions = formIntentions
    let capturedNotes = formNotes
    let capturedGoals = formGoals
    let capturedReflections = formReflections

    isLoading = true
    errorMessage = nil

    do {
      // 1. Fetch timeline cards for the captured day
      let timelineCards = storage.fetchTimelineCards(forDay: dayToSave)

      // 2. Fetch recent summaries for variety (exclude current day)
      let recentSummaries = storage.fetchRecentJournalSummaries(count: 3, excludingDay: dayToSave)

      // 3. Build prompt with captured context
      let prompt = buildSummaryPrompt(
        timelineCards: timelineCards,
        intentions: capturedIntentions,
        notes: capturedNotes,
        goals: capturedGoals,
        reflections: capturedReflections,
        recentSummaries: recentSummaries
      )

      // 4. Call LLM
      let rawResult = try await callLLMForSummary(prompt: prompt)

      // 5. Parse summary from <summary> tags (strip tags before saving)
      let cleanedSummary = parseSummaryFromTags(rawResult)

      // 6. Save summary to the captured day (not currentDay which may have changed)
      saveSummary(cleanedSummary, forDay: dayToSave)

      // Track success (character count only, no content)
      AnalyticsService.shared.capture(
        "journal_summary_generated",
        [
          "success": true,
          "summary_chars": cleanedSummary.count,
        ])

      // 7. Only update UI if we're still on the same day
      if currentDay == dayToSave {
        flowState = .boardComplete
      }

    } catch {
      // Track failure
      AnalyticsService.shared.capture(
        "journal_summary_generated",
        [
          "success": false,
          "summary_chars": 0,
        ])
      errorMessage = "Failed to generate summary: \(error.localizedDescription)"
      print("❌ [JournalDayManager] Summary generation failed: \(error)")
    }

    isLoading = false
  }

  private func buildSummaryPrompt(
    timelineCards: [TimelineCard],
    intentions: String,
    notes: String,
    goals: String,
    reflections: String,
    recentSummaries: [(day: String, summary: String)]
  ) -> String {
    // Format timeline as readable text
    let timelineText = timelineCards.map { card in
      "\(card.startTimestamp)-\(card.endTimestamp): \(card.title) - \(card.summary)"
    }.joined(separator: "\n")

    // Format recent summaries for variety prompt
    let recentSummariesText: String
    if recentSummaries.isEmpty {
      recentSummariesText = "(No recent summaries)"
    } else {
      recentSummariesText = recentSummaries.map { "[\($0.day)]\n\($0.summary)" }.joined(
        separator: "\n\n")
    }

    return """
      You are writing a personal daily summary for a productivity app. Write in first person from the user's perspective.

      FORMAT:
      **Wins:** 2-3 key accomplishments from the day, one line
      [Narrative paragraph: 3-5 sentences covering the arc of the day—morning, afternoon, evening—as relevant. Keep it warm and reflective, not robotic. Use varied sentence lengths. Be specific about what happened but don't over-explain.]
      **To improve:** 1 honest observation about what could've gone better, one line

      STYLE GUIDELINES:
      - Warm and reflective, like you're journaling for yourself
      - Punchy and scannable—no walls of text
      - Judicious bolding: 1-3 bolded phrases max in the narrative paragraph, only for key activities or focus areas that anchor the day. Don't bold generic words or overdo it.
      - Avoid corporate/productivity jargon ("deep work", "optimized", "leveraged")
      - Vary your sentence openers—don't start every sentence with "I"
      - Do NOT infer emotions or feelings—only reference how the user felt if they explicitly stated it in their intentions or reflections

      EXAMPLE:
      <summary>
      **Wins:** Shipped the journal feature I set out to finish. Made real progress on video animations and started rethinking how timeline cards should feel.

      The morning didn't have much direction—some scrolling, flight searches, a League video. Things clicked mid-afternoon when I got into **Swift animation work**, dialing in spring curves and reverse logic. Evening was a mix: Japan trip planning with friends, Duke interview prep, then back to **timeline card specs**. Ended the night playing with Opus 4.5.

      **To improve:** Morning had too much drift. Would've felt better to batch distractions and start focused.
      </summary>

      IMPORTANT: Below are the user's recent summaries. Do NOT reuse the same phrases, sentence structures, or openers. Keep the format consistent but make the language feel fresh.

      RECENT SUMMARIES:
      \(recentSummariesText)

      TODAY'S DATA:

      TIMELINE ACTIVITY:
      \(timelineText.isEmpty ? "No activity recorded" : timelineText)

      MORNING INTENTIONS:
      \(intentions.isEmpty ? "None set" : intentions)

      NOTES FOR THE DAY:
      \(notes.isEmpty ? "None" : notes)

      LONG-TERM GOALS:
      \(goals.isEmpty ? "None set" : goals)

      EVENING REFLECTIONS:
      \(reflections.isEmpty ? "None provided" : reflections)

      Write the summary now, wrapped in <summary> tags:
      """
  }

  /// Extract summary content from <summary> tags, handling malformed closing tags
  private func parseSummaryFromTags(_ raw: String) -> String {
    // Try to match <summary>content</summary> or <summary>content<summary (malformed)
    // Pattern handles both proper and malformed closing tags
    let pattern = #"<summary>([\s\S]*?)(?:</summary>|<summary|$)"#

    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
      let match = regex.firstMatch(
        in: raw, options: [], range: NSRange(raw.startIndex..., in: raw)),
      let contentRange = Range(match.range(at: 1), in: raw)
    else {
      // No tags found - return trimmed raw content as fallback
      return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return String(raw[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func callLLMForSummary(prompt: String) async throws -> String {
    // Use LLMService which handles provider selection automatically
    return try await LLMService.shared.generateText(prompt: prompt)
  }
}

// MARK: - JournalFlowState Extension

extension JournalFlowState {
  /// Whether this state allows editing (only today)
  var isEditableState: Bool {
    switch self {
    case .intentionsEdit, .reflectionEdit:
      return true
    default:
      return false
    }
  }
}
