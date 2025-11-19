import AppKit
import Sparkle

// A no-UI user driver that silently installs updates immediately
final class SilentUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        print("[Sparkle] Permission request; responding with automatic checks + downloads")
        // Enable automatic checks & downloads by default; do not send system profile
        let response = SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            automaticUpdateDownloading: NSNumber(value: true),
            sendSystemProfile: false
        )
        AnalyticsService.shared.capture("sparkle_permission_requested", [
            "automatic_checks": true,
            "automatic_downloads": true
        ])
        reply(response)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // No UI; ignore
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        print("[Sparkle] Update found: \(appcastItem.displayVersionString ?? appcastItem.versionString)")
        // Always proceed to install
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // No-op
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // No-op
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        AnalyticsService.shared.capture("sparkle_user_driver_error", [
            "domain": nsError.domain,
            "code": nsError.code
        ])
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        // No UI
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        // No UI
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        // No UI
    }

    func showDownloadDidStartExtractingUpdate() {
        // No UI
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        // No UI
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        print("[Sparkle] Ready to install; allowing termination")
        Task { @MainActor in
            AppDelegate.allowTermination = true
            AnalyticsService.shared.capture("sparkle_install_ready")
            reply(.install)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        // No UI; don't retry programmatically here
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        print("[Sparkle] Update installed; relaunched=\(relaunched)")
        AnalyticsService.shared.capture("sparkle_install_completed", [
            "relaunched": relaunched
        ])
        acknowledgement()
    }

    func showUpdateInFocus() {
        // No UI
    }

    func dismissUpdateInstallation() {
        // No UI
    }
}
