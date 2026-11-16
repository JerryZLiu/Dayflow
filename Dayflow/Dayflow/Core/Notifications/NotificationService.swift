//
//  NotificationService.swift
//  Dayflow
//
//  Main orchestrator for Daily and Weekly notifications.
//  Handles scheduling, permission requests, and notification tap responses.
//

import AppKit
import Foundation
@preconcurrency import UserNotifications

private let providerProblemSignInAction = "provider.problem.signIn"
private let providerProblemLaterAction = "provider.problem.later"

enum WeeklyUnlockNotificationScheduleResult {
  case scheduled
  case denied
  case failed
}

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
    registerProviderProblemActions()

    // Check current permission status
    Task {
      await retireJournalNotifications()
      await checkPermissionStatus()
    }
  }

  func clearSupportReplyNotification() {
    center.removeDeliveredNotifications(withIdentifiers: ["support.reply"])
    center.removePendingNotificationRequests(withIdentifiers: ["support.reply"])
  }

  func notifySupportReply() {
    notifyChatReply()
  }

  func clearFlowWaitlistReplyNotification() {
    center.removeDeliveredNotifications(withIdentifiers: ["flow.waitlist.reply"])
    center.removePendingNotificationRequests(withIdentifiers: ["flow.waitlist.reply"])
  }

  func notifyFlowWaitlistReply(sessionKey: String) {
    notifyChatReply(flowSessionKey: sessionKey)
  }

  private func notifyChatReply(flowSessionKey: String? = nil) {
    Task {
      var status = await authorizationStatus()
      if status == .notDetermined {
        await requestPermission()
        status = await authorizationStatus()
      }
      guard Self.canScheduleNotifications(for: status) else { return }
      let badges = NotificationBadgeManager.shared
      if let flowSessionKey {
        guard badges.flowWaitlistSessionKey == flowSessionKey, badges.flowWaitlistUnreadCount > 0
        else { return }
      } else {
        guard badges.supportUnreadCount > 0 else { return }
      }
      let isFlow = flowSessionKey != nil
      let identifier = isFlow ? "flow.waitlist.reply" : "support.reply"
      let content = UNMutableNotificationContent()
      content.title = String(localized: "New reply from Dayflow")
      content.body =
        isFlow
        ? String(localized: "You have a new reply about Flow. Open Flow to read it.")
        : String(localized: "You have a new support reply. Open Support to read it.")
      content.sound = .default
      do {
        try await center.add(
          UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
      } catch {
        print("[NotificationService] Chat notification failed (\(identifier)): \(error)")
      }
    }
  }

  // MARK: - Provider problems

  private static let providerProblemIdentifier = "provider.problem"
  private static let providerProblemSignInCategory = "provider_problem_sign_in"
  private static let providerProblemLastSentDayByKindKey =
    "providerProblemNotificationLastDayByKind"

  /// Adds the Sign in and Later buttons to the signed-out notification.
  private func registerProviderProblemActions() {
    let signIn = UNNotificationAction(
      identifier: providerProblemSignInAction,
      title: String(localized: "Sign in"),
      options: [.foreground])
    let later = UNNotificationAction(
      identifier: providerProblemLaterAction,
      title: String(localized: "Later"),
      options: [])
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.providerProblemSignInCategory,
        actions: [signIn, later],
        intentIdentifiers: [])
    ])
  }

  /// Tells the user about a provider problem only they can fix, when Dayflow isn't in front
  /// of them. At most once a day per kind of problem, and never asks for permission.
  func notifyProviderProblem(_ payload: TimelineFailureToastPayload) {
    guard !NSApp.isActive else { return }

    let logicalDay = Date().getDayInfoFor4AMBoundary().dayString
    let lastSentDayByKind =
      UserDefaults.standard.dictionary(forKey: Self.providerProblemLastSentDayByKindKey)
      as? [String: String] ?? [:]
    guard lastSentDayByKind[payload.failureKind] != logicalDay else { return }

    Task {
      let status = await authorizationStatus()
      guard Self.canScheduleNotifications(for: status) else { return }

      // Checked again here because another batch may have sent it while permission was read.
      var sentDayByKind =
        UserDefaults.standard.dictionary(forKey: Self.providerProblemLastSentDayByKindKey)
        as? [String: String] ?? [:]
      guard sentDayByKind[payload.failureKind] != logicalDay else { return }
      sentDayByKind[payload.failureKind] = logicalDay
      UserDefaults.standard.set(
        sentDayByKind, forKey: Self.providerProblemLastSentDayByKindKey)

      let content = UNMutableNotificationContent()
      content.title = payload.title ?? String(localized: "Dayflow needs a hand")
      var body = payload.message
      if let waiting = payload.waitingText {
        body += " " + String(localized: "\(waiting) of recording is waiting.")
      }
      content.body = body
      content.sound = .default
      if let signInProvider = payload.signInProvider {
        content.categoryIdentifier = Self.providerProblemSignInCategory
        content.userInfo = ["sign_in_provider": signInProvider]
      }

      do {
        try await center.add(
          UNNotificationRequest(
            identifier: Self.providerProblemIdentifier, content: content, trigger: nil))
        AnalyticsService.shared.capture(
          "provider_problem_notification_sent", payload.analyticsProps)
      } catch {
        print("[NotificationService] Provider problem notification failed: \(error)")
      }
    }
  }

  func clearProviderProblemNotification() {
    center.removeDeliveredNotifications(withIdentifiers: [Self.providerProblemIdentifier])
  }

  /// One-time nudge after onboarding: the first real timeline cards are ready.
  /// Never prompts for permission here; the welcome tour asks up front.
  func notifyFirstCardsReady() {
    Task {
      let status = await authorizationStatus()
      guard Self.canScheduleNotifications(for: status) else { return }

      let content = UNMutableNotificationContent()
      content.title = String(localized: "Your first Dayflow cards are ready")
      content.body = String(
        localized: "Take a look at what Dayflow picked up from your last few minutes of work.")
      content.sound = .default
      do {
        try await center.add(
          UNNotificationRequest(
            identifier: "gettingStarted.firstCards", content: content, trigger: nil))
        AnalyticsService.shared.capture("getting_started_first_cards_notification_sent")
      } catch {
        print("[NotificationService] First cards notification failed: \(error)")
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
      print("[NotificationService] requestPermission granted=\(granted)")
      return granted
    } catch {
      print("[NotificationService] Permission request failed: \(error)")
      return false
    }
  }

  /// Read the current notification authorization status and refresh the cached flag.
  func authorizationStatus() async -> UNAuthorizationStatus {
    let settings = await center.notificationSettings()
    let authorizationStatus = settings.authorizationStatus
    await MainActor.run {
      self.permissionGranted = Self.canScheduleNotifications(for: authorizationStatus)
    }
    return authorizationStatus
  }

  /// Remove reminders left by the retired Journal feature without touching Daily or Weekly.
  private func retireJournalNotifications() async {
    let pending = await center.pendingNotificationRequests()
    let pendingIDs = pending.filter { $0.identifier.hasPrefix("journal.") }.map(\.identifier)
    center.removePendingNotificationRequests(withIdentifiers: pendingIDs)

    let delivered = await center.deliveredNotifications()
    let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix("journal.") }
    center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
  }

  /// Notify the user that yesterday's daily recap is ready.
  /// Called only after successful generation + DB save.
  func scheduleDailyRecapReadyNotification(forDay day: String) {
    let trimmedDay = day.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDay.isEmpty else {
      print("[NotificationService] Skipping daily recap notification: empty day")
      return
    }
    print("[NotificationService] scheduleDailyRecapReadyNotification requested day=\(trimmedDay)")

    Task {
      var settings = await center.notificationSettings()
      var status = settings.authorizationStatus
      print(
        "[NotificationService] daily recap notification settings day=\(trimmedDay) "
          + "authorization_status=\(Self.authorizationStatusName(status))"
      )

      if status == .notDetermined {
        let granted = await requestPermission()
        settings = await center.notificationSettings()
        status = settings.authorizationStatus
        print(
          "[NotificationService] daily recap permission prompt result day=\(trimmedDay) "
            + "granted=\(granted) final_status=\(Self.authorizationStatusName(status))"
        )

        AnalyticsService.shared.capture(
          "daily_auto_generation_notification_permission_prompt_result",
          [
            "target_day": trimmedDay,
            "granted": granted,
            "authorization_status": Self.authorizationStatusName(status),
          ])
      }

      guard Self.canScheduleNotifications(for: status) else {
        print(
          "[NotificationService] Skipping daily recap notification (\(trimmedDay)): "
            + "permission_status=\(Self.authorizationStatusName(status))"
        )
        AnalyticsService.shared.capture(
          "daily_auto_generation_notification_skipped",
          [
            "target_day": trimmedDay,
            "reason": "permission_not_authorized",
            "authorization_status": Self.authorizationStatusName(status),
          ])
        return
      }

      enqueueDailyRecapReadyNotification(forDay: trimmedDay, settings: settings)
    }
  }

  func scheduleWeeklyUnlockNotification(at unlockDate: Date) async
    -> WeeklyUnlockNotificationScheduleResult
  {
    var settings = await center.notificationSettings()
    var status = settings.authorizationStatus

    if status == .notDetermined {
      _ = await requestPermission()
      settings = await center.notificationSettings()
      status = settings.authorizationStatus
    }

    guard Self.canScheduleNotifications(for: status) else {
      print(
        "[NotificationService] Skipping weekly unlock notification: "
          + "permission_status=\(Self.authorizationStatusName(status))"
      )
      return .denied
    }

    return await enqueueWeeklyUnlockNotification(at: unlockDate, settings: settings)
  }

  func cancelWeeklyUnlockNotification() {
    center.removePendingNotificationRequests(withIdentifiers: ["weekly.unlock"])
  }

  // MARK: - Private Methods

  private func checkPermissionStatus() async {
    let settings = await center.notificationSettings()
    await MainActor.run {
      self.permissionGranted = Self.canScheduleNotifications(for: settings.authorizationStatus)
    }
  }

  private func enqueueDailyRecapReadyNotification(
    forDay day: String, settings: UNNotificationSettings
  ) {
    let identifier = "daily.recap.\(day)"
    print(
      "[NotificationService] enqueue daily recap identifier=\(identifier) "
        + "day=\(day) alert_setting=\(Self.notificationSettingName(settings.alertSetting)) "
        + "sound_setting=\(Self.notificationSettingName(settings.soundSetting))"
    )
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
    print("[NotificationService] removed pending notification identifier=\(identifier)")

    let content = UNMutableNotificationContent()
    content.title = String(localized: "Your daily recap for yesterday is ready")
    content.body = String(localized: "Tap to open it in Daily view.")
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
        print(
          "[NotificationService] Failed to schedule daily recap notification (\(day)): \(error)")
        AnalyticsService.shared.capture(
          "daily_auto_generation_notification_failed",
          [
            "target_day": day,
            "error_message": String(error.localizedDescription.prefix(500)),
            "authorization_status": authStatus,
            "alert_setting": alertSetting,
            "sound_setting": soundSetting,
          ])
        return
      }
      print(
        "[NotificationService] Scheduled daily recap notification "
          + "identifier=\(identifier) day=\(day)"
      )

      Task { @MainActor in
        NotificationBadgeManager.shared.registerDailyRecapReady(forDay: day)
      }

      AnalyticsService.shared.capture(
        "daily_auto_generation_notification_scheduled",
        [
          "target_day": day,
          "authorization_status": authStatus,
          "alert_setting": alertSetting,
          "sound_setting": soundSetting,
        ])
    }
  }

  private func enqueueWeeklyUnlockNotification(
    at unlockDate: Date,
    settings: UNNotificationSettings
  ) async -> WeeklyUnlockNotificationScheduleResult {
    let identifier = "weekly.unlock"
    let interval = max(1, unlockDate.timeIntervalSinceNow)

    center.removePendingNotificationRequests(withIdentifiers: [identifier])

    let content = UNMutableNotificationContent()
    content.title = String(localized: "Weekly view is ready")
    content.body = String(localized: "Tap to open your weekly review.")
    content.sound = .default
    content.categoryIdentifier = "weekly_unlock"

    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
    )

    return await withCheckedContinuation { continuation in
      center.add(request) { error in
        if let error {
          print("[NotificationService] Failed to schedule weekly unlock notification: \(error)")
          continuation.resume(returning: .failed)
          return
        }

        print(
          "[NotificationService] Scheduled weekly unlock notification "
            + "identifier=\(identifier) seconds=\(Int(interval.rounded())) "
            + "alert_setting=\(Self.notificationSettingName(settings.alertSetting)) "
            + "sound_setting=\(Self.notificationSettingName(settings.soundSetting))"
        )
        continuation.resume(returning: .scheduled)
      }
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

  private func activateAppForNotificationTap() {
    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    if showDockIcon && NSApp.activationPolicy() == .accessory {
      NSApp.setActivationPolicy(.regular)
    }

    NSApp.unhide(nil)
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)
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
    let day = response.notification.request.content.userInfo["day"] as? String
    print(
      "[NotificationService] didReceive notification identifier=\(identifier) "
        + "action=\(response.actionIdentifier) day=\(day ?? "nil")"
    )

    let isDailyRecapNotification = identifier.hasPrefix("daily.")
    let isWeeklyUnlockNotification = identifier.hasPrefix("weekly.")

    let isSupportNotification = identifier.hasPrefix("support.")
    let isFlowNotification = identifier == "flow.waitlist.reply"
    let isGettingStartedNotification = identifier.hasPrefix("gettingStarted.")
    let isProviderProblemNotification = identifier.hasPrefix("provider.")
    let actionIdentifier = response.actionIdentifier
    let signInProvider =
      (response.notification.request.content.userInfo["sign_in_provider"]
      as? String).flatMap(LLMProviderID.init(rawValue:))
    guard
      isDailyRecapNotification || isWeeklyUnlockNotification || isSupportNotification
        || isFlowNotification || isGettingStartedNotification || isProviderProblemNotification
    else {
      completionHandler()
      return
    }

    Task { @MainActor in
      if isProviderProblemNotification {
        AnalyticsService.shared.capture(
          "provider_problem_notification_clicked", ["action": actionIdentifier])
        guard actionIdentifier != providerProblemLaterAction,
          actionIdentifier != UNNotificationDismissActionIdentifier
        else { return }
        AppDelegate.pendingNotificationNavigationDestination = .timeline
        activateAppForNotificationTap()
        if actionIdentifier == providerProblemSignInAction, let signInProvider {
          ProviderSignIn.shared.start(signInProvider, source: "notification")
        }
        // If the main window is still opening, it picks the request up when it appears.
        ProviderProblemCenter.shared.showCardAgain()
      } else if isGettingStartedNotification {
        AnalyticsService.shared.capture("getting_started_first_cards_notification_clicked")
        AppDelegate.pendingNotificationNavigationDestination = .timeline
        activateAppForNotificationTap()
      } else if isFlowNotification {
        AppDelegate.pendingNotificationNavigationDestination = .flow
        activateAppForNotificationTap()
      } else if isSupportNotification {
        AppDelegate.pendingNotificationNavigationDestination = .support
        activateAppForNotificationTap()
      } else if isDailyRecapNotification {
        AppDelegate.pendingNotificationNavigationDestination = .daily(day: day)

        if let day, !day.isEmpty {
          AnalyticsService.shared.capture(
            "daily_auto_generation_notification_clicked",
            [
              "target_day": day
            ])
          print("[NotificationService] didReceive daily notification navigation target_day=\(day)")
        } else {
          AnalyticsService.shared.capture(
            "daily_auto_generation_notification_clicked",
            [
              "target_day": "unknown"
            ])
          print("[NotificationService] didReceive daily notification navigation target_day=unknown")
        }

        activateAppForNotificationTap()
      } else {
        AppDelegate.pendingNotificationNavigationDestination = .weekly
        activateAppForNotificationTap()
        print(
          "[NotificationService] didReceive weekly unlock notification handled "
            + "identifier=\(identifier)"
        )
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
    let day = notification.request.content.userInfo["day"] as? String
    print("[NotificationService] willPresent identifier=\(identifier) day=\(day ?? "nil")")

    if identifier.hasPrefix("daily.") {
      print("[NotificationService] willPresent options=banner,sound identifier=\(identifier)")
      completionHandler([.banner, .sound])
      return
    }

    if identifier.hasPrefix("support.") || identifier == "flow.waitlist.reply" {
      completionHandler([.banner, .sound])
      return
    }

    if identifier.hasPrefix("weekly.") {
      print("[NotificationService] willPresent options=banner,sound identifier=\(identifier)")
      completionHandler([.banner, .sound])
      return
    }

    if identifier.hasPrefix("provider.") {
      completionHandler([.banner, .sound])
      return
    }

    // Someone already looking at Dayflow sees the cards arrive; no banner needed.
    if identifier.hasPrefix("gettingStarted.") {
      completionHandler([])
      return
    }

    print("[NotificationService] willPresent: unknown notification identifier, skipping")
    completionHandler([])
  }
}
