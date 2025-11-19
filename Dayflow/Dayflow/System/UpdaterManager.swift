//
//  UpdaterManager.swift
//  Dayflow
//
//  Thin wrapper around Sparkle to expose simple update actions/state to SwiftUI.
//

import Foundation
import Sparkle
import OSLog

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    private let userDriver = SilentUserDriver()
    private lazy var updater: SPUUpdater = {
        SPUUpdater(hostBundle: .main,
                   applicationBundle: .main,
                   userDriver: userDriver,
                   delegate: self)
    }()

    // Fallback interactive updater for cases requiring authorization/UI
    private lazy var interactiveController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(startingUpdater: false,
                                     updaterDelegate: self,
                                     userDriverDelegate: nil)
    }()

    // Simple state for Settings UI
    @Published var isChecking = false
    @Published var statusText: String = ""
    @Published var updateAvailable = false
    @Published var latestVersionString: String? = nil

    private let logger = Logger(subsystem: "com.dayflow.app", category: "sparkle")

    private override init() {
        super.init()

        // Print what Sparkle thinks the settings are *before* starting:
        print("[Sparkle] bundleId=\(Bundle.main.bundleIdentifier ?? "nil")")
        print("[Sparkle] Info SUFeedURL = \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") ?? "nil")")
        print("[Sparkle] Info SUPublicEDKey = \(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") ?? "nil")")

        do {
            try updater.start()
            print("[Sparkle] updater.start() OK")
            print("[Sparkle] feedURL=\(updater.feedURL?.absoluteString ?? "nil")")
            print("[Sparkle] autoChecks=\(updater.automaticallyChecksForUpdates)")
            print("[Sparkle] autoDownloads=\(updater.automaticallyDownloadsUpdates)")
            print("[Sparkle] interval=\(Int(updater.updateCheckInterval))")
        } catch {
            print("[Sparkle] updater.start() FAILED: \(error)")
        }
    }

    func checkForUpdates(showUI: Bool = false) {
        isChecking = true
        statusText = "Checking…"
        track("sparkle_check_triggered", [
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
}


extension UpdaterManager: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
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

    nonisolated func updater(_ updater: SPUUpdater,
                             willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
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

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        Task { @MainActor in
            if choice != .install {
                print("[Sparkle] User choice \(choice) for update \(item.versionString); disabling auto termination")
                AppDelegate.allowTermination = false
            } else {
                print("[Sparkle] User confirmed install for update \(item.versionString)")
            }
            self.track("sparkle_update_choice", self.props(for: item).merging([
                "choice": String(describing: choice)
            ], uniquingKeysWith: { _, new in new }))
        }
    }
    
    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        print("[Sparkle] finished cycle: \(updateCheck) error=\(String(describing: error))")
        logger.debug("Sparkle cycle finished error=\(String(describing: error))")
        Task { @MainActor in
            self.track("sparkle_cycle_finished", [
                "error_present": error != nil
            ])
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.updateAvailable = true
            self.latestVersionString = item.displayVersionString ?? item.versionString
            self.statusText = "Update available: v\(self.latestVersionString ?? "?")"
            self.isChecking = false
            AppDelegate.allowTermination = false
            print("[Sparkle] Valid update found: \(item.versionString)")
            self.track("sparkle_update_found", self.props(for: item))
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.updateAvailable = false
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
        print("[Sparkle] updater error: \(domain) \(code) - \(error.localizedDescription)")
        logger.error("Sparkle error \(domain) \(code): \(error.localizedDescription)")
        let needsInteraction = (domain == "SUSparkleErrorDomain") && [
            4001, // SUAuthenticationFailure
            4008, // SUInstallationAuthorizeLaterError
            4011, // SUInstallationRootInteractiveError
            4012  // SUInstallationWriteNoPermissionError
        ].contains(code)

        Task { @MainActor in
            self.isChecking = false
            self.statusText = needsInteraction ? "Update needs authorization" : "Update check failed"
            AppDelegate.allowTermination = needsInteraction
            self.track("sparkle_update_error", [
                "domain": domain,
                "code": code,
                "needs_interaction": needsInteraction
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
            "version": item.displayVersionString ?? item.versionString,
            "build": item.versionString
        ]

        // Sparkle 2.6 removed `channelIdentifier`; extract it manually if present in the feed
        if let dict = item.propertiesDictionary as? [String: Any],
           let channel = (dict["sparkle:channel"] as? String) ?? (dict["channel"] as? String) {
            props["channel"] = channel
        } else {
            props["channel"] = "default"
        }

        return props
    }
}
