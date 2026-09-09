import Foundation
import OSLog
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
  static let shared = LaunchAtLoginManager()

  @Published private(set) var isEnabled: Bool = false

  private let logger = Logger(subsystem: "com.dayflow.app", category: "launch_at_login")

  private init() {
    // Don't block init - refresh asynchronously
    Task {
      await refreshStatusAsync()
    }
  }

  /// Ensure the cached state is warmed up at launch so UI reflects the system toggle.
  func bootstrapDefaultPreference() {
    // Don't block app launch - refresh status asynchronously
    // SMAppService.mainApp.status makes a synchronous XPC call that can take 5+ seconds
    Task {
      await refreshStatusAsync()
    }
  }

  /// Re-sync with System Settings, e.g. if the user adds/removes Dayflow manually.
  /// This is the synchronous version for use in setEnabled() after user action.
  func refreshStatus() {
    let status = SMAppService.mainApp.status
    let enabled = (status == .enabled)
    if isEnabled != enabled {
      logger.debug(
        "Launch at login status changed → \(enabled ? "enabled" : "disabled") [status=\(String(describing: status))]"
      )
    }
    isEnabled = enabled
  }

  /// Async version that runs the XPC call off the main actor to avoid blocking
  private func refreshStatusAsync() async {
    // Run XPC call on background thread
    let status = await Task.detached(priority: .utility) {
      SMAppService.mainApp.status
    }.value

    let enabled = (status == .enabled)
    if isEnabled != enabled {
      logger.debug(
        "Launch at login status changed → \(enabled ? "enabled" : "disabled") [status=\(String(describing: status))]"
      )
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
      logger.error(
        "Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
