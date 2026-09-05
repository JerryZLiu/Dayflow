//
//  UpdaterManager.swift
//  Dayflow
//
//  Thin wrapper around Sparkle to expose simple update actions/state to SwiftUI.
//

import AppKit
import Foundation
import OSLog
import Sparkle

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
  static let shared = UpdaterManager()

  private let userDriver = SilentUserDriver()
  private lazy var updater: SPUUpdater = {
    SPUUpdater(
      hostBundle: .main,
      applicationBundle: .main,
      userDriver: userDriver,
      delegate: self)
  }()

  // Fallback interactive updater for cases requiring authorization/UI
  private lazy var interactiveController: SPUStandardUpdaterController = {
    SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: self,
      userDriverDelegate: nil)
  }()

  // Simple state for Settings UI
  @Published var isChecking = false
  @Published var statusText: String = ""
  @Published var updateAvailable = false
  @Published var latestVersionString: String? = nil

  // Mirrors of SPUUpdater properties. Read from Sparkle via KVO in setupObservers(),
  // written back through the explicit setters below (which are the only path the
  // Settings UI uses — so we never overwrite the user's saved preference at launch).
  @Published private(set) var automaticallyChecksForUpdates: Bool = false
  @Published private(set) var automaticallyDownloadsUpdates: Bool = false

  // Read-only view of SPUUpdater.canCheckForUpdates — the "Check now" button
  // binds to this to dim itself while Sparkle is mid-check.
  @Published private(set) var canCheckForUpdates: Bool = false

  // Captured from SUAppcastItem.releaseNotesURL in didFindValidUpdate, kept around
  // so the "View changelog" link in Settings stays valid until the next check.
  @Published private(set) var pendingReleaseNotesURL: URL? = nil

  private let logger = Logger(subsystem: "com.dayflow.app", category: "sparkle")
  private var observations: [NSKeyValueObservation] = []

  private override init() {
    super.init()

    // Print what Sparkle thinks the settings are *before* starting:
    print("[Sparkle] bundleId=\(Bundle.main.bundleIdentifier ?? "nil")")
    print(
      "[Sparkle] Info SUFeedURL = \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") ?? "nil")"
    )
    print(
      "[Sparkle] Info SUPublicEDKey = \(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") ?? "nil")"
    )

    do {
      try updater.start()
      // Sync the driver flag synchronously so there's no race window where the
      // driver's default (true) is active before the KVO .initial fires.
      userDriver.allowsSilentInstall = updater.automaticallyDownloadsUpdates
      print("[Sparkle] updater.start() OK")
      print("[Sparkle] feedURL=\(updater.feedURL?.absoluteString ?? "nil")")
      print("[Sparkle] autoChecks=\(updater.automaticallyChecksForUpdates)")
      print("[Sparkle] autoDownloads=\(updater.automaticallyDownloadsUpdates)")
      print("[Sparkle] interval=\(Int(updater.updateCheckInterval))")
    } catch {
      print("[Sparkle] updater.start() FAILED: \(error)")
    }

    // KVO mirrors of SPUUpdater settings. Sparkle persists these to NSUserDefaults,
    // so .initial pulls the user's saved preference from the previous session.
    setupObservers()
  }

  private func setupObservers() {
    observations = [
      updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) {
        [weak self] _, change in
        let newValue = change.newValue ?? false
        Task { @MainActor in
          guard let self = self else { return }
          self.automaticallyChecksForUpdates = newValue
        }
      },
      updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) {
        [weak self] _, change in
        let newValue = change.newValue ?? false
        Task { @MainActor in
          guard let self = self else { return }
          self.automaticallyDownloadsUpdates = newValue
          // Keep SilentUserDriver in lockstep so silent install is gated on the
          // download/install preference, not the check preference.
          self.userDriver.allowsSilentInstall = newValue
        }
      },
      updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
        [weak self] _, change in
        Task { @MainActor in
          self?.canCheckForUpdates = change.newValue ?? false
        }
      },
    ]
  }

  func checkForUpdates(showUI: Bool = false) {
    isChecking = true
    statusText = "Checking…"
    track(
      "sparkle_check_triggered",
      [
        "mode": showUI ? "manual" : "background"
      ])
    if showUI {
      // Start UI controller on demand so it can present prompts as needed
      interactiveController.startUpdater()
      interactiveController.checkForUpdates(nil)
    } else {
      // Trigger a background check immediately; the scheduler will also keep running
      updater.checkForUpdatesInBackground()
    }
  }

  // MARK: - User-facing update preferences
  //
  // These setters are the only path the Settings UI uses to change Sparkle
  // settings. Writing through SPUUpdater (rather than the @Published mirrors)
  // is what makes the change persist to NSUserDefaults, and is what the
  // Sparkle docs require: "Only set this property if the user wants to
  // change the default via a user settings option."

  func setAutomaticallyChecksForUpdates(_ newValue: Bool) {
    guard newValue != updater.automaticallyChecksForUpdates else { return }
    updater.automaticallyChecksForUpdates = newValue
    track(
      "sparkle_setting_changed",
      [
        "setting": "automaticallyChecksForUpdates",
        "value": newValue,
      ])
  }

  func setAutomaticallyDownloadsUpdates(_ newValue: Bool) {
    guard newValue != updater.automaticallyDownloadsUpdates else { return }
    updater.automaticallyDownloadsUpdates = newValue
    track(
      "sparkle_setting_changed",
      [
        "setting": "automaticallyDownloadsUpdates",
        "value": newValue,
      ])
  }

  /// Opens the release-notes URL captured from the most recent update check.
  /// No-op if no update has been found yet, or if the feed didn't include notes.
  func openReleaseNotes() {
    guard let url = pendingReleaseNotesURL,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return }
    NSWorkspace.shared.open(url)
  }
}

extension UpdaterManager: SPUUpdaterDelegate {
  nonisolated func feedParameters(
    for updater: SPUUpdater,
    sendingSystemProfile sendingProfile: Bool
  ) -> [[String: String]] {
    var parameters: [[String: String]] = [
      [
        "key": "analytics_opt_in",
        "value": AnalyticsService.shared.isOptedIn ? "1" : "0",
        "displayKey": "Analytics opt-in",
        "displayValue": AnalyticsService.shared.isOptedIn ? "Enabled" : "Disabled",
      ]
    ]

    if let postHogId = AnalyticsService.shared.postHogDistinctIdForAppcast() {
      parameters.append([
        "key": "phid",
        "value": postHogId,
        "displayKey": "Anonymous analytics ID",
        "displayValue": "Present",
      ])
    }

    let info = Bundle.main.infoDictionary
    if let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty {
      parameters.append([
        "key": "v",
        "value": version,
        "displayKey": "Version",
        "displayValue": version,
      ])
    }
    if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
      parameters.append([
        "key": "b",
        "value": build,
        "displayKey": "Build",
        "displayValue": build,
      ])
    }

    return parameters
  }

  private nonisolated static func isNoUpdateSparkleError(domain: String, code: Int) -> Bool {
    domain == "SUSparkleErrorDomain" && code == 1001
  }

  nonisolated func updater(
    _ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval
  ) {
    print("[Sparkle] Next scheduled check in \(Int(delay))s")
    logger.debug("Next Sparkle check scheduled in \(Int(delay))s")
  }

  nonisolated func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
    print("[Sparkle] Automatic checks disabled; no schedule")
    logger.debug("Sparkle automatic checks disabled")
  }

  nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    Task { @MainActor in
      print("[Sparkle] Will install update: \(item.versionString)")
      AppDelegate.allowTermination = true
      self.track("sparkle_install_will_start", self.props(for: item))
    }
  }

  nonisolated func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    // Convert Sparkle's deferred "install on quit" into an immediate install
    Task { @MainActor in
      print("[Sparkle] Immediate install requested for update: \(item.versionString)")
      AppDelegate.allowTermination = true
      immediateInstallHandler()
      self.track("sparkle_install_immediate", self.props(for: item))
    }
    return true
  }

  nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    Task { @MainActor in
      print("[Sparkle] Updater will relaunch application")
      AppDelegate.allowTermination = true
      self.track("sparkle_app_relaunching")
    }
  }

  nonisolated func updater(
    _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    Task { @MainActor in
      if choice != .install {
        print(
          "[Sparkle] User choice \(choice) for update \(item.versionString); disabling auto termination"
        )
        AppDelegate.allowTermination = false
      } else {
        print("[Sparkle] User confirmed install for update \(item.versionString)")
      }
      self.track(
        "sparkle_update_choice",
        self.props(for: item).merging(
          [
            "choice": String(describing: choice)
          ], uniquingKeysWith: { _, new in new }))
    }
  }

  nonisolated func updater(
    _ updater: SPUUpdater,
    didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: Error?
  ) {
    print("[Sparkle] finished cycle: \(updateCheck) error=\(String(describing: error))")
    logger.debug("Sparkle cycle finished error=\(String(describing: error))")
    Task { @MainActor in
      // Reset the spinner even when the cycle ends without a
      // didFindValidUpdate/updaterDidNotFindUpdate callback (e.g. user cancels).
      self.isChecking = false
      self.track(
        "sparkle_cycle_finished",
        [
          "error_present": error != nil
        ])
    }
  }

  nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    Task { @MainActor in
      self.updateAvailable = true
      self.latestVersionString = item.displayVersionString
      self.statusText = "Update available: v\(self.latestVersionString ?? "?")"
      self.isChecking = false
      self.pendingReleaseNotesURL = item.releaseNotesURL
      AppDelegate.allowTermination = false
      print("[Sparkle] Valid update found: \(item.versionString)")
      self.track("sparkle_update_found", self.props(for: item))
    }
  }

  nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    Task { @MainActor in
      self.updateAvailable = false
      self.pendingReleaseNotesURL = nil
      self.statusText = "Latest version"
      self.isChecking = false
      AppDelegate.allowTermination = false
      print("[Sparkle] No update available")
      self.track("sparkle_update_not_found")
    }
  }

  nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    // If silent install failed due to requiring interaction (auth, permission),
    // fall back to interactive flow so the user can authorize.
    let nsError = error as NSError
    let domain = nsError.domain
    let code = nsError.code
    let isNoUpdateError = Self.isNoUpdateSparkleError(domain: domain, code: code)

    if isNoUpdateError {
      print("[Sparkle] updater no-update result via error callback: \(domain) \(code)")
      logger.debug("Sparkle no-update callback via error path \(domain) \(code)")
    } else {
      print("[Sparkle] updater error: \(domain) \(code) - \(error.localizedDescription)")
      logger.error("Sparkle error \(domain) \(code): \(error.localizedDescription)")
    }

    let needsInteraction =
      (domain == "SUSparkleErrorDomain")
      && [
        4001,  // SUAuthenticationFailure
        4008,  // SUInstallationAuthorizeLaterError
        4011,  // SUInstallationRootInteractiveError
        4012,  // SUInstallationWriteNoPermissionError
      ].contains(code)

    Task { @MainActor in
      self.isChecking = false

      if isNoUpdateError {
        self.updateAvailable = false
        self.pendingReleaseNotesURL = nil
        self.statusText = "Latest version"
        AppDelegate.allowTermination = false
        return
      }

      self.statusText = needsInteraction ? "Update needs authorization" : "Update check failed"
      AppDelegate.allowTermination = needsInteraction
      self.track(
        "sparkle_update_error",
        [
          "domain": domain,
          "code": code,
          "needs_interaction": needsInteraction,
        ])
      if needsInteraction {
        // Trigger interactive updater; if a download already exists, Sparkle resumes and prompts
        self.interactiveController.updater.checkForUpdates()
      }
    }
  }

  private func track(_ event: String, _ props: [String: Any] = [:]) {
    AnalyticsService.shared.capture(event, props)
  }

  private func props(for item: SUAppcastItem) -> [String: Any] {
    var props: [String: Any] = [
      "version": item.displayVersionString,
      "build": item.versionString,
    ]

    // Sparkle 2.6 removed `channelIdentifier`; extract it manually if present in the feed
    if let dict = item.propertiesDictionary as? [String: Any],
      let channel = (dict["sparkle:channel"] as? String) ?? (dict["channel"] as? String)
    {
      props["channel"] = channel
    } else {
      props["channel"] = "default"
    }

    return props
  }
}
