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

    /// Notify the user that yesterday's daily recap is ready.
    /// Called only after successful generation + DB save.
    func scheduleDailyRecapReadyNotification(forDay day: String) {
        let trimmedDay = day.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDay.isEmpty else { return }

        Task {
            var settings = await center.notificationSettings()
            var status = settings.authorizationStatus

            if status == .notDetermined {
                let granted = await requestPermission()
                settings = await center.notificationSettings()
                status = settings.authorizationStatus

                AnalyticsService.shared.capture("daily_auto_generation_notification_permission_prompt_result", [
                    "target_day": trimmedDay,
                    "granted": granted,
                    "authorization_status": Self.authorizationStatusName(status)
                ])
            }

            guard Self.canScheduleNotifications(for: status) else {
                print(
                    "[NotificationService] Skipping daily recap notification (\(trimmedDay)): " +
                    "permission_status=\(Self.authorizationStatusName(status))"
                )
                AnalyticsService.shared.capture("daily_auto_generation_notification_skipped", [
                    "target_day": trimmedDay,
                    "reason": "permission_not_authorized",
                    "authorization_status": Self.authorizationStatusName(status)
                ])
                return
            }

            enqueueDailyRecapReadyNotification(forDay: trimmedDay, settings: settings)
        }
    }

    // MARK: - Private Methods

    private func checkPermissionStatus() async {
        let settings = await center.notificationSettings()
        await MainActor.run {
            self.permissionGranted = Self.canScheduleNotifications(for: settings.authorizationStatus)
        }
    }

    private func enqueueDailyRecapReadyNotification(forDay day: String, settings: UNNotificationSettings) {
        let identifier = "daily.recap.\(day)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Your daily recap for yesterday is ready"
        content.body = "Tap to open it in Daily view."
        content.sound = .default
        content.categoryIdentifier = "daily_recap"
        content.userInfo = ["day": day]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        let authStatus = Self.authorizationStatusName(settings.authorizationStatus)
        let alertSetting = Self.notificationSettingName(settings.alertSetting)
        let soundSetting = Self.notificationSettingName(settings.soundSetting)
        center.add(request) { error in
            if let error {
                print("[NotificationService] Failed to schedule daily recap notification (\(day)): \(error)")
                AnalyticsService.shared.capture("daily_auto_generation_notification_failed", [
                    "target_day": day,
                    "error_message": String(error.localizedDescription.prefix(500)),
                    "authorization_status": authStatus,
                    "alert_setting": alertSetting,
                    "sound_setting": soundSetting
                ])
                return
            }

            AnalyticsService.shared.capture("daily_auto_generation_notification_scheduled", [
                "target_day": day,
                "authorization_status": authStatus,
                "alert_setting": alertSetting,
                "sound_setting": soundSetting
            ])
        }
    }

    private static func authorizationStatusName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "not_determined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        @unknown default:
            return "unknown"
        }
    }

    private static func canScheduleNotifications(for status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    private static func notificationSettingName(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported:
            return "not_supported"
        case .disabled:
            return "disabled"
        case .enabled:
            return "enabled"
        @unknown default:
            return "unknown"
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

    private func activateAppForNotificationTap() {
        NSApp.activate(ignoringOtherApps: true)
        let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        if showDockIcon && NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
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

        let isJournalNotification = identifier.hasPrefix("journal.")
        let isDailyRecapNotification = identifier.hasPrefix("daily.")

        guard isJournalNotification || isDailyRecapNotification else {
            completionHandler()
            return
        }

        Task { @MainActor in
            if isJournalNotification {
                NotificationBadgeManager.shared.showBadge()
                NotificationCenter.default.post(name: .navigateToJournal, object: nil)
                AppDelegate.pendingNavigationToJournal = true
                activateAppForNotificationTap()
            } else {
                let day = response.notification.request.content.userInfo["day"] as? String
                AppDelegate.pendingNavigationToDailyDay = day
                AppDelegate.pendingNavigationToJournal = false

                if let day, !day.isEmpty {
                    NotificationCenter.default.post(
                        name: .navigateToDaily,
                        object: nil,
                        userInfo: ["day": day]
                    )
                    AnalyticsService.shared.capture("daily_auto_generation_notification_clicked", [
                        "target_day": day
                    ])
                } else {
                    NotificationCenter.default.post(name: .navigateToDaily, object: nil)
                    AnalyticsService.shared.capture("daily_auto_generation_notification_clicked", [
                        "target_day": "unknown"
                    ])
                }

                activateAppForNotificationTap()
            }
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

        if identifier.hasPrefix("journal.") {
            Task { @MainActor in
                print("[NotificationService] willPresent: showing badge")
                NotificationBadgeManager.shared.showBadge()
            }

            completionHandler([.banner, .sound, .badge])
            return
        }

        if identifier.hasPrefix("daily.") {
            completionHandler([.banner, .sound])
            return
        }

        print("[NotificationService] willPresent: unknown notification identifier, skipping")
        completionHandler([])
    }
}
