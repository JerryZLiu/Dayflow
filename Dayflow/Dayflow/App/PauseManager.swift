//
//  PauseManager.swift
//  Dayflow
//
//  Manages timed pause functionality for recording.
//  Keeps pause state in-memory only (no persistence) so app restart = resume recording.
//

import Foundation
import AppKit
import Combine

// MARK: - Pause Types

enum PauseDuration: Equatable {
    case minutes15
    case minutes30
    case hour1
    case indefinite

    var timeInterval: TimeInterval? {
        switch self {
        case .minutes15: return 15 * 60
        case .minutes30: return 30 * 60
        case .hour1: return 60 * 60
        case .indefinite: return nil
        }
    }

    var analyticsValue: String {
        switch self {
        case .minutes15: return "15_mins"
        case .minutes30: return "30_mins"
        case .hour1: return "1_hour"
        case .indefinite: return "indefinite"
        }
    }
}

enum PauseSource: String {
    case menuBar = "menu_bar"
    case mainApp = "main_app"
    case deeplink = "deeplink"
}

enum ResumeSource: String {
    case userClickedMenuBar = "user_menu_bar"
    case userClickedMainApp = "user_main_app"
    case timerExpired = "timer_expired"
    case wakeFromSleep = "wake_from_sleep"
}

@MainActor
final class PauseManager: ObservableObject {
    static let shared = PauseManager()

    /// When the timed pause should end. nil = not on a timed pause.
    @Published private(set) var pauseEndTime: Date?

    /// True if user selected indefinite pause (∞). Separate from timed pause.
    @Published private(set) var isPausedIndefinitely: Bool = false

    /// The duration that was selected (for analytics)
    private var currentPauseDuration: PauseDuration?

    /// Convenience: true if any kind of user-initiated pause is active
    var isPaused: Bool {
        isPausedIndefinitely || pauseEndTime != nil
    }

    /// Remaining seconds for countdown display. nil if not on timed pause.
    var remainingSeconds: Int? {
        guard let end = pauseEndTime else { return nil }
        let remaining = end.timeIntervalSinceNow
        return remaining > 0 ? Int(ceil(remaining)) : 0
    }

    /// Formatted remaining time for display (e.g., "14:59")
    var remainingTimeFormatted: String? {
        guard let seconds = remainingSeconds, seconds > 0 else { return nil }
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var timer: Timer?

    private init() {
        registerForWakeNotification()
    }

    // MARK: - Public API

    /// Pause recording for a specific duration from a specific source.
    /// - Parameters:
    ///   - duration: The pause duration (15 mins, 30 mins, 1 hour, or indefinite)
    ///   - source: Where the pause was initiated from (menu bar, main app, etc.)
    func pause(for duration: PauseDuration, source: PauseSource) {
        // Stop any existing timer
        stopTimer()

        // Store for analytics
        currentPauseDuration = duration

        if let interval = duration.timeInterval {
            // Timed pause
            pauseEndTime = Date().addingTimeInterval(interval)
            isPausedIndefinitely = false
            startTimer()
        } else {
            // Indefinite pause
            pauseEndTime = nil
            isPausedIndefinitely = true
        }

        // Stop recording
        AppState.shared.isRecording = false

        // Send analytics
        AnalyticsService.shared.capture("recording_paused", [
            "source": source.rawValue,
            "pause_type": duration.analyticsValue
        ])
    }

    /// Resume recording immediately from a specific source.
    /// - Parameter source: What triggered the resume
    func resume(source: ResumeSource) {
        let wasTimed = pauseEndTime != nil
        let pauseType = currentPauseDuration?.analyticsValue ?? "unknown"

        stopTimer()
        pauseEndTime = nil
        isPausedIndefinitely = false
        currentPauseDuration = nil

        // Start recording
        AppState.shared.isRecording = true

        // Send analytics
        AnalyticsService.shared.capture("recording_resumed", [
            "source": source.rawValue,
            "was_timed": wasTimed,
            "original_pause_type": pauseType
        ])
    }

    // MARK: - Timer Management

    private func startTimer() {
        timer?.invalidate()

        // Fire every second to update the countdown display
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }

        // Ensure timer fires even when menu is open (modal runloop)
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timerTick() {
        // Trigger UI update by notifying observers
        objectWillChange.send()

        // Check if pause has expired
        checkAndResumeIfExpired()
    }

    private func checkAndResumeIfExpired() {
        guard let end = pauseEndTime else { return }

        if Date() >= end {
            resume(source: .timerExpired)
        }
    }

    // MARK: - Wake Notification

    private func registerForWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    private func handleWake() {
        // If we were on a timed pause and it has now expired, auto-resume
        // This handles the case where computer slept past the pause end time
        if let end = pauseEndTime, Date() >= end {
            resume(source: .wakeFromSleep)
        }
        // If paused indefinitely, stay paused (no action needed)
    }
}
