//
//  UpdaterManager.swift
//  Dayflow
//
//  Thin wrapper around Sparkle to expose simple update actions/state to SwiftUI.
//

import Foundation
import Sparkle

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
    }

    nonisolated func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        print("[Sparkle] Automatic checks disabled; no schedule")
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in
            print("[Sparkle] Will install update: \(item.versionString)")
            AppDelegate.allowTermination = true
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
        }
        return true
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Task { @MainActor in
            print("[Sparkle] Updater will relaunch application")
            AppDelegate.allowTermination = true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice != .install {
            Task { @MainActor in
                print("[Sparkle] User choice \(choice) for update \(item.versionString); disabling auto termination")
                AppDelegate.allowTermination = false
            }
        }
    }
    
    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        print("[Sparkle] finished cycle: \(updateCheck) error=\(String(describing: error))")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.updateAvailable = true
			self.latestVersionString = item.displayVersionString
            self.statusText = "Update available: v\(self.latestVersionString ?? "?")"
            self.isChecking = false
            AppDelegate.allowTermination = false
            print("[Sparkle] Valid update found: \(item.versionString)")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.updateAvailable = false
            self.statusText = "Latest version"
            self.isChecking = false
            AppDelegate.allowTermination = false
            print("[Sparkle] No update available")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // If silent install failed due to requiring interaction (auth, permission),
        // fall back to interactive flow so the user can authorize.
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        print("[Sparkle] updater error: \(domain) \(code) - \(error.localizedDescription)")
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
            if needsInteraction {
                // Trigger interactive updater; if a download already exists, Sparkle resumes and prompts
                self.interactiveController.updater.checkForUpdates()
            }
        }
    }
}
