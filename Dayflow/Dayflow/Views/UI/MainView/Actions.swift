import SwiftUI
import AppKit

extension MainView {
    func handleCategoryChange(to category: TimelineCategory, for activity: TimelineActivity) {
        let newName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Optimistically update the selected activity so the UI reflects the change immediately.
        selectedActivity = activity.withCategory(newName)

        // Ask the timeline list to refresh so other cards stay in sync.
        refreshActivitiesTrigger &+= 1

        guard let recordId = activity.recordId else { return }

        // Persist the change off the main actor to avoid blocking UI interactions.
        Task.detached(priority: .userInitiated) {
            StorageManager.shared.updateTimelineCardCategory(cardId: recordId, category: newName)
        }
    }

    func handleTimelineRating(_ direction: TimelineRatingDirection) {
        guard let activity = selectedActivity else { return }

        feedbackActivitySnapshot = activity
        feedbackDirection = direction
        feedbackMessage = ""
        feedbackShareLogs = true
        feedbackMode = .form

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            feedbackModalVisible = true
        }

        let props = timelineFeedbackAnalyticsPayload(for: activity, direction: direction)
        AnalyticsService.shared.capture("timeline_summary_rated", props)
    }

    func handleFeedbackSubmit() {
        let trimmed = feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let activity = feedbackActivitySnapshot,
              let direction = feedbackDirection else { return }

        var props = timelineFeedbackAnalyticsPayload(for: activity, direction: direction)
        props["feedback_message_length"] = trimmed.count
        props["share_logs_enabled"] = feedbackShareLogs
        if !trimmed.isEmpty {
            props["feedback_message"] = trimmed
        }

        AnalyticsService.shared.capture("timeline_summary_feedback_submitted", props)
        feedbackMessage = ""
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            feedbackMode = .thanks
        }
    }

    func dismissFeedbackModal(animated: Bool = true) {
        guard feedbackModalVisible else { return }

        let reset = {
            feedbackModalVisible = false
            feedbackDirection = nil
            feedbackActivitySnapshot = nil
            feedbackMessage = ""
            feedbackMode = .form
        }

        if animated {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                reset()
            }
        } else {
            reset()
        }
    }

    func loadWeeklyTrackedMinutes() {
        Task.detached(priority: .userInitiated) {
            let minutes = StorageManager.shared.fetchTotalMinutesTrackedForWeek(containing: Date())
            await MainActor.run {
                weeklyTrackedMinutes = minutes
            }
        }
    }

    func updateCardsToReviewCount() {
        reviewCountTask?.cancel()
        let timelineDate = timelineDisplayDate(from: selectedDate, now: Date())
        let dayString = DateFormatter.yyyyMMdd.string(from: timelineDate)

        reviewCountTask = Task.detached(priority: .userInitiated) {
            let count = StorageManager.shared.fetchUnreviewedTimelineCardCount(forDay: dayString, coverageThreshold: 0.8)
            await MainActor.run {
                cardsToReviewCount = count
            }
        }
    }

    func copyTimelineToClipboard() {
        guard copyTimelineState != .copying else { return }

        let timelineDate = timelineDisplayDate(from: selectedDate, now: Date())
        let day = dayString(timelineDate)

        copyTimelineTask?.cancel()

        withAnimation(.snappy(duration: 0.3)) {
            copyTimelineState = .copying
        }

        copyTimelineTask = Task {
            defer {
                Task { @MainActor in
                    if copyTimelineState == .copying {
                        withAnimation(.snappy(duration: 0.3)) {
                            copyTimelineState = .idle
                        }
                    }
                    copyTimelineTask = nil
                }
            }

            let cards = StorageManager.shared.fetchTimelineCards(forDay: day)
            let clipboardText = TimelineClipboardFormatter.makeClipboardText(for: timelineDate, cards: cards)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(clipboardText, forType: .string)

                withAnimation(.snappy(duration: 0.3)) {
                    copyTimelineState = .copied
                }
            }

            AnalyticsService.shared.capture("timeline_copied", [
                "timeline_day": day,
                "activity_count": cards.count
            ])

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.snappy(duration: 0.3)) {
                    copyTimelineState = .idle
                }
            }
        }
    }

    func timelineFeedbackAnalyticsPayload(for activity: TimelineActivity, direction: TimelineRatingDirection) -> [String: Any] {
        var props: [String: Any] = [
            "thumb_direction": direction.rawValue,
            "timeline_selected_day": dayString(selectedDate),
            "activity_title": activity.title,
            "activity_summary": activity.summary,
            "activity_detailed_summary": activity.detailedSummary,
            "activity_category": activity.category,
            "activity_subcategory": activity.subcategory,
            "activity_start_ts": iso8601Formatter.string(from: activity.startTime),
            "activity_end_ts": iso8601Formatter.string(from: activity.endTime),
            "activity_duration_seconds": Int(activity.endTime.timeIntervalSince(activity.startTime)),
            "activity_day_bucket": AnalyticsService.shared.dayString(activity.startTime),
            "activity_has_screenshot": activity.screenshot != nil,
            "activity_has_video_summary": activity.videoSummaryURL != nil,
            "timeline_share_logs_default": true
        ]

        if let recordId = activity.recordId {
            props["activity_record_id"] = Int(recordId)
        }
        if let batchId = activity.batchId {
            props["activity_batch_id"] = Int(batchId)
        }
        if let videoURL = activity.videoSummaryURL {
            props["activity_video_summary_url"] = videoURL
        }
        if let appSites = activity.appSites {
            if let primary = appSites.primary {
                props["activity_primary_site"] = primary
            }
            if let secondary = appSites.secondary {
                props["activity_secondary_site"] = secondary
            }
        }
        if let distractions = activity.distractions, !distractions.isEmpty {
            props["activity_distractions_count"] = distractions.count
            let preview = distractions.prefix(3).map { "\($0.title):\($0.summary)" }.joined(separator: " || ")
            props["activity_distractions_preview"] = preview
        } else {
            props["activity_distractions_count"] = 0
        }

        props["activity_summary_length"] = activity.summary.count
        props["activity_detailed_summary_length"] = activity.detailedSummary.count

        return props
    }
}
