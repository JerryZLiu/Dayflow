//
//  NotificationService.swift
//  Dayflow
//
//  Main orchestrator for journal reminder notifications.
//  Handles scheduling, permission requests, and notification tap responses.
//

import Foundation
@preconcurrency import UserNotifications
import AppKit

@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    @Published private(set) var permissionGranted: Bool = false

    override private init() {
        super.init()
    }

    // MARK: - Public Methods

    /// Call this from AppDelegate.applicationDidFinishLaunching
    func start() {
        center.delegate = self

        // Check current permission status
        Task {
            await checkPermissionStatus()

            // Reschedule if reminders are enabled
            if NotificationPreferences.isEnabled {
                scheduleReminders()
            }
        }
    }

    /// Request notification permission from the user
    @discardableResult
    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                self.permissionGranted = granted
            }
            return granted
        } catch {
            print("[NotificationService] Permission request failed: \(error)")
            return false
        }
    }

    /// Schedule all reminders based on current preferences
    func scheduleReminders() {
        // First, cancel all existing journal reminders
        cancelAllReminders()

        let weekdays = NotificationPreferences.weekdays
        guard !weekdays.isEmpty else { return }

        // Schedule intention reminders
        let intentionHour = NotificationPreferences.intentionHour
        let intentionMinute = NotificationPreferences.intentionMinute

        for weekday in weekdays {
            scheduleNotification(
                identifier: "journal.intentions.weekday.\(weekday)",
                title: "Set your intentions",
                body: "Take a moment to plan your day with Dayflow.",
                hour: intentionHour,
                minute: intentionMinute,
                weekday: weekday
            )
        }

        // Schedule reflection reminders
        let reflectionHour = NotificationPreferences.reflectionHour
        let reflectionMinute = NotificationPreferences.reflectionMinute

        for weekday in weekdays {
            scheduleNotification(
                identifier: "journal.reflections.weekday.\(weekday)",
                title: "Time to reflect",
                body: "How did your day go? Capture your thoughts.",
                hour: reflectionHour,
                minute: reflectionMinute,
                weekday: weekday
            )
        }

        NotificationPreferences.isEnabled = true
        print("[NotificationService] Scheduled \(weekdays.count * 2) notifications")
    }

    /// Cancel all journal reminder notifications
    func cancelAllReminders() {
        let center = self.center  // Capture locally while on MainActor
        center.getPendingNotificationRequests { requests in
            let journalIds = requests
                .filter { $0.identifier.hasPrefix("journal.") }
                .map { $0.identifier }

            center.removePendingNotificationRequests(withIdentifiers: journalIds)
            print("[NotificationService] Cancelled \(journalIds.count) pending notifications")
        }
    }

    // MARK: - Private Methods

    private func checkPermissionStatus() async {
        let settings = await center.notificationSettings()
        await MainActor.run {
            self.permissionGranted = settings.authorizationStatus == .authorized
        }
    }

    private func scheduleNotification(
        identifier: String,
        title: String,
        body: String,
        hour: Int,
        minute: Int,
        weekday: Int
    ) {
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        dateComponents.weekday = weekday

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "journal_reminder"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error = error {
                print("[NotificationService] Failed to schedule \(identifier): \(error)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Called when user taps on a notification
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier

        guard identifier.hasPrefix("journal.") else {
            completionHandler()
            return
        }

        Task { @MainActor in
            // Show badge
            NotificationBadgeManager.shared.showBadge()

            // Post notification to navigate to Journal
            NotificationCenter.default.post(name: .navigateToJournal, object: nil)

            // Set flag for cold launch (skip video)
            AppDelegate.pendingNavigationToJournal = true

            // Activate app and bring to foreground
            NSApp.activate(ignoringOtherApps: true)
            // Only show Dock icon if user preference allows it
            let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
            if showDockIcon && NSApp.activationPolicy() == .accessory {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        completionHandler()
    }

    /// Called when notification fires while app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        print("[NotificationService] willPresent called for: \(identifier)")

        guard identifier.hasPrefix("journal.") else {
            print("[NotificationService] willPresent: not a journal notification, skipping")
            completionHandler([])
            return
        }

        Task { @MainActor in
            // Show badge even when app is in foreground
            print("[NotificationService] willPresent: showing badge")
            NotificationBadgeManager.shared.showBadge()
        }

        // Show the notification banner even when app is active
        completionHandler([.banner, .sound, .badge])
    }
}
