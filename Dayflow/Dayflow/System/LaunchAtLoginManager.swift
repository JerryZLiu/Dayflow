import Foundation
import ServiceManagement
import OSLog

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false

    private let logger = Logger(subsystem: "com.dayflow.app", category: "launch_at_login")

    private init() {
        refreshStatus()
    }

    /// Ensure the cached state is warmed up at launch so UI reflects the system toggle.
    func bootstrapDefaultPreference() {
        refreshStatus()
    }

    /// Re-sync with System Settings, e.g. if the user adds/removes Dayflow manually.
    func refreshStatus() {
        let status = SMAppService.mainApp.status
        let enabled = (status == .enabled)
        if isEnabled != enabled {
            logger.debug("Launch at login status changed → \(enabled ? "enabled" : "disabled") [status=\(String(describing: status))]")
        }
        isEnabled = enabled
    }

    /// Register or unregister the main app as a login item.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enabled
            logger.info("Launch at login \(enabled ? "enabled" : "disabled") successfully")
        } catch {
            logger.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }
}
