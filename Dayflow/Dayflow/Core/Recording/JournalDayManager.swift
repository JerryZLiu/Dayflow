//
//  JournalDayManager.swift
//  Dayflow
//
//  Manages state and data for JournalDayView
//

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
        guard let date = dateFromDayString(currentDay),
              let previousDate = Calendar.current.date(byAdding: .day, value: -1, to: date) else {
            return
        }
        let (dayString, _, _) = previousDate.getDayInfoFor4AMBoundary()
        loadDay(dayString)
    }

    /// Navigate to the next day (capped at today)
    func navigateToNextDay() {
        guard let date = dateFromDayString(currentDay),
              let nextDate = Calendar.current.date(byAdding: .day, value: 1, to: date) else {
            return
        }

        // Don't go past today
        let (todayString, _, _) = Date().getDayInfoFor4AMBoundary()
        let (nextDayString, _, _) = nextDate.getDayInfoFor4AMBoundary()

        if nextDayString <= todayString {
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

        // Reload entry
        entry = storage.fetchJournalEntry(forDay: currentDay)
        syncFormDataFromEntry()

        // Transition to saved state
        flowState = .reflectionSaved
    }

    /// Skip reflections
    func skipReflections() {
        formReflections = ""
        flowState = .reflectionSaved
    }

    /// Save the AI summary
    func saveSummary(_ summary: String) {
        storage.updateJournalSummary(day: currentDay, summary: summary)

        // Reload entry
        entry = storage.fetchJournalEntry(forDay: currentDay)
        syncFormDataFromEntry()

        // Transition to complete
        flowState = .boardComplete
    }

    /// Update summary text (for editing)
    func updateSummary(_ summary: String) {
        formSummary = summary
        storage.updateJournalSummary(day: currentDay, summary: summary)
        entry = storage.fetchJournalEntry(forDay: currentDay)
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
        formatter.dateFormat = "EEEE, MMMM d"

        if isToday {
            return "Today, \(formatter.string(from: date))"
        } else {
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
        return formatter.date(from: day)
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

        default: // "draft" or unknown
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
